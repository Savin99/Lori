import BackgroundTasks
import UIKit
import XCTest
@testable import LoriLocal

/// Общие заготовки для тестов очереди и пакетного импорта.
///
/// Свои, а не переиспользованные из `TranscriptionConcurrencyTests`: там шлагбаум
/// `private` и умеет только «открыть всё разом», а проверять порядок и счётчики
/// «2 из 5» можно лишь тогда, когда записи отпускаются по одной.

/// Шлагбаум для движка-заглушки: записывает, кто и в каком порядке дошёл, и держит
/// дошедших, пока тест не отпустит.
actor QueueGate {
    private let blocking: Bool
    private var open: Bool
    private var arrived: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var expectation: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    /// `blocking: false` — только запись порядка, без остановок.
    init(blocking: Bool = true) {
        self.blocking = blocking
        self.open = !blocking
    }

    func arrive(_ name: String) async {
        arrived.append(name)
        if let expectation, arrived.count >= expectation.count {
            self.expectation = nil
            expectation.continuation.resume()
        }
        guard !open else { return }
        await withCheckedContinuation { held.append($0) }
    }

    /// Отпускает самую давно дошедшую запись — остальные продолжают стоять.
    func release() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    func openAll() {
        open = true
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    func arrivals() -> [String] { arrived }

    /// Ждёт, пока до шлагбаума доедут `count` записей. Без опроса в цикле: тест
    /// обязан упасть по таймауту, а не пройти случайно.
    func waitForArrivals(_ count: Int) async {
        guard arrived.count < count else { return }
        await withCheckedContinuation { continuation in
            expectation = (count, continuation)
        }
    }
}

/// Движок-заглушка очереди. Падает на тех файлах, что названы в `failing`.
struct QueueEngine: Transcribing {
    let name = "Очередь"
    let gate: QueueGate
    var failing: Set<String> = []
    var available = true

    func isAvailable() async -> Bool { available }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        progress(0, 2)
        await gate.arrive(audioURL.lastPathComponent)
        try Task.checkCancellation()
        if failing.contains(audioURL.lastPathComponent) {
            throw TranscriptionError.api("сбой на \(audioURL.lastPathComponent)")
        }
        progress(2, 2)
        return Transcript(text: "готово \(audioURL.lastPathComponent)")
    }
}

/// Рабочая папка, файл очереди и сервис — на одном временном каталоге, который
/// убирается за тестом.
@MainActor
final class QueueFixture {
    let root: URL
    let store: URL
    let workspace: WorkspaceStore

    init(files: [String] = []) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "LoriQueue-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = FileManager.default.temporaryDirectory
            .appending(path: "LoriQueueStore-\(UUID().uuidString).json")
        workspace = WorkspaceStore(rootURL: root)
        workspace.start()
        for name in files { try addAudio(name) }
        try workspace.refresh()
    }

    /// Не аудио, а байты: движок-заглушка их не читает.
    @discardableResult
    func addAudio(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("не настоящее аудио".utf8).write(to: url)
        return url
    }

    func entry(_ name: String) throws -> WorkspaceEntry {
        try workspace.entry(at: name)
    }

    /// Сервис на файле очереди фикстуры. Новый вызов — это «новый запуск приложения»:
    /// файл тот же, память пустая.
    func service(
        gate: QueueGate,
        failing: Set<String> = [],
        kind: TranscriptionEngineKind = .gigaam
    ) -> TranscriptionService {
        TranscriptionService(
            engines: [kind: QueueEngine(gate: gate, failing: failing)],
            interruptedStore: store,
            availableMemory: { 0 }
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: store)
    }
}

// MARK: - Подставная система для фоновой задачи

/// Подставная системная задача: запоминает, что с ней делали, и зовёт обработчик
/// истечения так, как зовёт система, — с чужой очереди.
@MainActor
final class FakeRunwayTask: TranscriptionRunway.RunwayTask {
    var totalUnitCount: Int64 = 0
    var completedUnitCount: Int64 = 0
    private(set) var completions: [Bool] = []
    private var expiration: (@Sendable () -> Void)?

    var hasExpirationHandler: Bool { expiration != nil }

    func setExpirationHandler(_ handler: (@Sendable () -> Void)?) { expiration = handler }
    func setTaskCompleted(success: Bool) { completions.append(success) }
    func updateSubtitle(_ subtitle: String) {}

    func expireFromSystemQueue() async {
        guard let handler = expiration else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                handler()
                done.resume()
            }
        }
    }
}

/// Подставная система вокруг Runway: окна UIKit, планировщик, доставка событий фоновой
/// передачи. Ничего настоящего не трогает — ни экран, ни планировщик телефона.
@MainActor
final class FakeSystem {
    var active: Bool
    var submitError: Error?
    private(set) var begun: [String] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private(set) var submitted: [String] = []
    private(set) var cancelled: [String] = []
    private var windows: [String: (id: UIBackgroundTaskIdentifier, expire: () -> Void)] = [:]
    private var deliveries: [@Sendable () -> Void] = []
    private var nextID = 100

    init(active: Bool) { self.active = active }

    func hooks() -> TranscriptionRunway.SystemHooks {
        var hooks = TranscriptionRunway.SystemHooks()
        hooks.isActive = { [self] in active }
        hooks.setScreenAwake = { _ in }
        hooks.notifications = NotificationCenter()
        hooks.isRegistered = { true }
        hooks.submitsAsynchronously = false
        hooks.submit = { [self] request in
            if let submitError { throw submitError }
            submitted.append(request.identifier)
        }
        hooks.pendingRequests = { reply in DispatchQueue.global().async { reply([]) } }
        hooks.cancelRequest = { [self] in cancelled.append($0) }
        hooks.beginBackgroundTask = { [self] name, expire in
            nextID += 1
            let id = UIBackgroundTaskIdentifier(rawValue: nextID)
            begun.append(name)
            windows[name] = (id, expire)
            return id
        }
        hooks.endBackgroundTask = { [self] in ended.append($0) }
        hooks.reconnectTransfers = { [self] in deliveries.append($0) }
        return hooks
    }

    /// Окно с этим именем открыто и не закрыто.
    func isOpen(_ name: String) -> Bool {
        windows[name].map { !ended.contains($0.id) } ?? false
    }

    /// Время окна вышло: UIKit зовёт обработчик на главном потоке.
    func expireWindow(_ name: String) { windows[name]?.expire() }

    /// Сессия доставила все события — с очереди делегата, как настоящая.
    func deliverTransferEvents() {
        let pending = deliveries
        deliveries = []
        DispatchQueue.global().async { pending.forEach { $0() } }
    }
}

/// Асинхронная подача заявки, которой тест отвечает сам и в своём порядке — как
/// `submitTaskRequest` на iOS 27, отвечающий «after an arbitrary amount of delay».
actor SubmissionGate {
    private var calls: [CheckedContinuation<Void, Error>?] = []
    private var expectation: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func submit() async throws {
        try await withCheckedThrowingContinuation { continuation in
            calls.append(continuation)
            if let expectation, calls.count >= expectation.count {
                self.expectation = nil
                expectation.continuation.resume()
            }
        }
    }

    func waitForSubmissions(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { expectation = (count, $0) }
    }

    /// Ответить на заявку номер `index` (с нуля): `error` nil — принята.
    func answer(_ index: Int, error: Error? = nil) {
        guard let continuation = calls[index] else { return }
        calls[index] = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
