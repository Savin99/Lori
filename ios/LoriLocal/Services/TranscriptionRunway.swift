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
    /// Все записи, которые задача видела в этой пачке. Пачка растёт по ходу — человек
    /// добавляет записи, пока идут прежние, — и без этого счёт «сделано» уехал бы в
    /// минус, а полоса замерла бы.
    private var seen: Set<String> = []
    /// Фоновое окно UIKit на те ~30 секунд, что даёт система, когда настоящей фоновой
    /// задачи нет. Короткому облачному запросу этого хватает, длинной локальной — нет,
    /// и врать об этом не нужно.
    private var grace: UIBackgroundTaskIdentifier = .invalid

    init(service: TranscriptionService) {
        self.service = service
        Self.current = self
        network.pathUpdateHandler = { @Sendable [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.service.connectionBecameAvailable() }
        }
        network.start(queue: DispatchQueue(label: "Lori.connectivity"))
        if #unavailable(iOS 26.0) {
            state = .foregroundOnly("Фоновая расшифровка есть с iOS 26. Здесь работа идёт, пока приложение открыто.")
        }
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
                await runway.drive(box.task)
            }
        }
        registration.settle(accepted)
        Journal.append("фон: регистрация \(taskIdentifier) — \(accepted ? "принята" : "отклонена")")
    }

    /// Ждёт ли заявка того, чтобы приложение стало активным.
    private var deferred = false
    /// Уже ведём полосу. Планировщик может запустить задачу повторно, и два `drive`
    /// разом мешали бы друг другу: оба пишут прогресс и оба зовут `batchDidFinish`,
    /// а тот сбрасывает `submitted` — и приложение подаёт заявку по кругу.
    private var driving = false
    private var expired = false
    var canExecuteInBackground: Bool { driving || grace != .invalid }

    func applicationDidEnterBackground() {
        guard !service.isIdle, !driving else { return }
        beginGrace()
    }

    /// Очередь непуста — просим у системы фон под всю пачку.
    func batchDidStart() {
        guard !submitted else { return }
        // Заявка создаётся «от имени приложения на переднем плане» (`BGTaskRequest.h`),
        // а `resumeInterrupted` дёргает очередь прямо на запуске, когда приложение ещё
        // не активно. Тогда откладываем до `didBecomeActive`, а не тратим попытку.
        guard UIApplication.shared.applicationState == .active else {
            deferred = true
            Journal.append("фон: приложение ещё не активно, заявку откладываю")
            beginGrace()
            return
        }
        submitted = true
        guard #available(iOS 26.0, *) else {
            beginGrace()
            return
        }
        // Без принятой регистрации `submit` не отказывает, а убивает приложение.
        guard Self.isRegistered else {
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
            subtitle: Self.subtitle(done: 0, total: service.batchCount, current: nil)
        )
        // `.queue` вместо `.fail`: под нагрузкой лучше подождать очереди планировщика,
        // чем остаться без фона совсем. Работа при этом уже идёт — она не ждёт задачу.
        request.strategy = .queue
        // Пустой набор (в Objective-C это `…ResourcesDefault`) — то есть обычные
        // фоновые CPU и сеть. Ресурс `.gpu` сюда не просим: он требует entitlement
        // `com.apple.developer.background-tasks.continued-processing.gpu`, а его
        // бесплатная команда разработчика не подписывает — как и App Groups.
        request.requiredResources = []
        do {
            try BGTaskScheduler.shared.submit(request)
            state = .foregroundOnly("Система ещё готовит фоновое выполнение. Если времени не хватит, работа продолжится при возвращении.")
            beginGrace()
            Journal.append("фон: заявка \(request.identifier) подана, записей \(service.batchCount)")
        } catch {
            submitted = false
            // Не гадаем, почему отказ: спрашиваем систему и пишем ответ рядом.
            // «Проверь настройки» без указания какой именно — это переспрос,
            // а не диагноз, и прошлый раз он стоил лишнего круга.
            let reason = "\(Self.explain(error)) \(Self.remedy())"
            state = .foregroundOnly(reason)
            let raw = error as NSError
            Journal.append(
                "фон: заявка отклонена — \(reason) "
                + "[\(raw.domain) \(raw.code), состояние \(Self.stateName), userInfo \(raw.userInfo)]"
            )
            beginGrace()
        }
    }

    /// Приложение стало активным — самое время подать отложенную заявку.
    func applicationDidBecomeActive() {
        guard deferred, !service.isIdle else {
            deferred = false
            return
        }
        deferred = false
        batchDidStart()
    }

    /// Очередь опустела своим ходом — фоновое окно UIKit больше не нужно.
    func batchDidFinish() {
        guard !driving else { endGrace(); return }
        if submitted { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier) }
        submitted = false
        deferred = false
        endGrace()
        if case .running = state { state = .ready }
    }

    /// Тело фоновой задачи: сама она не считает, а ведёт полосу и держит процесс.
    @available(iOS 26.0, *)
    private func drive(_ task: BGContinuedProcessingTask) async {
        guard !driving else {
            Journal.append("фон: полосу уже ведёт другая задача, эту завершаю")
            task.setTaskCompleted(success: true)
            return
        }
        guard !service.isIdle else {
            task.setTaskCompleted(success: true)
            batchDidFinish()
            return
        }
        driving = true
        expired = false
        endGrace()
        state = .running
        Journal.append("фон: задача взяла пачку из \(service.batchCount)")

        seen = []
        task.progress.totalUnitCount = Int64(max(service.batchCount, 1)) * 1000
        task.progress.completedUnitCount = 0

        // `@Sendable` обязателен по той же причине, что и у обработчика запуска:
        // истечение приходит с чужой очереди, а замыкание из `@MainActor`-метода
        // унаследовало бы изоляцию и уронило процесс проверкой очереди.
        task.expirationHandler = { @Sendable in
            Task { @MainActor [weak self] in
                Journal.append("фон: система забрала процесс, записи помечены прерванными")
                guard let self, !self.expired else { return }
                self.expired = true
                self.state = .foregroundOnly("iOS приостановила обработку. Сохранённая работа продолжится при возвращении в Lori.")
                self.service.interruptEverything()
            }
        }

        // Полоса обновляется, пока идёт работа. Это не косметика: по `progress`
        // система и рисует прогресс, и отличает живую задачу от подвисшей.
        let ticker = Task { @MainActor [weak self] in
            while let self, !self.service.isIdle, !Task.isCancelled {
                self.pump(task)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        await service.waitForDrain()
        ticker.cancel()

        let success = !expired && service.interrupted.isEmpty && service.failed.isEmpty
        if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
        task.expirationHandler = nil
        driving = false
        task.setTaskCompleted(success: success)
        batchDidFinish()
        // Пачка кончилась — 618 МБ весов держать больше незачем.
        await EngineSessionCache.shared.dropIdle()
    }

    @available(iOS 26.0, *)
    private func pump(_ task: BGContinuedProcessingTask) {
        seen.formUnion(service.running)
        seen.formUnion(service.queued)
        let total = max(seen.count, 1)
        let done = max(0, seen.count - service.batchCount)
        task.progress.totalUnitCount = Int64(total) * 1000
        // Доля недоделанных записей идёт в общий счёт. Это не косметика: по `progress`
        // планировщик отличает живую задачу от подвисшей и **принудительно завершает**
        // ту, что стоит на месте («tasks that appear stalled may be forcibly expired»,
        // `BGTask.h`). Именно так и вышло на первом живом прогоне: облачный запрос идёт
        // одним куском, доли у него нет вовсе, ноль стоял две с половиной минуты — и
        // систему это не устроило.
        //
        // Поэтому у записи без известной доли берётся оценка по времени: сколько
        // прошло от начала против ожидаемого срока. Она заведомо приблизительная и
        // потому упирается в потолок, не доходя до конца, — «готово» ставит только
        // настоящее завершение.
        let partial = service.running.reduce(0.0) { sum, path in
            if let known = service.progressFraction(for: path) { return sum + known }
            // Нет измеренного прогресса — не выдаём таймер за сделанную работу.
            return sum
        }
        task.progress.completedUnitCount = min(
            task.progress.totalUnitCount,
            Int64((Double(done) + partial) * 1000)
        )
        task.updateTitle(
            "Расшифровка",
            subtitle: Self.subtitle(done: done, total: total, current: service.running.sorted().first)
        )
    }

    /// «2 из 5 · Совещание 27.08». Имя записи — это то, по чему человек её узнаёт
    /// в Dynamic Island, где больше ничего и не помещается.
    nonisolated static func subtitle(done: Int, total: Int, current: String?) -> String {
        let name = current.map { ((($0 as NSString).lastPathComponent) as NSString).deletingPathExtension }
        guard total > 1 else { return name ?? "одна запись" }
        let counter = "\(min(done + 1, total)) из \(total)"
        guard let name, !name.isEmpty else { return counter }
        return "\(counter) · \(name)"
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
        grace = UIApplication.shared.beginBackgroundTask(withName: "Lori transcription") { [weak self] in
            guard let self else { return }
            if !self.driving, UIApplication.shared.applicationState != .active {
                self.state = .foregroundOnly("iOS приостановила обработку. Прогресс сохранён; продолжу после возвращения в Lori.")
                self.service.interruptEverything()
            }
            self.endGrace()
        }
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }
}
