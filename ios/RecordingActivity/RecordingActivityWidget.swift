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
            RecordingLockScreenView(
                state: context.state,
                finishURL: context.attributes.finishURL,
                stale: context.isStale
            )
            .activityBackgroundTint(RecordingTint.canvas)
            .activitySystemActionForegroundColor(RecordingTint.ink)
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
