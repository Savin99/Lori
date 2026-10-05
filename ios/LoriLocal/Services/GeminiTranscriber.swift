import Foundation
import CryptoKit

/// Расшифровка через Gemini.
///
/// Документация Google от 27 августа 2026: `gemini-3.5-transcribe` берёт **до часа
/// аудио одним запросом** (до 30 минут, если нужны таймкоды слов или разделение
/// говорящих), для длинных записей рекомендуется отдавать файл через Files API, а
/// тайминги слов приходят нативно — `start_offset`/`end_offset`, плюс `speaker`.
///
/// **Нарезка здесь есть, и она не про предел сервиса.** Документация Google говорит
/// прямо: `timestamp_granularities` документированы только как `["word"]`, они
/// несовместимы с `custom_vocabulary` и «degrade transcription accuracy». Значит в
/// режиме «Точность» время из сервиса не достать вовсе, и единственное честное время —
/// границы того куска, который отправили мы сами. Поэтому запись режется на части
/// длиной `TranscriptionSettings.geminiPartSeconds`, границы садятся на паузы, и каждая
/// часть даёт отметку времени в расшифровке.
///
/// Прошлая пятиминутная нарезка была убрана как лишняя точка отказа, и урок из неё
/// учтён: части заходят друг на друга, дубли снимает `SegmentMerge`, а разрез ищет
/// тишину вместо того, чтобы падать по таймеру на середину слова.
struct GeminiTranscriber: Transcribing {
    /// Общий размер запроса ограничен 20 МБ, а base64 растит данные на треть:
    /// всё, что крупнее, уходит через Files API по ссылке — как и рекомендует Google.
    static let maxInlineBytes = 12 * 1024 * 1024
    /// Перекрытие для случая, когда запись всё-таки приходится делить.
    static let overlapSeconds: TimeInterval = 2
    /// Попыток на запрос: обычная и настойчивая. Дальше — обрезка повтора и предупреждение.
    static let maxAttempts = 2
    /// Словарь: сервис принимает до 1000 терминов, но лучше работает до сотни.
    static let maxVocabulary = 100

    let session: URLSession
    let splitter: AudioSplitter
    /// Ключ приходит извне: так движок проверяется тестами без Keychain и без сети.
    let keyProvider: @Sendable () throws -> String?
    let inlineLimit: Int
    /// Предел одного запроса. Обычно берётся из режима; в тестах задаётся руками,
    /// чтобы проверять деление на секундах, а не на получасовых записях.
    let singleRequestLimit: TimeInterval?
    /// Длина части. Обычно из настроек; в тестах задаётся руками.
    let partLimit: TimeInterval?

    init(
        session: URLSession = CloudSession.shared,
        splitter: AudioSplitter = AudioSplitter(),
        keyProvider: @escaping @Sendable () throws -> String? = { try KeychainStore.key(for: .gemini) },
        inlineLimit: Int = GeminiTranscriber.maxInlineBytes,
        singleRequestLimit: TimeInterval? = nil,
        partLimit: TimeInterval? = nil
    ) {
        self.session = session
        self.splitter = splitter
        self.keyProvider = keyProvider
        self.inlineLimit = inlineLimit
        self.singleRequestLimit = singleRequestLimit
        self.partLimit = partLimit
    }

    var name: String { "Gemini · \(TranscriptionSettings.geminiModel)" }

    func isAvailable() async -> Bool {
        ((try? keyProvider()) ?? nil)?.isEmpty == false
    }

    // MARK: - Расшифровка

    /// Что просим у сервиса в этой расшифровке: режим плюс действующие
    /// переключатели. Считается один раз на запись — настройки, изменённые
    /// посреди расшифровки, не должны менять её на полпути.
    struct Ask: Sendable {
        let mode: GeminiMode
        let timestamps: Bool
        let speakers: Bool

        /// Час одним запросом; 30 минут, когда просим таймкоды слов или говорящих.
        var maxSeconds: TimeInterval { timestamps || speakers ? 30 * 60 : 60 * 60 }

        static func fromSettings() -> Ask {
            Ask(
                mode: TranscriptionSettings.geminiMode,
                timestamps: TranscriptionSettings.geminiWantsWordTimestamps,
                speakers: TranscriptionSettings.geminiWantsDiarization
            )
        }
    }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        guard let key = try keyProvider(), !key.isEmpty else {
            throw TranscriptionError.missingKey(.gemini)
        }
        let ask = Ask.fromSettings()
        let duration = try await splitter.duration(of: audioURL)
        let limit = singleRequestLimit ?? ask.maxSeconds
        let capabilities = Capabilities()
        // Предел сервиса — потолок, но обычно режем мельче: длина части это и есть
        // частота отметок времени в расшифровке.
        let target = min(partLimit ?? TranscriptionSettings.geminiPartSeconds, limit)

        // Запись короче части — один запрос, ни нарезки, ни склейки.
        if duration <= target {
            Diagnostics.log.notice(
                "Gemini: один запрос на \(Int(duration)) с, режим \(ask.mode.rawValue, privacy: .public), таймкоды \(ask.timestamps ? "вкл" : "выкл", privacy: .public), говорящие \(ask.speakers ? "вкл" : "выкл", privacy: .public)"
            )
            progress(0, 1)
            let piece = AudioSplitter.Part(url: audioURL, start: 0, length: duration, isOriginal: true)
            let outcome = try await self.ask(piece, key: key, ask: ask, capabilities: capabilities)
            let settled = await recover(outcome, of: piece, source: audioURL, key: key, ask: ask, capabilities: capabilities)
            let gaps = await settleGaps(
                settled, source: audioURL, duration: duration, key: key, ask: ask, capabilities: capabilities
            )
            progress(1, 1)
            return try transcript(from: settled + gaps.outcomes, duration: duration, carried: gaps.warnings)
        }

        // На пределе сервиса части нужен запас: остаток идёт на перекрытие
        // и на заголовки контейнера. Части короче предела запаса не требуют.
        let step = target >= limit ? limit - min(30, limit / 10) : target

        // Черновик: что уже посчитано и оплачено, того второй раз не спрашиваем.
        let fingerprint = TranscriptCheckpoint.fingerprint(
            audio: audioURL,
            engine: "gemini",
            model: TranscriptionSettings.geminiModel,
            mode: "\(ask.mode.rawValue)|\(ask.timestamps)|\(ask.speakers)",
            partSeconds: step,
            vocabulary: Array(TranscriptionSettings.vocabulary.prefix(Self.maxVocabulary))
        )
        var draft = TranscriptCheckpoint.load(fingerprint: fingerprint)
        var cutter = splitter.cutter(
            audioURL,
            duration: duration,
            partSeconds: step,
            overlapSeconds: Self.overlapSeconds,
            alignToSilence: true,
            from: draft.cursor
        )
        var outcomes: [Outcome] = []
        var done = 0
        if !draft.isEmpty {
            outcomes.append(Outcome(
                range: 0...max(draft.cursor, 0.1),
                segments: draft.pieces.map {
                    TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, isApproximate: $0.isApproximate)
                }
            ))
            done = draft.pieces.count
            Diagnostics.note(
                "Gemini: поднят черновик — \(draft.pieces.count) реплик до \(Int(draft.cursor)) с, спрашиваем остаток"
            )
        }
        Diagnostics.note(
            "Gemini: запись \(Int(duration)) с, части по \(Int(step)) с, ожидается \(cutter.expectedCount)"
        )

        while let part = try await cutter.next() {
            // Полоса считает сделанное: 0% в начале честнее 100% в середине.
            // Число частей оценочное, поэтому оно никогда не меньше уже готовых
            // плюс та, что идёт, — иначе полоса упёрлась бы в сотню раньше конца.
            progress(done, max(cutter.expectedCount, done + 1))
            let outcome = try await self.ask(part, key: key, ask: ask, capabilities: capabilities)
            let settled = await recover(
                outcome, of: part, source: audioURL, key: key, ask: ask, capabilities: capabilities
            )
            splitter.discard([part])
            outcomes += settled
            done += 1

            draft.pieces += settled.flatMap(\.segments).map {
                TranscriptCheckpoint.Piece(
                    start: $0.start, end: $0.end, text: $0.text, isApproximate: $0.isApproximate
                )
            }
            draft.warnings += settled.compactMap(\.warning)
            draft.cursor = cutter.cursor
            TranscriptCheckpoint.save(draft)
        }
        progress(done, done)

        // Переспрос пропусков идёт **после** последнего чекпоинта: его плашки в
        // черновик не попадают и на возобновлённом прогоне не удваиваются.
        let gaps = await settleGaps(
            outcomes, source: audioURL, duration: duration, key: key, ask: ask, capabilities: capabilities
        )
        let result = try transcript(
            from: outcomes + gaps.outcomes,
            duration: duration,
            carried: draft.warnings + gaps.warnings
        )
        // Расшифровка сошлась — черновик больше не нужен. Оставить его значит
        // подменить им следующую расшифровку той же записи тем же движком.
        TranscriptCheckpoint.drop(fingerprint: fingerprint)
        return result
    }

    /// Ниже этой длины половинить участок незачем: срыв на минутном запросе —
    /// это не про длину, и второй такой же запрос ничего не изменит.
    static let minimumHalving: TimeInterval = 120

    /// Переспрос сорвавшегося участка половинами.
    ///
    /// Где именно начался повтор, узнать неоткуда: в «Точности» времени внутри
    /// ответа нет вовсе, а вычислять позицию по доле знаков — значит назвать
    /// выдуманную секунду. Зато известно другое: срыв — свойство длинного
    /// запроса, и та же речь куском вдвое короче обычно проходит. Половины
    /// покрывают участок целиком, а если сорвётся одна из них, потерянный
    /// отрезок назван точно.
    ///
    /// Заход ровно один. Два подряд означали бы, что дело не в длине, а дробить
    /// до бесконечности — это счёт за расшифровку, которой не будет.
    private func recover(
        _ outcome: Outcome,
        of part: AudioSplitter.Part,
        source: URL,
        key: String,
        ask: Ask,
        capabilities: Capabilities
    ) async -> [Outcome] {
        guard outcome.needsSmallerAsk, part.length >= Self.minimumHalving else { return [outcome] }

        let half = part.length / 2
        let shift = Self.overlapSeconds / 2
        let windows: [(start: TimeInterval, length: TimeInterval)] = [
            (part.start, half + shift),
            (part.start + half - shift, part.length - half + shift),
        ]
        Diagnostics.note(
            "Gemini: участок \(TranscriptCoverage.describe(part.start...part.end)) сорвался, переспрашиваю половинами"
        )

        var pieces: [AudioSplitter.Part] = []
        var recovered: [Outcome] = []
        do {
            for window in windows {
                let piece = try await splitter.part(of: source, from: window.start, length: window.length)
                pieces.append(piece)
                recovered.append(try await self.ask(piece, key: key, ask: ask, capabilities: capabilities))
            }
        } catch {
            splitter.discard(pieces)
            Diagnostics.fault("Gemini: переспрос половинами не удался — \(error.localizedDescription)")
            return [outcome]
        }
        splitter.discard(pieces)

        // Переспрос принимается, как только он дал хоть какой-то текст.
        //
        // Сравнивать по длине заманчиво и неверно: усечённое начало бывает
        // длиннее в знаках, но в нём заведомо нет ничего из того, что шло после
        // срыва, а половины проверку на повтор прошли и покрывают участок
        // целиком. Сорвалась и половина — её отрезок назван точно, и это тоже
        // лучше одной жалобы на весь участок.
        guard Self.characters(in: recovered) > 0 else {
            Diagnostics.note("Gemini: половины текста не дали, оставляю первый ответ")
            return [outcome]
        }
        return recovered
    }

    private static func characters(in outcomes: [Outcome]) -> Int {
        outcomes.reduce(0) { total, outcome in
            total + outcome.segments.reduce(0) { $0 + $1.text.count }
        }
    }

    /// Итог одного запроса.
    struct Outcome {
        let range: ClosedRange<TimeInterval>
        var segments: [TranscriptSegment]
        var warning: String?
        /// Участок стоит переспросить куском поменьше: модель либо сорвалась в
        /// повтор, либо не прислала текста вовсе. И то и другое случается на
        /// длинном запросе и обычно проходит на коротком.
        var needsSmallerAsk: Bool = false
    }

    /// `carried` — замечания из черновика: они про уже разобранные части, и
    /// вместе с обрывом теряться не должны.
    private func transcript(
        from outcomes: [Outcome],
        duration: TimeInterval,
        carried: [String] = []
    ) throws -> Transcript {
        var segments: [TranscriptSegment] = []
        var warnings: [String] = carried
        for outcome in outcomes {
            SegmentMerge.merge(outcome.segments, into: &segments)
            if let warning = outcome.warning { warnings.append(warning) }
        }
        segments.sort { $0.start < $1.start }

        // Полнота считается только там, где есть настоящие тайминги: границы
        // куска за таймкод речи мы не выдаём и покрытие по ним не считаем.
        //
        // Сами пропуски разобраны раньше — в `settleGaps`, где ещё можно послушать
        // звук и переспросить сервис. Здесь их плашки уже готовы и лежат в
        // `carried`: судить о полноте по одной арифметике значит звать пропуском
        // молчание в разговоре, а это и была та ложная тревога.
        let measured = segments.filter { !$0.isApproximate }
        if !measured.isEmpty {
            let share = TranscriptCoverage.share(measured, duration: duration)
            // В файл журнала, а не только в системный лог: разбор идёт по телефону
            // владельца, а системный лог оттуда без пароля не забрать.
            Diagnostics.note("Gemini: покрытие \(Int(share * 100))%, реплик \(segments.count)")
        }

        // Инвариант: у каждой отправленной части должна быть непустая реплика.
        // Покрытие по словам здесь не работает — без нативных таймингов считать
        // нечего, — а вот молчание в ответ на целую часть видно всегда.
        for outcome in outcomes where outcome.warning == nil {
            let empty = outcome.segments.allSatisfy {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard empty else { continue }
            warnings.append("Участок \(TranscriptCoverage.describe(outcome.range)): в ответе не было текста.")
        }

        guard !segments.isEmpty else {
            if !warnings.isEmpty { throw TranscriptionError.api(warnings.uniqued().joined(separator: " ")) }
            throw TranscriptionError.emptyResult
        }
        return Transcript(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments,
            warnings: warnings.uniqued()
        )
    }

    // MARK: - Пропуски

    /// Сколько пропусков переспрашиваем за расшифровку. Предел не про технику, а
    /// про счёт: каждый переспрос — оплаченный запрос, а расшифровка с десятком
    /// пропусков сломана целиком, и лечится она не добором кусков.
    static let maxGapReasks = 3

    /// Минута без единого слова — это уже не пауза в разговоре. Порог ниже давал
    /// предупреждения на обычной тишине между фразами.
    static let gapMinimum: TimeInterval = 60

    /// Пропуски: тишину не считаем потерей, участок со звуком переспрашиваем.
    ///
    /// Раньше пропуск только назывался плашкой, и назывался по одной арифметике —
    /// «слов на этот участок не пришло». Владелец увидел четыре таких плашки на
    /// одной записи и спросил, настоящие ли они; ответить приложение не могло.
    ///
    /// **Судит переспрос, а не громкость.** Живой прогон той самой записи показал,
    /// почему так: звук в пропусках был (шум комнаты), а на переспрос трёх участков
    /// по отдельности сервис дал 7, 7 и 11 слов — и все на краях, там, где речь и
    /// так была расшифрована. То есть речи внутри не было вовсе. Громкость — это
    /// дешёвый предварительный фильтр, чтобы не платить за тишину; вывод делается
    /// по ответу на прямой вопрос об этом участке:
    ///
    /// - тихо — ни плашки, ни запроса: молчать в разговоре не запрещено;
    /// - есть звук — участок переспрашивается отдельным куском, и **из ответа
    ///   берётся только то, что попало внутрь пропуска**. Края спрашиваются с
    ///   перекрытием ради контекста, но их расшифровка у нас уже есть, и вторая
    ///   версия тех же слов — это дубль в тексте, а не находка;
    /// - переспросили и внутри ничего не нашлось — плашки нет: два независимых
    ///   вопроса об одном участке ответили одно и то же;
    /// - переспросить не успели (предел) — плашка говорит ровно то, что известно:
    ///   слов на участок сервис не дал.
    ///
    /// Заход ровно один. Два подряд означали бы, что дело не в длине запроса, а
    /// дробить до бесконечности — это счёт за расшифровку, которой не будет.
    private func settleGaps(
        _ outcomes: [Outcome],
        source: URL,
        duration: TimeInterval,
        key: String,
        ask: Ask,
        capabilities: Capabilities
    ) async -> (outcomes: [Outcome], warnings: [String]) {
        var segments: [TranscriptSegment] = []
        for outcome in outcomes { SegmentMerge.merge(outcome.segments, into: &segments) }
        let measured = segments.filter { !$0.isApproximate }
        // Без настоящих таймингов пропуск не найти: в «Точности» время реплики —
        // это границы отправленного куска, и дыр в нём не бывает по определению.
        guard !measured.isEmpty else { return ([], []) }
        let gaps = TranscriptCoverage.gaps(in: measured, duration: duration, minimum: Self.gapMinimum)
        guard !gaps.isEmpty else { return ([], []) }

        // Порог считается от уровня речи этой же записи: абсолютный порог на
        // настоящей записи ловил бы шум комнаты и звал бы его потерянной речью.
        let level = AudioLoudness.speechLevel(in: source, speech: TranscriptCoverage.merged(measured))
        let threshold = AudioLoudness.threshold(speechLevel: level)
        Diagnostics.note(
            "пропусков \(gaps.count), уровень речи \(level.map { String(format: "%.4f", $0) } ?? "не измерен"), "
            + "порог тишины \(String(format: "%.4f", threshold))"
        )

        // Что переспрашивать, решается до первого запроса: от длинного к короткому,
        // чтобы предел переспросов ушёл туда, где потеряно больше.
        var loud: [(gap: ClosedRange<TimeInterval>, sound: ClosedRange<TimeInterval>)] = []
        for gap in gaps {
            guard let sound = AudioLoudness.sound(in: source, range: gap, louderThan: threshold) else {
                Diagnostics.note("пропуск \(TranscriptCoverage.describe(gap)): тихо, переспрашивать нечего")
                continue
            }
            loud.append((gap, sound))
        }
        loud.sort { ($0.sound.upperBound - $0.sound.lowerBound) > ($1.sound.upperBound - $1.sound.lowerBound) }

        var extra: [Outcome] = []
        var warnings: [String] = []
        for (index, found) in loud.enumerated() {
            guard index < Self.maxGapReasks else {
                // Единственная честная плашка: про этот участок мы сервис не
                // спрашивали, и утверждать про него нечего, кроме факта.
                warnings.append(
                    "Пропуск \(TranscriptCoverage.describe(found.gap)): слов для этого участка сервис не дал."
                )
                continue
            }
            if let outcome = await reask(found, source: source, duration: duration, key: key, ask: ask, capabilities: capabilities) {
                extra.append(outcome)
            }
        }
        return (extra, warnings)
    }

    /// Переспрос одного пропуска. `nil` — внутри пропуска ничего не нашлось.
    private func reask(
        _ found: (gap: ClosedRange<TimeInterval>, sound: ClosedRange<TimeInterval>),
        source: URL,
        duration: TimeInterval,
        key: String,
        ask: Ask,
        capabilities: Capabilities
    ) async -> Outcome? {
        // Спрашиваем шире найденного звука: слово на самом краю иначе достанется
        // модели половиной. А берём — только внутренность пропуска.
        let from = max(0, found.sound.lowerBound - Self.overlapSeconds)
        let to = min(duration, found.sound.upperBound + Self.overlapSeconds)
        guard to - from > 0.5 else { return nil }
        let inside = (found.gap.lowerBound + Self.overlapSeconds)...(found.gap.upperBound - Self.overlapSeconds)
        Diagnostics.note("пропуск \(TranscriptCoverage.describe(found.gap)): есть звук, переспрашиваю")

        var piece: AudioSplitter.Part?
        defer { if let piece { splitter.discard([piece]) } }
        do {
            let part = try await splitter.part(of: source, from: from, length: to - from)
            piece = part
            let outcome = try await self.ask(part, key: key, ask: ask, capabilities: capabilities)
            // Ответ без таймингов обрезать нечем — он про весь кусок целиком, и
            // берётся целиком: там внутренность пропуска и есть почти весь кусок.
            let usable = outcome.segments.filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (inside.contains($0.start) || $0.isApproximate)
            }
            let dropped = outcome.segments.count - usable.count
            Diagnostics.note(
                "переспрос \(TranscriptCoverage.describe(found.gap)): внутри \(usable.count) реплик, "
                + "на краях отброшено \(dropped)"
            )
            guard !usable.isEmpty else { return nil }
            return Outcome(range: part.start...part.end, segments: usable, warning: outcome.warning)
        } catch {
            Diagnostics.fault("переспрос пропуска не удался — \(error.localizedDescription)")
            return nil
        }
    }

    /// Один запрос с проверкой на зацикливание.
    ///
    /// Сложную систему повторов и подробления убрали вместе с нарезкой: если ответ
    /// сорвался в повтор, просим один раз настойчивее, а потом отдаём нормальное
    /// начало и честно предупреждаем про остаток.
    private func ask(
        _ part: AudioSplitter.Part,
        key: String,
        ask: Ask,
        capabilities: Capabilities
    ) async throws -> Outcome {
        var attempt = 0
        var best: [TranscriptSegment] = []
        var reason: String?
        var wasEmpty = false

        while attempt < Self.maxAttempts {
            attempt += 1
            let answer = try await send(part, key: key, ask: ask, insist: attempt > 1, capabilities: capabilities)
            let joined = answer.segments.map(\.text).joined(separator: " ")
            let report = RepetitionCheck.inspect(text: joined, duration: part.length)
            // В файл журнала, а не только в системный лог: разбор срыва идёт по
            // телефону владельца, а системный лог оттуда без пароля не забрать —
            // `log collect` требует root, `sysdiagnose` — согласия на устройстве.
            // Именно этих строк не хватило, когда из части в 24 минуты в
            // расшифровку попало 72 знака: по журналу было видно два ответа
            // одинаковой длины и ни одной причины.
            Diagnostics.note(
                "Gemini запрос: start=\(Int(part.start))с duration=\(Int(part.length))с "
                + "попытка=\(attempt) знаков=\(joined.count) слов=\(answer.words) "
                + "повтор=\(String(format: "%.2f", report.score)) "
                + "остановка=\(answer.finish ?? "—") "
                + "итог=\(report.isSuspicious ? "срыв" : "ок")"
            )

            guard report.isSuspicious else {
                guard !answer.segments.isEmpty else {
                    Diagnostics.fault("попытка \(attempt): пусто")
                    if capabilities.markProbed() { await describeModel(key: key) }
                    wasEmpty = true
                    reason = "сервис ответил без текста"
                    continue
                }
                // Ответ оборвался по длине: текст годный, но участок не закончен.
                // Второй попыткой это не лечится — модель ответит так же, — а
                // половинами лечится, и `recover` для этого уже написан. Раньше
                // такой ответ принимался молча, и минуты речи из середины части
                // просто не доходили до расшифровки.
                guard !GeminiAnnotations.isLengthCut(answer.finish) else {
                    return Outcome(
                        range: part.start...part.end,
                        segments: answer.segments,
                        warning: "Участок \(TranscriptCoverage.describe(part.start...part.end)): ответ сервиса оборвался по длине — принято только начало участка, остальное не расшифровано.",
                        needsSmallerAsk: true
                    )
                }
                return Outcome(range: part.start...part.end, segments: answer.segments, warning: nil)
            }

            reason = report.reason
            // Речь до срыва сохраняем: терять её хуже, чем иметь неполный участок.
            let clean = cleaned(answer.segments)
            if clean.count > best.count { best = clean }
        }

        guard !best.isEmpty else {
            // Формулировка честная: пустой ответ и зацикливание — разные беды,
            // и лечатся они по-разному.
            let complaint = wasEmpty
                ? "Участок \(TranscriptCoverage.describe(part.start...part.end)): сервис ответил, но текста в ответе не было. Ответ и журнал запроса сохранены в папке Lori — по ним видно, что именно вернул сервис."
                : "Участок \(TranscriptCoverage.describe(part.start...part.end)): модель зациклилась (\(reason ?? "повтор")), расшифровки этого участка нет."
            return Outcome(range: part.start...part.end, segments: [], warning: complaint, needsSmallerAsk: true)
        }
        // Прошлая формулировка — «повтор отброшен» — читалась как «всё в порядке,
        // мусор убрали». На деле отброшен не только повтор: всё, что модель
        // должна была сказать после срыва, тоже не пришло. Говорим про потерю,
        // а не про уборку.
        return Outcome(
            range: part.start...part.end,
            segments: best,
            warning: "Участок \(TranscriptCoverage.describe(part.start...part.end)): модель начала повторяться — принято только начало участка, остальное не расшифровано.",
            needsSmallerAsk: true
        )
    }

    /// Реплики до срыва: сорвавшаяся не тянется целиком, а всё после неё не берётся —
    /// модель уже деградировала.
    private func cleaned(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var kept: [TranscriptSegment] = []
        for segment in segments {
            let length = max(1, segment.end - segment.start)
            let report = RepetitionCheck.inspect(text: segment.text, duration: length)
            guard report.isSuspicious else {
                kept.append(segment)
                continue
            }
            let prefix = RepetitionCheck.truncated(segment.text, duration: length)
            if !prefix.isEmpty, !RepetitionCheck.inspect(text: prefix).isSuspicious {
                kept.append(TranscriptSegment(
                    start: segment.start,
                    end: segment.end,
                    text: prefix,
                    isApproximate: segment.isApproximate
                ))
            }
            break
        }
        return kept
    }

    // MARK: - Запрос

    struct Answer {
        let segments: [TranscriptSegment]
        /// Сколько слов с таймингами прислал сервис: 0 — тайминги не нативные.
        let words: Int
        /// Чем сервис объяснил остановку. Нужна на удачном ответе не меньше, чем
        /// на пустом: `MAX_TOKENS` при непустом тексте — это оборванный участок.
        let finish: String?
    }

    /// Поля запроса, которые сервис не принял, и путь, который у него работает.
    /// Форма настроек у интерфейса расшифровки своя, и вместо угадывания мы
    /// отправляем полный набор, а на «Unknown name» убираем именно то поле.
    final class Capabilities: @unchecked Sendable {
        private let lock = NSLock()
        private var dropped = Set<String>()
        private var useGenerateContent = false
        private var probed = false

        func isAllowed(_ field: String) -> Bool { lock.withLock { !dropped.contains(field) } }

        /// Карточку модели спрашиваем один раз за расшифровку: сообщений об
        /// отказе может быть много, а сведения о модели одни и те же.
        func markProbed() -> Bool {
            lock.withLock {
                guard !probed else { return false }
                probed = true
                return true
            }
        }
        func drop(_ field: String) { lock.withLock { dropped.insert(field) } }
        var prefersGenerateContent: Bool { lock.withLock { useGenerateContent } }
        func switchToGenerateContent() { lock.withLock { useGenerateContent = true } }
    }

    private func send(
        _ part: AudioSplitter.Part,
        key: String,
        ask: Ask,
        insist: Bool,
        capabilities: Capabilities
    ) async throws -> Answer {
        // Диктофон пишет ALAC, а сервис такого формата не понимает и молча
        // возвращает пустой ответ. Перед отправкой запись приводится к FLAC.
        let prepared = try CloudAudio.prepare(part.url)
        defer { prepared.discard() }
        let mime = prepared.mime
        let data = try Data(contentsOf: prepared.url)

        var uploaded: FileInfo?
        let audio: [String: Any]
        if data.count <= inlineLimit {
            audio = ["type": "audio", "data": data.base64EncodedString(), "mime_type": mime]
        } else {
            // Для длинных записей Google рекомендует именно Files API.
            let file = try await upload(data: data, name: prepared.url.lastPathComponent, mime: mime, key: key)
            uploaded = file
            if let job = TranscriptionJob.current {
                let folder = job.directory.appending(path: "remote-files")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try JSONEncoder().encode(file).write(to: folder.appending(path: URL(fileURLWithPath: file.name).lastPathComponent + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            audio = ["type": "audio", "uri": file.uri, "mime_type": mime]
        }
        defer {
            // После suspension фоновый запрос ещё читает этот файл. Удалять его
            // до ответа нельзя; сервис также имеет собственный срок хранения.
            if let uploaded, TranscriptionJob.current == nil, !Task.isCancelled {
                Task { try? await delete(file: uploaded, key: key) }
            }
        }

        // Пробуем полный набор настроек, убирая по одному то, чего сервис не знает.
        // Отвергнуть он может любое из пяти необязательных полей, плюс запас на
        // смену точки входа.
        for _ in 0...7 {
            do {
                let body = try await request(audio: audio, key: key, ask: ask, insist: insist, capabilities: capabilities)
                return answer(from: body, part: part, ask: ask)
            } catch let error as TranscriptionError {
                if let unknown = Self.unknownField(error), capabilities.isAllowed(unknown) {
                    Diagnostics.note("поле «\(unknown)» не принято, убираю и повторяю")
                    capabilities.drop(unknown)
                    if capabilities.markProbed() { await describeModel(key: key) }
                    continue
                }
                if capabilities.markProbed() { await describeModel(key: key) }
                if case .api = error, !capabilities.prefersGenerateContent, Self.looksLikeMissingEndpoint(error) {
                    capabilities.switchToGenerateContent()
                    continue
                }
                throw error
            }
        }
        throw TranscriptionError.badResponse("Gemini не принял ни один вариант запроса.")
    }

    private func request(
        audio: [String: Any],
        key: String,
        ask: Ask,
        insist: Bool,
        capabilities: Capabilities
    ) async throws -> Data {
        let model = TranscriptionSettings.geminiModel
        var payload: [String: Any] = ["model": model]
        var input: [[String: Any]] = [audio]
        // У специализированной модели расшифровки поведение задают поля запроса,
        // а не текст. Подсказку добавляем только как страховку: когда сервис не
        // принял штатные поля или когда первый запрос вернул пустоту.
        if Self.needsPrompt(model: model, insist: insist, capabilities: capabilities) {
            input.append(["type": "text", "text": Self.prompt(insist: insist, ask: ask, capabilities: capabilities)])
        }
        payload["input"] = input

        // Настройки расшифровки живут внутри `generation_config.transcription_config` —
        // так это описано в документации. Раньше они уходили верхним уровнем, и
        // сервис отвечал «Unknown parameter» на каждое поле по очереди.
        var transcription: [String: Any] = [:]
        if capabilities.isAllowed("mode") {
            transcription["mode"] = Self.modePayload(for: ask, capabilities: capabilities)
        }
        if capabilities.isAllowed("language_codes"), let language = Self.languageTag {
            transcription["language_codes"] = [language]
        }
        let vocabulary = Array(TranscriptionSettings.vocabulary.prefix(Self.maxVocabulary))
        if !vocabulary.isEmpty, capabilities.isAllowed("custom_vocabulary") {
            transcription["custom_vocabulary"] = vocabulary
        }
        if !transcription.isEmpty, capabilities.isAllowed("transcription_config") {
            payload["generation_config"] = ["transcription_config": transcription]
        }

        let url = capabilities.prefersGenerateContent
            ? TranscriptionSettings.geminiHost.appending(path: "v1beta/models/\(TranscriptionSettings.geminiModel):generateContent")
            : TranscriptionSettings.geminiInteractionsURL
        var body = payload
        if capabilities.prefersGenerateContent {
            // Классический путь принимает другую форму входа.
            var parts: [[String: Any]] = [Self.inlinePart(from: audio)]
            // Модель расшифровки уже знает, что делать с аудио. Первая попытка —
            // только запись: 49 токенов подсказки в прошлом запросе не помогли,
            // ответ пришёл пустым. Подсказку добавляем лишь при повторе.
            if Self.needsPrompt(model: model, insist: insist, capabilities: capabilities) {
                parts.append(["text": Self.prompt(insist: insist, ask: ask, capabilities: capabilities)])
            }
            body = ["contents": [["parts": parts]]]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        Diagnostics.note(
            "Gemini → \(url.path) поля: \(body.keys.sorted().joined(separator: ", "))"
            + (capabilities.prefersGenerateContent ? " (classic)" : "")
        )
        // Форма настроек в журнал: по ней при живой проверке видно, что тумблеры
        // реально меняют запрос. Только имена полей, содержимое не пишется.
        if !capabilities.prefersGenerateContent, !transcription.isEmpty {
            let mode: String
            switch transcription["mode"] {
            case let text as String: mode = "«\(text)»"
            case let object as [String: Any]: mode = "{\(object.keys.sorted().joined(separator: ", "))}"
            default: mode = "нет"
            }
            Diagnostics.note(
                "Gemini transcription_config: \(transcription.keys.sorted().joined(separator: ", ")); mode: \(mode)"
            )
        }
        let (data, response) = try await BackgroundTranscriptionTransport.data(for: request, session: session)
        try APICheck.ensureSuccess(response: response, data: data)
        Diagnostics.note("Gemini ← \(data.count) байт")
        return data
    }

    /// Ответ: сначала нативные тайминги слов, потом текст.
    private func answer(from data: Data, part: AudioSplitter.Part, ask: Ask) -> Answer {
        let finish = GeminiAnnotations.finish(from: data)
        let words = GeminiAnnotations.words(from: data)
        if !words.isEmpty {
            let segments = GeminiAnnotations.segments(from: words, offset: part.start)
            if !segments.isEmpty {
                Diagnostics.note("разобрано слов: \(words.count), реплик: \(segments.count)")
                return Answer(segments: segments, words: words.count, finish: finish)
            }
        }

        let text = (((try? Self.text(from: data)) ?? GeminiAnnotations.text(from: data)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // Пустой разбор при успешном ответе — самое непонятное, что может
            // случиться. Сохраняем ответ целиком: иначе причину не найти.
            dump(data)
            Diagnostics.fault("ответ без текста: \(Self.describeOutcome(data))")
            return Answer(segments: [], words: 0, finish: finish)
        }
        // Время могло приехать прямо в тексте — так его и просили, когда штатное
        // поле сервис не принял. Если таймкоды не просили вовсе, похожие на них
        // числа в тексте — совпадение, и разбирать их как время нельзя.
        if ask.timestamps, StampedTranscript.looksStamped(text) {
            let stamped = StampedTranscript.segments(from: text, offset: part.start, end: part.end)
            if !stamped.isEmpty {
                Diagnostics.note("время взято из текста ответа: реплик \(stamped.count)")
                return Answer(segments: stamped, words: 0, finish: finish)
            }
        }
        // Таймкодов нет — время указывается как границы отправленного фрагмента,
        // и в файле это помечено словом «кусок». Если тайминги или говорящих
        // просили, а в разборе их нет — ответ сохраняется: по нему видно, в какой
        // форме сервис на самом деле их прислал (или не прислал).
        if ask.timestamps || ask.speakers {
            dump(data)
            Diagnostics.note("просили таймкоды или говорящих, в разборе их нет — ответ сохранён")
        }
        Diagnostics.note("таймингов слов нет, текст \(text.count) символов")
        return Answer(
            segments: [TranscriptSegment(start: part.start, end: part.end, text: text, isApproximate: true)],
            words: 0,
            finish: finish
        )
    }

    /// Текст ответа: у `interactions` он в шагах, у `generateContent` — в кандидатах.
    static func text(from data: Data) throws -> String {
        if let interaction = try? JSONDecoder().decode(Interaction.self, from: data) {
            if let whole = interaction.outputText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !whole.isEmpty {
                return whole
            }
            let parts = (interaction.steps ?? [])
                .flatMap { $0.content ?? [] }
                .compactMap { $0.text }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: "\n\n") }
        }
        if let answer = try? JSONDecoder().decode(Candidates.self, from: data) {
            let parts = (answer.candidates ?? [])
                .compactMap(\.content)
                .flatMap { $0.parts ?? [] }
                .compactMap { $0.text }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: "\n\n") }
        }
        throw TranscriptionError.badResponse("Gemini вернул ответ, который не удалось разобрать.")
    }

    private struct Interaction: Decodable {
        /// Документированное место полного текста расшифровки.
        let outputText: String?
        let steps: [Step]?

        enum CodingKeys: String, CodingKey {
            case outputText = "output_text"
            case steps
        }

        struct Step: Decodable {
            let type: String?
            let content: [Content]?

            struct Content: Decodable {
                let type: String?
                let text: String?
            }
        }
    }

    private struct Candidates: Decodable {
        let candidates: [Candidate]?

        struct Candidate: Decodable {
            let content: Content?

            struct Content: Decodable {
                let parts: [Part]?

                struct Part: Decodable {
                    let text: String?
                }
            }
        }
    }

    // MARK: - Подсказка и словарь

    static var languageTag: String? {
        switch TranscriptionSettings.language {
        case "": return nil
        case "en": return "en-US"
        default: return "ru-RU"
        }
    }

    /// Значение поля `mode`: у `smart` это строка, у дословного — объект, в котором
    /// таймкоды и говорящие включаются каждым своим подполем. Гейт по `Capabilities`
    /// стоит на каждом подполе отдельно: если сервис не принял только
    /// `timestamp_granularities`, снимается оно одно, а не весь `mode`.
    static func modePayload(for ask: Ask, capabilities: Capabilities) -> Any {
        // Строкой отправляется только `smart`. Проверять «всё, кроме accuracy»
        // было опасно: появился третий режим — и он молча уехал в smart, то
        // есть в режим, несовместимый ровно с тем, что он должен включать.
        guard ask.mode != .smart else { return "smart" }
        var verbatim: [String: Any] = ["type": "verbatim"]
        // Живой прогон 28 августа: diarization_mode без timestamp_granularities
        // сервис принимает, но говорящих не присылает вовсе — они приходят только
        // в word_info вместе с таймингами. Поэтому говорящие тянут за собой
        // тайминги слов в запросе; писать ли время в файл — отдельное решение
        // тумблера таймкодов.
        if ask.timestamps || ask.speakers, capabilities.isAllowed("timestamp_granularities") {
            verbatim["timestamp_granularities"] = ["word"]
        }
        if ask.speakers, capabilities.isAllowed("diarization_mode") {
            verbatim["diarization_mode"] = "speaker"
        }
        return verbatim
    }

    /// Нужна ли подсказка текстом. У `…-transcribe` — нет, пока штатные поля работают.
    static func needsPrompt(model: String, insist: Bool, capabilities: Capabilities) -> Bool {
        guard model.lowercased().contains("transcribe") else { return true }
        if insist { return true }
        return [
            "transcription_config", "mode", "language_codes", "custom_vocabulary",
            "timestamp_granularities", "diarization_mode",
        ].contains { !capabilities.isAllowed($0) }
    }

    /// Подсказка остаётся страховкой: если сервис не принял штатные поля, просьбы
    /// в тексте — единственный способ получить дословность, таймкоды и словарь.
    static func prompt(insist: Bool, ask: Ask, capabilities: Capabilities) -> String {
        var parts = ["Расшифруй речь из этого аудио дословно, ничего не пропускай и не сокращай."]
        if insist {
            parts.append("Расшифруй запись целиком, с первой секунды до конца, и не повторяй одну и ту же фразу.")
        }
        if !capabilities.isAllowed("language_codes"), let language = languageTag {
            parts.append("Язык записи — \(language).")
        }
        // Просьба в тексте появляется, когда штатного пути не осталось: сняли либо
        // весь `mode`, либо конкретное подполе.
        let stampsRejected = !capabilities.isAllowed("mode") || !capabilities.isAllowed("timestamp_granularities")
        let speakersRejected = !capabilities.isAllowed("mode") || !capabilities.isAllowed("diarization_mode")
        if ask.timestamps, stampsRejected {
            parts.append(
                "Каждую реплику начинай с новой строки и ставь перед ней время от начала записи "
                + "в квадратных скобках, например «[1:23]». Время должно расти и доходить до конца записи."
            )
        }
        if ask.speakers, speakersRejected {
            parts.append("Помечай говорящих: «S1», «S2».")
        }
        let vocabulary = Array(TranscriptionSettings.vocabulary.prefix(maxVocabulary))
        if !vocabulary.isEmpty, !capabilities.isAllowed("custom_vocabulary") {
            parts.append("Эти имена и термины пиши именно так: " + vocabulary.joined(separator: ", ") + ".")
        }
        return parts.joined(separator: " ")
    }

    /// Имя поля из жалобы сервиса: «Unknown name "diarization": Cannot find field.»
    ///
    /// Так набор настроек подстраивается под то, что интерфейс действительно
    /// принимает, вместо угадывания формы запроса.
    /// Какое поле сервис не принял. Форм жалобы у него как минимум четыре, и на
    /// каждой новой приложение спотыкалось: «Unknown name "mode"»,
    /// «The value 'verbatim' is not supported for 'mode'», «Unknown parameter
    /// 'language'», «Invalid value at 'language'». Поэтому разбор общий: набор
    /// образцов, а не единственный шаблон.
    static func unknownField(_ error: Error) -> String? {
        guard case let .api(message)? = error as? TranscriptionError else { return nil }
        let patterns: [(marker: String, pattern: String, quote: Character)] = [
            ("unknown name", "[Uu]nknown name \"[^\"]+\"", "\""),
            ("unknown name", "[Uu]nknown name '[^']+'", "'"),
            ("unknown parameter", "[Uu]nknown parameter \"[^\"]+\"", "\""),
            ("unknown parameter", "[Uu]nknown parameter '[^']+'", "'"),
            ("unknown field", "[Uu]nknown field '[^']+'", "'"),
            ("is not supported for", "is not supported for '[^']+'", "'"),
            ("is not supported for", "is not supported for \"[^\"]+\"", "\""),
            ("invalid value", "at '[^']+'", "'"),
            ("cannot find field", "cannot find field '[^']+'", "'"),
        ]
        for entry in patterns where message.localizedCaseInsensitiveContains(entry.marker) {
            if let field = quoted(in: message, pattern: entry.pattern, quote: entry.quote) {
                // Пути вида «payload.mode» приводим к имени поля.
                return field.components(separatedBy: ".").last
            }
        }
        // «custom_vocabulary is incompatible with timestamps.» — живой ответ
        // сервиса от 28 августа: без кавычек, виновник назван первым словом.
        // Убирается именно он; словарь при этом всё равно дойдёт текстом подсказки.
        if let range = message.range(of: " is incompatible with", options: .caseInsensitive) {
            let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
            let subject = message[..<range.lowerBound]
                .components(separatedBy: .whitespacesAndNewlines).last?
                .trimmingCharacters(in: keep.inverted) ?? ""
            if !subject.isEmpty { return subject.components(separatedBy: ".").last }
        }
        return nil
    }

    private static func quoted(in message: String, pattern: String, quote: Character) -> String? {
        guard let match = message.range(of: pattern, options: .regularExpression) else { return nil }
        let fragment = message[match]
        guard let open = fragment.firstIndex(of: quote),
              let close = fragment.lastIndex(of: quote),
              open < close else { return nil }
        return String(fragment[fragment.index(after: open)..<close])
    }

    /// Стоит ли пробовать классический `generateContent`.
    static func looksLikeMissingEndpoint(_ error: Error) -> Bool {
        guard case let .api(message)? = error as? TranscriptionError else { return false }
        let lower = message.lowercased()
        // Только про сам метод: «не поддерживается значение поля» сюда не относится,
        // иначе приложение бросает рабочую точку входа из-за одной настройки.
        guard !lower.contains("is not supported for") else { return false }
        return ["not found", "is not supported for the api", "method not", "unknown api"]
            .contains { lower.contains($0) }
    }

    private static func inlinePart(from audio: [String: Any]) -> [String: Any] {
        let mime = audio["mime_type"] as? String ?? "audio/mp4"
        if let data = audio["data"] as? String {
            return ["inline_data": ["mime_type": mime, "data": data]]
        }
        if let uri = audio["uri"] as? String {
            return ["file_data": ["mime_type": mime, "file_uri": uri]]
        }
        return [:]
    }

    /// Спрашивает у сервиса карточку модели: какими методами её вызывать и что
    /// она про себя пишет. Гадать форму запроса по названиям кнопок в чужом
    /// интерфейсе уже приводило к ошибкам — надёжнее спросить сам сервис.
    private func describeModel(key: String) async {
        let model = TranscriptionSettings.geminiModel
        var request = URLRequest(url: TranscriptionSettings.geminiHost.appending(path: "v1beta/models/\(model)"))
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        guard let (data, _) = try? await BackgroundTranscriptionTransport.data(for: request, session: session),
              let card = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Diagnostics.fault("карточку модели \(model) получить не удалось")
            return
        }
        if let failure = (card["error"] as? [String: Any])?["message"] as? String {
            Diagnostics.fault("карточка модели \(model): \(failure)")
            return
        }
        let methods = (card["supportedGenerationMethods"] as? [String])?.joined(separator: ", ") ?? "—"
        Diagnostics.note("карточка \(model): методы [\(methods)]")
        if let about = card["description"] as? String { Diagnostics.note("описание: \(about)") }
        for (field, value) in card.sorted(by: { $0.key < $1.key })
        where !["description", "supportedGenerationMethods", "name"].contains(field) {
            Diagnostics.note("  \(field): \(value)")
        }
    }

    /// Короткая сводка по пустому ответу: она объясняет, дошло ли аудио и почему
    /// модель молчит. Именно так выяснилось, что запись сервис прочитал целиком.
    static func describeOutcome(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "ответ не разобрать"
        }
        var notes: [String] = []
        if let candidates = json["candidates"] as? [[String: Any]],
           let reason = candidates.first?["finishReason"] as? String {
            notes.append("остановка: \(reason)")
        }
        if let usage = json["usageMetadata"] as? [String: Any] {
            let audio = (usage["promptTokensDetails"] as? [[String: Any]])?
                .first(where: { $0["modality"] as? String == "AUDIO" })?["tokenCount"] as? Int
            if let audio { notes.append("аудио прочитано: \(audio) токенов") }
            let produced = usage["candidatesTokenCount"] as? Int ?? 0
            notes.append("выдано: \(produced) токенов")
        }
        return notes.isEmpty ? "ни слов с таймингами, ни строки расшифровки" : notes.joined(separator: ", ")
    }

    /// Сохраняет ответ, который не удалось разобрать. Файл лежит в рабочей папке
    /// и виден через «Файлы»: без него причина пустой расшифровки не находится.
    private func dump(_ data: Data) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appending(path: "Lori", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "last-gemini-response.json")
        try? data.write(to: url, options: .atomic)
        Diagnostics.log.error(
            "Gemini: ответ не разобран, сохранил \(data.count) байт в last-gemini-response.json"
        )
    }

    // MARK: - Files API

    struct FileInfo: Codable, Sendable {
        let name: String
        let uri: String
        let state: String?
    }

    private struct FileEnvelope: Decodable {
        let file: FileInfo
    }

    /// Возобновляемая загрузка в два шага: сначала метаданные и адрес, потом байты.
    static func uploadName(data: Data, original: String) -> String {
        guard let job = TranscriptionJob.current else { return original }
        // FLAC временно получает UUID. В Files API имя должно переживать повтор,
        // иначе неизменные байты создадут новую upload-сессию вместо продолжения.
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return job.id + "_" + hash
    }

    private func upload(data: Data, name: String, mime: String, key: String) async throws -> FileInfo {
        var start = URLRequest(url: TranscriptionSettings.geminiFilesUploadURL)
        start.httpMethod = "POST"
        start.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(data.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mime, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": Self.uploadName(data: data, original: name)]], options: [.sortedKeys])

        let (startBody, startResponse) = try await BackgroundTranscriptionTransport.data(for: start, session: session)
        try APICheck.ensureSuccess(response: startResponse, data: startBody)
        guard let http = startResponse as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "x-goog-upload-url"),
              let uploadURL = Self.routed(location) else {
            throw TranscriptionError.badResponse("Gemini не дал адрес для загрузки файла.")
        }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        upload.timeoutInterval = 1800

        let (uploadBody, uploadResponse) = try await BackgroundTranscriptionTransport.upload(for: upload, from: data, session: session)
        try APICheck.ensureSuccess(response: uploadResponse, data: uploadBody)
        guard let envelope = try? JSONDecoder().decode(FileEnvelope.self, from: uploadBody) else {
            throw TranscriptionError.badResponse("Gemini не подтвердил загрузку файла.")
        }
        return try await activated(envelope.file, key: key)
    }

    /// Сервис возвращает адрес загрузки на своём хосте. Если мы работаем через
    /// свой прокси, идти по этому адресу напрямую бессмысленно.
    static func routed(_ location: String) -> URL? {
        guard let original = URL(string: location) else { return nil }
        guard TranscriptionSettings.geminiUsesCustomHost,
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false),
              let host = URLComponents(url: TranscriptionSettings.geminiHost, resolvingAgainstBaseURL: false)
        else { return original }
        components.scheme = host.scheme
        components.host = host.host
        components.port = host.port
        return components.url ?? original
    }

    /// Свежезагруженный файл сначала обрабатывается на стороне Google.
    private func activated(_ file: FileInfo, key: String, attempts: Int = 30) async throws -> FileInfo {
        var current = file
        for _ in 0..<attempts {
            switch current.state?.uppercased() {
            case "ACTIVE", nil: return current
            case "FAILED": throw TranscriptionError.api("Google не смог обработать загруженное аудио.")
            default: break
            }
            try await Task.sleep(for: .seconds(1))
            var request = URLRequest(url: TranscriptionSettings.geminiHost.appending(path: "v1beta/\(current.name)"))
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let (body, response) = try await BackgroundTranscriptionTransport.data(for: request, session: session)
            try APICheck.ensureSuccess(response: response, data: body)
            guard let refreshed = try? JSONDecoder().decode(FileInfo.self, from: body) else { return current }
            current = refreshed
        }
        throw TranscriptionError.api("Google слишком долго обрабатывает загруженное аудио.")
    }

    /// Файлы нужны всем повторам задания. Удаляем после завершения/отмены,
    /// а не после одной части: сохранённый upload иначе ссылался бы на удалённый URI.
    static func cleanupRemoteFiles(for job: TranscriptionJob) {
        guard job.kind == .gemini else { return }
        let folder = job.directory.appending(path: "remote-files")
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil as FileInfo? }
            return try? JSONDecoder().decode(FileInfo.self, from: data)
        }
        guard !files.isEmpty else { return }
        Task {
            await TranscriptionJob.$current.withValue(job) {
                let engine = GeminiTranscriber()
                guard let key = try? engine.keyProvider(), !key.isEmpty else { return }
                for file in files { try? await engine.delete(file: file, key: key) }
            }
        }
    }

    private func delete(file: FileInfo, key: String) async throws {
        var request = URLRequest(url: TranscriptionSettings.geminiHost.appending(path: "v1beta/\(file.name)"))
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        _ = try await session.data(for: request)
    }

    /// Проверка ключа для настроек: список моделей отвечает «ключ рабочий».
    func validate() async throws -> String {
        guard let key = try keyProvider(), !key.isEmpty else {
            throw TranscriptionError.missingKey(.gemini)
        }
        var request = URLRequest(url: TranscriptionSettings.geminiModelsURL)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 30
        let (data, response) = try await BackgroundTranscriptionTransport.data(for: request, session: session)
        try APICheck.ensureSuccess(response: response, data: data)
        return TranscriptionSettings.describedTarget(for: .gemini)
    }
}
