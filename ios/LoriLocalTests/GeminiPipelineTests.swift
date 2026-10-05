import XCTest
@testable import LoriLocal

/// Пайплайн: когда запись уходит одним запросом, когда делится, и что происходит
/// при срыве модели в повтор.
final class GeminiPipelineTests: XCTestCase {
    private var audio: URL!
    private let keys = [
        TranscriptionSettings.geminiModeKey,
        TranscriptionSettings.vocabularyKey,
        TranscriptionSettings.languageKey,
        TranscriptionSettings.timecodesKey,
        TranscriptionSettings.speakerLabelsKey,
        TranscriptionSettings.geminiPartKey,
    ]

    override func setUpWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        audio = FileManager.default.temporaryDirectory.appending(path: "pipe-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 30, at: audio)
    }

    override func tearDownWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        try? FileManager.default.removeItem(at: audio)
        try? FileManager.default.removeItem(at: TranscriptCheckpoint.directory)
        StubURLProtocol.reset()
    }

    private static func words(_ items: [(Double, Double, String)]) -> StubURLProtocol.Reply {
        let words: [[String: Any]] = items.map {
            ["word": $0.2, "start_offset": "\($0.0)s", "end_offset": "\($0.1)s"]
        }
        let payload = try! JSONSerialization.data(withJSONObject: [
            "steps": [["type": "model_output", "content": [["words": words]]]],
        ])
        return .json(String(data: payload, encoding: .utf8)!)
    }

    /// Ответ, оборванный по длине: текст нормальный, а участок не закончен.
    private static func cutWords(_ items: [(Double, Double, String)]) -> StubURLProtocol.Reply {
        let words: [[String: Any]] = items.map {
            ["word": $0.2, "start_offset": "\($0.0)s", "end_offset": "\($0.1)s"]
        }
        let payload = try! JSONSerialization.data(withJSONObject: [
            "steps": [["type": "model_output", "content": [["words": words]]]],
            "finishReason": "MAX_TOKENS",
        ])
        return .json(String(data: payload, encoding: .utf8)!)
    }

    private static func text(_ value: String) -> StubURLProtocol.Reply {
        let payload = try! JSONSerialization.data(withJSONObject: [
            "steps": [["type": "model_output", "content": [["type": "text", "text": value]]]],
        ])
        return .json(String(data: payload, encoding: .utf8)!)
    }

    private static let loop = String(repeating: "здесь мы, ", count: 150)

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
    }

    // MARK: - Один запрос против деления

    func testRecordingWithinLimitIsNotSplit() async throws {
        let session = StubURLProtocol.session { _, _ in
            Self.words([(0, 1, "Слово"), (1, 2, "второе.")])
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(StubURLProtocol.requests.count, 1, "тридцать секунд — это один запрос")
        XCTAssertFalse(transcript.segments.isEmpty)
        XCTAssertTrue(transcript.warnings.isEmpty, "\(transcript.warnings)")
    }

    /// Деление появляется только там, где сервис не берёт столько за раз.
    func testRecordingAboveLimitIsSplitWithOverlap() async throws {
        let session = StubURLProtocol.session { _, _ in
            Self.words([(0, 2, "Речь"), (2, 8, "куска.")])
        }
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            singleRequestLimit: 12
        )

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertGreaterThan(StubURLProtocol.requests.count, 1, "запись длиннее предела нужно делить")
        XCTAssertFalse(transcript.segments.isEmpty)
        // Начало записи не теряется даже при делении.
        XCTAssertLessThan(try XCTUnwrap(transcript.segments.map(\.start).min()), 1)
    }

    // MARK: - Зацикливание

    /// Повтор не принимается: сначала настойчивый повтор запроса, потом обрезка
    /// и честное предупреждение — но речь до срыва остаётся.
    func testRepetitionLoopIsNotAcceptedAndSpeechBeforeItSurvives() async throws {
        let session = StubURLProtocol.session { _, _ in
            Self.text("Мы обсудили сроки поставки и смету. Дальше про схему обвязки. " + Self.loop)
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertFalse(transcript.text.contains("здесь мы, здесь мы"), "повтор в расшифровку попадать не должен")
        XCTAssertTrue(transcript.text.contains("сроки поставки"), "речь до срыва обязана остаться")
        XCTAssertEqual(StubURLProtocol.requests.count, GeminiTranscriber.maxAttempts, "сорвавшийся запрос повторяется")
        XCTAssertTrue(
            transcript.warnings.contains { $0.contains("повторяться") },
            "о выброшенном повторе нужно предупредить: \(transcript.warnings)"
        )
    }

    /// Спасать нечего — участок помечен как требующий проверки, с таймкодом.
    func testPureLoopBecomesErrorWithTimecode() async throws {
        let session = StubURLProtocol.session { _, _ in Self.text(Self.loop) }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        do {
            _ = try await engine.transcribe(audioURL: audio)
            XCTFail("сотня повторов — это не расшифровка")
        } catch {
            guard case let .api(message)? = error as? TranscriptionError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("зациклилась"), message)
            XCTAssertTrue(message.contains("0:00"), "нужен таймкод участка: \(message)")
        }
    }

    /// Настойчивая попытка помогла — предупреждать не о чем.
    func testSecondAttemptCanRecover() async throws {
        let counter = Counter()
        let session = StubURLProtocol.session { _, _ in
            counter.next() == 1
                ? Self.text(Self.loop)
                : Self.words([(0, 2, "Нормальная"), (2, 5, "расшифровка.")])
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertEqual(transcript.text, "Нормальная расшифровка.")
        XCTAssertTrue(transcript.warnings.isEmpty, "\(transcript.warnings)")
    }

    // MARK: - Нарезка ради читаемости

    /// В «Точности» сервис времени не отдаёт: `timestamp_granularities`
    /// документированы только как `["word"]`, они несовместимы со словарём и, по
    /// документации Google, роняют точность. Поэтому единственная отметка
    /// времени — граница части, и части режутся мельче предела сервиса.
    func testAccuracyModeSplitsForReadabilityBelowServiceLimit() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "read-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 120, at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        // Тексты частей разные: одинаковые склейка справедливо сочла бы дублем
        // перекрытия, и тест мерил бы дедупликацию, а не нарезку.
        let counter = Counter()
        let spoken = [
            "Начали с бюджета и сроков.",
            "Потом обсуждали схему обвязки.",
            "Дальше про приёмку и документы.",
            "В конце договорились о встрече.",
            "Разошлись под вечер.",
        ]
        let session = StubURLProtocol.session { _, _ in
            Self.text(spoken[min(counter.next() - 1, spoken.count - 1)])
        }
        // Предел сервиса заведомо больше записи: делить его ради читаемости.
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            inlineLimit: 64 * 1024 * 1024,
            singleRequestLimit: 600,
            partLimit: 40
        )

        let transcript = try await engine.transcribe(audioURL: long)

        XCTAssertGreaterThan(StubURLProtocol.requests.count, 1, "две минуты одной репликой — это стена без времени")
        XCTAssertGreaterThan(transcript.segments.count, 1, "у каждой части своя отметка времени")
        XCTAssertTrue(transcript.segments.allSatisfy(\.isApproximate), "время части — это границы куска, а не речи")
        // Время растёт: вторая часть начинается позже первой, а не с нуля.
        let starts = transcript.segments.map(\.start).sorted()
        XCTAssertGreaterThan(try XCTUnwrap(starts.last), 0)
    }

    /// Длина части не может превысить предел сервиса, как бы её ни задали.
    func testPartNeverExceedsTheServiceLimit() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "cap-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 120, at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        let session = StubURLProtocol.session { _, _ in Self.text("Текст части.") }
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            inlineLimit: 64 * 1024 * 1024,
            singleRequestLimit: 30,
            partLimit: 600
        )

        _ = try await engine.transcribe(audioURL: long)

        XCTAssertGreaterThan(StubURLProtocol.requests.count, 3, "часть длиннее предела сервис не возьмёт")
    }

    // MARK: - Переспрос сорвавшегося участка

    /// Срыв — свойство длинного запроса. Участок переспрашивается половинами,
    /// и текст, потерянный после срыва, возвращается.
    func testLoopedPartIsAskedAgainInHalves() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "halves-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 150, at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        let counter = Counter()
        let session = StubURLProtocol.session { _, _ in
            let attempt = counter.next()
            guard attempt > GeminiTranscriber.maxAttempts else { return Self.text(Self.loop) }
            return Self.text(attempt == GeminiTranscriber.maxAttempts + 1 ? "Первая половина." : "Вторая половина.")
        }
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            inlineLimit: 64 * 1024 * 1024,
            partLimit: 150
        )

        let transcript = try await engine.transcribe(audioURL: long)

        XCTAssertEqual(
            StubURLProtocol.requests.count,
            GeminiTranscriber.maxAttempts + 2,
            "две попытки на часть и по одной на каждую половину"
        )
        XCTAssertTrue(transcript.text.contains("Первая половина."), transcript.text)
        XCTAssertTrue(transcript.text.contains("Вторая половина."), transcript.text)
        XCTAssertTrue(transcript.warnings.isEmpty, "половины прошли — жаловаться не на что: \(transcript.warnings)")
    }

    /// Заход ровно один: если и половина сорвалась, дальше дробить бессмысленно.
    func testHalvesAreAskedOnlyOnce() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "once-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 150, at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        let session = StubURLProtocol.session { _, _ in Self.text(Self.loop) }
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            inlineLimit: 64 * 1024 * 1024,
            partLimit: 150
        )

        do {
            _ = try await engine.transcribe(audioURL: long)
            XCTFail("сплошной повтор — это не расшифровка")
        } catch {
            guard case let .api(message)? = error as? TranscriptionError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("зациклилась"), message)
        }
        XCTAssertEqual(
            StubURLProtocol.requests.count,
            GeminiTranscriber.maxAttempts * 3,
            "часть и две её половины, по две попытки на каждую — и ни одного дробления дальше"
        )
    }

    /// Короткий участок половинить незачем: дело не в длине запроса.
    func testShortPartIsNotHalved() async throws {
        let session = StubURLProtocol.session { _, _ in Self.text(Self.loop) }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try? await engine.transcribe(audioURL: audio)

        XCTAssertEqual(StubURLProtocol.requests.count, GeminiTranscriber.maxAttempts, "тридцать секунд делить не на что")
    }

    /// Прошлая формулировка «повтор отброшен» читалась как «мусор убрали».
    /// Убран не только повтор — всё после срыва тоже не пришло, и текст
    /// предупреждения обязан говорить про потерю.
    func testWarningNamesTheLossAndTheRange() async throws {
        let session = StubURLProtocol.session { _, _ in
            Self.text("Мы обсудили сроки поставки и смету. Дальше про схему обвязки. " + Self.loop)
        }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        let warning = try XCTUnwrap(transcript.warnings.first)
        XCTAssertTrue(warning.contains("не расшифровано"), warning)
        XCTAssertFalse(warning.contains("повтор отброшен"), "об уборке мусора речи не идёт: \(warning)")
        XCTAssertTrue(warning.contains("0:00"), "участок обязан быть назван: \(warning)")
    }

    // MARK: - Черновик готовых частей

    /// Ради чего чекпоинты и заведены: на живом прогоне шесть частей из девяти
    /// прошли и были оплачены, система забрала процесс на седьмой — и всё шесть
    /// ушло в никуда. Теперь оплаченное переживает обрыв.
    func testFinishedPartsSurviveAnInterruptionAndOnlyTheRestIsAsked() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "draft-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 120, at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        func engine(_ session: URLSession) -> GeminiTranscriber {
            GeminiTranscriber(
                session: session,
                keyProvider: { "тест-ключ" },
                inlineLimit: 64 * 1024 * 1024,
                partLimit: 40
            )
        }

        // Первый заход: две части прошли, на третьей сервис отвалился —
        // так же выглядит и процесс, забранный системой.
        let first = Counter()
        let failing = StubURLProtocol.session { _, _ in
            switch first.next() {
            case 1: Self.text("Начали с бюджета.")
            case 2: Self.text("Потом схема обвязки.")
            default: .json(#"{"error": {"message": "оборвалось"}}"#, status: 500)
            }
        }
        do {
            _ = try await engine(failing).transcribe(audioURL: long)
            XCTFail("обрыв — это ошибка, а не тихий успех")
        } catch {}

        // Второй заход: спрашивается только остаток, а текст первых частей
        // приходит из черновика — сервис его в этот раз не присылал вовсе.
        let second = Counter()
        let session = StubURLProtocol.session { _, _ in
            Self.text(second.next() == 1 ? "Дальше про приёмку." : "В конце о встрече.")
        }
        let transcript = try await engine(session).transcribe(audioURL: long)

        XCTAssertEqual(second.count, 2, "уже оплаченные части второй раз не спрашиваются")
        XCTAssertTrue(transcript.text.contains("Начали с бюджета."), "черновик не поднялся: \(transcript.text)")
        XCTAssertTrue(transcript.text.contains("Потом схема обвязки."), transcript.text)
        XCTAssertTrue(transcript.text.contains("Дальше про приёмку."), transcript.text)
        XCTAssertTrue(transcript.text.contains("В конце о встрече."), transcript.text)
    }

    /// Расшифровка сошлась — черновик обязан уйти. Иначе следующая расшифровка
    /// той же записи тем же движком подменилась бы старым текстом.
    func testDraftIsGoneAfterASuccessfulRun() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "clean-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 120, at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        let counter = Counter()
        let session = StubURLProtocol.session { _, _ in Self.text("Часть номер \(counter.next()) записи.") }
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            inlineLimit: 64 * 1024 * 1024,
            partLimit: 40
        )

        _ = try await engine.transcribe(audioURL: long)

        let drafts = (try? FileManager.default.contentsOfDirectory(
            at: TranscriptCheckpoint.directory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(drafts.isEmpty, "после удачной расшифровки черновиков не остаётся: \(drafts)")
    }

    // MARK: - Таймкоды и полнота

    /// Ответ без таймингов слов: время помечается как границы фрагмента, а не
    /// выдаётся за таймкод речи.
    func testTextOnlyAnswerIsMarkedAsChunkBounds() async throws {
        let session = StubURLProtocol.session { _, _ in Self.text("Текст без таймкодов") }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertTrue(transcript.segments.allSatisfy(\.isApproximate))
        XCTAssertTrue(transcript.markdown(title: "Запись", engine: "Gemini").contains("**[кусок "))
        XCTAssertTrue(transcript.warnings.isEmpty, "по границам фрагмента полноту не считаем")
    }

    /// Минута без слов над **тишиной** — это не пропуск, а молчание в разговоре.
    ///
    /// Раньше этот тест требовал обратного: он ждал плашку и получал её, потому
    /// что полнота считалась одной арифметикой по таймингам. Фикстура здесь —
    /// цифровой ноль, то есть ровно та тишина, на которую владелец и увидел
    /// четыре ложные плашки на одной записи.
    func testSilentStretchIsNotReportedAsAGap() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "pipe-long-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 200, at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        let session = StubURLProtocol.session { _, _ in
            Self.words([(0, 2, "Начало"), (180, 190, "конец.")])
        }
        // Порог inline поднят: трёхминутная тишина весит больше 12 МБ, а Files API
        // здесь не проверяется — он проверяется своим тестом.
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            inlineLimit: 64 * 1024 * 1024
        )

        let transcript = try await engine.transcribe(audioURL: long)

        XCTAssertTrue(transcript.warnings.isEmpty, "на тишине плашек быть не должно: \(transcript.warnings)")
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "и переспрашивать тишину незачем")
    }

    /// А вот пропуск, под которым есть звук, — это потерянная речь, и она
    /// переспрашивается тем же куском, где звук и нашёлся.
    func testGapWithSoundIsReaskedAndClosed() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "pipe-sound-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 200, levels: [(0...200, 0.5)], at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        let counter = Counter()
        let session = StubURLProtocol.session { _, _ in
            counter.next() == 1
                ? Self.words([(0, 2, "Начало"), (178, 190, "конец.")])
                // Время в ответе — от начала куска, а кусок начался на 0:00:
                // реплика ложится внутрь пропуска, а не на его край.
                : Self.words([(10, 170, "Середина записи.")])
        }
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            inlineLimit: 64 * 1024 * 1024
        )

        let transcript = try await engine.transcribe(audioURL: long)

        XCTAssertEqual(StubURLProtocol.requests.count, 2, "один запрос на запись и один на пропуск")
        XCTAssertTrue(transcript.text.contains("Середина записи."), transcript.text)
        XCTAssertTrue(transcript.warnings.isEmpty, "пропуск закрыт — плашке не о чем говорить: \(transcript.warnings)")
    }

    /// Переспросили участок отдельным запросом, и внутри опять ничего.
    ///
    /// Это **не** повод для плашки: два независимых вопроса об одном участке
    /// ответили одно и то же, и настаивать, что речь там есть, нечем. Ровно так
    /// живой прогон и выглядел: на три переспроса по 7, 7 и 11 слов, все на краях.
    func testGapConfirmedEmptyByReaskIsNotAlarmed() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "pipe-lost-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 200, levels: [(0...200, 0.5)], at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        let counter = Counter()
        let session = StubURLProtocol.session { _, _ in
            counter.next() == 1
                ? Self.words([(0, 2, "Начало"), (178, 190, "конец.")])
                : .json(#"{"steps": []}"#)
        }
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            inlineLimit: 64 * 1024 * 1024
        )

        let transcript = try await engine.transcribe(audioURL: long)

        XCTAssertTrue(
            transcript.warnings.isEmpty,
            "спросили дважды, ответ один — тревожить нечем: \(transcript.warnings)"
        )
    }

    /// **Дефект с телефона.** Переспрос спрашивается с перекрытием, и модель
    /// возвращает заодно речь с краёв пропуска — ту, которая уже расшифрована.
    /// Формулировки у двух ответов разные («Здравствуйте, здоров.» против
    /// «Привет и здоров.»), и склейка по сходству слов их дублем не считает: на
    /// экране получились две реплики на одной секунде и с разными говорящими.
    func testEdgeRepliesFromReaskDoNotDuplicateTheTranscript() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "pipe-edge-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 200, levels: [(0...200, 0.5)], at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        let counter = Counter()
        let session = StubURLProtocol.session { _, _ in
            counter.next() == 1
                ? Self.words([(0, 2, "Здравствуйте, здоров."), (178, 190, "конец.")])
                // Кусок начинается на 0:00, пропуск — с 0:02: реплика на первой
                // секунде это край, и её расшифровка у нас уже есть.
                : Self.words([(0, 2, "Привет и здоров."), (10, 170, "Середина записи.")])
        }
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            inlineLimit: 64 * 1024 * 1024
        )

        let transcript = try await engine.transcribe(audioURL: long)

        XCTAssertTrue(transcript.text.contains("Середина записи."), "находка внутри пропуска берётся")
        XCTAssertFalse(
            transcript.text.contains("Привет и здоров."),
            "а вторая версия уже расшифрованного края — нет: \(transcript.text)"
        )
        XCTAssertTrue(transcript.text.contains("Здравствуйте, здоров."), transcript.text)
    }

    /// Переспрос может вернуть текст без таймингов. Обрезать его нечем, и он
    /// берётся целиком: внутренность пропуска — это почти весь спрошенный кусок.
    func testReaskWithoutTimingsIsCalledByItsName() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "pipe-notime-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 200, levels: [(0...200, 0.5)], at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        let counter = Counter()
        let session = StubURLProtocol.session { _, _ in
            counter.next() == 1
                ? Self.words([(0, 2, "Начало"), (178, 190, "конец.")])
                : Self.text("Речь середины записи без таймкодов.")
        }
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            inlineLimit: 64 * 1024 * 1024
        )

        let transcript = try await engine.transcribe(audioURL: long)

        XCTAssertTrue(transcript.text.contains("Речь середины записи без таймкодов."), transcript.text)
        XCTAssertTrue(
            transcript.warnings.isEmpty,
            "текст участка есть — тревожить нечем: \(transcript.warnings)"
        )
    }

    /// Предел переспросов — это про счёт, а не про технику: каждый переспрос
    /// оплачен. Записи с пятью дырами он не лечит, и врать об этом нельзя —
    /// непереспрошенные пропуски названы плашками.
    func testGapReasksAreCapped() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "pipe-many-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 530, levels: [(0...530, 0.5)], at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        let counter = Counter()
        let session = StubURLProtocol.session { _, _ in
            counter.next() == 1
                ? Self.words([
                    (0, 2, "Раз."), (105, 107, "Два."), (210, 212, "Три."),
                    (315, 317, "Четыре."), (420, 422, "Пять."),
                ])
                : Self.words([(0.5, 5, "Переспрос номер \(counter.count).")])
        }
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            inlineLimit: 64 * 1024 * 1024
        )

        let transcript = try await engine.transcribe(audioURL: long)

        XCTAssertEqual(
            StubURLProtocol.requests.count,
            1 + GeminiTranscriber.maxGapReasks,
            "переспросов ровно столько, сколько разрешено"
        )
        XCTAssertEqual(
            transcript.warnings.count,
            5 - GeminiTranscriber.maxGapReasks,
            "плашка только у тех, кого не спрашивали: \(transcript.warnings)"
        )
        XCTAssertTrue(
            transcript.warnings.allSatisfy { $0.contains("сервис не дал") },
            "и говорит она факт, а не догадку про речь: \(transcript.warnings)"
        )
    }

    // MARK: - Обрыв ответа по длине

    /// `MAX_TOKENS` при непустом тексте — это оборванный посреди участка ответ.
    /// Раньше он принимался молча и вылезал потом пропуском в середине записи.
    func testLengthCutIsNotAcceptedSilently() async throws {
        Journal.clear()
        let session = StubURLProtocol.session { _, _ in Self.cutWords([(0, 2, "Только"), (2, 4, "начало.")]) }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        let transcript = try await engine.transcribe(audioURL: audio)

        XCTAssertTrue(
            transcript.warnings.contains { $0.contains("оборвался по длине") },
            "\(transcript.warnings)"
        )
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "повтор того же запроса обрыв не лечит")
        let journal = (try? String(contentsOf: Journal.url, encoding: .utf8)) ?? ""
        XCTAssertTrue(
            journal.contains("остановка=MAX_TOKENS"),
            "причина остановки обязана быть в файле журнала: с телефона системный лог не забрать"
        )
    }

    /// Участок, который можно поделить, обрывом не теряется: половины его
    /// закрывают, и плашке не о чем говорить.
    func testLengthCutIsRecoveredByHalving() async throws {
        let long = FileManager.default.temporaryDirectory.appending(path: "pipe-cut-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 200, at: long)
        defer { try? FileManager.default.removeItem(at: long) }

        let counter = Counter()
        let session = StubURLProtocol.session { _, _ in
            switch counter.next() {
            case 1: Self.cutWords([(0, 40, "Начало участка.")])
            case 2: Self.words([(0, 100, "Половина первая.")])
            default: Self.words([(0, 100, "Половина вторая.")])
            }
        }
        let engine = GeminiTranscriber(
            session: session,
            keyProvider: { "тест-ключ" },
            inlineLimit: 64 * 1024 * 1024
        )

        let transcript = try await engine.transcribe(audioURL: long)

        XCTAssertEqual(StubURLProtocol.requests.count, 3, "запись, затем две половины")
        XCTAssertTrue(transcript.text.contains("Половина первая."), transcript.text)
        XCTAssertTrue(transcript.text.contains("Половина вторая."), transcript.text)
        XCTAssertTrue(transcript.warnings.isEmpty, "потеря возвращена, а не названа: \(transcript.warnings)")
    }

    // MARK: - Пустой ответ

    /// Пустой ответ и зацикливание — разные беды. На устройстве приложение
    /// назвало пустой ответ повтором, и это сбивало с толку.
    func testEmptyAnswerIsNotCalledALoop() async throws {
        let session = StubURLProtocol.session { _, _ in .json(#"{"steps": []}"#) }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        do {
            _ = try await engine.transcribe(audioURL: audio)
            XCTFail("расшифровки нет — это ошибка, а не тихий успех")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(message.contains("текста в ответе не было"), message)
            XCTAssertFalse(message.contains("зациклилась"), "пустой ответ повтором не называем")
        }
    }

    /// Непонятный ответ сохраняется целиком — иначе причину не найти.
    func testUnparsedAnswerIsSavedForInspection() async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dump = documents.appending(path: "Lori/last-gemini-response.json")
        try? FileManager.default.removeItem(at: dump)
        let session = StubURLProtocol.session { _, _ in .json(#"{"steps": [], "state": "DONE"}"#) }
        let engine = GeminiTranscriber(session: session, keyProvider: { "тест-ключ" })

        _ = try? await engine.transcribe(audioURL: audio)

        let saved = try XCTUnwrap(try? String(contentsOf: dump, encoding: .utf8))
        XCTAssertTrue(saved.contains("DONE"), "сохранён именно ответ сервиса")
    }
}
