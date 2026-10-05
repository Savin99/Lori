import Combine
import Foundation
import Hub
import MLXLMCommon

/// Модель, которая делает заголовок и краткое описание расшифровки.
///
/// Веса скачиваются по желанию: без них приложение работает как раньше,
/// заголовком служит первая фраза. Вариантов два, потому что предел памяти у
/// приложения на iPhone около трёх гигабайт, а права на его повышение
/// (`com.apple.developer.kernel.increased-memory-limit`) бесплатная команда
/// разработчика не подписывает — проверено сборкой.
enum SummaryVariant: String, CaseIterable, Identifiable, Sendable {
    /// Qwen3 4B в четырёхбитном виде: формулировки заметно лучше.
    case heavy
    /// Qwen3 1.7B: запас по памяти, если устройство занято.
    case light

    var id: String { rawValue }

    var repository: String {
        switch self {
        case .heavy: "mlx-community/Qwen3-4B-4bit"
        case .light: "mlx-community/Qwen3-1.7B-4bit"
        }
    }

    var title: String {
        switch self {
        case .heavy: "Крупная модель"
        case .light: "Лёгкая модель"
        }
    }

    var detail: String {
        switch self {
        case .heavy: "Qwen3 4B, около 2,3 ГБ. Формулировки лучше, но памяти нужно почти столько, сколько iOS вообще даёт приложению."
        case .light: "Qwen3 1.7B, около 1,1 ГБ. Проще формулировки, зато запас по памяти."
        }
    }

    /// Приблизительный вес — показывается до скачивания.
    var bytes: Int {
        switch self {
        case .heavy: 2_300_000_000
        case .light: 1_100_000_000
        }
    }

    /// «2,3 ГБ» — для кнопки скачивания.
    var sizeLabel: String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000)
            .replacingOccurrences(of: ".", with: ",") + " ГБ"
    }

    /// «крупную модель» — для «Скачать …» и «Удалить …».
    var accusative: String {
        switch self {
        case .heavy: "крупную модель"
        case .light: "лёгкую модель"
        }
    }

    /// Почему эту модель предлагают первой (`SummaryModelStore.recommendedVariant`).
    var recommendation: String {
        switch self {
        case .heavy: "Для этого iPhone — крупная модель: формулирует лучше, и памяти телефона ей хватает."
        case .light: "Для этого iPhone — лёгкая модель: крупной здесь не хватит памяти."
        }
    }

    /// Сколько памяти считаем достаточной, чтобы вообще браться за модель.
    /// У крупной запас больше её собственного веса: после прошлого запуска
    /// память возвращается не сразу, и запускать вторую расшифровку впритык —
    /// верный способ поймать снятие приложения системой.
    var requiredFreeBytes: Int {
        switch self {
        case .heavy: 3_100_000_000
        case .light: 1_500_000_000
        }
    }
}

/// Где лежат веса и что уже скачано.
///
/// Каталог свой, а не системный кэш: `defaultHubApi` кладёт файлы в Caches,
/// откуда iOS вправе их удалить в любой момент — для двух гигабайт это плохой
/// дом. Application Support рядом с моделями GigaAM надёжнее.
@MainActor
class SummaryModelStore: ObservableObject {
    @Published private(set) var installed: Set<SummaryVariant> = []
    @Published private(set) var downloading: SummaryVariant?
    @Published private(set) var fraction: Double = 0
    @Published var failure: String?

    private let root: URL
    private var task: Task<Void, Never>?

    init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
        refresh()
    }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori", directoryHint: .isDirectory)
            .appending(path: "Summary", directoryHint: .isDirectory)
    }

    var hub: HubApi { HubApi(downloadBase: root) }

    func directory(of variant: SummaryVariant) -> URL {
        hub.localRepoLocation(Hub.Repo(id: variant.repository))
    }

    /// Модель считается скачанной, когда на месте и веса, и конфигурация:
    /// оборванная закачка не должна выглядеть готовой.
    func isInstalled(_ variant: SummaryVariant) -> Bool {
        let directory = directory(of: variant)
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.appending(path: "config.json").path) else { return false }
        let contents = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    func refresh() {
        installed = Set(SummaryVariant.allCases.filter(isInstalled))
    }

    /// Хоть одна модель скачана — заголовки придумывает модель, а не первая фраза.
    var isReady: Bool { !installed.isEmpty }

    /// Какую модель предложить скачать одной кнопкой.
    var recommendedVariant: SummaryVariant { Self.recommendedVariant() }

    /// Выбор по памяти телефона, а не по вкусу.
    ///
    /// Права `increased-memory-limit` бесплатная команда не подписывает, и
    /// приложению достаётся только часть памяти телефона. Крупная модель берётся
    /// за работу, когда свободно 3,1 ГБ (`requiredFreeBytes`): на телефоне с 8 ГБ
    /// это впритык, но проходит — журнал 2 сентября, iPhone 16 Pro Max: после
    /// загрузки 2,3 ГБ весов свободно ещё около гигабайта. На телефоне с 6 ГБ
    /// приложению столько не дают вовсе: скачанная крупная модель там никогда бы
    /// не запустилась, и заголовков не было бы совсем. Порог — 7 млрд байт:
    /// `physicalMemory` у телефонов «8 ГБ» чуть ниже номинала, у «6 ГБ» — около 6.
    nonisolated static func recommendedVariant(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> SummaryVariant {
        physicalMemory >= 7_000_000_000 ? .heavy : .light
    }

    /// Значение строки «Заголовки» в корне настроек. Без модели заголовки всё
    /// равно есть — из первой фразы, и «выключены» там было неправдой.
    var statusLine: String {
        if downloading != nil { return "скачивается \(Int(fraction * 100))%" }
        if let best = SummaryVariant.allCases.first(where: installed.contains) {
            return best.title.lowercased()
        }
        return "первая фраза"
    }

    func download(_ variant: SummaryVariant) {
        guard downloading == nil else { return }
        downloading = variant
        fraction = 0
        failure = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let hub = await self.hub
                // **Качаем файлы, а не собираем модель.** `loadModelContainer`
                // после скачивания ещё и строит модель, а это `eval(model)` —
                // настоящая работа на графическом процессоре. Два следствия, и
                // оба плохие: две с лишним гигабайты весов оказывались в памяти
                // без всякой нужды (предел у приложения около трёх), а если
                // скачивание доходило при свёрнутом приложении, где iOS
                // графический процессор не даёт, MLX гасил процесс по `abort()`
                // — та же гибель, что и у счёта заголовка.
                _ = try await downloadModel(
                    hub: hub,
                    configuration: ModelConfiguration(id: variant.repository)
                ) { progress in
                    Task { @MainActor [weak self] in
                        self?.fraction = progress.fractionCompleted
                    }
                }
            } catch is CancellationError {
                // Отмену человек сделал сам.
            } catch {
                await MainActor.run { self.failure = error.localizedDescription }
            }
            await MainActor.run {
                self.downloading = nil
                self.fraction = 0
                self.refresh()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        downloading = nil
        fraction = 0
    }

    func delete(_ variant: SummaryVariant) {
        try? FileManager.default.removeItem(at: directory(of: variant))
        refresh()
    }

    /// Сколько места занято на диске — в настройках это важнее имени модели.
    func installedBytes() -> Int {
        SummaryVariant.allCases.filter(isInstalled).reduce(0) { total, variant in
            total + Self.size(of: directory(of: variant))
        }
    }

    private static func size(of directory: URL) -> Int {
        let manager = FileManager.default
        guard let items = manager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total = 0
        for case let url as URL in items {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
