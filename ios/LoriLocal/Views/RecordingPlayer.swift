import AVFoundation
import SwiftUI

/// Проигрыватель записи. Отдельный от `AudioCaptureStore`: рекордер только пишет.
/// Делегат `AVAudioPlayerDelegate` намеренно не используется — его метод не изолирован
/// в главном акторе, а сам `AVAudioPlayer` не `Sendable`. Окончание ловит тикер.
@MainActor
final class AudioPlaybackStore: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var loadError: String?

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?
    /// Пока палец на ползунке, тикер не должен перебивать выбранное время.
    private var isScrubbing = false

    var remaining: TimeInterval { max(0, duration - position) }

    func load(_ url: URL) {
        guard player == nil else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
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

    func skip(_ delta: TimeInterval) {
        seek(to: position + delta)
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

/// Экран записи: сначала послушать, и только потом решать про расшифровку.
/// Раньше тап по аудио сразу запускал распознавание, и прослушать запись было нечем.
struct RecordingSheet: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = AudioPlaybackStore()

    let entry: WorkspaceEntry
    @ObservedObject var transcription: TranscriptionService
    /// Нельзя слушать и писать одновременно: аудиосессия одна.
    let isRecording: Bool
    let openTranscript: (String) -> Void

    private var meta: String {
        let stamp = LoriFormat.stamp(entry.modifiedAt)
        guard playback.duration > 0 else { return "Запись · \(stamp)" }
        return "Запись · \(stamp) · \(LoriFormat.duration(playback.duration))"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayName)
                        .font(LoriFont.displaySmall)
                        .foregroundStyle(LoriPalette.ink)
                        .lineLimit(3)
                    Text(meta)
                        .font(LoriFont.meta)
                        .foregroundStyle(LoriPalette.muted)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)

                if let error = playback.loadError {
                    Text(error)
                        .font(LoriFont.meta)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.top, 26)
                } else {
                    scrubber.padding(.top, 26)
                    transport.padding(.top, 14)
                }

                // Текст живёт на этом же экране: звук и его расшифровка —
                // одна вещь, и низ экрана иначе остаётся пустым.
                // Что показывать — обработанное «Важное» или дословный текст —
                // решает переключатель внутри карточки.
                TranscriptCard(
                    transcription: transcription,
                    entry: entry,
                    openFile: { path in
                        playback.stop()
                        openTranscript(path)
                    }
                )
                .padding(.top, 26)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LoriPalette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // «Готово» слева — как в редакторе заметки и в браузере файлов.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .recordingBanner { dismiss() }
        .task {
            guard let url = try? workspace.fileURL(for: entry.relativePath) else { return }
            playback.load(url)
        }
        .onDisappear { playback.stop() }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { playback.position },
                    set: { playback.scrub(to: $0) }
                ),
                in: 0...max(playback.duration, 0.01),
                onEditingChanged: { editing in
                    if editing { playback.beginScrub() } else { playback.endScrub() }
                }
            )
            .tint(LoriPalette.lime)
            .disabled(playback.duration == 0)

            HStack {
                Text(LoriFormat.duration(playback.position))
                Spacer()
                Text("−\(LoriFormat.duration(playback.remaining))")
            }
            .font(LoriFont.small.monospacedDigit())
            .foregroundStyle(LoriPalette.muted)
        }
        .padding(.horizontal, 20)
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button { playback.skip(-15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(LoriPalette.ink)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Назад на 15 секунд")

            Button(action: playback.toggle) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.white)
                    // Треугольник «play» визуально смещён влево — компенсируем.
                    .offset(x: playback.isPlaying ? 0 : 2)
                    .frame(width: 72, height: 72)
                    .background(LoriPalette.lime, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isRecording || playback.duration == 0)
            .opacity(isRecording ? 0.4 : 1)
            .accessibilityLabel(playback.isPlaying ? "Пауза" : "Слушать")

            Button { playback.skip(15) } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(LoriPalette.ink)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Вперёд на 15 секунд")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .overlay(alignment: .bottom) {
            if isRecording {
                Text("Сейчас идёт запись — слушать можно после неё.")
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
                    .offset(y: 20)
            }
        }
    }
}
