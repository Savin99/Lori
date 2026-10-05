import Foundation

/// Факт одного прогона: запись такой длины на таком движке заняла столько.
struct SpeedMeasure: Equatable {
    let engine: TranscriptionEngineKind
    let mode: String?
    let audio: TimeInterval
    let spent: TimeInterval
}

/// Сколько времени займёт расшифровка — по факту прошлых прогонов на этом телефоне.
///
/// Оценка остатка у `TranscriptionService` считается по уже начатой работе, а
/// человеку нужно знать цену решения **до** нажатия: «на телефоне ~12 минут»
/// против «в облако ~3 минуты» — это и есть выбор движка. Гадать по названию
/// движка нельзя: телефоны различаются в разы, а сеть — на порядок. Поэтому
/// скорость запоминается по факту, а умолчания служат лишь до первого замера.
@MainActor
final class TranscriptionSpeed: ObservableObject {
    /// Доля: секунд работы на секунду звука. Считается скользящим средним,
    /// чтобы один аномальный прогон не сдвинул оценку навсегда.
    struct Measure: Codable, Equatable {
        var ratio: Double
        var runs: Int
    }

    @Published private(set) var measures: [String: Measure] = [:]

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
        load()
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori", directoryHint: .isDirectory)
            .appending(path: "speed.json")
    }

    /// Замеры разведены по режимам: у GigaAM точный вариант считает заметно
    /// дольше быстрого, и одно среднее на движок врало бы обоим.
    static func key(engine: TranscriptionEngineKind, mode: String?) -> String {
        "\(engine.rawValue)/\(mode ?? "-")"
    }

    // MARK: - Оценка

    /// Сколько примерно займёт расшифровка записи такой длины.
    func estimate(audio seconds: TimeInterval, engine: TranscriptionEngineKind, mode: String?) -> TimeInterval {
        guard seconds > 0 else { return 0 }
        let ratio = measures[Self.key(engine: engine, mode: mode)]?.ratio ?? Self.defaultRatio(for: engine)
        return seconds * ratio + Self.upload(seconds: seconds, engine: engine)
    }

    /// Вторая строка карточки прикреплённого файла: куда уйдёт запись и надолго ли.
    /// Слово «примерно» обязательно — это оценка, а не обещание.
    func summary(audio seconds: TimeInterval, engine: EngineDescriptor, mode: TranscriptionMode?) -> String {
        let place = engine.locality == .cloud ? "в облако" : "на телефоне"
        guard seconds > 0 else { return place }
        let value = estimate(audio: seconds, engine: engine.kind, mode: mode?.id)
        return "\(place) · примерно \(LoriFormat.approximate(value))"
    }

    // MARK: - Замер

    /// Запоминает прогон. Вес нового замера падает с числом прогонов, но не ниже
    /// трети: телефон могли поставить на зарядку, сеть — сменить, и оценка должна
    /// уметь догнать новую реальность.
    func record(audio seconds: TimeInterval, spent: TimeInterval, engine: TranscriptionEngineKind, mode: String?) {
        guard seconds > 1, spent > 0, spent.isFinite else { return }
        let ratio = spent / seconds
        let key = Self.key(engine: engine, mode: mode)
        if let previous = measures[key] {
            let weight = max(1.0 / 3.0, 1.0 / Double(previous.runs + 1))
            measures[key] = Measure(
                ratio: previous.ratio * (1 - weight) + ratio * weight,
                runs: previous.runs + 1
            )
        } else {
            measures[key] = Measure(ratio: ratio, runs: 1)
        }
        save()
    }

    // MARK: - Умолчания

    /// До первого замера. Числа осознанно грубые: они живут ровно один прогон,
    /// а показывать «неизвестно» вместо оценки — значит не отвечать на вопрос.
    private static func defaultRatio(for engine: TranscriptionEngineKind) -> Double {
        switch engine {
        case .gigaam: 0.25
        // Turbo — четыре слоя декодера против тридцати двух у large-v3, но
        // авторегрессивный декодер всё равно дороже CTC. Число живёт до первого замера.
        case .whisper: 0.35
        case .apple: 0.12
        case .openAI: 0.08
        case .gemini: 0.06
        // Запись уходит одним запросом, поэтому в оценке почти всё — выгрузка;
        // сам Scribe считает быстрее реального времени. Живёт до первого замера.
        case .elevenLabs: 0.05
        }
    }

    /// Отправка в облако. Запись уходит уже сжатой в FLAC 16 кГц моно
    /// (`CloudAudio`) — это около 32 КБ на секунду звука; типичную скорость
    /// отдачи берём мобильной, а не домашней, иначе оценка врёт там, где важна.
    private static func upload(seconds: TimeInterval, engine: TranscriptionEngineKind) -> TimeInterval {
        guard engine.leavesDevice else { return 0 }
        let bytes = seconds * 32_000
        return bytes / 600_000
    }

    // MARK: - Хранение

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode([String: Measure].self, from: data) else { return }
        measures = payload
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(measures) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
