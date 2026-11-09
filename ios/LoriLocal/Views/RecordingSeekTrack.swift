import SwiftUI
import UIKit

/// Настоящий UISlider с дорожкой 4 pt из макета. Невидимый бегунок оставляет
/// системное перетаскивание и VoiceOver, а область касания — 44 pt.
struct RecordingSeekTrack: UIViewRepresentable {
    @ObservedObject var playback: AudioPlaybackStore
    let enabled: Bool
    func makeUIView(context: Context) -> UISlider {
        let slider = ThinSlider()
        slider.setThumbImage(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }, for: .normal)
        slider.accessibilityLabel = "Позиция в записи"
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }
    func updateUIView(_ slider: UISlider, context: Context) {
        slider.minimumValue = 0; slider.maximumValue = Float(max(0.01, playback.duration))
        if !slider.isTracking { slider.value = Float(playback.position) }
        slider.minimumTrackTintColor = UIColor(LoriPalette.lime)
        slider.maximumTrackTintColor = UIColor(LoriPalette.muted.opacity(0.25))
        slider.isEnabled = enabled
    }
    func makeCoordinator() -> Coordinator { Coordinator(playback) }
    @MainActor final class Coordinator: NSObject {
        let playback: AudioPlaybackStore
        init(_ playback: AudioPlaybackStore) { self.playback = playback }
        @objc func began() { playback.beginScrub() }
        @objc func changed(_ slider: UISlider) {
            playback.scrub(to: Double(slider.value))
            if !slider.isTracking { playback.endScrub() } // VoiceOver меняет без touchDown.
        }
        @objc func ended() { playback.endScrub() }
    }
    private final class ThinSlider: UISlider {
        override var accessibilityValue: String? {
            get { TranscriptSegment.stamp(Double(value)) }
            set {} // UIKit по умолчанию пишет проценты; VoiceOver нужны секунды.
        }
        override func trackRect(forBounds bounds: CGRect) -> CGRect {
            CGRect(x: 0, y: bounds.midY - 2, width: bounds.width, height: 4)
        }
    }
}
