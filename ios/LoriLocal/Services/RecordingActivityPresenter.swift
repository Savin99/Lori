// `Activity` не объявлен `Sendable`, а обновляют его из главного актора: без
// `@preconcurrency` Swift 6 считает каждый `await activity.update` гонкой. Сама
// ActivityKit потокобезопасна для этих вызовов — так её и показывает Apple.
@preconcurrency import ActivityKit
import Foundation

/// То, чем запись управляет своей Live Activity. Протокол — ради модульных тестов:
/// они проверяют, что островок узнаёт о каждой смене состояния, не трогая ActivityKit.
@MainActor
protocol RecordingActivityPresenting: AnyObject {
    /// Live Activity у Lori не выключены человеком в настройках.
    var areEnabled: Bool { get }
    /// Есть живая (не законченная и не смахнутая) активность записи.
    var isRunning: Bool { get }
    /// Опознавательный знак текущей активности — чтобы прощание старой записи не
    /// закрыло активность новой, начатой за эти секунды.
    var token: String? { get }

    /// Подобрать активность, пережившую перезапуск Lori. Лишние — закончить.
    func adopt() async -> Bool
    /// Начать активность. Только на переднем плане — так требует ActivityKit.
    func start(_ state: RecordingActivityAttributes.ContentState, staleDate: Date?) throws
    func update(_ state: RecordingActivityAttributes.ContentState, staleDate: Date?) async
    /// Закончить активность с этим знаком и сразу убрать её. Знак обязателен: «текущая»
    /// через пару секунд прощания могла стать активностью уже новой записи.
    func end(token: String, final state: RecordingActivityAttributes.ContentState?) async
    /// Закончить все активности записи, в том числе висящие от прошлого запуска.
    func endAll() async
}

/// Настоящая Live Activity через ActivityKit.
@MainActor
final class LiveRecordingActivity: RecordingActivityPresenting {
    private let finishURL: URL
    private var activity: Activity<RecordingActivityAttributes>?

    init(finishURL: URL) {
        self.finishURL = finishURL
    }

    var areEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var isRunning: Bool {
        guard let activity else { return false }
        return Self.isLive(activity.activityState)
    }

    var token: String? { activity?.id }

    func adopt() async -> Bool {
        let live = Activity<RecordingActivityAttributes>.activities.filter { Self.isLive($0.activityState) }
        activity = live.first
        for extra in live.dropFirst() {
            await extra.end(nil, dismissalPolicy: .immediate)
        }
        return activity != nil
    }

    func start(_ state: RecordingActivityAttributes.ContentState, staleDate: Date?) throws {
        // `pushType: nil` — серверных обновлений у Lori нет: всё обновляет само приложение.
        activity = try Activity.request(
            attributes: RecordingActivityAttributes(finishURL: finishURL),
            content: ActivityContent(state: state, staleDate: staleDate),
            pushType: nil
        )
    }

    func update(_ state: RecordingActivityAttributes.ContentState, staleDate: Date?) async {
        guard let activity, Self.isLive(activity.activityState) else { return }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func end(token id: String, final state: RecordingActivityAttributes.ContentState?) async {
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        for candidate in Activity<RecordingActivityAttributes>.activities where candidate.id == id {
            await candidate.end(content, dismissalPolicy: .immediate)
        }
        if activity?.id == id { activity = nil }
    }

    func endAll() async {
        for candidate in Activity<RecordingActivityAttributes>.activities {
            await candidate.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }

    /// Смахнутая с экрана блокировки активность — `dismissed`: обновлять её бесполезно,
    /// нужна новая. Устаревшая (`stale`) жива — её обновление и снимает устаревание.
    private static func isLive(_ state: ActivityState) -> Bool {
        state == .active || state == .stale
    }
}
