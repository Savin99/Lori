import AVFoundation
import SwiftUI

/// Проигрыватель записи. Отдельный от `RecordingController`: диктофон только пишет.
/// Делегат `AVAudioPlayerDelegate` намеренно не используется — его метод не изолирован
/// в главном акторе, а сам `AVAudioPlayer` не `Sendable`. Окончание ловит тикер.
@MainActor
final class AudioPlaybackStore: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var loadError: String?
    /// Скорость: расшифровку часто слушают быстрее, чем говорили.
    @Published var rate: Float = 1 {
        didSet {
            player?.rate = rate
            if isPlaying { player?.play() }
        }
    }

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?
    /// Пока палец на ползунке, тикер не должен перебивать выбранное время.
    private var isScrubbing = false

    var remaining: TimeInterval { max(0, duration - position) }

    /// Загруженный файл. Без него повторный `load` другой записи молча
    /// возвращался, и играла предыдущая — на экране записи это незаметно
    /// (там файл один). Всплыло в ленте ассистента, где пилюли вели в разные
    /// записи; чат удалён 5 октября 2026, а смена файла оставлена: хранилище,
    /// которое молча играет не то, что просили, — ловушка для следующего экрана.
    private var loaded: URL?

    func load(_ url: URL) {
        guard loaded != url else { return }
        stop()
        loaded = url
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.rate = rate
            // `prepareToPlay` декодирует первые буферы синхронно. Для длинной
            // записи это задерживало открытие всего экрана; подготовка теперь
            // случается только по явному нажатию «Слушать».
            self.player = player
            duration = player.duration
            position = 0
            loadError = nil
        } catch {
            loadError = "Не удалось открыть запись: \(error.localizedDescription)"
        }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        do {
            // Категория `.record` остаётся от рекордера и глушит воспроизведение,
            // поэтому сессию нужно переключить прямо перед стартом.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            loadError = "Не удалось включить звук: \(error.localizedDescription)"
            return
        }
        player.rate = rate
        guard player.play() else { return }
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, seconds), duration)
        player.currentTime = clamped
        position = clamped
    }

    func beginScrub() {
        isScrubbing = true
    }

    func scrub(to seconds: TimeInterval) {
        position = min(max(0, seconds), duration)
    }

    func endScrub() {
        isScrubbing = false
        seek(to: position)
    }

    /// Закрытие экрана: звук глушится, сессия отдаётся обратно системе.
    func stop() {
        stopTicker()
        player?.stop()
        player = nil
        // Забыть файл обязательно: иначе после `stop` повторный `load` той же
        // записи считает её уже загруженной и не создаёт проигрыватель.
        loaded = nil
        isPlaying = false
        position = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                if !self.isScrubbing { self.position = player.currentTime }
                if !player.isPlaying {
                    // Дошло до конца само: ползунок к началу, кнопка снова «играть».
                    self.isPlaying = false
                    self.position = 0
                    player.currentTime = 0
                    return
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
