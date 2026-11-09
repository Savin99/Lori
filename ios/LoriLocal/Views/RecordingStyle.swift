import SwiftUI

private struct RecordingFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let monospaced: Bool
    init(size: CGFloat, weight: Font.Weight, relativeTo: Font.TextStyle, monospaced: Bool) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: relativeTo)
        self.weight = weight; self.monospaced = monospaced
    }
    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight).monospacedDigitIf(monospaced))
    }
}
private extension Font {
    func monospacedDigitIf(_ enabled: Bool) -> Font { enabled ? monospacedDigit() : self }
}

extension View {
    /// SF остаётся системным: скрытое имя UIFont нельзя передавать Font.custom,
    /// оно не зарегистрировано как пользовательский шрифт и даёт serif fallback.
    func recordingFont(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo: Font.TextStyle = .body, monospaced: Bool = false) -> some View {
        modifier(RecordingFont(size: size, weight: weight, relativeTo: relativeTo, monospaced: monospaced))
    }

    func recordingCard(radius: CGFloat = 22) -> some View {
        background(LoriPalette.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(LoriPalette.line, lineWidth: 1))
    }
}

/// Переносит чипы без обрезки: число строк зависит от ширины и Dynamic Type.
struct RecordingFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (view, frame) in zip(subviews, result.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0, used: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += height + spacing; height = 0 }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            used = max(used, x + size.width); x += size.width + spacing; height = max(height, size.height)
        }
        return (CGSize(width: width.isFinite ? width : used, height: y + height), frames)
    }
}

struct RecordingChip: View {
    let text: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).recordingFont(14, relativeTo: .footnote).accessibilityHidden(true) }
            Text(text).recordingFont(13, relativeTo: .footnote).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(LoriPalette.chipText)
        .padding(.horizontal, 11)
        .frame(minHeight: 30)
        .padding(.vertical, 0)
        .background(LoriPalette.chip, in: Capsule())
    }
}

/// Цвет привязан к метке, инициал — к назначенному имени.
struct RecordingAvatar: View {
    let label: String
    let name: String
    var size: CGFloat = 28
    @ScaledMetric(relativeTo: .footnote) private var scale: CGFloat = 1
    private var alternate: Bool { (Int(label.filter(\.isNumber)) ?? 1).isMultiple(of: 2) }
    var body: some View {
        Text(name == label && label.range(of: #"^S[0-9]+$"#, options: .regularExpression) != nil
             ? label : String(name.prefix(1)).uppercased())
            .recordingFont(size == 20 ? 11 : 12, weight: .semibold, relativeTo: .caption)
            .foregroundStyle(alternate ? LoriPalette.warmText : LoriPalette.oliveText)
            .frame(width: size * scale, height: size * scale)
            .background(alternate ? LoriPalette.warmFill : LoriPalette.limeSoft, in: Circle())
            .accessibilityHidden(true)
    }
}
