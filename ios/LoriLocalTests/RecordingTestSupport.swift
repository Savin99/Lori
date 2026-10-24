import AVFoundation
import XCTest
@testable import LoriLocal

/// Заготовки для тестов записи: микрофон и Live Activity понарошку.
///
/// В симуляторе микрофона нет (`AVAudioRecorder.record()` отвечает «нет»), а
/// ActivityKit из модульного теста не проверить, — поэтому контроллер записи гоняется
/// на подставных устройствах. Куски при этом **настоящие** m4a (AAC 44,1 кГц моно, как
/// у рекордера): склейка, проверка читаемости и длительности работают с честными файлами.

/// Микрофон понарошку: `end()` пишет кусок нужной длины настоящим AAC.
@MainActor
final class FakeRecordingDevice: RecordingDevice {
    var onFailure: (() -> Void)?
    var permission = true
    var activateError: Error?
    var beginError: Error?
    /// Длина следующих кусков по очереди; кончились — `defaultSeconds`.
    var chunkSeconds: [TimeInterval] = []
    var defaultSeconds: TimeInterval = 1
    var inputs = ["Built-In Microphone"]

    private(set) var activeURL: URL?
    private(set) var begins: [URL] = []
    private(set) var ends = 0
    private(set) var activations = 0
    private(set) var deactivations = 0

    var currentTime: TimeInterval { activeURL == nil ? 0 : (chunkSeconds.first ?? defaultSeconds) }

    func requestPermission() async -> Bool { permission }

    func activate() throws {
        if let activateError { throw activateError }
        activations += 1
    }

    func deactivate() { deactivations += 1 }

    func begin(at url: URL) throws {
        if let beginError { throw beginError }
        // Открытый кусок, как у настоящего рекордера: файл есть, читать нечего.
        FileManager.default.createFile(atPath: url.path, contents: Data("ftyp".utf8))
        activeURL = url
        begins.append(url)
    }

    func end() {
        guard let url = activeURL else { return }
        activeURL = nil
        ends += 1
        let seconds = chunkSeconds.isEmpty ? defaultSeconds : chunkSeconds.removeFirst()
        try? RecordingFiles.writeAAC(seconds: seconds, to: url)
    }

    func level() -> Double? { activeURL == nil ? nil : 0.5 }

    func currentInputs() -> [String] { inputs }

    /// Процесс умер посреди куска: файл остаётся без оглавления, `end()` не звали.
    func dieMidChunk(seconds: TimeInterval = 2) throws {
        guard let url = activeURL else { return }
        try RecordingFiles.writeAAC(seconds: seconds, to: url)
        try RecordingFiles.cutTail(of: url)
        activeURL = nil
    }

    /// Рекордер встал сам (ошибка кодировщика).
    func failOnItsOwn() {
        onFailure?()
    }
}

/// Live Activity понарошку: запоминает каждое состояние, которое ей показали.
@MainActor
final class FakeRecordingActivity: RecordingActivityPresenting {
    var areEnabled = true
    /// Подберётся ли «живая» активность после перезапуска.
    var adoptable = false
    private(set) var running = false
    private var serial = 0
    private(set) var history: [RecordingActivityAttributes.ContentState] = []
    private(set) var staleDates: [Date?] = []
    private(set) var starts = 0
    private(set) var ends: [(token: String?, final: RecordingActivityAttributes.ContentState?)] = []
    private(set) var endAllCount = 0

    var isRunning: Bool { running }
    var token: String? { running ? "activity-\(serial)" : nil }
    var last: RecordingActivityAttributes.ContentState? { history.last }

    func adopt() async -> Bool {
        if adoptable {
            serial += 1
            running = true
        }
        return adoptable
    }

    func start(_ state: RecordingActivityAttributes.ContentState, staleDate: Date?) throws {
        serial += 1
        running = true
        starts += 1
        history.append(state)
        staleDates.append(staleDate)
    }

    func update(_ state: RecordingActivityAttributes.ContentState, staleDate: Date?) async {
        guard running else { return }
        history.append(state)
        staleDates.append(staleDate)
    }

    func end(token: String?, final state: RecordingActivityAttributes.ContentState?) async {
        ends.append((token, state))
        if token == nil || token == self.token { running = false }
    }

    func endAll() async {
        endAllCount += 1
        running = false
    }
}

/// Настоящие короткие m4a для склейки.
enum RecordingFiles {
    /// AAC 44,1 кГц моно — те же настройки, что у рекордера Lori. Тон, а не тишина:
    /// у тишины нечего сравнивать, а длительность считается и так.
    static func writeAAC(seconds: TimeInterval, to url: URL, frequency: Double = 330) throws {
        try? FileManager.default.removeItem(at: url)
        let rate = 44_100.0
        let file = try AVAudioFile(forWriting: url, settings: MicrophoneDevice.settings)
        let format = file.processingFormat
        let total = Int(seconds * rate)
        var written = 0
        while written < total {
            let frames = min(Int(rate), total - written)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
            buffer.frameLength = AVAudioFrameCount(frames)
            for index in 0..<frames {
                let time = Double(written + index) / rate
                channel[index] = Float(0.3 * sin(2 * Double.pi * frequency * time))
            }
            try file.write(from: buffer)
            written += frames
        }
    }

    /// Отрезает хвост файла вместе с оглавлением m4a — так выглядит кусок процесса,
    /// убитого посреди записи.
    static func cutTail(of url: URL) throws {
        let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size / 2))
        try handle.close()
    }

    static func duration(of url: URL) async throws -> TimeInterval {
        try await AVURLAsset(url: url).load(.duration).seconds
    }
}

/// Рабочая папка, папка сессии, очередь расшифровки и контроллер — на временных
/// каталогах, которые убираются за тестом.
@MainActor
final class RecordingFixture {
    let root: URL
    let sessionDirectory: URL
    let queueStore: URL
    let workspace: WorkspaceStore
    let gate: QueueGate
    let transcription: TranscriptionService
    let device = FakeRecordingDevice()
    let activity = FakeRecordingActivity()
    let center = NotificationCenter()
    var autoTranscribe = true
    var engine: TranscriptionEngineKind = .gigaam
    var inCall = false
    var appActive = true
    private(set) var log: [String] = []
    private(set) var backgroundTimeTaken: [String] = []
    private(set) var backgroundTimeReleased = 0

    init() {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "LoriRecording-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = base.appending(path: "Workspace", directoryHint: .isDirectory)
        sessionDirectory = base.appending(path: "Session", directoryHint: .isDirectory)
        queueStore = base.appending(path: "queue.json")
        workspace = WorkspaceStore(rootURL: root)
        workspace.start()
        // Движок-заглушка на каждый вид: какой бы ни стоял в настройках тестового
        // приложения, запись встанет в очередь, а шлагбаум её там подержит.
        let gate = QueueGate()
        self.gate = gate
        let engines = Dictionary(uniqueKeysWithValues: TranscriptionEngineKind.allCases.map {
            ($0, QueueEngine(gate: gate) as any Transcribing)
        })
        transcription = TranscriptionService(engines: engines, interruptedStore: queueStore, availableMemory: { 0 })
    }

    var store: RecordingSessionStore { RecordingSessionStore(directory: sessionDirectory) }

    /// Новый контроллер на тех же папках — то же, что новый запуск Lori.
    func controller() -> RecordingController {
        var hooks = RecordingController.Hooks(inCall: { [unowned self] in self.inCall })
        hooks.autoTranscribe = { [unowned self] in self.autoTranscribe }
        hooks.engine = { [unowned self] in self.engine }
        hooks.isAppActive = { [unowned self] in self.appActive }
        hooks.backgroundTime = { [unowned self] name in
            self.backgroundTimeTaken.append(name)
            return { [unowned self] in self.backgroundTimeReleased += 1 }
        }
        hooks.notifications = center
        hooks.log = { [unowned self] line in
            MainActor.assumeIsolated { self.log.append(line) }
        }
        hooks.farewell = .zero
        hooks.failureGrace = .milliseconds(20)
        hooks.finishURL = URL(string: "ru.ilyaqa.lori.local.qa://recording/finish")!
        return RecordingController(
            workspace: workspace,
            transcription: transcription,
            device: device,
            store: store,
            presenter: activity,
            hooks: hooks
        )
    }

    /// Файлы в корзине Lori.
    func trash() -> [String] {
        let trash = root.appending(path: ".LoriTrash", directoryHint: .isDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).sorted()
    }

    /// Записи в `Recordings/`.
    func recordings() -> [String] {
        let folder = root.appending(path: "Recordings", directoryHint: .isDirectory)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func cleanUp() async {
        transcription.cancelAll()
        await gate.openAll()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

/// Ждёт условия без жёсткого сна: уведомления идут через главную очередь, а
/// обновления активности — цепочкой задач.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("условие не наступило за \(timeout)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
