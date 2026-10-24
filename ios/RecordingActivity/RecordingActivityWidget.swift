import ActivityKit
import SwiftUI
import WidgetKit

/// Расширение Lori — только Live Activity записи. Виджетов на экране «Домой» нет:
/// владелец просил кнопки записи, а не ещё одну плитку.
@main
struct RecordingActivityBundle: WidgetBundle {
    var body: some Widget {
        RecordingActivityWidget()
    }
}

/// Островок и экран блокировки. Начинка — общие виды (`RecordingActivityViews`),
/// здесь только раскладка по местам, которые знает WidgetKit.
struct RecordingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenPresentation(
                state: context.state,
                finishURL: context.attributes.finishURL,
                stale: context.isStale
            )
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    RecordingIslandParts.ExpandedLeading(state: context.state, stale: context.isStale)
                        // «Пауза · приложение перезапускалось» у камеры не помещается —
                        // пусть уходит под неё, а не режется.
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingIslandParts.ExpandedTrailing(state: context.state, stale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RecordingIslandParts.ExpandedBottom(
                        state: context.state,
                        finishURL: context.attributes.finishURL,
                        stale: context.isStale
                    )
                }
            } compactLeading: {
                RecordingIslandParts.CompactLeading(state: context.state, stale: context.isStale)
            } compactTrailing: {
                RecordingIslandParts.CompactTrailing(state: context.state, stale: context.isStale)
            } minimal: {
                RecordingIslandParts.Minimal(state: context.state, stale: context.isStale)
            }
            .keylineTint(RecordingTint.lime)
        }
    }
}

/// Экран блокировки. Подложка — под ту тему, в которой рисуется начинка: динамический
/// цвет в `activityBackgroundTint` система решала светлым, а буквы — тёмной темой,
/// и на кремовой карточке оставались кремовые буквы (`RecordingTint.canvas(for:)`).
private struct LockScreenPresentation: View {
    @Environment(\.colorScheme) private var scheme
    let state: RecordingActivityAttributes.ContentState
    let finishURL: URL
    let stale: Bool

    var body: some View {
        RecordingLockScreenView(state: state, finishURL: finishURL, stale: stale)
            .activityBackgroundTint(RecordingTint.canvas(for: scheme))
            .activitySystemActionForegroundColor(RecordingTint.ink(for: scheme))
    }
}
