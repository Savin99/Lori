import SwiftUI

/// Одна полоса на часть, одинаковая в списке, записи и нижней панели.
struct PartsProgressView: View {
    @EnvironmentObject private var speed: TranscriptionSpeed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: TranscriptionParts
    var compact = false
    var retry: ((Int) -> Void)? = nil

    private var listening: Bool { progress.parts.contains { if case .listening = $0.phase { true } else { false } } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : (listening ? 1.0 / 24 : 60))) { context in
            VStack(alignment: .leading, spacing: compact ? 6 : 12) {
                HStack(spacing: 4) {
                    ForEach(progress.parts.indices, id: \.self) { index in
                        segment(progress.parts[index].phase, time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate)
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        status(now: context.date)
                        Spacer(minLength: 0)
                        estimate
                    }
                    VStack(alignment: .leading, spacing: 4) { status(now: context.date); estimate }
                }
                if !compact, let retry {
                    ForEach(progress.failedIndices, id: \.self) { index in
                        if progress.activeIndex != nil {
                            Text(progress.failureDetail(index)).font(LoriFont.small).foregroundStyle(LoriPalette.muted)
                        }
                        Button("Повторить часть \(index + 1)") { retry(index) }
                            .font(LoriFont.meta.weight(.semibold)).foregroundStyle(LoriPalette.lime)
                            .padding(.horizontal, 16).frame(minHeight: 44)
                            .background(LoriPalette.limeSoft, in: Capsule())
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("retryPart.\(index)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("partsProgress")
    }

    private func status(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(progress.title(now: now))
                .font(compact ? LoriFont.small : LoriFont.meta.weight(.medium))
                .foregroundStyle(LoriPalette.ink)
            if let detail = progress.detail(now: now) {
                Text(detail).font(LoriFont.small.monospacedDigit()).foregroundStyle(LoriPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private var estimate: some View {
        if progress.activeIndex != nil, progress.unfinishedAudio > 0 {
            let seconds = speed.estimate(audio: progress.unfinishedAudio, engine: progress.engine, mode: progress.mode)
            if seconds.isFinite, seconds > 0 {
                Text("≈ " + LoriFormat.approximate(seconds)).font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted).fixedSize()
                    .accessibilityLabel("Примерно " + LoriFormat.approximate(seconds))
            }
        }
    }
    private func segment(_ phase: TranscriptionParts.Phase, time: TimeInterval) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                LoriPalette.bubble
                switch phase {
                case .complete: LoriPalette.lime
                case .failed: LoriPalette.danger
                case .sending:
                    if let share = phase.uploadShare {
                        LoriPalette.info.frame(width: geometry.size.width * share)
                    }
                case .listening:
                    LoriPalette.lime
                    Canvas { context, size in
                        let offset = CGFloat(time.truncatingRemainder(dividingBy: 0.9) / 0.9) * 28
                        for x in stride(from: -28.0, to: size.width + 28, by: 14) {
                            var stripe = Path()
                            stripe.move(to: CGPoint(x: x + offset, y: 0))
                            stripe.addLine(to: CGPoint(x: x + offset + 7, y: 0))
                            stripe.addLine(to: CGPoint(x: x + offset - 1, y: size.height))
                            stripe.addLine(to: CGPoint(x: x + offset - 8, y: size.height))
                            stripe.closeSubpath()
                            context.fill(stripe, with: .color(LoriPalette.limeSoft.opacity(0.65)))
                        }
                    }
                case .waiting: EmptyView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}
