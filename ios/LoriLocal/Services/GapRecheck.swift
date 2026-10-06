import Foundation

/// Перепроверка сохранённых плашек «Пропуск A–B» по самому звуку.
///
/// Расшифровки, сделанные до 6 октября 2026, несут в файле строки `>` о пропусках,
/// которые прежнее правило находило в обычной тишине: хватало щелчка, стука или
/// вдоха (`AudioLoudness`). У владельца такие строки уже лежат в файлах — на записи
/// 43:28 это «Пропуск 4:19–5:19» и «Пропуск 20:17–20:34».
///
/// Переписывать `.md` молча нельзя: это файл человека, его правят руками и уносят
/// наружу. Поэтому экран записи и экспорт спрашивают здесь, какие замечания
/// показывать. «Пропуск», под которым в записи тишина, прячется — файл остаётся
/// как был, и другой движок или следующая версия правила его прочтут заново.
///
/// - Слушаются только участки из плашек — не вся запись: участок плюс дюжина проб
///   по четыре секунды на уровень речи.
/// - Вердикт хранится по записи (размер и время правки файла), по таймкодам
///   расшифровки и по версии правила (`AudioLoudness.rule`). Повторное открытие —
///   и после перезапуска — ничего не декодирует.
/// - Записи нет или участок не читается — плашка остаётся: спрятать тревогу можно,
///   только услышав тишину, а не предположив её.
actor GapRecheck {
    /// Общий экземпляр приложения: экран записи и экспорт делят вердикты.
    static let shared = GapRecheck(storage: GapRecheck.defaultStorage)

    /// `Caches`, а не `Application Support`: вердикт — производное от звука, его
    /// можно потерять и посчитать заново, и в резервную копию ему незачем.
    static var defaultStorage: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "Lori", directoryHint: .isDirectory)
            .appending(path: "gap-verdicts.json")
    }

    /// Больше вердиктов не держим: это несколько десятков байт на плашку, но
    /// файл не должен расти вечно.
    static let capacity = 400

    typealias Judge = @Sendable (URL, ClosedRange<TimeInterval>, Float?) -> AudioLoudness.Verdict
    typealias Measure = @Sendable (URL, [ClosedRange<TimeInterval>]) -> Float?

    private struct Entry: Codable {
        let silent: Bool
        let checked: Date
    }

    private struct Stored: Codable {
        var rule: Int
        var verdicts: [String: Entry]
    }

    private let storage: URL?
    private let judge: Judge
    private let measure: Measure
    private var verdicts: [String: Entry] = [:]
    private var loaded = false
    /// Одна и та же проверка, о которой спросили дважды (экран и «Поделиться»),
    /// декодируется один раз: второй ждёт первого.
    private var running: [String: Task<[String: AudioLoudness.Verdict], Never>] = [:]

    /// `judge` и `measure` подставляются в тестах — чтобы считать, сколько раз
    /// слушали звук. По умолчанию это правило `AudioLoudness`.
    init(
        storage: URL?,
        judge: @escaping Judge = { AudioLoudness.verdict(in: $0, range: $1, speechLevel: $2) },
        measure: @escaping Measure = { AudioLoudness.speechLevel(in: $0, speech: $1) }
    ) {
        self.storage = storage
        self.judge = judge
        self.measure = measure
    }

    // MARK: - Что показывать

    /// Замечания, которые стоит показать, в прежнем порядке: все, кроме
    /// «пропусков», под которыми в записи тишина.
    func visible(in document: TranscriptDocument, audio: URL?) async -> [String] {
        await visible(document.warnings, speech: Self.speech(in: document), audio: audio)
    }

    /// То же по голым значениям: `speech` — отрезки с текстом, из них меряется
    /// уровень речи этой записи.
    func visible(_ warnings: [String], speech: [ClosedRange<TimeInterval>], audio: URL?) async -> [String] {
        let gaps = warnings.compactMap { warning in TranscriptCoverage.gap(in: warning).map { (warning, $0) } }
        guard !gaps.isEmpty, let audio, let identity = Self.identity(of: audio) else { return warnings }
        loadIfNeeded()

        let base = "\(identity)|\(Self.fingerprint(speech))|\(AudioLoudness.rule)"
        var silent: Set<String> = []
        var unknown: [ClosedRange<TimeInterval>] = []
        for (warning, range) in gaps {
            guard let entry = verdicts["\(base)|\(Self.key(range))"] else {
                unknown.append(range)
                continue
            }
            if entry.silent { silent.insert(warning) }
        }

        if !unknown.isEmpty {
            let judged = await judgeOnce(unknown, audio: audio, speech: speech, base: base)
            let now = Date()
            for (warning, range) in gaps where unknown.contains(range) {
                let key = Self.key(range)
                switch judged[key] {
                case .silence:
                    silent.insert(warning)
                    verdicts["\(base)|\(key)"] = Entry(silent: true, checked: now)
                case .speech:
                    verdicts["\(base)|\(key)"] = Entry(silent: false, checked: now)
                case .unreadable, nil:
                    // Не услышали — не утверждаем и не запоминаем: файл мог быть
                    // занят или ещё не докачан, в следующий раз послушаем снова.
                    break
                }
            }
            save()
        }
        return warnings.filter { !silent.contains($0) }
    }

    /// Плашка о пропуске — то, что здесь перепроверяется.
    nonisolated static func isGap(_ warning: String) -> Bool {
        TranscriptCoverage.gap(in: warning) != nil
    }

    /// Отрезки с текстом из разобранного файла: реплики с настоящим временем.
    /// Границы куска («кусок 0:00–5:00») за время речи не считаются — как и при
    /// самой расшифровке.
    nonisolated static func speech(in document: TranscriptDocument) -> [ClosedRange<TimeInterval>] {
        document.lines.compactMap { line in
            guard !line.isApproximate, let start = line.start, let end = line.end, end > start else { return nil }
            return start...end
        }
    }

    // MARK: - Слушание

    private func judgeOnce(
        _ ranges: [ClosedRange<TimeInterval>],
        audio: URL,
        speech: [ClosedRange<TimeInterval>],
        base: String
    ) async -> [String: AudioLoudness.Verdict] {
        let batch = base + "|" + ranges.map(Self.key).joined(separator: ",")
        if let task = running[batch] { return await task.value }
        let judge = judge
        let measure = measure
        // Декодирование — вне актора и не на главном потоке: минута звука это
        // доли секунды на телефоне, но экран не должен ждать её в очереди.
        let task = Task.detached(priority: .utility) { () -> [String: AudioLoudness.Verdict] in
            let level = measure(audio, speech)
            var result: [String: AudioLoudness.Verdict] = [:]
            for range in ranges {
                let verdict = judge(audio, range, level)
                result[Self.key(range)] = verdict
                // В файл журнала: по нему с телефона видно, почему плашка исчезла.
                let place = TranscriptCoverage.describe(range)
                switch verdict {
                case .silence:
                    Diagnostics.note("плашка «Пропуск \(place)»: в записи тишина — не показываю")
                case let .speech(found):
                    Diagnostics.note(
                        "плашка «Пропуск \(place)»: речь \(TranscriptCoverage.describe(found)) — показываю"
                    )
                case .unreadable:
                    Diagnostics.note("плашка «Пропуск \(place)»: звук не читается — показываю как есть")
                }
            }
            return result
        }
        running[batch] = task
        let result = await task.value
        running[batch] = nil
        return result
    }

    // MARK: - Ключи

    /// Запись по размеру и времени правки, а не по пути: переименование не меняет
    /// звука, а путь контейнера приложения меняется при переустановке.
    /// `attributesOfItem`, а не `URL.resourceValues`: последний кэширует значения
    /// на самом объекте URL (ловушка из `TranscriptCheckpoint`).
    private static func identity(of audio: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: audio.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(size.int64Value)-\(Int(modified.timeIntervalSince1970))"
    }

    /// Отпечаток таймкодов расшифровки: от них зависит уровень речи, а значит и
    /// порог. Перерасшифровали — отпечаток другой, и вердикт считается заново.
    /// Свой FNV-1a, а не `Hasher`: тот солится заново при каждом запуске.
    private static func fingerprint(_ speech: [ClosedRange<TimeInterval>]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for range in speech {
            for byte in "\(Int(range.lowerBound * 10))-\(Int(range.upperBound * 10));".utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return "\(speech.count)-\(String(hash, radix: 16))"
    }

    private static func key(_ range: ClosedRange<TimeInterval>) -> String {
        "\(Int(range.lowerBound * 10))-\(Int(range.upperBound * 10))"
    }

    // MARK: - Хранение

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let storage, let data = try? Data(contentsOf: storage),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.rule == AudioLoudness.rule else { return }
        verdicts = stored.verdicts
    }

    private func save() {
        guard let storage else { return }
        if verdicts.count > Self.capacity {
            let newest = verdicts.sorted { $0.value.checked > $1.value.checked }.prefix(Self.capacity)
            verdicts = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        do {
            try FileManager.default.createDirectory(
                at: storage.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Stored(rule: AudioLoudness.rule, verdicts: verdicts))
            try data.write(to: storage, options: .atomic)
        } catch {
            // Кэш, а не данные человека: не записался — посчитаем в следующий раз.
            Diagnostics.log.notice("вердикты пропусков не сохранились — \(error.localizedDescription, privacy: .public)")
        }
    }
}
