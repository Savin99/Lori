import AVFoundation
import Foundation
import UIKit

/// Диктофон Lori уровня приложения: запись идёт, когда человек ушёл из Lori, звонок
/// и прочие прерывания ставят её на паузу, а не обрывают, и управлять ею можно из
/// островка Dynamic Island и с экрана блокировки (владелец, 24 октября 2026).
///
/// Живёт в `LoriLocalApp`, а не в экране: кнопки островка приходят интентами в
/// процесс приложения, и запуск ради них может обойтись вовсе без окна. Экраны
/// берут его из окружения.
///
/// Как устроено:
/// - запись — куски (`RecordingSession`): каждый непрерывный отрезок между паузами
///   свой закрытый файл, состояние — в `Application Support/Lori/Recording`;
/// - любое прерывание (звонок, другое приложение, пропавший микрофон, сбой звука)
///   закрывает кусок и ставит паузу с причиной словами. Продолжения само не бывает:
///   владелец решил ждать «Продолжить», даже когда система советует продолжить;
/// - «Расшифровать» склеивает куски в одну запись `Recordings/…` (`RecordingAssembler`)
///   и ставит её в очередь, если включено «Расшифровывать запись сразу»;
/// - запуск с незаконченной записью на диске поднимает её на паузе.
///
/// Запись **не зависит** от распознавания: её недоступность не мешает сохранить звук.
@MainActor
final class RecordingController: ObservableObject, RecordingIntentHandling {
    enum Phase: Equatable {
        case idle
        case recording
        case paused
        /// Куски склеиваются в одну запись.
        case finishing
    }

    @Published private(set) var phase: Phase = .idle
    /// Длительность и громкость нужны интерфейсу: без них запись выглядит как зависшая кнопка.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0
    /// История уровней для живой волны в панели: на ровной речи мгновенное значение
    /// стоит на месте, и запись выглядела бы зависшей.
    @Published private(set) var levels: [Double] = []
    /// Почему пауза — «звонок», «микрофон отключён». `nil` — пауза от человека или запись идёт.
    @Published private(set) var pauseWords: String?
    /// Запись поднята после перезапуска Lori.
    @Published private(set) var isRestored = false
    /// Одна строка, когда кнопок в островке не будет: Live Activity выключены человеком.
    @Published private(set) var activityHint: String?
    /// Ошибка для алерта главного экрана.
    @Published var lastError: String?

    /// Около десяти секунд звука при шаге замера 120 мс.
    static let waveSamples = 80

    static let activitiesOffHint = "Кнопок в островке не будет: Live Activity для Lori выключены в Настройках."

    /// Идёт захват: сюда же попадает пауза — кнопка микрофона в это время «стоп».
    var isCapturing: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }
    var isPaused: Bool { phase == .paused }

    /// Всё, чем контроллер трогает систему, — подменяется в тестах.
    struct Hooks {
        var autoTranscribe: @MainActor () -> Bool = {
            UserDefaults.standard.bool(forKey: TranscriptionSettings.autoTranscribeKey)
        }
        var engine: @MainActor () -> TranscriptionEngineKind = { TranscriptionSettings.engine }
        var inCall: @MainActor () -> Bool
        var isAppActive: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
        /// Фоновое время на операцию: пауза из островка, склейка, прощание активности.
        /// Без него iOS усыпит Lori на полуслове, как только микрофон отпущен.
        var backgroundTime: @MainActor (String) -> (@MainActor () -> Void) = RecordingController.beginBackgroundTime
        var notifications: NotificationCenter = .default
        var now: @MainActor () -> Date = { Date() }
        var log: (String) -> Void = { Journal.append($0) }
        /// Сколько висит «Отправлено на расшифровку», прежде чем активность уйдёт.
        var farewell: Duration = .milliseconds(2500)
        /// Через сколько активность идущей записи считается устаревшей, если Lori её не обновит.
        var staleAfter: TimeInterval = 15 * 60
        /// Как часто идущая запись подтверждает активность.
        var refreshEvery: Duration = .seconds(5 * 60)
        /// Ссылка «Расшифровать» для движка на телефоне.
        var finishURL: URL = RecordingController.finishURL
        /// Сколько ждать уведомления о прерывании после сбоя рекордера.
        var failureGrace: Duration = .milliseconds(300)

        init(inCall: @escaping @MainActor () -> Bool) {
            self.inCall = inCall
        }
    }

    private let workspace: WorkspaceStore
    private let transcription: TranscriptionService
    private let device: any RecordingDevice
    private let store: RecordingSessionStore
    private let presenter: any RecordingActivityPresenting
    private let hooks: Hooks

    private var session: RecordingSession?
    /// Идёт операция, которую нельзя пересекать: старт, склейка, удаление.
    private var busy = false
    private var appIsActive = false
    private var meterTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// Обновления активности идут цепочкой: каждое ждёт предыдущее и шлёт
    /// состояние на момент исполнения — порядок не путается.
    private var activityTask: Task<Void, Never>?
    private let observers: ObserverBag

    init(
        workspace: WorkspaceStore,
        transcription: TranscriptionService,
        device: any RecordingDevice,
        store: RecordingSessionStore = RecordingSessionStore(),
        presenter: (any RecordingActivityPresenting)? = nil,
        hooks: Hooks? = nil
    ) {
        let detector = CallDetector()
        let hooks = hooks ?? Hooks(inCall: { detector.isInCall })
        self.workspace = workspace
        self.transcription = transcription
        self.device = device
        self.store = store
        self.presenter = presenter ?? LiveRecordingActivity(finishURL: hooks.finishURL)
        self.hooks = hooks
        observers = ObserverBag(center: hooks.notifications)
        appIsActive = hooks.isAppActive()
        device.onFailure = { [weak self] in self?.deviceFailed() }
        observeSystem()
    }

    // MARK: - Ссылка из островка

    /// `ru.ilyaqa.lori.local://recording/finish` — у Lori QA схема своя.
    nonisolated static var finishURL: URL {
        let scheme = Bundle.main.bundleIdentifier ?? "ru.ilyaqa.lori.local"
        return URL(string: "\(scheme)://recording/finish")!
    }

    nonisolated static func isFinishLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == finishURL.scheme?.lowercased()
            && url.host() == "recording" && url.path() == "/finish"
    }

    /// Ссылка «Расшифровать» из островка (движок на телефоне): Lori уже открыта, и
    /// заявку на фоновую расшифровку iOS примет. Чужая ссылка — `false`.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard Self.isFinishLink(url) else { return false }
        Task { await finish() }
        return true
    }

    // MARK: - Старт

    /// Начинает запись. Только по нажатию в приложении на переднем плане: там же
    /// заводится Live Activity (из фона ActivityKit её начать не даст).
    func start() async throws {
        guard phase == .idle, !busy else { return }
        busy = true
        defer { busy = false }
        guard await device.requestPermission() else { throw AudioCaptureError.microphoneDenied }
        try device.activate()

        // Папка сессии без файла сессии — остатки, которым неоткуда взяться, кроме
        // сбоя на полпути. Новая запись начинается с чистого места.
        store.clear()
        var session = RecordingSession(startedAt: hooks.now())
        do {
            try beginChunk(&session)
        } catch {
            device.deactivate()
            store.clear()
            throw error
        }
        self.session = session
        isRestored = false
        pauseWords = nil
        lastError = nil
        phase = .recording
        elapsed = 0
        levels = []
        startMetering()
        startRefreshing()
        // Хвост прошлой записи («Отправлено…») и висящие активности — прочь: у новой
        // записи активность своя.
        await presenter.endAll()
        pushActivity()
        hooks.log("запись: начата")
    }

    // MARK: - Пауза и продолжение

    /// Ставит паузу: текущий кусок закрывается файлом сразу. Возвращает, была ли пауза.
    @discardableResult
    func pause(_ reason: RecordingPauseReason = .user) -> Bool {
        guard phase == .recording, var session else { return false }
        closeChunk(&session)
        session.state = .paused
        session.reason = reason
        session.interruptionEnded = false
        persist(session)
        device.deactivate()
        phase = .paused
        pauseWords = session.reasonWords
        elapsed = session.recorded
        stopMetering(resetWave: false)
        stopRefreshing()
        pushActivity()
        hooks.log("запись: пауза (\(reason.rawValue)), записано \(Int(session.recorded)) с")
        return true
    }

    /// Новый кусок. Не вышло (микрофон занят звонком) — запись остаётся на паузе
    /// с причиной «микрофон занят», а не теряется.
    @discardableResult
    func resume() -> Bool {
        guard phase == .paused, var session, !busy else { return false }
        do {
            try device.activate()
            try beginChunk(&session)
        } catch {
            device.deactivate()
            // `beginChunk` уже успел записать «идёт запись» — возвращаем паузу.
            session.state = .paused
            session.active = nil
            session.reason = .microphoneBusy
            session.interruptionEnded = false
            persist(session)
            pauseWords = session.reasonWords
            pushActivity()
            hooks.log("запись: продолжить не вышло — \(error.localizedDescription)")
            return false
        }
        // Поднятая после перезапуска запись снова обычная: «Удалить» в островке — только
        // пока её никто не трогал.
        session.restored = false
        persist(session)
        self.session = session
        isRestored = false
        pauseWords = nil
        phase = .recording
        startMetering()
        startRefreshing()
        pushActivity()
        hooks.log("запись: продолжена, кусок \(session.chunks.count + 1)")
        return true
    }

    // MARK: - Конец

    /// «Расшифровать» (или «Сохранить»): закрыть кусок, склеить куски в
    /// `Recordings/Recording-<начало>.m4a`, убрать служебное и — если включено
    /// «Расшифровывать запись сразу» — поставить запись в очередь. Логика, которая
    /// раньше жила в `ContentView.stopRecording`.
    ///
    /// Не вышло склеить — куски остаются на месте, запись на паузе, и попробовать
    /// можно ещё раз: звук не теряется ни при каком исходе.
    @discardableResult
    func finish() async -> String? {
        guard var session, phase == .recording || phase == .paused, !busy else { return nil }
        busy = true
        defer { busy = false }
        let release = hooks.backgroundTime("Lori: сохраняю запись")
        defer { release() }

        if phase == .recording {
            closeChunk(&session)
            device.deactivate()
        }
        session.state = .paused
        persist(session)
        self.session = session
        phase = .finishing
        stopMetering(resetWave: false)
        stopRefreshing()

        let chunks = session.chunks.map { store.url(for: $0.file) }
        do {
            let destination = try workspace.makeRecordingURL(startedAt: session.startedAt)
            let outcome = try await RecordingAssembler.assemble(chunks, into: destination, workDirectory: store.directory)
            store.clear()
            self.session = nil
            resetToIdle()
            let path = "Recordings/\(destination.lastPathComponent)"
            workspace.requestRefresh()
            var queued = false
            if hooks.autoTranscribe(), let entry = try? workspace.entry(at: path) {
                queued = transcription.enqueue(entry, in: workspace)
            }
            hooks.log(
                "запись: сохранена \(path), \(Int(outcome.duration)) с, кусков \(chunks.count)"
                    + (outcome.skipped > 0 ? ", не прочиталось \(outcome.skipped)" : "")
                    + (outcome.reencoded ? ", с перекодированием" : "")
                    + (queued ? ", в очереди" : "")
            )
            sayFarewell(queued ? "Отправлено на расшифровку" : "Сохранено в Lori")
            return path
        } catch RecordingAssembler.Failure.nothingToSave {
            trash(session)
            store.clear()
            self.session = nil
            resetToIdle()
            lastError = RecordingAssembler.Failure.nothingToSave.errorDescription
            hooks.log("запись: звука нет, куски в корзине")
            await presenter.end(token: nil, final: nil)
            return nil
        } catch {
            phase = .paused
            pauseWords = session.reasonWords
            elapsed = session.recorded
            lastError = error.localizedDescription
            pushActivity()
            hooks.log("запись: склеить не вышло — \(error.localizedDescription)")
            return nil
        }
    }

    /// «Отмена» в панели и «Удалить» у поднятой записи: куски — в корзину Lori.
    /// Удаление в Lori всегда обратимо.
    func discard() async {
        guard var session, phase == .recording || phase == .paused, !busy else { return }
        busy = true
        defer { busy = false }
        let release = hooks.backgroundTime("Lori: удаляю запись")
        defer { release() }
        if phase == .recording {
            closeChunk(&session)
            device.deactivate()
        }
        trash(session)
        store.clear()
        self.session = nil
        resetToIdle()
        hooks.log("запись: удалена в корзину")
        await presenter.end(token: nil, final: nil)
    }

    // MARK: - Восстановление

    /// Поднимает незаконченную запись с диска — синхронно, ещё в `App.init`: интент из
    /// островка, ради которого Lori могли запустить, должен застать её уже на месте.
    ///
    /// Кусок, который писался, когда процесс умер, без оглавления не читается: такой
    /// уходит в корзину (а не в никуда), и об этом говорится словами. Запись, которая
    /// шла, встаёт на паузу с причиной «приложение перезапускалось»; стоявшая на паузе
    /// (звонок, человек) — сохраняет свою причину: для человека ничего не поменялось.
    func restoreSession() {
        store.removeLeftovers()
        guard var session = store.load() else { return }
        let wasRecording = session.state == .recording
        if let active = session.active {
            let url = store.url(for: active)
            if let duration = RecordingAudio.duration(of: url), duration > 0.05 {
                session.chunks.append(RecordingSession.Chunk(file: active, duration: duration))
            } else if Self.hasBytes(url) {
                trash(url, as: "\(Self.baseName(session))-оборвано.m4a")
                session.lostChunks += 1
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            session.active = nil
        }
        if wasRecording { session.reason = .relaunch }
        session.state = .paused
        session.interruptionEnded = false

        guard !session.chunks.isEmpty else {
            // Сохранять нечего: запись умерла на первых долях секунды.
            store.clear()
            if session.lostChunks > 0 {
                lastError = "Запись оборвалась вместе с Lori, и её кусок не дописался. Он отложен в корзину Lori."
            }
            hooks.log("запись: после перезапуска сохранять нечего, потеряно кусков \(session.lostChunks)")
            return
        }
        session.restored = true
        persist(session)
        self.session = session
        phase = .paused
        isRestored = true
        pauseWords = session.reasonWords
        elapsed = session.recorded
        if session.lostChunks > 0 {
            lastError = "Lori закрылась посреди записи: последний кусок не дописался и отложен в корзину. Остальное на месте."
        }
        hooks.log("запись: поднята после перезапуска, кусков \(session.chunks.count), записано \(Int(session.recorded)) с, потеряно \(session.lostChunks)")
    }

    /// Активность после запуска: подобрать живую или, если записи нет, закончить
    /// висящую от прошлой сессии — островок не должен тикать по записи, которой нет.
    func reconcileActivity() async {
        guard session != nil else {
            await presenter.endAll()
            return
        }
        _ = await presenter.adopt()
        await pushActivity().value
    }

    // MARK: - Интенты островка

    func pauseFromIntent() async {
        let release = hooks.backgroundTime("Lori: пауза из островка")
        defer { release() }
        await adoptActivityIfNeeded()
        guard pause() else { return await settleOrphanActivity() }
        await activityTask?.value
    }

    func resumeFromIntent() async {
        let release = hooks.backgroundTime("Lori: продолжить из островка")
        defer { release() }
        await adoptActivityIfNeeded()
        guard phase == .paused else { return await settleOrphanActivity() }
        resume()
        await activityTask?.value
    }

    func finishFromIntent() async {
        await adoptActivityIfNeeded()
        guard phase == .recording || phase == .paused else { return await settleOrphanActivity() }
        await finish()
    }

    func discardFromIntent() async {
        await adoptActivityIfNeeded()
        guard phase == .recording || phase == .paused else { return await settleOrphanActivity() }
        await discard()
    }

    /// Lori запустили ради нажатия в островке: `reconcileActivity` из `App.init` мог ещё
    /// не подобрать активность, а без неё обновление ушло бы в никуда — островок показал
    /// бы паузу при идущей записи.
    private func adoptActivityIfNeeded() async {
        guard session != nil, !presenter.isRunning else { return }
        _ = await presenter.adopt()
    }

    /// Кнопку нажали в активности, у которой записи уже нет (она закончена в
    /// приложении, а островок не успел уйти) — убрать активность.
    private func settleOrphanActivity() async {
        if session == nil { await presenter.endAll() } else { await pushActivity().value }
    }

    // MARK: - Система

    func handle(_ event: RecordingAudioEvent) {
        switch event {
        case let .interrupted(reason):
            guard phase == .recording else { return }
            // Микрофон отпущен — iOS вот-вот усыпит Lori в фоне. Время нужно, чтобы
            // островок успел узнать о паузе.
            let release = hooks.backgroundTime("Lori: пауза от системы")
            pause(reason)
            let task = activityTask
            Task { @MainActor in
                await task?.value
                release()
            }
        case .interruptionEnded:
            guard phase == .paused, var session, !session.interruptionEnded,
                  session.reason == .call || session.reason == .otherApp else { return }
            // Рекомендацию продолжить не исполняем — решение владельца: «ждать
            // „Продолжить“». Меняются только слова: «Пауза · звонок закончился».
            session.interruptionEnded = true
            persist(session)
            self.session = session
            pauseWords = session.reasonWords
            pushActivity()
        case .ignore:
            break
        }
    }

    /// Рекордер встал сам. Пауза — с задержкой в долю секунды: если это звонок,
    /// уведомление о прерывании придёт следом и назовёт причину верно, а «сбой звука»
    /// на месте «звонка» сбивал бы с толку. Звук за эти доли секунды не теряется —
    /// рекордер уже стоит.
    private func deviceFailed() {
        let delay = hooks.failureGrace
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.phase == .recording else { return }
            self.handle(.interrupted(self.hooks.inCall() ? .call : .audioFailure))
        }
    }

    private func observeSystem() {
        let observers = observers
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (Notification) -> Void) {
            observers.add(name) { note in
                // `queue: .main` — блок идёт синхронно на главном потоке, и уведомление
                // из него никуда не уезжает; Swift 6 этого из типов не видит.
                nonisolated(unsafe) let note = note
                MainActor.assumeIsolated { action(note) }
            }
        }

        if #available(iOS 27.0, *) {
            observe(AVAudioSession.didBecomeInactiveNotification) { [weak self] note in
                guard let self else { return }
                let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                let event = RecordingInterruptions.deactivation(
                    bySystem: context?.source == .system,
                    interruption: context?.interruptionContext?.reason,
                    hasInterruptionContext: context?.interruptionContext != nil,
                    inCall: hooks.inCall()
                )
                handle(event)
            }
            observe(AVAudioSession.resumptionRecommendationNotification) { [weak self] _ in
                self?.handle(.interruptionEnded)
            }
        } else {
            observe(AVAudioSession.interruptionNotification) { [weak self] note in
                guard let self else { return }
                handle(RecordingInterruptions.legacy(note.userInfo, inCall: hooks.inCall()))
            }
        }
        observe(AVAudioSession.routeChangeNotification) { [weak self] note in
            guard let self, phase == .recording else { return }
            handle(RecordingInterruptions.routeChange(
                note.userInfo,
                previousInputs: RecordingInterruptions.previousInputs(note.userInfo),
                currentInputs: device.currentInputs()
            ))
        }
        observe(AVAudioSession.mediaServicesWereLostNotification) { [weak self] _ in
            self?.handle(.interrupted(.audioFailure))
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            self?.handle(.interrupted(.audioFailure))
        }

        // Lori закрывают, пока пишет: кусок закрывается файлом, запись встаёт на паузу.
        // На следующем запуске она поднимется целиком.
        observe(UIApplication.willTerminateNotification) { [weak self] _ in
            self?.applicationWillTerminate()
        }
        observe(UIApplication.didBecomeActiveNotification) { [weak self] _ in
            self?.applicationDidBecomeActive()
        }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] _ in
            self?.applicationDidEnterBackground()
        }
    }

    func applicationWillTerminate() {
        guard phase == .recording, var session else { return }
        closeChunk(&session)
        session.state = .paused
        session.reason = .relaunch
        persist(session)
        device.deactivate()
        self.session = session
        phase = .paused
        pauseWords = session.reasonWords
        stopMetering(resetWave: false)
        stopRefreshing()
        pushActivity()
        hooks.log("запись: Lori закрывается — кусок закрыт, запись на паузе")
    }

    func applicationDidBecomeActive() {
        appIsActive = true
        if phase == .recording { startMetering() }
        // Активности могло не быть: запись поднята в фоне, человек смахнул её с экрана
        // блокировки, Live Activity включили только что. Завести можно только сейчас.
        if session != nil { pushActivity() }
    }

    func applicationDidEnterBackground() {
        appIsActive = false
        // Волну в фоне никто не видит, а 8 раз в секунду на часовой записи — это батарея.
        meterTask?.cancel()
        meterTask = nil
        // Пока Lori была на виду, могли сменить движок или «Расшифровывать сразу» —
        // кнопка «Расшифровать» в островке должна знать об этом до того, как её нажмут.
        if session != nil { pushActivity() }
    }

    // MARK: - Куски

    private func beginChunk(_ session: inout RecordingSession) throws {
        let name = session.nextChunkName
        session.active = name
        session.state = .recording
        session.reason = nil
        session.interruptionEnded = false
        // След — до начала записи: убитый процесс оставит файл сессии, где видно,
        // какой кусок был открыт.
        try store.save(session)
        do {
            try device.begin(at: store.url(for: name))
        } catch {
            session.active = nil
            try? FileManager.default.removeItem(at: store.url(for: name))
            throw error
        }
    }

    /// Закрывает идущий кусок и вписывает его длительность по самому файлу.
    private func closeChunk(_ session: inout RecordingSession) {
        device.end()
        guard let name = session.active else { return }
        session.active = nil
        let url = store.url(for: name)
        if let duration = RecordingAudio.duration(of: url), duration > 0.05 {
            session.chunks.append(RecordingSession.Chunk(file: name, duration: duration))
        } else if RecordingAudio.duration(of: url) == nil, Self.hasBytes(url) {
            // Звук есть, а файл не закрылся (упал звуковой сервер) — в корзину, не в никуда.
            trash(url, as: "\(Self.baseName(session))-оборвано.m4a")
            session.lostChunks += 1
        } else {
            // Пауза на первой же доле секунды: в куске нет звука.
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func persist(_ session: RecordingSession) {
        self.session = session
        do {
            try store.save(session)
        } catch {
            hooks.log("запись: не сохранилось состояние — \(error.localizedDescription)")
        }
    }

    private func trash(_ session: RecordingSession) {
        let base = Self.baseName(session)
        let files = session.chunks.map(\.file) + [session.active].compactMap { $0 }
        for (index, file) in files.enumerated() {
            let name = files.count == 1 ? "\(base).m4a" : "\(base)-часть-\(index + 1).m4a"
            trash(store.url(for: file), as: name)
        }
    }

    private func trash(_ url: URL, as name: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try workspace.moveToTrash(external: url, named: name)
        } catch {
            hooks.log("запись: в корзину не переехало \(url.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    private static func baseName(_ session: RecordingSession) -> String {
        let stamp = ISO8601DateFormatter().string(from: session.startedAt).replacingOccurrences(of: ":", with: "-")
        return "Recording-\(stamp)"
    }

    private static func hasBytes(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0
    }

    private func resetToIdle() {
        phase = .idle
        elapsed = 0
        level = 0
        levels = []
        pauseWords = nil
        isRestored = false
        activityHint = nil
        stopMetering()
        stopRefreshing()
    }

    // MARK: - Live Activity

    /// Состояние островка на этот момент.
    func activityState() -> RecordingActivityAttributes.ContentState? {
        guard let session else { return nil }
        let recorded = session.recorded + (phase == .recording ? device.currentTime : 0)
        let auto = hooks.autoTranscribe()
        return RecordingActivityAttributes.ContentState(
            phase: phase == .recording ? .recording : .paused,
            timerStart: hooks.now().addingTimeInterval(-recorded),
            recorded: recorded,
            reason: phase == .recording ? nil : session.reasonWords,
            finishOpensApp: auto && !hooks.engine().leavesDevice,
            finishTitle: auto ? "Расшифровать" : "Сохранить",
            canDiscard: session.restored,
            note: nil
        )
    }

    /// Ставит обновление активности в цепочку и отдаёт его задачу — интенту есть чего
    /// дождаться, прежде чем вернуть управление системе.
    @discardableResult
    private func pushActivity() -> Task<Void, Never> {
        let previous = activityTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.applyActivity()
        }
        activityTask = task
        return task
    }

    private func applyActivity() async {
        guard let state = activityState() else { return }
        let stale = state.phase == .recording ? hooks.now().addingTimeInterval(hooks.staleAfter) : nil
        if presenter.isRunning {
            await presenter.update(state, staleDate: stale)
        } else if appIsActive || hooks.isAppActive(), presenter.areEnabled {
            do {
                try presenter.start(state, staleDate: stale)
            } catch {
                hooks.log("запись: Live Activity не началась — \(error.localizedDescription)")
            }
        }
        activityHint = presenter.areEnabled ? nil : Self.activitiesOffHint
    }

    /// «Отправлено на расшифровку» — пару секунд, потом активность уходит. Задача
    /// отдельная: новая запись не должна ждать прощания старой.
    private func sayFarewell(_ note: String) {
        let token = presenter.token
        let release = hooks.backgroundTime("Lori: островок прощается")
        let farewell = hooks.farewell
        let final = RecordingActivityAttributes.ContentState(
            phase: .finished,
            timerStart: hooks.now(),
            recorded: 0,
            reason: nil,
            finishOpensApp: false,
            finishTitle: "",
            canDiscard: false,
            note: note
        )
        let previous = activityTask
        let presenter = presenter
        // В цепочку встаёт только показ прощания, а не пауза перед уходом: новая
        // запись, начатая в эти секунды, не должна ждать, пока старая попрощается.
        let farewellShown = Task { @MainActor in
            await previous?.value
            if token != nil, presenter.token == token {
                await presenter.update(final, staleDate: nil)
            }
        }
        activityTask = farewellShown
        Task { @MainActor in
            await farewellShown.value
            try? await Task.sleep(for: farewell)
            await presenter.end(token: token, final: final)
            release()
        }
    }

    // MARK: - Замеры

    private func startMetering() {
        meterTask?.cancel()
        guard appIsActive || hooks.isAppActive() else { return }
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .recording else { return }
                self.elapsed = (self.session?.recorded ?? 0) + self.device.currentTime
                let value = self.device.level() ?? 0
                self.level = value
                self.levels.append(value)
                if self.levels.count > Self.waveSamples {
                    self.levels.removeFirst(self.levels.count - Self.waveSamples)
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func stopMetering(resetWave: Bool = true) {
        meterTask?.cancel()
        meterTask = nil
        level = 0
        // На паузе волна замирает на последнем виде, а не обнуляется: иначе пауза
        // визуально неотличима от остановленной записи.
        if resetWave {
            levels = []
        }
    }

    /// Идущая запись раз в несколько минут подтверждает активность и отодвигает её
    /// срок годности. Умри процесс — активность станет устаревшей и скажет «Lori не
    /// отвечает», а не будет тикать по записи, которая уже не идёт.
    private func startRefreshing() {
        refreshTask?.cancel()
        let period = hooks.refreshEvery
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: period)
                guard !Task.isCancelled, let self, self.phase == .recording else { return }
                self.pushActivity()
            }
        }
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Фоновое время

    /// Обычное окно UIKit: пока оно открыто, iOS не усыпит Lori посреди склейки.
    static func beginBackgroundTime(_ name: String) -> (@MainActor () -> Void) {
        let box = BackgroundTimeBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: name) { [box] in
            MainActor.assumeIsolated { box.finish() }
        }
        return { box.finish() }
    }
}

/// Подписки на уведомления — в своём объекте: `deinit` класса на главном акторе не
/// может трогать его поля, а снять подписки при уничтожении надо (так же устроен
/// `TranscriptionRunway`).
private final class ObserverBag: @unchecked Sendable {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    func add(_ name: Notification.Name, _ block: @escaping @Sendable (Notification) -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: .main, using: block))
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }
}

/// Идентификатор фонового окна в коробке: обработчик истечения и обычное завершение
/// закрывают одно окно ровно один раз.
@MainActor
private final class BackgroundTimeBox {
    var id: UIBackgroundTaskIdentifier = .invalid

    func finish() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
