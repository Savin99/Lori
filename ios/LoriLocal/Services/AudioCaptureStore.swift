import AVFoundation
import Foundation
import Speech

enum AudioCaptureError: LocalizedError {
    case microphoneDenied
    case noRecording

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Разреши Lori доступ к микрофону в настройках iPhone."
        case .noRecording:
            "Запись ещё не началась."
        }
    }
}

/// Пишет в Lori/Workspace/Recordings. Запись не зависит от распознавания:
/// раньше `start` падал, если движок расшифровки недоступен, и звук нельзя было
/// сохранить вообще. Расшифровка — отдельный шаг в `TranscriptionService`.
@MainActor
final class AudioCaptureStore: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case paused
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var recordingURL: URL?
    /// Длительность и громкость нужны интерфейсу: без них запись выглядит как зависшая кнопка.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?

    /// Идёт захват: сюда же попадает пауза, кнопка микрофона в это время — «стоп».
    var isCapturing: Bool { state == .recording || state == .paused }
    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }

    func start(in workspace: WorkspaceStore) async throws {
        guard state == .idle else { return }
        guard await requestMicrophonePermission() else { throw AudioCaptureError.microphoneDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setActive(true)

        let url = try workspace.makeRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw AudioCaptureError.noRecording }
        self.recorder = recorder
        recordingURL = url
        state = .recording
        startMetering()
    }

    func pause() {
        guard state == .recording, let recorder else { return }
        recorder.pause()
        stopMetering(resetElapsed: false)
        state = .paused
    }

    func resume() {
        guard state == .paused, let recorder else { return }
        guard recorder.record() else { return }
        state = .recording
        startMetering()
    }

    /// Отменённая запись не должна превращаться в файл, который человек не просил.
    /// По правилам проекта удаление — это перенос в локальную корзину.
    func discard(in workspace: WorkspaceStore) {
        let url = recordingURL
        cancel()
        guard let url else { return }
        let relativePath = "Recordings/\(url.lastPathComponent)"
        try? workspace.moveToTrash(relativePath)
    }

    /// Останавливает запись и отдаёт путь сохранённого файла внутри рабочей папки.
    /// Расшифровка вызывается отдельно, поэтому её недоступность не теряет звук.
    @discardableResult
    func stop() -> String? {
        guard isCapturing, let recorder, let url = recordingURL else { return nil }
        recorder.stop()
        self.recorder = nil
        stopMetering()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        recordingURL = nil
        return "Recordings/\(url.lastPathComponent)"
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        recordingURL = nil
        stopMetering()
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                self.level = Self.normalizedLevel(recorder.averagePower(forChannel: 0))
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func stopMetering(resetElapsed: Bool = true) {
        meterTask?.cancel()
        meterTask = nil
        level = 0
        if resetElapsed { elapsed = 0 }
    }

    /// Средняя мощность приходит в децибелах от -160 до 0; для индикатора хватает верхних 50 дБ.
    private static func normalizedLevel(_ decibels: Float) -> Double {
        let floor: Float = -50
        guard decibels.isFinite else { return 0 }
        let clamped = min(0, max(floor, decibels))
        return Double((clamped - floor) / -floor)
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
