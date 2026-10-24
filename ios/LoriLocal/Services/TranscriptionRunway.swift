import BackgroundTasks
import Foundation
import Network
import UIKit

/// Фон для расшифровки: работа не обрывается, когда человек ушёл из приложения или
/// запер телефон, а прогресс виден в Dynamic Island и на экране блокировки.
///
/// Держит всё это `BGContinuedProcessingTask` из iOS 26 — механизм ровно для этого
/// случая: работа начата человеком в приложении и продолжается в фоне, а полосу
/// прогресса **рисует сама система**. Поэтому здесь нет ни расширения-виджета, ни
/// ActivityKit: своё Live Activity потребовало бы отдельного таргета (ещё один App ID
/// против лимита бесплатной команды разработчика), фонового времени не дало бы вовсе,
/// а полоса встала бы второй рядом с системной.
///
/// **Кто делает работу.** Не эта задача. Считает `TranscriptionService`, в своём
/// процессе, начиная сразу — как и раньше. Задача здесь только держит процесс живым и
/// ведёт полосу: `launchHandler` ждёт, пока очередь опустеет, и по дороге обновляет
/// `task.progress`. Если задача не пришла вовсе — симулятор, отказ системы, iOS ниже
/// 26 — ничего не ломается: расшифровка идёт как прежде, теряется только выживание
/// в фоне, и `state` говорит об этом прямо, а не молчит.
///
/// **Одна задача на пачку, а не на запись.** Три причины: в Dynamic Island нужна одна
/// строка про общий прогресс, а не пять конкурирующих; заявка на запись, ждущую своей
/// очереди, отчитывалась бы нулевым прогрессом, а планировщик такие завершает
/// принудительно («tasks that appear stalled may be forcibly expired», `BGTask.h`);
/// и подавать заявку можно только от приложения на переднем плане, а `enqueue` — это
/// либо нажатие, либо остановка диктофона.
@MainActor
final class TranscriptionRunway: ObservableObject {
    /// Что приложение может пообещать про фон. Показывается человеку — обещать
    /// фоновую работу там, где её нет, нельзя.
    enum State: Equatable {
        /// Система не дала фон: симулятор, отказ, или iOS старше 26.
        case foregroundOnly(String)
        /// Фон есть, но сейчас ничего не идёт.
        case ready
        /// Работа идёт под системной задачей.
        case running
    }

    @Published private(set) var state: State = .ready

    /// Один идентификатор во всех трёх местах: в `BGTaskSchedulerPermittedIdentifiers`,
    /// в `register` и в заявке. Так вышло не сразу, и обе догадки по дороге были неверны.
    ///
    /// Заголовок `BGTaskRequest.h` описывает форму с шаблоном (`<база>.*` в plist,
    /// заявка `<база>.<uuid>`), и первая версия следовала ему. Рантайм iOS 26.5 отвечает
    /// иначе — замерено подставными идентификаторами:
    ///
    /// | В `Info.plist` | `register` | `submit` | Ответ |
    /// | --- | --- | --- | --- |
    /// | `…probewild.*` | любая | — | «Registration rejected; … not advertised» |
    /// | `…probea` | `…probea` | `…probea` | **принята** |
    /// | `…probea` | `…probea` | `…probea.<uuid>` | код 3, «Unrecognized Identifier» |
    ///
    /// То есть: в plist — только базовая форма, а подавать надо ровно то, что
    /// зарегистрировано; составная к базовой регистрации не привязывается. Нам этого
    /// хватает с запасом: задача одна на всю очередь, второй одновременно не бывает.
    /// Повторная заявка с тем же идентификатором заменяет предыдущую — ровно то,
    /// что нужно, когда очередь началась заново.
    ///
    /// Сравнение идёт с учётом регистра, поэтому строку стережёт тест.
    nonisolated static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "ru.ilyaqa.lori.local") + ".transcribe"

    /// Живой сейчас взлёт. SwiftUI вправе позвать `App.init()` не один раз, а
    /// обработчик регистрируется ровно один — и захват первого экземпляра слабой
    /// ссылкой означал бы, что задача приходит к выброшенному объекту и молча
    /// завершается: работа идёт, полосы нет. Здесь всегда тот, что создан последним.
    private(set) static weak var current: TranscriptionRunway?

    private unowned let service: TranscriptionService
    private var submitted = false
    private let network = NWPathMonitor()
    /// Фоновое окно UIKit на те ~30 секунд, что даёт система, когда настоящей фоновой
    /// задачи нет. Короткому облачному запросу этого хватает, длинной локальной — нет,
    /// и врать об этом не нужно.
    private var grace: UIBackgroundTaskIdentifier = .invalid

    /// Как назвать запись человеку: по пути вернуть её заголовок или `nil` — тогда в
    /// Dynamic Island встанет имя файла. Подставляет приложение: заголовки живут в
    /// `SummaryStore`, а полосе прогресса о нём знать незачем. По умолчанию — имя файла
    /// как было: у записи с диктофона это `Recording-2026-09-01T12-00-00Z`, у принесённой
    /// — то, что назвал человек.
    var displayTitle: (String) -> String? = { _ in nil }

    /// То, чем Runway трогает систему. Отдельной структурой, чтобы тест подменял это и не
    /// включал настоящему телефону вечный экран, не подавал заявок настоящему планировщику
    /// и мог позвать обработчики так, как зовёт их система, — с чужой очереди.
    struct SystemHooks {
        /// Приложение на виду прямо сейчас: начальное состояние до первого уведомления и
        /// вопрос «можно ли подать заявку» (`batchDidStart`).
        var isActive: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
        /// `UIApplication.isIdleTimerDisabled`: пока `true`, экран не гаснет по таймеру автоблокировки.
        var setScreenAwake: @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }
        var notifications: NotificationCenter = .default

        // MARK: Планировщик

        /// Принята ли регистрация обработчика (`register`).
        var isRegistered: @MainActor () -> Bool = { TranscriptionRunway.isRegistered }
        /// Подавать ли заявку асинхронно, вне главного потока (iOS 27, `submitTaskRequest`).
        var submitsAsynchronously = TranscriptionRunway.submitsAsynchronouslyByDefault
        /// Синхронная подача (`submit`, iOS 26).
        var submit: @MainActor (BGTaskRequest) throws -> Void = { try BGTaskScheduler.shared.submit($0) }
        /// Асинхронная подача — зовётся вне главного актора.
        var submitAsync: @Sendable (BGTaskRequest) async throws -> Void = TranscriptionRunway.systemSubmit
        /// Ждущие заявки по идентификаторам. Ответ приходит с чужой очереди.
        var pendingRequests: @Sendable (@escaping @Sendable ([String]) -> Void) -> Void = TranscriptionRunway.systemPendingRequests
        var cancelRequest: @MainActor (String) -> Void = { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0) }

        // MARK: UIKit и фоновая передача

        /// `beginBackgroundTask(withName:expirationHandler:)`: UIKit зовёт обработчик на
        /// главном потоке (`NS_SWIFT_UI_ACTOR` в заголовке).
        var beginBackgroundTask: @MainActor (String, @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier = {
            UIApplication.shared.beginBackgroundTask(withName: $0, expirationHandler: $1)
        }
        var endBackgroundTask: @MainActor (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
        /// Пересоздать фоновую сессию и узнать, когда её события доставлены.
        var reconnectTransfers: @MainActor (@escaping @Sendable () -> Void) -> Void = {
            BackgroundTranscriptionTransport.shared.reconnect(completion: $0)
        }
    }

    /// iOS 27 — асинхронно: синхронный `submit(_:)` там объявлен устаревшим.
    nonisolated static var submitsAsynchronouslyByDefault: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    /// Асинхронная подача заявки системе. `nonisolated`: «Do not call this method from the
    /// main thread» (`BGTaskScheduler.h`, `submitTaskRequest`).
    nonisolated static func systemSubmit(_ request: BGTaskRequest) async throws {
        if #available(iOS 27.0, *) {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        } else {
            try BGTaskScheduler.shared.submit(request)
        }
    }

    /// Ждущие заявки планировщика. «The handler may execute on a background thread»
    /// (`BGTaskScheduler.h`) — замерено: в симуляторе ответ приходит с
    /// `com.apple.root.utility-qos`.
    ///
    /// Ловушки `register` здесь **нет**, и это проверено, а не предположено (ревью 24 октября
    /// 2026 сочло иначе). У этого метода есть асинхронный вариант, и Swift импортирует его
    /// обработчик как `@Sendable` — так выглядит интерфейс, который видит компилятор
    /// (`swift-synthesize-interface`, модуль `BackgroundTasks.BGTaskScheduler`):
    /// `getPendingTaskRequests(completionHandler: @escaping @Sendable ([BGTaskRequest]) -> Void)`.
    /// `@Sendable`-замыкание изоляцию главного актора не наследует, и проверки очереди в нём
    /// нет — опыт с прежним кодом в модуле приложения (Swift 6) ответ с чужой очереди
    /// пережил. У `register` обработчик импортирован без `@Sendable`
    /// (`launchHandler: @escaping (BGTask) -> Void`) — оттуда и прежний крэш. `nonisolated` и
    /// явный `@Sendable` оставлены страховкой: на случай, если импорт изменится, и чтобы
    /// это место не служило образцом для обработчиков вроде `register`.
    nonisolated static func systemPendingRequests(_ reply: @escaping @Sendable ([String]) -> Void) {
        BGTaskScheduler.shared.getPendingTaskRequests { @Sendable requests in
            reply(requests.map(\.identifier))
        }
    }

    /// Системная задача так, как её видит Runway. Протоколом, а не `BGContinuedProcessingTask`:
    /// ту в тесте не создать (`init` у `BGTask` — `NS_UNAVAILABLE`), а без этого истечение,
    /// закрытие и полоса оставались бы непроверенными.
    @MainActor
    protocol RunwayTask: AnyObject {
        var totalUnitCount: Int64 { get set }
        var completedUnitCount: Int64 { get set }
        /// Обработчик истечения. Система зовёт его со своей очереди — поэтому `@Sendable`.
        func setExpirationHandler(_ handler: (@Sendable () -> Void)?)
        func setTaskCompleted(success: Bool)
        func updateSubtitle(_ subtitle: String)
    }

    @available(iOS 26.0, *)
    private final class SystemTask: RunwayTask {
        private let task: BGContinuedProcessingTask
        init(_ task: BGContinuedProcessingTask) { self.task = task }

        var totalUnitCount: Int64 {
            get { task.progress.totalUnitCount }
            set { task.progress.totalUnitCount = newValue }
        }
        var completedUnitCount: Int64 {
            get { task.progress.completedUnitCount }
            set { task.progress.completedUnitCount = newValue }
        }
        func setExpirationHandler(_ handler: (@Sendable () -> Void)?) { task.expirationHandler = handler }
        func setTaskCompleted(success: Bool) { task.setTaskCompleted(success: success) }
        func updateSubtitle(_ subtitle: String) { task.updateTitle("Расшифровка", subtitle: subtitle) }
    }

    private let hooks: SystemHooks
    /// На виду ли приложение. Следим по уведомлениям, а не спрашиваем систему на месте:
    /// на `willResignActive` `applicationState` ещё показывает `.active`.
    private var appIsActive: Bool
    private var keepingScreenAwake = false
    private let observation: NotificationObservation

    init(service: TranscriptionService, hooks: SystemHooks = SystemHooks()) {
        self.service = service
        self.hooks = hooks
        self.appIsActive = hooks.isActive()
        self.observation = NotificationObservation(center: hooks.notifications)
        Self.current = self
        network.pathUpdateHandler = { @Sendable [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.service.connectionBecameAvailable() }
        }
        network.start(queue: DispatchQueue(label: "Lori.connectivity"))
        if #unavailable(iOS 26.0) {
            state = .foregroundOnly("Фоновая расшифровка есть с iOS 26. Здесь работа идёт, пока приложение открыто.")
        }
        // Уход с переднего плана ловится здесь, а не в `LoriLocalApp`: приложение
        // пересылает сюда только `didBecomeActive` и `didEnterBackground`, а экран надо
        // отпустить раньше — как только он перестал быть на виду.
        observation.observe(UIApplication.willResignActiveNotification) { [weak self] in
            self?.appIsActive = false
            self?.syncScreen()
        }
        observation.observe(UIApplication.didBecomeActiveNotification) { [weak self] in
            self?.appIsActive = true
            self?.syncScreen()
        }
    }

    /// Подписки на уведомления живут в своём объекте: `deinit` изолированного на главном
    /// акторе класса не может трогать его поля, а снять подписку надо при уничтожении.
    ///
    /// Обработчики идут синхронно на потоке отправителя (`queue: nil`): систему слушаем
    /// только по уведомлениям `UIApplication`, а их она шлёт с главного потока. Чужой
    /// поток не роняет процесс, а переезжает на главный актор задачей.
    private final class NotificationObservation: @unchecked Sendable {
        private let center: NotificationCenter
        private var tokens: [NSObjectProtocol] = []

        init(center: NotificationCenter) { self.center = center }

        func observe(_ name: Notification.Name, perform action: @escaping @MainActor @Sendable () -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated(action)
                } else {
                    Task { @MainActor in action() }
                }
            })
        }

        deinit { for token in tokens { center.removeObserver(token) } }
    }

    /// Экран не гаснет, пока очередь идёт и приложение на виду.
    ///
    /// Автоблокировка через ~30 секунд без касаний уводит приложение в фон. Там, где
    /// настоящей фоновой задачи нет (симулятор, iOS ниже 26, отказ системы), у работы
    /// остаётся запасное окно UIKit в те же ~30 секунд — и после него всё оборванное
    /// считается заново с нуля. Длинная запись, поставленная и оставленная на столе,
    /// именно так и пропадала. Поэтому пока что-то считается, экран держим включённым.
    ///
    /// Отпускаем в двух случаях: очередь опустела или приложение ушло с переднего плана.
    /// Второе не про батарею, а про вежливость: флаг глобален для приложения, и он не
    /// должен пережить его уход из-под пальца человека.
    private func syncScreen() {
        let wanted = appIsActive && !service.isIdle
        guard wanted != keepingScreenAwake else { return }
        keepingScreenAwake = wanted
        hooks.setScreenAwake(wanted)
    }

    /// Коробка для перевозки задачи на главный актор.
    ///
    /// `BGTask` — обычный класс Objective-C, `Sendable` он не является, а обработчик
    /// приходит с очереди планировщика, откуда задачу надо передать туда, где живёт
    /// сервис. Пометка безопасна по факту владения: планировщик отдаёт задачу одним
    /// вызовом и больше к ней не притрагивается, а дальше её трогает только главный
    /// актор — и `drive`, и обработчик истечения.
    @available(iOS 26.0, *)
    private struct TaskBox: @unchecked Sendable {
        let task: BGContinuedProcessingTask
    }

    /// Состояние регистрации. Живёт под замком, а не на главном акторе, потому что
    /// саму регистрацию приходится делать `nonisolated` — см. ниже.
    private final class Registration: @unchecked Sendable {
        private let lock = NSLock()
        private var attempted = false
        private var accepted = false

        /// Регистрировать один идентификатор дважды нельзя: система убивает приложение
        /// на второй регистрации. Отсюда флаг, а не надежда, что зовут один раз.
        func claim() -> Bool { lock.withLock { defer { attempted = true }; return !attempted } }
        func settle(_ ok: Bool) { lock.withLock { accepted = ok } }
        var isAccepted: Bool { lock.withLock { accepted } }
    }

    private nonisolated static let registration = Registration()

    /// Приняли ли регистрацию. **Не косметика:** `submit` неизвестного планировщику
    /// идентификатора не возвращает ошибку, а роняет процесс —
    /// `*** Assertion failure in -[BGTaskScheduler
    /// _handleSubmissionWithoutRegistrationForTaskRequest:error:]`.
    nonisolated static var isRegistered: Bool { registration.isAccepted }

    /// Регистрация обработчика. Зовётся из `LoriLocalApp.init()`: обработчик не должен
    /// зависеть от того, построен ли уже экран.
    ///
    /// **`nonisolated` здесь обязателен, и это не стиль.** Планировщик зовёт обработчик
    /// со своей очереди `com.apple.BGTaskScheduler`, а замыкание, созданное внутри
    /// `@MainActor`-типа, наследует изоляцию главного актора — и рантайм Swift 6 роняет
    /// процесс проверкой `dispatch_assert_queue` в момент запуска задачи, то есть ровно
    /// тогда, когда фон наконец заработал. Поймано крэш-логом с телефона:
    /// `EXC_BREAKPOINT` в `closure #1 in static TranscriptionRunway.register()`.
    /// `@Sendable` на самом замыкании — вторая страховка от того же: такое замыкание
    /// изоляцию контекста не наследует.
    nonisolated static func register() {
        guard #available(iOS 26.0, *), registration.claim() else { return }
        let accepted = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { @Sendable task in
            // Первым делом — след в журнале. Без него «полосы нет» неотличимо от
            // «задачу так и не запустили», а разбираться придётся по переспросам.
            Journal.append("фон: система запустила задачу \(task.identifier)")
            guard let task = task as? BGContinuedProcessingTask else {
                Journal.append("фон: пришла задача не того типа")
                task.setTaskCompleted(success: false)
                return
            }
            let box = TaskBox(task: task)
            Task { @MainActor in
                guard let runway = current else {
                    Journal.append("фон: некому вести полосу — взлёт не найден")
                    box.task.setTaskCompleted(success: false)
                    return
                }
                await runway.drive(SystemTask(box.task))
            }
        }
        registration.settle(accepted)
        // Версия системы — в той же строке: на iOS 27 планировщик мог начать иначе
        // принимать идентификаторы (заголовок SDK по-прежнему советует форму с `.*`, а
        // замер на iOS 26.5 — базовую), и разбирать это придётся по журналу с телефона.
        Journal.append("фон: регистрация \(taskIdentifier) — \(accepted ? "принята" : "отклонена") (iOS \(systemVersion))")
    }

    /// «26.5» или «27.0.1» — для журнала. Через `ProcessInfo`, а не `UIDevice`: тот
    /// изолирован главным актором, а регистрация обязана быть `nonisolated`.
    nonisolated static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    /// Ждёт ли заявка того, чтобы приложение стало активным.
    private var deferred = false
    /// Номер последней поданной заявки. На iOS 27 ответ планировщика приходит когда
    /// угодно, и ответ на прежнюю заявку не должен решать за новую: ни снимать её отказом,
    /// ни оставлять в планировщике заявку, которую уже никто не ждёт.
    private var submission = 0
    /// Задача, которую ведём сейчас. Планировщик может запустить задачу повторно, и два
    /// `drive` разом мешали бы друг другу: оба пишут прогресс и оба зовут `batchDidFinish`,
    /// а тот сбрасывает `submitted` — и приложение подаёт заявку по кругу.
    private var ongoing: Drive?
    private var expired = false
    /// Задачу закрыли на истечении, а пачка жива: облачная запись осталась ждать ответ
    /// системы. Новая запись, поставленная по ходу, просит новую заявку (`wantsSubmission`) —
    /// иначе она шла бы вовсе без фоновой задачи, ведь «пачка» для сервиса не кончилась.
    private var lostTask = false
    /// Окно `beginBackgroundTask`, пока система разбудила приложение событиями передачи.
    private var wake: UIBackgroundTaskIdentifier = .invalid
    private var wakeStarted = Date()
    /// Обработчики системы из `handleEventsForBackgroundURLSession`: звать их можно только
    /// тогда, когда записи сохранены, — после них система вправе снова усыпить процесс.
    private var wakeCompletions: [() -> Void] = []
    /// События пробуждения уже доставлены (`urlSessionDidFinishEvents`).
    private var wakeDelivered = false

    var canExecuteInBackground: Bool { ongoing != nil || grace != .invalid || wake != .invalid }
    var wantsSubmission: Bool { lostTask && !submitted && ongoing == nil }
    /// Заявка подана и ещё нужна, и сколько ответов планировщика уже разобрано — для
    /// тестов гонок асинхронной подачи: «ничего не изменилось» иначе не дождаться.
    var hasLiveSubmission: Bool { submitted }
    private(set) var answeredSubmissions = 0

    /// Одна запущенная системой задача и всё, что к ней относится.
    ///
    /// Своим объектом, потому что истечение теперь может закрыть задачу раньше, чем
    /// опустеет очередь (облачная запись ждёт ответ системы), — и `drive`, проснувшийся
    /// потом, должен знать, что задача уже отдана. Живёт на главном акторе, как и всё, что
    /// её трогает, — истечение перевозится сюда задачей.
    @MainActor
    private final class Drive {
        let task: any RunwayTask
        let started = Date()
        var closed = false
        var ticker: Task<Void, Never>?
        /// Последнее, что отдано полосе, и знаменатель, при котором отдано (`barUnits`).
        var completed: Int64 = 0
        var total = 0
        /// Откуда последняя доля каждой записи — в журнал идёт только смена источника.
        var sources: [String: TranscriptionService.BackgroundShare.Source] = [:]

        init(task: any RunwayTask) { self.task = task }
    }

    /// Единиц полосы на запись. Миллион, а не тысяча: оценка ожидания ответа нарочно
    /// замедляется, и через час её приращение за секунду — тысячные доли процента; в
    /// тысяче единиц на запись полоса стояла бы на месте минутами.
    nonisolated static let unitsPerRecord: Int64 = 1_000_000

    func applicationDidEnterBackground() {
        appIsActive = false
        syncScreen()
        guard !service.isIdle else { return }
        // По этой строке видно, чем было прикрыто то, что шло, в момент ухода: задачей
        // планировщика или только запасным окном. Жалоба «выхожу — и всё прекращается»
        // без неё не разбирается.
        Journal.append(
            "фон: приложение ушло в фон — \(ongoing != nil ? "работу ведёт задача планировщика" : submitted ? "заявка подана, задача ещё не пришла" : "заявки нет, только запасное окно"); "
            + service.workSummary()
        )
        guard ongoing == nil else { return }
        beginGrace()
    }

    /// Очередь непуста — просим у системы фон под всю пачку.
    func batchDidStart() {
        syncScreen()
        guard !submitted else { return }
        // Заявка создаётся «от имени приложения на переднем плане» (`BGTaskRequest.h`),
        // а `resumeInterrupted` дёргает очередь прямо на запуске, когда приложение ещё
        // не активно. Тогда откладываем до `didBecomeActive`, а не тратим попытку.
        // Так же и постановка из Dynamic Island: Apple подаёт заявку «from the
        // foreground … as a result of a person’s action» (`BGContinuedProcessingTaskRequest`),
        // а из фона её не подать — облачной записи хватает запасного окна, чтобы запрос
        // ушёл системе, дальше её ведёт фоновая передача.
        guard hooks.isActive() else {
            deferred = true
            Journal.append("фон: приложение ещё не активно, заявку откладываю")
            beginGrace()
            return
        }
        submitted = true
        lostTask = false
        guard #available(iOS 26.0, *) else {
            beginGrace()
            return
        }
        // Без принятой регистрации `submit` не отказывает, а убивает приложение.
        guard hooks.isRegistered() else {
            submitted = false
            state = .foregroundOnly("Система не приняла регистрацию фоновой задачи — работа идёт, пока приложение открыто.")
            Journal.append("фон: регистрация \(Self.taskIdentifier) не принята, заявку не подаём")
            beginGrace()
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            // Ровно тот идентификатор, что зарегистрирован: составной планировщик
            // не узнаёт и отвечает «Unrecognized Identifier».
            identifier: Self.taskIdentifier,
            title: "Расшифровка",
            subtitle: currentSubtitle()
        )
        // `.queue` вместо `.fail`: под нагрузкой лучше подождать очереди планировщика,
        // чем остаться без фона совсем. Работа при этом уже идёт — она не ждёт задачу.
        request.strategy = .queue
        // Пустой набор (в Objective-C это `…ResourcesDefault`) — то есть обычные
        // фоновые CPU и сеть. Ресурс `.gpu` сюда не просим: он требует entitlement
        // `com.apple.developer.background-tasks.continued-processing.gpu`, а его
        // бесплатная команда разработчика не подписывает — как и App Groups.
        request.requiredResources = []
        // Запасное окно — сразу, а не по ответу планировщика: на iOS 27 ответ приходит
        // «on an arbitrary queue after an arbitrary amount of delay» (`BGTaskScheduler.h`).
        state = .foregroundOnly("Система ещё готовит фоновое выполнение. Если времени не хватит, работа продолжится при возвращении.")
        beginGrace()
        submission += 1
        let generation = submission
        let records = service.batchTotal
        if hooks.submitsAsynchronously {
            // iOS 27: синхронный `submit(_:)` объявлен устаревшим «to capture all error
            // conditions», замена — `submitTaskRequest(_:)`, и её «Do not call … from the
            // main thread». Отсюда отдельная задача вне главного актора. Идентификатор не
            // меняем: форма с `.*` из заголовка на iOS 26.5 ломала регистрацию (таблица
            // выше), а проверить iOS 27 можно только на телефоне — по этим строкам журнала.
            let box = RequestBox(request: request)
            let submit = hooks.submitAsync
            Journal.append("фон: подаю заявку \(request.identifier) через submitTaskRequest (iOS \(Self.systemVersion)), записей \(records)")
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try await submit(box.request)
                    await self?.submissionAccepted(generation, api: "submitTaskRequest", records: records)
                } catch {
                    await self?.submissionRefused(generation, error)
                }
            }
        } else {
            do {
                try hooks.submit(request)
                submissionAccepted(generation, api: "submit", records: records)
            } catch {
                submissionRefused(generation, error)
            }
        }
    }

    /// Коробка для перевозки заявки в задачу вне главного актора: `BGTaskRequest` —
    /// класс Objective-C без `Sendable`, а трогает его после передачи только планировщик.
    private struct RequestBox: @unchecked Sendable {
        let request: BGTaskRequest
    }

    private func submissionAccepted(_ generation: Int, api: String, records: Int) {
        answeredSubmissions += 1
        Journal.append("фон: заявка \(Self.taskIdentifier) подана (\(api), iOS \(Self.systemVersion)), записей \(records)")
        guard generation == submission, submitted else {
            // Ответ на iOS 27 пришёл позже, чем кончилась пачка: `cancel` в `batchDidFinish`
            // тогда снимать было нечего, и задача запустилась бы впустую. Снимаем сейчас —
            // но только если новой заявки нет: идентификатор у всех один, и `cancel` снял
            // бы и её. Новая сама заменит прежнюю у планировщика.
            if submitted {
                Journal.append("фон: это ответ на прежнюю заявку — действует новая, её не трогаю")
            } else {
                hooks.cancelRequest(Self.taskIdentifier)
                Journal.append("фон: заявка принята, когда пачка уже кончилась, — снимаю её")
            }
            return
        }
        // Подана — ещё не значит «в очереди планировщика»: на iOS 27 отказ мог бы прийти
        // и иначе. Список ждущих заявок система отдаёт сама — пишем его рядом. Ответ
        // приходит с чужой очереди, поэтому замыкание `@Sendable` — см. `systemPendingRequests`.
        hooks.pendingRequests { @Sendable identifiers in
            Journal.append("фон: у планировщика ждут: \(identifiers.isEmpty ? "ничего (задача уже идёт или снята)" : identifiers.joined(separator: ", "))")
        }
    }

    private func submissionRefused(_ generation: Int, _ error: Error) {
        answeredSubmissions += 1
        // Не гадаем, почему отказ: спрашиваем систему и пишем ответ рядом.
        // «Проверь настройки» без указания какой именно — это переспрос,
        // а не диагноз, и прошлый раз он стоил лишнего круга.
        let reason = "\(Self.explain(error)) \(Self.remedy())"
        let raw = error as NSError
        Journal.append(
            "фон: заявка отклонена — \(reason) "
            + "[\(raw.domain) \(raw.code), состояние \(Self.stateName), iOS \(Self.systemVersion), userInfo \(raw.userInfo)]"
        )
        // Запоздалый отказ прежней заявки не трогает новую: ни её отметку, ни строку.
        guard generation == submission else {
            Journal.append("фон: отказ пришёл на прежнюю заявку — новую не трогаю")
            return
        }
        submitted = false
        // Пачка успела кончиться, пока ответ планировщика шёл (iOS 27, асинхронно):
        // строка про фон относилась бы уже ни к чему.
        guard !service.isIdle else { return }
        state = .foregroundOnly(reason)
    }

    /// Приложение стало активным — самое время подать отложенную заявку.
    func applicationDidBecomeActive() {
        appIsActive = true
        syncScreen()
        // Пробуждение событиями передачи больше не нужно держать своим окном: процесс на
        // переднем плане. Иначе окно, кончившись, прервало бы работу, которую человек
        // видит на экране.
        if wake != .invalid || !wakeCompletions.isEmpty {
            if wakeDelivered {
                finishWake("Lori открыли — дальше работа идёт на переднем плане")
            } else {
                endWakeWindow()
            }
        }
        guard deferred, !service.isIdle else {
            deferred = false
            return
        }
        deferred = false
        batchDidStart()
    }

    /// Очередь опустела своим ходом — фоновое окно UIKit больше не нужно.
    func batchDidFinish() {
        syncScreen()
        guard ongoing == nil else { endGrace(); return }
        if submitted { hooks.cancelRequest(Self.taskIdentifier) }
        submitted = false
        deferred = false
        lostTask = false
        endGrace()
        if case .running = state { state = .ready }
    }

    /// Тело фоновой задачи: сама она не считает, а ведёт полосу и держит процесс.
    /// Не `private`: тест ведёт полосу подставной задачей (`RunwayTask`).
    func drive(_ task: any RunwayTask) async {
        guard ongoing == nil else {
            Journal.append("фон: полосу уже ведёт другая задача, эту завершаю")
            task.setTaskCompleted(success: true)
            return
        }
        guard !service.isIdle else {
            task.setTaskCompleted(success: true)
            batchDidFinish()
            return
        }
        let session = Drive(task: task)
        ongoing = session
        expired = false
        lostTask = false
        endGrace()
        state = .running
        Journal.append("фон: задача взяла пачку из \(service.batchTotal) — \(service.workSummary())")

        // Задача могла прийти не с начала пачки — часть записей к этому времени уже
        // сделана, и полоса начинает с них, а не с нуля.
        let total = max(service.batchTotal, 1)
        session.total = total
        task.totalUnitCount = Int64(total) * Self.unitsPerRecord
        session.completed = Int64(min(service.batchDone, total)) * Self.unitsPerRecord
        task.completedUnitCount = session.completed

        // `@Sendable` обязателен по той же причине, что и у обработчика запуска:
        // истечение приходит с чужой очереди, а замыкание из `@MainActor`-метода
        // унаследовало бы изоляцию и уронило процесс проверкой очереди.
        task.setExpirationHandler { @Sendable [weak self] in
            Task { @MainActor in self?.expire(session) }
        }

        // Полоса обновляется, пока идёт работа. Это не косметика: по `progress`
        // система и рисует прогресс, и отличает живую задачу от подвисшей.
        session.ticker = Task { @MainActor [weak self] in
            while let self, !self.service.isIdle, !Task.isCancelled, !session.closed {
                self.pump(session)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let outcome = await service.waitForDrain()
        session.ticker?.cancel()
        guard !session.closed else {
            // Задачу уже отдали на истечении (облачная запись ждала ответ системы), а
            // очередь опустела только теперь: системе отвечать больше нечего.
            await EngineSessionCache.shared.dropIdle()
            return
        }

        let success = Self.completionSuccess(expired: expired, outcome: outcome)
        if success { task.completedUnitCount = task.totalUnitCount }
        close(session, success: success)
        batchDidFinish()
        // Пачка кончилась — 618 МБ весов держать больше незачем.
        await EngineSessionCache.shared.dropIdle()
    }

    /// Отдаёт задачу системе — один раз.
    private func close(_ session: Drive, success: Bool) {
        guard !session.closed else { return }
        session.closed = true
        session.ticker?.cancel()
        session.task.setExpirationHandler(nil)
        session.task.setTaskCompleted(success: success)
        if ongoing === session { ongoing = nil }
    }

    /// Система забирает время задачи: человек снял её в Live Activity, системе стало
    /// тесно или задача показалась ей стоящей.
    ///
    /// Всё, что считается в процессе, прерывается, как и раньше. Облачная запись, чей
    /// запрос уже у системной передачи, остаётся ждать (`interruptEverything`) — и тогда
    /// задачу закрываем **сразу**, не дожидаясь пустой очереди: «Not calling
    /// setTaskCompleted(success:) before the time for the task expires may result in the
    /// system killing your app» (`BGTask.h`), а ответ сервиса может идти минуты. Убитый
    /// процесс ответ всё равно получит — пробуждением, — но спящий доделает быстрее.
    private func expire(_ session: Drive) {
        guard !session.closed, !expired else { return }
        expired = true
        let seconds = Int(Date().timeIntervalSince(session.started))
        Journal.append("фон: система забрала время задачи через \(seconds) с — \(service.workSummary())")
        let parked = service.interruptEverything()
        guard !parked.isEmpty else {
            Journal.append("фон: всё, что шло, помечено прерванным и продолжится при возвращении")
            state = .foregroundOnly("iOS приостановила обработку. Сохранённая работа продолжится при возвращении в Lori.")
            return
        }
        Journal.append("фон: оставил облачную запись ждать ответ системы — \(parked.map { "«\($0)»" }.joined(separator: ", ")); задачу отдаю сейчас")
        state = .foregroundOnly("iOS забрала фоновое время. Запись уже у сервиса — Lori доделает её, когда придёт ответ.")
        close(session, success: false)
        submitted = false
        deferred = false
        lostTask = true
        endGrace()
    }

    /// Как задача отчитывается системе: успешно или нет — **по этой пачке**.
    ///
    /// Раньше смотрели на общие словари сервиса (`failed`, `interrupted`), которые никто
    /// не обнулял: одна старая ошибка, давно показанная на своей карточке, делала
    /// неудачной каждую следующую пачку, а ждущая решения облачная запись «Прервано»
    /// — тоже. Отмена человеком сбоем не считается: задачу закончили сознательно.
    nonisolated static func completionSuccess(expired: Bool, outcome: TranscriptionBatchOutcome?) -> Bool {
        !expired && (outcome?.isClean ?? true)
    }

    /// Сколько единиц отдать полосе — чистая функция.
    ///
    /// Полоса не идёт назад: доля записи может на миг упасть (ответ получен — фаза запроса
    /// сброшена, а движок ещё не сказал «1 из 1»; запись вышла из счёта идущих, а в
    /// «готово» ещё не вошла), и системе это выглядело бы откатом работы. **Кроме одного
    /// случая: знаменатель уменьшился** — запись сняли или оборвали, и она ушла из счёта
    /// вместе со своей долей. Раньше максимум держался и тогда: запись на 0,95 снята,
    /// следующая растёт от нуля и выше 0,95 не поднимается — полоса стояла весь её прогон,
    /// а стоящую задачу планировщик снимает.
    nonisolated static func barUnits(previous: Int64, previousTotal: Int, total: Int, done: Int, partial: Double) -> Int64 {
        let units = Int64(max(total, 1)) * unitsPerRecord
        let measured = min(units, max(0, Int64(((Double(done) + partial) * Double(unitsPerRecord)).rounded(.down))))
        guard total >= previousTotal else { return measured }
        return min(units, max(previous, measured))
    }

    private func pump(_ session: Drive) {
        // Счёт ведёт сервис, а не задача: он знает и про добавленные по ходу записи, и про
        // снятые, и про упавшие — всё, что раньше приходилось выводить из `seen`.
        let total = max(service.batchTotal, 1)
        let done = min(service.batchDone, total)
        // Доля недоделанных записей идёт в общий счёт. Это не косметика: по `progress`
        // планировщик отличает живую задачу от подвисшей и **принудительно завершает**
        // ту, что стоит на месте («tasks that appear stalled may be forcibly expired»,
        // `BGTask.h`). Именно так и вышло на первом живом прогоне: облачный запрос идёт
        // одним куском, доли у него нет вовсе, ноль стоял две с половиной минуты — и
        // систему это не устроило.
        //
        // Доля записи — `TranscriptionService.backgroundShare`: куски движка, байты
        // отправки, а пока ждём ответ или мерить нечего — оценка по времени с потолком
        // ниже единицы. «Готово» ставит только настоящее завершение.
        var partial = 0.0
        for path in service.batchRunning {
            let share = service.backgroundShare(for: path)
            partial += share.value
            if session.sources[path] != share.source {
                session.sources[path] = share.source
                Journal.append("фон: полоса по «\(path)» — \(share.source.rawValue)")
            }
        }
        let completed = Self.barUnits(previous: session.completed, previousTotal: session.total, total: total, done: done, partial: partial)
        if total < session.total {
            Journal.append("фон: из пачки ушла запись — полоса считается заново: \(done) готово из \(total)")
        }
        // Порядок — чтобы доля ни на миг не вышла за единицу: растёт знаменатель — сначала он.
        if total >= session.total {
            session.task.totalUnitCount = Int64(total) * Self.unitsPerRecord
            session.task.completedUnitCount = completed
        } else {
            session.task.completedUnitCount = completed
            session.task.totalUnitCount = Int64(total) * Self.unitsPerRecord
        }
        session.completed = completed
        session.total = total
        session.task.updateSubtitle(currentSubtitle())
    }

    // MARK: - Пробуждение событиями фоновой передачи

    /// Система разбудила приложение событиями фоновой передачи: ответ сервиса пришёл,
    /// пока процесс спал, или процесс уже убит и поднят заново ради этого события.
    ///
    /// Порядок из документации Apple: обработчик системы запомнить, сессию с тем же
    /// идентификатором пересоздать (её события тогда приходят делегату), а звать
    /// обработчик — когда события доставлены и обработаны
    /// (`urlSessionDidFinishEvents(forBackgroundURLSession:)`; «Downloading files in the
    /// background»). «Обработаны» для Lori — это разобранный и сохранённый текст, а не
    /// просто полученные байты: после обработчика система вправе снова усыпить процесс.
    /// Поэтому работа идёт под своим окном `beginBackgroundTask`, и системе отвечаем,
    /// когда записи доделаны (`finishAfterSystemWake`) или окно кончилось.
    ///
    /// Lori на экране — окно не нужно, и режим «только готовые ответы» тоже: прерванное
    /// поднимет обычный ход переднего плана (`resumeInterrupted`).
    func systemWokeForTransfers(completion: @escaping () -> Void) {
        if wakeCompletions.isEmpty { wakeStarted = Date() }
        wakeCompletions.append(completion)
        wakeDelivered = false
        let onScreen = hooks.isActive()
        if !onScreen {
            if wake == .invalid {
                wake = hooks.beginBackgroundTask("Lori: ответ сервиса") { [weak self] in self?.wakeWindowExpired() }
            }
            // Приложение поднято в фоне — сервис обязан это знать: иначе появление сети или
            // таймер повтора подняли бы прерванные записи — и локальные, и облачные без
            // готового ответа — прямо из фона (у только что запущенного сервиса
            // «на экране» по умолчанию).
            service.applicationDidEnterBackground()
        }
        Journal.append(
            "фон: система разбудила приложение событиями передачи (\(Self.stateName), iOS \(Self.systemVersion)) — "
            + (service.isIdle ? "в памяти ничего не идёт: процесс подняли заново" : "процесс спал; \(service.workSummary())")
        )
        hooks.reconnectTransfers { @Sendable [weak self] in
            // Все события сессии доставлены: ответы уже у ждущего Swift-кода или распиской.
            Task { @MainActor in await self?.wakeEventsDelivered() }
        }
    }

    private func wakeEventsDelivered() async {
        wakeDelivered = true
        guard !hooks.isActive() else {
            finishWake("события доставлены, Lori на экране — дальше обычным ходом")
            return
        }
        let report = await service.finishAfterSystemWake(in: WorkspaceStore.current)
        let outcome = report.outcome
        finishWake(
            "шло \(report.alive.count), поднято по распискам \(report.resumed.count); "
            + "сохранено \(outcome?.succeeded.count ?? 0), ошибок \(outcome?.failed.count ?? 0), ждут возвращения \(outcome?.interrupted.count ?? 0)"
        )
    }

    /// Окно пробуждения кончилось раньше, чем запись доделана (например, задание по частям
    /// отправило следующую): что у системы — снова ждёт, остальное прерывается. Но только
    /// если работу больше ничто не держит: живая задача планировщика или запасное окно
    /// ведут её дальше, а на экране прерывать нечего.
    private func wakeWindowExpired() {
        if ongoing == nil, grace == .invalid, !hooks.isActive() {
            let parked = service.interruptEverything()
            finishWake("окно пробуждения кончилось, ждут ответ системы: \(parked.count)")
        } else {
            let keeper = ongoing != nil ? "задача планировщика" : grace != .invalid ? "запасное окно" : "передний план"
            finishWake("окно пробуждения кончилось, работу дальше ведёт \(keeper)")
        }
    }

    /// Отвечает системе — один раз на пробуждение — и отпускает окно.
    private func finishWake(_ summary: String) {
        guard !wakeCompletions.isEmpty || wake != .invalid else { return }
        let completions = wakeCompletions
        wakeCompletions = []
        wakeDelivered = false
        Journal.append("фон: пробуждение закончено за \(Int(Date().timeIntervalSince(wakeStarted))) с — \(summary); отдаю системе")
        completions.forEach { $0() }
        endWakeWindow()
    }

    private func endWakeWindow() {
        guard wake != .invalid else { return }
        hooks.endBackgroundTask(wake)
        wake = .invalid
    }

    /// Строка под полосой прогресса сейчас: «2 из 5 · Совещание 27.08».
    ///
    /// Имя берётся у приложения (`displayTitle`) — настоящий заголовок записи, а не
    /// `Recording-2026-09-01T12-00-00Z`. Не нашлось или пусто — имя файла, как раньше.
    func currentSubtitle() -> String {
        let path = service.currentPath
        let title = path
            .flatMap { displayTitle($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return Self.subtitle(
            done: service.batchDone,
            total: service.batchTotal,
            name: title ?? path.map(Self.fileName(of:))
        )
    }

    /// «2 из 5 · Совещание 27.08». Имя записи — это то, по чему человек её узнаёт
    /// в Dynamic Island, где больше ничего и не помещается.
    nonisolated static func subtitle(done: Int, total: Int, current: String?) -> String {
        subtitle(done: done, total: total, name: current.map(fileName(of:)))
    }

    /// То же, но с готовым названием: заголовок вроде «Отчёт 27.08» нельзя пускать через
    /// разбор пути — «.08» принялось бы за расширение и отрезалось.
    nonisolated static func subtitle(done: Int, total: Int, name: String?) -> String {
        guard total > 1 else { return name ?? "одна запись" }
        let counter = TranscriptionService.counter(done: done, total: total)
        guard let name, !name.isEmpty else { return counter }
        return "\(counter) · \(name)"
    }

    /// Имя файла без папки и расширения.
    nonisolated static func fileName(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    nonisolated static func explain(_ error: Error) -> String {
        guard #available(iOS 26.0, *), let code = (error as NSError?).flatMap({
            $0.domain == BGTaskScheduler.errorDomain ? BGTaskScheduler.Error.Code(rawValue: $0.code) : nil
        }) else {
            return "Система не дала фон: \(error.localizedDescription)"
        }
        switch code {
        case .unavailable:
            return "Фоновая работа выключена — на телефоне её мог отключить сам человек в «Обновление контента»."
        case .notPermitted:
            // На телефоне это почти всегда запрет фоновых запусков, и человеку нужно
            // знать, куда идти, а не код ошибки. Симулятор отвечает тем же кодом, но
            // там фона нет вовсе. Что именно не так — дописывает `remedy()` по факту.
            return "Система запретила фоновую работу."
        case .tooManyPendingTaskRequests:
            return "Фоновых задач уже слишком много — дождись, пока закончатся прежние."
        case .immediateRunIneligible:
            return "Телефон сейчас занят и не может взять работу в фон."
        @unknown default:
            return "Система не дала фон: \(error.localizedDescription)"
        }
    }

    /// Состояние приложения словом — в журнал, чтобы не гадать, из фона ли подавали.
    static var stateName: String {
        switch UIApplication.shared.applicationState {
        case .active: "активно"
        case .inactive: "неактивно"
        case .background: "в фоне"
        @unknown default: "неизвестно"
        }
    }

    /// Что именно мешает, по ответу самой системы. Здесь два выключателя, и оба
    /// человек мог щёлкнуть сам, не связав их с расшифровкой.
    static func remedy() -> String {
        #if targetEnvironment(simulator)
        return "В симуляторе фоновых задач нет вовсе — это проверяется только на iPhone."
        #else
        var parts: [String] = []
        switch UIApplication.shared.backgroundRefreshStatus {
        case .denied:
            parts.append("«Обновление контента» для Lori выключено: Настройки → Основные → Обновление контента.")
        case .restricted:
            parts.append("Фоновые запуски ограничены родительским контролем или профилем устройства.")
        default:
            break
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            parts.append("Включён режим энергосбережения — он выключает фоновую работу.")
        }
        guard parts.isEmpty else { return parts.joined(separator: " ") }
        return "«Обновление контента» включено и энергосбережение выключено — причина в чём-то другом."
        #endif
    }

    // MARK: - Запасное окно UIKit

    private func beginGrace() {
        guard grace == .invalid else { return }
        grace = hooks.beginBackgroundTask("Lori transcription") { [weak self] in self?.graceExpired() }
    }

    /// Запасное окно кончилось. Прерывать — только если работу больше ничто не держит:
    /// ни задача планировщика, ни окно пробуждения (оно кончится своим ходом и решит само),
    /// ни передний план.
    private func graceExpired() {
        if ongoing == nil, wake == .invalid, !hooks.isActive() {
            Journal.append("фон: запасное окно iOS кончилось — \(service.workSummary())")
            let parked = service.interruptEverything()
            if parked.isEmpty {
                state = .foregroundOnly("iOS приостановила обработку. Прогресс сохранён; продолжу после возвращения в Lori.")
            } else {
                Journal.append("фон: оставил облачную запись ждать ответ системы — \(parked.map { "«\($0)»" }.joined(separator: ", "))")
                state = .foregroundOnly("iOS забрала фоновое время. Запись уже у сервиса — Lori доделает её, когда придёт ответ.")
            }
        }
        endGrace()
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        hooks.endBackgroundTask(grace)
        grace = .invalid
    }
}
