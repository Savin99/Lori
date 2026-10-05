import SwiftUI

/// Плашка «идёт запись» для модальных экранов. Пилюля рекордера живёт в композере
/// главного экрана, и под открытым листом её не видно: человек редактировал заметку,
/// не зная, что диктофон всё ещё пишет. Нажатие закрывает лист и возвращает к пилюле.
struct RecordingBanner: View {
    @EnvironmentObject private var recorder: AudioCaptureStore
    let close: () -> Void

    var body: some View {
        Button(action: close) {
            HStack(spacing: 9) {
                Circle()
                    .fill(recorder.isPaused ? LoriPalette.muted : LoriPalette.danger)
                    .frame(width: 8, height: 8)
                    .opacity(recorder.isPaused ? 0.5 : 0.55 + 0.45 * min(1, max(0, recorder.level)))

                Text(recorder.isPaused ? "Запись на паузе" : "Идёт запись")
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.ink)

                Text(LoriFormat.duration(recorder.elapsed))
                    .font(LoriFont.small.monospacedDigit())
                    .foregroundStyle(LoriPalette.muted)

                Spacer(minLength: 8)

                Text("К записи")
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
                Image(systemName: "chevron.right")
                    .font(LoriFont.tiny.weight(.semibold))
                    .foregroundStyle(LoriPalette.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(LoriPalette.limeSoft.opacity(0.55))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(LoriPalette.line)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isPaused ? "Запись на паузе" : "Идёт запись")
        .accessibilityHint("Закрывает экран и возвращает к записи")
    }
}

/// Рекордер берётся из окружения, чтобы не тащить его параметром
/// через инициализаторы всех листов.
private struct RecordingBannerModifier: ViewModifier {
    @EnvironmentObject private var recorder: AudioCaptureStore
    let close: () -> Void

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if recorder.isCapturing {
                    RecordingBanner(close: close)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: recorder.isCapturing)
    }
}

extension View {
    /// Вешается на корень каждого листа.
    func recordingBanner(close: @escaping () -> Void) -> some View {
        modifier(RecordingBannerModifier(close: close))
    }
}
