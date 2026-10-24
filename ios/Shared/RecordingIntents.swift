import AppIntents
import Foundation

// Кнопки Live Activity записи.
//
// Интенты лежат в общей папке и компилируются в обе цели: расширению тип нужен,
// чтобы нарисовать `Button(intent:)`, а исполняет их **процесс приложения** —
// так система поступает с `LiveActivityIntent` (WidgetKit, «Adding interactivity
// to widgets and Live Activities»: «if … the intent conforms to … LiveActivityIntent,
// the system performs the app intent in the app’s process»). Нужно — запускает
// приложение в фоне, не открывая его.
//
// Код приложения в расширение не тянется: интенты говорят с записью через
// `RecordingIntentBridge`, где обработчик — протокол. В приложении его ставит
// `RecordingController`, в расширении он пуст, и `perform()` там ничего не делает —
// система его там и не зовёт.
//
// `isDiscoverable = false`: в «Быстрых командах» этим кнопкам делать нечего —
// «Продолжить» без островка, из которого её нажали, не имеет смысла.

/// Пауза. Кусок закрывается файлом сразу — брошенный на паузе кусок m4a иначе
/// остался бы без оглавления и не читался.
struct PauseRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Пауза записи Lori"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await RecordingIntentBridge.run { await $0.pauseFromIntent() }
        return .result()
    }
}

/// «Продолжить» — новый кусок записи.
///
/// `AudioRecordingIntent` — именно он даёт право начать запись, когда Lori не на
/// виду: «When you adopt AudioRecordingIntent, you must start a Live Activity when
/// you begin the audio recording and keep it active as long as you record audio. If
/// you don’t start a Live Activity, the audio recording stops» (документация
/// `AudioRecordingIntent`). Активность к этому моменту уже есть — кнопка в ней и
/// нажата. Оба протокола — пустые уточнения `SystemIntent` (`AppIntents.swiftinterface`
/// SDK 27.1), так что тип вправе быть тем и другим сразу.
struct ResumeRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Продолжить запись Lori"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await RecordingIntentBridge.run { await $0.resumeFromIntent() }
        return .result()
    }
}

/// «Расшифровать» (или «Сохранить») без открытия приложения: стоп, склейка кусков,
/// постановка в очередь. Только для облачного движка — для движка на телефоне кнопка
/// в активности — ссылка, открывающая Lori (`ContentState.finishOpensApp`).
struct FinishRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Закончить запись Lori"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await RecordingIntentBridge.run { await $0.finishFromIntent() }
        return .result()
    }
}

/// «Удалить» у записи, поднятой после перезапуска: куски уходят в корзину Lori.
struct DiscardRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Удалить запись Lori"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await RecordingIntentBridge.run { await $0.discardFromIntent() }
        return .result()
    }
}

/// Что умеет запись для кнопок активности. Ошибки не бросаются: кнопка в островке
/// показать их не может, поэтому исход виден в самой активности («Пауза · микрофон
/// занят»), а в приложении — строкой.
@MainActor
protocol RecordingIntentHandling: AnyObject {
    func pauseFromIntent() async
    func resumeFromIntent() async
    func finishFromIntent() async
    func discardFromIntent() async
}

/// Мост от интента к записи.
///
/// Сильная ссылка, а не слабая: контроллер записи живёт всё время процесса, а
/// SwiftUI вправе построить `App` не один раз — слабая ссылка на лишний экземпляр
/// обнулилась бы, и нажатие в островке ушло бы в пустоту. `AppDependencyManager` не
/// подходит по другой причине: `@Dependency` требует конкретный тип в интенте, и
/// расширение пришлось бы собирать вместе с записью, расшифровкой и рабочей папкой.
@MainActor
enum RecordingIntentBridge {
    static var handler: (any RecordingIntentHandling)?

    /// Сколько ждать обработчик, если приложение только что запущено ради интента.
    /// `App.init` ставит его раньше, чем система зовёт `perform()`, — это запас.
    static var launchGrace: Duration = .seconds(2)

    static func run(_ action: @MainActor (any RecordingIntentHandling) async -> Void) async {
        let deadline = ContinuousClock.now.advanced(by: launchGrace)
        while handler == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let handler else { return }
        await action(handler)
    }
}
