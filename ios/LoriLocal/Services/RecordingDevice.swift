import AVFoundation
import Foundation

enum AudioCaptureError: LocalizedError, Equatable {
    case microphoneDenied
    case noRecording
    /// Сессию записи не дали включить: микрофон держит звонок или другое приложение.
    case microphoneBusy

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Разреши Lori доступ к микрофону в настройках iPhone."
        case .noRecording:
            "Запись не началась: микрофон сейчас недоступен. Если звук пишет другое приложение, закрой его и попробуй снова."
        case .microphoneBusy:
            "Микрофон сейчас занят — например, идёт звонок. Попробуй, когда он закончится."
        }
    }
}

/// То, чем запись трогает звуковое железо. Отдельным протоколом, чтобы модульные
/// тесты гоняли контроллер записи без микрофона: в симуляторе его нет вовсе
/// (`AVAudioRecorder.record()` отвечает «нет»), а переходы «пауза — звонок —
/// продолжить — склейка» проверить надо.
@MainActor
protocol RecordingDevice: AnyObject {
    /// Кусок оборвался не по нашей просьбе: ошибка кодировщика, рекордер встал сам.
    var onFailure: (() -> Void)? { get set }
    /// Сколько пишется текущий кусок.
    var currentTime: TimeInterval { get }

    func requestPermission() async -> Bool
    /// Включает звуковую сессию записи. Отказ — это чаще всего занятый микрофон.
    func activate() throws
    /// Отпускает сессию и даёт другим приложениям продолжить свой звук.
    func deactivate()
    /// Начинает кусок в файл. Файл появляется сразу, но читаемым становится после `end()`.
    func begin(at url: URL) throws
    /// Закрывает кусок: дописывает оглавление m4a. Без этого файл не прочитать.
    func end()
    /// Громкость 0…1 для живой волны, пока кусок пишется.
    func level() -> Double?
    /// Входы текущего маршрута: по ним видно, пропал ли микрофон при смене маршрута.
    func currentInputs() -> [String]
}

/// Настоящий микрофон: `AVAudioRecorder`, AAC 44,1 кГц моно — как и раньше.
@MainActor
final class MicrophoneDevice: NSObject, RecordingDevice, AVAudioRecorderDelegate {
    var onFailure: (() -> Void)?
    private var recorder: AVAudioRecorder?

    /// Формат кусков. Вычисляемое свойство, а не хранимое: словарь `[String: Any]` не
    /// `Sendable`, а нужен он и вне главного актора (заглушка, тесты склейки).
    nonisolated static var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }

    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        // Входящий звонок баннером не прерывает запись, пока его не приняли: отклонённый
        // звонок не ставит паузу вовсе, принятый — ставит. Так и задумано для приложений
        // записи (заголовок `AVAudioSession.h`, `setPrefersNoInterruptionsFromSystemAlerts`:
        // «Apps that record audio … are candidates for using this feature»). При
        // полноэкранном звонке настройка не действует, и прерывание приходит сразу.
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        do {
            try session.setActive(true)
        } catch {
            throw AudioCaptureError.microphoneBusy
        }
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func begin(at url: URL) throws {
        let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        guard recorder.record() else {
            // Файл к этому моменту уже создан — пустой, с одним заголовком.
            recorder.delegate = nil
            recorder.stop()
            try? FileManager.default.removeItem(at: url)
            throw AudioCaptureError.noRecording
        }
        self.recorder = recorder
    }

    func end() {
        guard let recorder else { return }
        self.recorder = nil
        // Делегат снимается до `stop()`: своя остановка — не сбой.
        recorder.delegate = nil
        recorder.stop()
    }

    func level() -> Double? {
        guard let recorder, recorder.isRecording else { return nil }
        recorder.updateMeters()
        return Self.normalizedLevel(recorder.averagePower(forChannel: 0))
    }

    func currentInputs() -> [String] {
        AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid)
    }

    /// Средняя мощность приходит в децибелах от -160 до 0; для индикатора хватает верхних 50 дБ.
    static func normalizedLevel(_ decibels: Float) -> Double {
        let floor: Float = -50
        guard decibels.isFinite else { return 0 }
        let clamped = min(0, max(floor, decibels))
        return Double((clamped - floor) / -floor)
    }

    // Делегат зовут не обязательно на главном потоке; рекордер не `Sendable`, поэтому
    // через границу едет только его опознавательный знак.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in self.stoppedOnItsOwn(id) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in self.stoppedOnItsOwn(id) }
    }

    private func stoppedOnItsOwn(_ id: ObjectIdentifier) {
        guard let recorder, ObjectIdentifier(recorder) == id else { return }
        onFailure?()
    }
}

#if DEBUG
/// Микрофон-заглушка для Lori QA в симуляторе: без него запись, островок и склейку
/// там не увидеть вовсе. Пишет настоящий m4a — тихий тон длиной ровно в «записанное»,
/// так что склейка, плеер и расшифровка проверочным движком работают с честным файлом.
///
/// Включается так же, как проверочный движок: DEBUG, bundle ID Lori QA и аргумент
/// запуска `--ui-stub-recorder`.
@MainActor
final class StubRecordingDevice: RecordingDevice {
    nonisolated static let argument = "--ui-stub-recorder"

    nonisolated static var enabled: Bool {
        RecoveryProbe.allowsDiagnostics(in: Bundle.main.bundleIdentifier)
            && ProcessInfo.processInfo.arguments.contains(argument)
    }

    var onFailure: (() -> Void)?
    private var startedAt: Date?
    private var url: URL?

    var currentTime: TimeInterval { startedAt.map { Date.now.timeIntervalSince($0) } ?? 0 }

    func requestPermission() async -> Bool { true }
    func activate() throws {}
    func deactivate() {}

    func begin(at url: URL) throws {
        // Открытый кусок — как у настоящего рекордера: файл есть, но не читается.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.url = url
        startedAt = .now
    }

    func end() {
        guard let url, let startedAt else { return }
        self.url = nil
        self.startedAt = nil
        try? Self.writeTone(seconds: max(0.2, Date.now.timeIntervalSince(startedAt)), to: url)
    }

    func level() -> Double? {
        guard startedAt != nil else { return nil }
        let t = currentTime
        return 0.35 + 0.25 * sin(t * 2.1) * sin(t * 0.7)
    }

    func currentInputs() -> [String] { ["stub"] }

    static func writeTone(seconds: TimeInterval, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let rate = 44_100.0
        let file = try AVAudioFile(forWriting: url, settings: MicrophoneDevice.settings)
        let format = file.processingFormat
        let block = AVAudioFrameCount(rate)
        var written = 0.0
        let total = seconds * rate
        while written < total {
            let frames = AVAudioFrameCount(min(Double(block), total - written))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let channel = buffer.floatChannelData?[0] else { break }
            buffer.frameLength = frames
            for index in 0..<Int(frames) {
                let time = (written + Double(index)) / rate
                channel[index] = Float(0.05 * sin(2 * Double.pi * 220 * time))
            }
            try file.write(from: buffer)
            written += Double(frames)
        }
    }
}
#endif
