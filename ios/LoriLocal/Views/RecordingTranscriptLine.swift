import SwiftUI

/// Строки подписаны лишь на смену звучащей реплики; 60-мс позиция не
/// пересобирает текст и не сбрасывает системное выделение слова.
struct RecordingTranscriptLine: View {
    @ObservedObject var cursor: TranscriptPlaybackCursor
    let id: Int
    let start: TimeInterval?
    let approximate: Bool
    let label: String?
    let name: String?
    let text: String
    let timeColumn: CGFloat?
    let canSeek: Bool
    let seek: (TimeInterval) -> Void
    let rename: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    private var active: Bool { cursor.activeLineID == id }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) { time; avatar; speakerName }
                    replica
                }
            } else {
                // По базовой линии, а не по верху: подпись в кружке, время и первая строка
                // (имя или реплика) встают на одну линию. Кружок 28 pt, прижатый к верху,
                // висел ниже строки 16 pt (владелец, 16 ноября 2026).
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if timeColumn != nil { time }
                    avatar
                    VStack(alignment: .leading, spacing: 3) { speakerName; replica }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? LoriPalette.card : .clear, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(active ? LoriPalette.line : .clear))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(active ? "transcriptLine.playing" : "transcriptLine.\(id)")
    }
    @ViewBuilder private var time: some View {
        if let start {
            let stamp = TranscriptSegment.stamp(start)
            Button { seek(start) } label: {
                Text((approximate ? "≈" : "") + stamp)
                    .recordingFont(13, weight: active ? .semibold : .regular, relativeTo: .footnote, monospaced: true)
                    .foregroundStyle(active ? LoriPalette.lime : LoriPalette.tertiary)
                    .lineLimit(1).fixedSize()
                    .frame(width: typeSize.isAccessibilitySize ? nil : timeColumn, alignment: .leading)
                    .frame(minHeight: 44, alignment: .center)
                    .padding(.horizontal, 2).contentShape(Rectangle()).padding(.horizontal, -2).padding(.vertical, -12).padding(.top, 2)
            }
            .buttonStyle(.plain).disabled(!canSeek)
            .accessibilityLabel(approximate ? "Примерно \(stamp)" : stamp)
            .accessibilityHint("Слушать с \(stamp)")
            .accessibilityIdentifier("lineTime")
        } else if let timeColumn, !typeSize.isAccessibilitySize {
            Color.clear.frame(width: timeColumn, height: 1).accessibilityHidden(true)
        }
    }
    @ViewBuilder private var avatar: some View {
        if let label, let name {
            RecordingAvatar(label: label, name: name)
                .onLongPressGesture(minimumDuration: 0.5, perform: rename)
                .accessibilityHidden(false)
                .accessibilityLabel("Говорящий \(name)")
                .accessibilityAction(named: "Назвать говорящего", rename)
                .accessibilityIdentifier("speakerDot")
        }
    }
    /// Имя над репликой — только назначенное: «S1» уже стоит в кружке рядом, и
    /// подпись повторяла бы его у каждой реплики (владелец, 16 ноября 2026).
    @ViewBuilder private var speakerName: some View {
        if let name, name != label {
            Text(name + (active ? " · сейчас звучит" : ""))
                .recordingFont(13, weight: .semibold, relativeTo: .footnote)
                .foregroundStyle(active ? LoriPalette.lime : LoriPalette.muted)
        } else if active {
            Text("сейчас звучит").recordingFont(13, relativeTo: .footnote).foregroundStyle(LoriPalette.lime)
        }
    }
    private var replica: some View {
        Text(text).recordingFont(16).lineSpacing(5)
            .foregroundStyle(active ? LoriPalette.ink : LoriPalette.prose)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
