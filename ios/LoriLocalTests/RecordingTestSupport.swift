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
    var isInputAvailable = true
    /// Сколько начала нового куска повторяет конец старого при смене.
    var rotationOverlap: TimeInterval = 0.3
    /// Смена с дырой: так ведёт себя `MicrophoneDevice`, если второй рекордер не пошёл.
    var rotationGap: TimeInterval?
    var rotateError: Error?
    /// Смена встаёт на середине и ждёт `releaseRotation()` — чтобы вклиниться паузой.
    var holdRotation = false

    private(set) var activeURL: URL?
    private(set) var incomingURL: URL?
    private(set) var rotations = 0
    private var heldRotation: CheckedContinuation<Void, Never>?
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
        if let incomingURL {
            // Как у настоящего: начатый посреди смены кусок — повтор хвоста, его выбрасывают.
            try? FileManager.default.removeItem(at: incomingURL)
            self.incomingURL = nil
        }
        guard let url = activeURL else { return }
        activeURL = nil
        ends += 1
        let seconds = chunkSeconds.isEmpty ? defaultSeconds : chunkSeconds.removeFirst()
        try? RecordingFiles.writeAAC(seconds: seconds, to: url)
    }

    func rotate(to url: URL) async throws -> ChunkHandover? {
        guard let old = activeURL else { throw AudioCaptureError.noRecording }
        if let rotateError { throw rotateError }
        rotations += 1
        FileManager.default.createFile(atPath: url.path, contents: Data("ftyp".utf8))
        incomingURL = url
        if holdRotation {
            await withCheckedContinuation { heldRotation = $0 }
        }
        guard incomingURL == url, activeURL == old else { return nil }
        incomingURL = nil
        let seconds = chunkSeconds.isEmpty ? defaultSeconds : chunkSeconds.removeFirst()
        try? RecordingFiles.writeAAC(seconds: seconds, to: old)
        ends += 1
        activeURL = url
        begins.append(url)
        if let rotationGap { return ChunkHandover(overlap: 0, gap: rotationGap) }
        return ChunkHandover(overlap: rotationOverlap, gap: nil)
    }

    /// Отпустить смену, вставшую на `holdRotation`.
    func releaseRotation() {
        heldRotation?.resume()
        heldRotation = nil
    }

    var rotationIsHeld: Bool { heldRotation != nil }

    func level() -> Double? { activeURL == nil ? nil : 0.5 }

    func currentInputs() -> [String] { inputs }

    /// Процесс умер посреди куска: на диске то, что писатель успел записать до `close`.
    func dieMidChunk(seconds: TimeInterval = 2) throws {
        guard let url = activeURL else { return }
        try RecordingFiles.writeUnclosedAAC(seconds: seconds, to: url)
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
    private(set) var ends: [(token: String, final: RecordingActivityAttributes.ContentState?)] = []
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

    func end(token: String, final state: RecordingActivityAttributes.ContentState?) async {
        ends.append((token, state))
        if token == self.token { running = false }
    }

    func endAll() async {
        endAllCount += 1
        running = false
        if holdEndAll {
            await withCheckedContinuation { heldEndAll = $0 }
        }
    }

    /// `endAll` встаёт и ждёт `releaseEndAll()` — так `start()` застревает на ActivityKit.
    var holdEndAll = false
    private var heldEndAll: CheckedContinuation<Void, Never>?
    var endAllIsHeld: Bool { heldEndAll != nil }

    func releaseEndAll() {
        holdEndAll = false
        heldEndAll?.resume()
        heldEndAll = nil
    }
}

/// Звонки понарошку: тест сам говорит, идёт ли звонок, соединился ли и кончился ли.
@MainActor
final class FakeCalls: CallMonitoring {
    var isInCall = false
    var lastCallConnected = false
    var onChange: ((CallChange) -> Void)?

    /// Звонок пошёл (звонит, ещё не соединился).
    func ring() {
        isInCall = true
        lastCallConnected = false
        onChange?(CallChange(connected: false, allEnded: false))
    }

    /// Ответили — с человеком говорят.
    func connect() {
        lastCallConnected = true
        onChange?(CallChange(connected: true, allEnded: false))
    }

    /// Звонков больше нет.
    func hangUp() {
        isInCall = false
        onChange?(CallChange(connected: lastCallConnected, allEnded: true))
    }
}

/// Настоящие короткие m4a для склейки.
enum RecordingFiles {
    static let rate = 44_100.0

    /// Шум с известным зерном: по нему корреляцией находится, где в склейке какой
    /// кусок исходника. Сглажен четырьмя отсчётами — меньше верхов, которые AAC режет.
    static func noise(seconds: TimeInterval, seed: UInt64 = 7) -> [Float] {
        var state = seed
        let count = Int(seconds * rate)
        var raw = [Float](repeating: 0, count: count + 3)
        for index in raw.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            // Равномерно в -0,4…0,4, без постоянной составляющей.
            raw[index] = Float(Int64(bitPattern: state >> 11) % 2_000_000 - 1_000_000) / 1_000_000 * 0.4
        }
        return (0..<count).map { (raw[$0] + raw[$0 + 1] + raw[$0 + 2] + raw[$0 + 3]) / 4 }
    }

    /// AAC из готовых отсчётов — те же настройки, что у рекордера.
    static func writeAAC(samples: ArraySlice<Float>, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: MicrophoneDevice.settings)
        var offset = samples.startIndex
        while offset < samples.endIndex {
            let frames = min(Int(rate), samples.endIndex - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
            buffer.frameLength = AVAudioFrameCount(frames)
            for index in 0..<frames { channel[index] = samples[offset + index] }
            try file.write(from: buffer)
            offset += frames
        }
    }

    /// Отсчёты файла так, как их видит плеер: по временной шкале ассета, со списками
    /// правок — то есть без «разгона» AAC и с отрезанными на стыках повторами.
    static func decode(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            samples += chunk
        }
        return samples
    }

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

    /// Кусок процесса, убитого посреди записи: копия файла, снятая, пока писатель ещё
    /// открыт. Обрезать хвост закрытого файла для этого не годится — замер 24 октября
    /// 2026: закрытый писателем m4a держит `moov` в начале (`ftyp`, `moov`, `free`,
    /// `mdat`) и читается и без хвоста, а у открытого на месте `moov` нули — его не
    /// открывает ничто. Ровно это и остаётся от убитого процесса.
    static func writeUnclosedAAC(seconds: TimeInterval, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let source = url.deletingLastPathComponent().appending(path: ".writing-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: source) }
        let rate = 44_100.0
        let file = try AVAudioFile(forWriting: source, settings: MicrophoneDevice.settings)
        let frames = Int(seconds * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { channel[index] = Float(0.3 * sin(Double(index) * 0.05)) }
        try file.write(from: buffer)
        try FileManager.default.copyItem(at: source, to: url)
        withExtendedLifetime(file) {}
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
    let calls = FakeCalls()
    let center = NotificationCenter()
    var autoTranscribe = true
    var engine: TranscriptionEngineKind = .gigaam
    var appActive = true
    var farewell: Duration = .zero
    var failureGrace: Duration = .milliseconds(20)
    /// Плановая смена куска в тестах не мешает: зовут её сами, `rotateChunk()`.
    var rotateEvery: Duration = .seconds(3600)
    var callSettle: Duration = .milliseconds(10)

    /// Идёт ли звонок — короче, чем `calls.isInCall`.
    var inCall: Bool {
        get { calls.isInCall }
        set { calls.isInCall = newValue }
    }
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
        var hooks = RecordingController.Hooks()
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
        hooks.farewell = farewell
        hooks.failureGrace = failureGrace
        hooks.rotateEvery = rotateEvery
        hooks.callSettle = callSettle
        hooks.finishURL = URL(string: "ru.ilyaqa.lori.local.qa://recording/finish")!
        return RecordingController(
            workspace: workspace,
            transcription: transcription,
            device: device,
            store: store,
            presenter: activity,
            calls: calls,
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
