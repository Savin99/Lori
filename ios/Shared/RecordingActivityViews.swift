import AppIntents
import SwiftUI
import UIKit

// Виды Live Activity записи. Лежат в общей папке, а не в расширении, по одной
// причине: модульные тесты приложения рисуют их в PNG (`ImageRenderer`) и смотрят
// глазами в светлой и тёмной теме. Поэтому здесь только SwiftUI — без типов
// WidgetKit (`ActivityViewContext`, регионы островка): их собирает расширение.

/// Цвета активности. Значения повторяют `LoriPalette` приложения — расширение его
/// кода не видит, а цвет должен быть тот же: оливковый акцент Lori и её чернила.
/// Красного нет совсем (владелец, 24 октября 2026: «незаметно»).
enum RecordingTint {
    private static func pair(_ light: (Double, Double, Double, Double), _ dark: (Double, Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0, green: value.1, blue: value.2, alpha: value.3)
        })
    }

    /// `LoriPalette.lime`.
    static let lime = pair((0.36, 0.47, 0.0, 1), (0.66, 0.78, 0.29, 1))
    /// `LoriPalette.ink`.
    static let ink = pair((0.12, 0.12, 0.11, 1), (0.957, 0.953, 0.925, 1))
    /// `LoriPalette.muted`.
    static let muted = pair((0.44, 0.44, 0.41, 1), (0.64, 0.64, 0.61, 1))
    /// `LoriPalette.canvas` — подложка на экране блокировки.
    static let canvas = pair((0.961, 0.957, 0.914, 1), (0.071, 0.071, 0.067, 1))
    /// `LoriPalette.onInk` — текст на оливковой заливке.
    static let onLime = pair((1, 1, 1, 1), (0.071, 0.071, 0.067, 1))
    /// Нейтральная заливка кнопки — та же, что у чипов на стеклянной панели.
    static let chip = pair((0, 0, 0, 0.07), (1, 1, 1, 0.14))

    /// Подложка экрана блокировки — уже решённая для темы, а не динамическая.
    ///
    /// Замер в симуляторе iOS 26.5 (24 октября 2026): `activityBackgroundTint` с
    /// динамическим цветом система решает как светлый, а начинку той же карточки
    /// рисует в тёмной теме — кремовые буквы «Пауза» и «Продолжить» на кремовой
    /// подложке почти пропадали. Поэтому подложка берётся из той же `colorScheme`,
    /// что видит начинка (`RecordingActivityWidget`).
    static func canvas(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.071, green: 0.071, blue: 0.067)
            : Color(red: 0.961, green: 0.957, blue: 0.914)
    }

    /// Чернила для системных кнопок активности — под ту же тему, что подложка.
    static func ink(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.957, green: 0.953, blue: 0.925)
            : Color(red: 0.12, green: 0.12, blue: 0.11)
    }
}

/// Глиф Lori — волна «≋» оливковым. На паузе гаснет до приглушённого: человек видит,
/// что Lori стоит, не читая подписи.
struct RecordingGlyph: View {
    var dimmed = false
    var size: CGFloat = 15

    var body: some View {
        Image(systemName: "water.waves")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(dimmed ? RecordingTint.muted : RecordingTint.lime)
            .accessibilityHidden(true)
    }
}

/// Таймер без обновлений раз в секунду: `Text(timerInterval:)` считает сам, а на
/// паузе стоит на `pauseTime`. Обновления активности система ограничивает, и
/// секундный таймер через `update` был бы и дорог, и рван.
struct RecordingTimer: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Text(timerInterval: state.timerRange, pauseTime: state.pauseTime, countsDown: false, showsHours: true)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

/// Строка «≋ Lori» или «⏸ Пауза · звонок».
struct RecordingHeadline: View {
    let state: RecordingActivityAttributes.ContentState
    var stale = false

    var body: some View {
        HStack(spacing: 6) {
            switch state.phase {
            case .recording:
                RecordingGlyph(dimmed: stale)
            case .paused:
                Image(systemName: "pause.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(RecordingTint.muted)
                    .accessibilityHidden(true)
            case .finished:
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(RecordingTint.lime)
                    .accessibilityHidden(true)
            }
            Text(RecordingActivityCopy.headline(state))
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(RecordingTint.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }
}

/// Кнопки активности: «Пауза» или «Продолжить», «Расшифровать» и — у записи,
/// поднятой после перезапуска, — «Удалить».
struct RecordingActivityButtons: View {
    let state: RecordingActivityAttributes.ContentState
    let finishURL: URL

    var body: some View {
        HStack(spacing: 8) {
            if state.phase == .recording {
                Button(intent: PauseRecordingIntent()) {
                    capsule(RecordingActivityCopy.pause, symbol: "pause.fill", prominent: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(RecordingActivityCopy.pauseHint)
            } else {
                Button(intent: ResumeRecordingIntent()) {
                    capsule(RecordingActivityCopy.resume, symbol: "play.fill", prominent: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(RecordingActivityCopy.resumeHint)
            }

            finish
                .accessibilityLabel(RecordingActivityCopy.finishHint(state))

            if state.canDiscard {
                Button(intent: DiscardRecordingIntent()) {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RecordingTint.muted)
                        .frame(width: 44, height: 38)
                        .background(RecordingTint.chip, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(RecordingActivityCopy.discardHint)
            }
        }
    }

    /// Движок на телефоне — ссылка, открывающая Lori: заявку на фоновую расшифровку
    /// iOS примет только от приложения на виду и по действию человека. Облачный —
    /// интент, который сделает всё в фоне.
    @ViewBuilder
    private var finish: some View {
        let symbol = state.finishTitle == "Сохранить" ? "checkmark" : "arrow.up"
        if state.finishOpensApp {
            Link(destination: finishURL) {
                capsule(state.finishTitle, symbol: symbol, prominent: true)
            }
        } else {
            Button(intent: FinishRecordingIntent()) {
                capsule(state.finishTitle, symbol: symbol, prominent: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func capsule(_ title: String, symbol: String, prominent: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(prominent ? RecordingTint.onLime : RecordingTint.ink)
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(prominent ? RecordingTint.lime : RecordingTint.chip, in: Capsule())
        .contentShape(Capsule())
    }
}

/// Экран блокировки (и баннер на телефонах без островка): «≋ Lori   12:34» и кнопки.
struct RecordingLockScreenView: View {
    let state: RecordingActivityAttributes.ContentState
    let finishURL: URL
    var stale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                RecordingHeadline(state: state, stale: stale)
                Spacer(minLength: 8)
                timer
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(RecordingActivityCopy.accessibilitySummary(state, stale: stale))

            if stale, state.phase == .recording {
                Text(RecordingActivityCopy.staleLine)
                    .font(.footnote)
                    .foregroundStyle(RecordingTint.muted)
            }
            if state.phase != .finished {
                RecordingActivityButtons(state: state, finishURL: finishURL)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var timer: some View {
        if stale, state.phase == .recording {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(RecordingTint.muted)
        } else {
            RecordingTimer(state: state)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(state.phase == .recording ? RecordingTint.ink : RecordingTint.muted)
                .frame(maxWidth: 110, alignment: .trailing)
        }
    }
}

/// Части островка. Регионы `DynamicIsland` собирает расширение, а начинку берёт
/// отсюда — та же, что видят тесты.
enum RecordingIslandParts {
    /// Свёрнуто слева: глиф.
    struct CompactLeading: View {
        let state: RecordingActivityAttributes.ContentState
        var stale = false

        var body: some View {
            Group {
                if state.phase == .finished {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(RecordingTint.lime)
                } else {
                    RecordingGlyph(dimmed: state.phase != .recording || stale)
                }
            }
            .accessibilityLabel(RecordingActivityCopy.accessibilitySummary(state, stale: stale))
        }
    }

    /// Свёрнуто справа: таймер. Ширина задана: `Text(timerInterval:)` иначе
    /// занимает всё, что дадут, и островок раздувается до краёв.
    struct CompactTrailing: View {
        let state: RecordingActivityAttributes.ContentState
        var stale = false

        var body: some View {
            if stale, state.phase == .recording {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(RecordingTint.muted)
            } else if state.phase == .finished {
                EmptyView()
            } else {
                RecordingTimer(state: state)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(state.phase == .recording ? RecordingTint.ink : RecordingTint.muted)
                    .frame(width: state.showsHours ? 62 : 44, alignment: .trailing)
            }
        }
    }

    /// Свёрнуто в кружок, когда активностей несколько: только глиф.
    struct Minimal: View {
        let state: RecordingActivityAttributes.ContentState
        var stale = false

        var body: some View {
            CompactLeading(state: state, stale: stale)
        }
    }

    /// Развёрнуто, слева у камеры: «≋ Lori» или «⏸ Пауза · звонок».
    struct ExpandedLeading: View {
        let state: RecordingActivityAttributes.ContentState
        var stale = false

        var body: some View {
            RecordingHeadline(state: state, stale: stale)
                .padding(.leading, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(RecordingActivityCopy.accessibilitySummary(state, stale: stale))
        }
    }

    /// Развёрнуто, справа у камеры: таймер.
    struct ExpandedTrailing: View {
        let state: RecordingActivityAttributes.ContentState
        var stale = false

        var body: some View {
            Group {
                if stale, state.phase == .recording {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(RecordingTint.muted)
                } else {
                    RecordingTimer(state: state)
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(state.phase == .recording ? RecordingTint.ink : RecordingTint.muted)
                        .frame(maxWidth: 110, alignment: .trailing)
                }
            }
            .padding(.trailing, 4)
        }
    }

    /// Развёрнуто, низ: кнопки, а у зависшей активности — строка «Lori не отвечает».
    struct ExpandedBottom: View {
        let state: RecordingActivityAttributes.ContentState
        let finishURL: URL
        var stale = false

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if stale, state.phase == .recording {
                    Text(RecordingActivityCopy.staleLine)
                        .font(.footnote)
                        .foregroundStyle(RecordingTint.muted)
                }
                if state.phase != .finished {
                    RecordingActivityButtons(state: state, finishURL: finishURL)
                }
            }
            .padding(.top, 4)
        }
    }
}
