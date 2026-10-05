import Combine
import Foundation
import UIKit

/// Запуск модели заголовков после расшифровки.
///
/// Работает по одной записи за раз, только когда памяти заведомо хватает и
/// только пока приложение на переднем плане. Память: у приложения на iPhone
/// предел около трёх гигабайт, и модель на 2,3 из них нельзя запускать «на
/// авось» — система убивает процесс без предупреждения. Передний план — см.
/// `drain`: в фоне тот же запуск гасит процесс изнутри MLX (крэш 2 сентября,
/// `ios/CLAUDE.md`).
@MainActor
final class SummaryRunner: ObservableObject {
    @Published private(set) var running: String?
    /// Последняя ошибка заголовка. Общая на все записи — поэтому рядом
    /// `failurePath`: экран записи показывает только свою, а не чужую.
    @Published var failure: String? {
        didSet { if failure == nil { failurePath = nil } }
    }
    /// Чья это ошибка: путь записи или nil — ошибка не про запись (очередь не
    /// сохранилась). Ставится раньше `failure`, чтобы тот, кто следит за
    /// `failure`, уже видел, чья она.
    @Published private(set) var failurePath: String?
    @Published private(set) var waitingReason: String?
    @Published private(set) var pendingCount = 0
    /// Записи с расшифровкой, которым ещё нужен заголовок, но в очередь они не
    /// встали: автоматически за раз берётся не больше `backlogLimit`.
    @Published private(set) var backlogCount = 0

    /// Короче этого текст заголовком не украшают.
    static let minimumCharacters = 80
    /// Сколько записей без заголовка автомат держит в очереди. Модель на каждую
    /// тратит десятки секунд графического процессора; архив в сотню записей
    /// после скачивания весов — это час работы и горячий телефон. Поэтому за раз
    /// берутся самые новые, остальные — при следующих возвращениях в Lori или по
    /// кнопке в настройках (`summarizeBacklog`).
    static let backlogLimit = 10
    /// Сколько раз подряд автомат берётся за запись, с которой модель не
    /// справляется при том же тексте. Каждая попытка — загрузка весов и сотни
    /// токенов на графическом процессоре; раньше безнадёжная запись повторялась
    /// на каждом возвращении в приложение и после каждой расшифровки. Новый
    /// текст начинает счёт заново, «Придумать заголовок» работает всегда.
    static let automaticAttempts = 3

    private let models: SummaryModelStore
    private let store: SummaryStore
    private let availableMemory: @Sendable () -> UInt64
    private let isForeground: @MainActor () -> Bool
    private let summarize: @Sendable (SummaryVariant, URL, String) async throws -> Summarizer.Summary

    /// Заявка в очереди. На диске — только путь и признак явной просьбы: раньше
    /// туда же ложился весь текст расшифровки, и без скачанных весов файл очереди
    /// копил полные тексты всех записей бессрочно. Текст перечитывается из файла
    /// расшифровки, когда до записи дошла очередь, — и это заодно самый свежий текст.
    private struct Postponed: Codable, Equatable {
        let path: String
        var force: Bool
    }

    /// Что модель получит и по чему узнаётся тот же текст.
    private struct Source: Sendable {
        /// Начало и конец (`Summarizer.excerpt`) — больше модели не нужно.
        let excerpt: String
        /// Отпечаток всего текста, а не отрывка: правка в середине — тоже новый текст.
        let fingerprint: String
        let characters: Int

        init(text: String) {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            excerpt = Summarizer.excerpt(from: clean)
            fingerprint = SummaryStore.fingerprint(of: clean)
            characters = clean.count
        }
    }

    private enum Outcome {
        case done
        /// Делать нечего: расшифровки нет, текст короткий, запись удалили.
        case dropped
        /// Ушли в фон или освобождали память под расшифровку — повторим.
        case cancelled
        /// Модель не справилась; отпечаток — того текста, с которым не справилась.
        case failed(String, fingerprint: String?)
    }

    /// Неудачи подряд по записи при одном тексте — на диске, иначе каждый
    /// перезапуск приложения давал бы безнадёжной записи новые попытки.
    private struct Misses: Codable, Equatable {
        var fingerprint: String?
        var count: Int
    }
    private var misses: [String: Misses] = [:]
    private let missesURL: URL

    private var postponed: [Postponed] = []
    /// Текст, пришедший вместе с заявкой в этом запуске, — только в памяти.
    private var sources: [String: Source] = [:]
    /// Номер последней заявки по записи. Ответ модели на текст, который успели
    /// переписать, пока она считала, не снимает пометку «устарело».
    private var revisions: [String: Int] = [:]
    // Ошибка одной записи не останавливает остальные. Неудачные заявки
    // остаются на диске и повторяются при следующем возвращении в приложение.
    private var failedThisPass: Set<String> = []
    /// Записи с коротким текстом: перечитывать их на каждом возвращении незачем.
    private var tooShort: Set<String> = []
    private var task: Task<Void, Never>?
    private var memoryRetry: Task<Void, Never>?
    private var transcriptionPauses = 0
    private let queueURL: URL
    private var modelSubscription: AnyCancellable?
    private weak var workspace: WorkspaceStore?
    private weak var transcription: TranscriptionService?
    /// Последняя строка журнала о причине простоя: одну и ту же не повторяем.
    private var lastNote: String?

    init(
        models: SummaryModelStore,
        store: SummaryStore,
        availableMemory: @escaping @Sendable () -> UInt64 = { MemoryReport.availableBytes },
        isForeground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
        summarize: (@Sendable (SummaryVariant, URL, String) async throws -> Summarizer.Summary)? = nil
    ) {
        self.models = models
        self.store = store
        self.availableMemory = availableMemory
        self.isForeground = isForeground
        self.summarize = summarize ?? { variant, directory, text in
            await EngineSessionCache.shared.dropIdle()
            return try await Summarizer(variant: variant, directory: directory).summary(of: text)
        }
        self.queueURL = store.pendingQueueURL
        self.missesURL = store.failuresURL
        if let data = try? Data(contentsOf: missesURL),
           let saved = try? JSONDecoder().decode([String: Misses].self, from: data) { misses = saved }
        // Очередь прежних сборок хранила ещё и текст — он просто не читается.
        if let data = try? Data(contentsOf: queueURL),
           let saved = try? JSONDecoder().decode([Postponed].self, from: data) { postponed = saved }
        pendingCount = postponed.count
        // Веса скачали или удалили. После скачивания заголовки записям, которым
        // их не хватает, придумываются сами — новые первыми.
        modelSubscription = models.$installed.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                self?.failedThisPass.removeAll()
                self?.recoverMissingSummaries()
                self?.drain()
            }
        }
    }

    /// Почему модель не запускается. Раньше обе причины — «нет весов» и «мало
    /// памяти» — давали одно и то же сообщение про скачивание, и оно врало.
    enum Obstacle: Equatable {
        case noWeights
        case notEnoughMemory

        var message: String {
            switch self {
            case .noWeights: "Модель заголовков ещё не скачана. Настройки → Заголовки → «Скачать»."
            case .notEnoughMemory: "Сейчас мало свободной памяти для модели заголовков. Закрой пару приложений и попробуй снова."
            }
        }
    }

    /// Ответ на «Придумать заголовок».
    enum TitleRequest: Equatable {
        /// Заявка принята; заголовок появится, когда модель ответит.
        case queued
        /// Модели нет. Заявка ждёт её: после скачивания заголовок придумается сам,
        /// поэтому на месте достаточно предложить скачать
        /// (`SummaryModelStore.recommendedVariant`).
        case needsModel
        /// Модель есть, но памяти сейчас мало; повтор будет сам.
        case waitingForMemory(String)
        /// В записи слишком мало текста для заголовка.
        case tooShort
        /// Просьбу не удалось сохранить.
        case failed(String)
    }

    /// Какой моделью считать. Крупная лучше, но если памяти под неё нет —
    /// берём лёгкую, а не падаем.
    func choose() -> SummaryVariant? {
        let installed = SummaryVariant.allCases.filter(models.isInstalled)
        guard !installed.isEmpty else { return nil }
        let free = availableMemory()
        // Ноль означает «неизвестно» (так отвечает симулятор), а не «памяти нет»:
        // на этом проверка однажды уже отказала при скачанных весах.
        guard free > 0 else { return installed.first }
        return installed.first { free >= UInt64($0.requiredFreeBytes) }
    }

    func obstacle() -> Obstacle? {
        guard choose() == nil else { return nil }
        return hasWeights ? .notEnoughMemory : .noWeights
    }

    private var hasWeights: Bool { SummaryVariant.allCases.contains(where: models.isInstalled) }

    /// Источник событий — сервис и сохранённые файлы, а не onChange во View.
    func connect(to workspace: WorkspaceStore, transcription: TranscriptionService? = nil) {
        self.workspace = workspace
        self.transcription = transcription
    }

    /// Стоит ли запись в очереди (в том числе та, что считается сейчас).
    func isQueued(_ path: String) -> Bool {
        postponed.contains { $0.path == path }
    }

    // MARK: - Заявки

    /// Расшифровка есть: заголовок нужен, если ответа модели ещё нет, у записи
    /// только имя файла или ручное имя без описания — или модель писала по
    /// другому тексту. Повторный вызов с тем же текстом ничего не делает.
    func summarize(path: String, text: String, force: Bool = false) {
        store.retryLoadIfNeeded()
        let source = Source(text: text)
        guard source.characters > Self.minimumCharacters else {
            note("заголовок: текст короче \(Self.minimumCharacters) знаков — «\(Self.name(of: path))»")
            dropStaleAnswer(for: path)
            return
        }
        // Новый текст — у модели новый шанс: счёт неудач был про прежний.
        if let miss = misses[path], miss.fingerprint != source.fingerprint {
            misses[path] = nil
            persistMisses()
        }
        if !force {
            guard !gaveUp(on: path) else {
                note("заголовок: «\(Self.name(of: path))» — модель уже \(Self.automaticAttempts) раза не справилась с этим текстом, автоматически не пробую")
                return
            }
            guard !store.isUpToDate(path, fingerprint: source.fingerprint) else { return }
            // Модель писала по другому тексту: прежний ответ виден, пока не придёт новый.
            store.markStale(path)
            guard store.needsSummary(for: path) else { return }
        }
        enqueue(path, force: force, source: source)
    }

    /// Расшифровку записи сохранили — движок закончил работу или человек
    /// поправил текст. Звать с путём аудиозаписи. Текст можно не передавать:
    /// тогда он прочитается из файла вне главного потока.
    func transcriptSaved(path: String, text: String? = nil) {
        tooShort.remove(path)
        failedThisPass.remove(path)
        if let text {
            summarize(path: path, text: text)
            return
        }
        guard let url = transcriptURL(for: path) else { return }
        Task { [weak self] in
            guard let text = await Self.readPlainText(at: url) else { return }
            self?.summarize(path: path, text: text)
        }
    }

    /// «Придумать заголовок»: явная просьба человека. Ручное имя модель заменит,
    /// но только когда ответит (`SummaryStore.allowGeneratedTitle`). Без модели
    /// заявка ждёт её, а экран предлагает скачать на месте.
    func requestTitle(for path: String, text: String? = nil) -> TitleRequest {
        store.retryLoadIfNeeded()
        failure = nil
        let source = text.map(Source.init(text:))
        if let source, source.characters <= Self.minimumCharacters {
            // Ответ «заголовком служит первая фраза» обязан стать правдой.
            dropStaleAnswer(for: path)
            return .tooShort
        }
        guard store.allowGeneratedTitle(for: path) else {
            return .failed("Не удалось сохранить настройку заголовка. Попробуй ещё раз.")
        }
        tooShort.remove(path)
        enqueue(path, force: true, source: source)
        switch obstacle() {
        case .noWeights: return .needsModel
        case .notEnoughMemory: return .waitingForMemory(Obstacle.notEnoughMemory.message)
        case nil: return .queued
        }
    }

    /// Придумать заголовки всем записям, которым их не хватает, — по кнопке в
    /// настройках, без предела автомата: человек попросил сам.
    func summarizeBacklog() {
        guard let workspace, !store.isUnreadable else { return }
        for entry in workspace.audio where lacksSummary(entry, in: workspace) {
            postponed.append(Postponed(path: entry.relativePath, force: false))
            revisions[entry.relativePath, default: 0] += 1
        }
        backlogCount = 0
        persist()
        drain()
    }

    /// Пересчитать, скольким записям не хватает заголовка, — для экрана
    /// настроек. В очередь ничего не ставит и файлов не читает.
    func refreshBacklog() {
        guard let workspace, hasWeights, !store.isUnreadable else {
            backlogCount = 0
            return
        }
        backlogCount = workspace.audio.filter { lacksSummary($0, in: workspace) }.count
    }

    /// Запись переименовали: заявка едет за ней.
    func move(from old: String, to new: String) {
        guard old != new else { return }
        for index in postponed.indices where postponed[index].path == old {
            postponed[index] = Postponed(path: new, force: postponed[index].force)
        }
        if let source = sources.removeValue(forKey: old) { sources[new] = source }
        if tooShort.remove(old) != nil { tooShort.insert(new) }
        failedThisPass.remove(old)
        if let miss = misses.removeValue(forKey: old) {
            misses[new] = miss
            persistMisses()
        }
        revisions[new, default: 0] += 1
        persist()
    }

    /// Запись удалили: её заявка больше не нужна.
    func forget(_ path: String) {
        postponed.removeAll { $0.path == path }
        sources[path] = nil
        tooShort.remove(path)
        failedThisPass.remove(path)
        if misses.removeValue(forKey: path) != nil { persistMisses() }
        revisions[path, default: 0] += 1
        persist()
    }

    private func enqueue(_ path: String, force: Bool, source: Source?) {
        // Без весов автоматическая заявка не копится: после скачивания такие
        // записи найдёт `recoverMissingSummaries`. Явную просьбу человека держим.
        guard force || hasWeights else {
            note("заголовки: модели нет — у «\(Self.name(of: path))» пока заголовок из первой фразы")
            return
        }
        failedThisPass.remove(path)
        let wasForced = postponed.contains { $0.path == path && $0.force }
        postponed.removeAll { $0.path == path }
        let request = Postponed(path: path, force: force || wasForced)
        if request.force {
            // Явная просьба — первой среди автоматических: человек ждёт её на экране.
            postponed.insert(request, at: postponed.firstIndex { !$0.force } ?? postponed.endIndex)
        } else {
            postponed.append(request)
        }
        revisions[path, default: 0] += 1
        if let source { sources[path] = source }
        persist()
        drain()
    }

    // MARK: - Жизненный цикл

    func applicationWillResignActive() {
        task?.cancel()
        memoryRetry?.cancel()
        memoryRetry = nil
    }

    /// Отмена кооперативная: перед загрузкой ASR ждём освобождения весов MLX.
    func prepareForTranscription() async {
        transcriptionPauses += 1
        defer { transcriptionPauses -= 1 }
        applicationWillResignActive()
        await task?.value
    }

    func applicationDidBecomeActive() {
        // Вернулись в приложение — телефон разблокирован, и файл заголовков,
        // не прочитавшийся на запуске, обычно читается уже сейчас.
        store.retryLoadIfNeeded()
        failedThisPass.removeAll()
        recoverMissingSummaries()
        drain()
    }

    /// Записи с расшифровкой, которым нужен ответ модели, — в очередь, новые
    /// первыми и не больше `backlogLimit` автоматических заявок разом.
    ///
    /// Находит и результаты, записанные перед убийством процесса, когда очередь
    /// заголовков ещё не успела сохраниться. Файлы здесь не читаются вовсе —
    /// только снимок рабочей папки и хранилище: раньше на каждом возвращении в
    /// приложение каждая расшифровка разбиралась целиком на главном потоке.
    private func recoverMissingSummaries() {
        guard let workspace else { return }
        // Пока файл заголовков не прочитан, хранилище не знает ручных имён: в
        // очередь встали бы и записи, которые человек назвал сам.
        guard !store.isUnreadable else {
            backlogCount = 0
            return
        }
        guard hasWeights else {
            backlogCount = 0
            return
        }
        var room = Self.backlogLimit - postponed.filter { !$0.force }.count
        var added = 0
        var waiting = 0
        // `audio` уже отсортирован: новые записи сверху.
        for entry in workspace.audio where lacksSummary(entry, in: workspace) {
            guard room > 0 else {
                waiting += 1
                continue
            }
            postponed.append(Postponed(path: entry.relativePath, force: false))
            revisions[entry.relativePath, default: 0] += 1
            room -= 1
            added += 1
        }
        backlogCount = waiting
        guard added > 0 else { return }
        note("заголовки: в очередь \(added) записей без заголовка, ещё ждут \(waiting)")
        persist()
    }

    private func lacksSummary(_ entry: WorkspaceEntry, in workspace: WorkspaceStore) -> Bool {
        let path = entry.relativePath
        return store.needsSummary(for: path)
            && !tooShort.contains(path)
            && !gaveUp(on: path)
            && !postponed.contains(where: { $0.path == path })
            && workspace.existingTranscript(for: entry) != nil
    }

    private func persist() {
        pendingCount = postponed.count
        do {
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(postponed).write(to: queueURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            fail("Не удалось сохранить очередь заголовков: \(error.localizedDescription)", for: nil)
            Diagnostics.fault("заголовки: очередь не сохранилась: \(error.localizedDescription)")
        }
    }

    // MARK: - Очередь

    private func drain() {
        guard transcriptionPauses == 0, running == nil, !postponed.isEmpty else { return }
        // Решать, чьё имя защищено, по пустой памяти нельзя: работа ждёт, пока
        // файл заголовков прочитается (`applicationDidBecomeActive`).
        guard !store.isUnreadable else {
            waitingReason = "Заголовки продолжатся, когда файл заголовков снова прочитается"
            note("заголовки: файл заголовков не читается — жду (в очереди \(postponed.count))", reason: "файл")
            return
        }
        // Графического процессора в фоне нет: команда возвращается с ошибкой, и MLX
        // гасит процесс из своей очереди. Работа не теряется — откладывается.
        guard isForeground() else {
            waitingReason = "Заголовки продолжатся после возвращения в Lori"
            note("заголовки: жду возвращения в Lori — в фоне графический процессор недоступен (в очереди \(postponed.count))", reason: "фон")
            return
        }
        guard transcription?.isIdle != false else {
            waitingReason = "Заголовки ждут завершения расшифровки"
            note("заголовки: жду конца расшифровки (в очереди \(postponed.count))", reason: "расшифровка")
            return
        }
        guard let variant = choose() else {
            let obstacle = obstacle()
            waitingReason = obstacle?.message
            if obstacle == .notEnoughMemory {
                note("заголовки: мало памяти — свободно \(availableMemory() / 1_048_576) МБ, повторяю каждые 5 с", reason: "память")
                if memoryRetry == nil {
                    memoryRetry = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        guard let self else { return }
                        self.memoryRetry = nil
                        self.drain()
                    }
                }
            } else {
                note("заголовки: модели нет — ждут \(postponed.count)", reason: "нет модели")
            }
            return
        }
        postponed.removeAll { !$0.force && (!store.needsSummary(for: $0.path) || gaveUp(on: $0.path)) }
        guard let next = postponed.first(where: { !failedThisPass.contains($0.path) }) else {
            persist()
            waitingReason = postponed.isEmpty ? nil : "Не удалось создать заголовок. Повторю при возвращении в Lori"
            return
        }
        if let workspace, (try? workspace.entry(at: next.path)) == nil {
            postponed.removeAll { $0.path == next.path }
            sources[next.path] = nil
            persist()
            drain()
            return
        }
        running = next.path
        waitingReason = nil
        failure = nil
        let directory = models.directory(of: variant)
        let revision = revisions[next.path] ?? 0
        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.run(next, variant: variant, directory: directory)
            self.finish(next, revision: revision, outcome: outcome)
        }
    }

    private func run(_ request: Postponed, variant: SummaryVariant, directory: URL) async -> Outcome {
        let name = Self.name(of: request.path)
        var source = sources[request.path]
        if source == nil, let url = transcriptURL(for: request.path) {
            source = await Self.readSource(at: url)
        }
        if Task.isCancelled { return .cancelled }
        guard let source else {
            note("заголовок: нет расшифровки — «\(name)»")
            if request.force { fail("У записи нет расшифровки — заголовок придумывать не из чего.", for: request.path) }
            return .dropped
        }
        guard source.characters > Self.minimumCharacters else {
            tooShort.insert(request.path)
            note("заголовок: текст короче \(Self.minimumCharacters) знаков — «\(name)»")
            dropStaleAnswer(for: request.path)
            if request.force { fail("В записи слишком мало текста, чтобы придумать заголовок.", for: request.path) }
            return .dropped
        }
        // Пока читался файл, приложение могло уйти в фон — модель там гасит процесс.
        guard isForeground() else { return .cancelled }
        note("заголовок: беру \(variant.rawValue), текста \(source.characters) знаков — «\(name)»")
        do {
            let summary = try await summarize(variant, directory, source.excerpt)
            try Task.checkCancellation()
            // Запись могли удалить или переименовать, пока модель считала.
            if let workspace, (try? workspace.entry(at: request.path)) == nil { return .dropped }
            guard store.store(
                title: summary.title,
                detail: summary.detail,
                for: request.path,
                force: request.force,
                source: source.fingerprint
            ) else { return .failed("Не удалось сохранить заголовок.", fingerprint: source.fingerprint) }
            return .done
        } catch {
            if Task.isCancelled || error is CancellationError { return .cancelled }
            return .failed(error.localizedDescription, fingerprint: source.fingerprint)
        }
    }

    private func finish(_ request: Postponed, revision: Int, outcome: Outcome) {
        // Пока модель считала, по записи могла прийти новая заявка — с новым
        // текстом. Её не удаляем, а свежий ответ на старый текст помечаем устаревшим.
        // Заявка из файла очереди номера не получала — для неё это ноль, как и в `drain`.
        let superseded = (revisions[request.path] ?? 0) != revision
        switch outcome {
        case .done:
            if superseded {
                store.markStale(request.path)
            } else {
                postponed.removeAll { $0.path == request.path }
                sources[request.path] = nil
            }
            failedThisPass.remove(request.path)
            if misses.removeValue(forKey: request.path) != nil { persistMisses() }
        case .dropped:
            if !superseded {
                postponed.removeAll { $0.path == request.path }
                sources[request.path] = nil
            }
        case .cancelled:
            waitingReason = "Заголовки продолжатся после возвращения в Lori"
        case .failed(let message, let fingerprint):
            failedThisPass.insert(request.path)
            fail(message, for: request.path)
            Diagnostics.fault("заголовок: «\(Self.name(of: request.path))» — \(message)")
            countMiss(request, fingerprint: fingerprint)
        }
        persist()
        running = nil
        task = nil
        // Ошибка остаётся на диске, но не запускает бесконечный цикл запросов.
        if !Task.isCancelled || isForeground() { drain() }
    }

    // MARK: - Вспомогательное

    /// Автомат за эту запись больше не берётся: модель не справилась с её
    /// текстом `automaticAttempts` раз подряд.
    private func gaveUp(on path: String) -> Bool {
        (misses[path]?.count ?? 0) >= Self.automaticAttempts
    }

    /// Ещё одна неудача по записи. Заявка остаётся в очереди и повторяется при
    /// следующем возвращении в приложение, пока неудач при том же тексте меньше
    /// `automaticAttempts`; потом снимается. Явная просьба считается так же —
    /// но новое нажатие «Придумать заголовок» всегда даёт ещё одну попытку
    /// (`requestTitle` предел не проверяет). Снимать заявку на первой же неудаче
    /// нельзя: экран записи показывает ошибку, только пока заявка в очереди.
    private func countMiss(_ request: Postponed, fingerprint: String?) {
        var miss = misses[request.path] ?? Misses(fingerprint: fingerprint, count: 0)
        if miss.fingerprint != fingerprint { miss = Misses(fingerprint: fingerprint, count: 0) }
        miss.count += 1
        misses[request.path] = miss
        persistMisses()
        let name = Self.name(of: request.path)
        if miss.count >= Self.automaticAttempts {
            postponed.removeAll { $0.path == request.path }
            sources[request.path] = nil
            waitingReason = nil
            Diagnostics.note("заголовок: модель \(miss.count) раза подряд не справилась с «\(name)» — автоматически больше не пробую, пока текст не поменяется; «Придумать заголовок» по-прежнему работает")
        } else {
            waitingReason = "Не удалось создать заголовок. Повторю при возвращении в Lori"
        }
    }

    private func persistMisses() {
        do {
            try FileManager.default.createDirectory(at: missesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(misses).write(to: missesURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Diagnostics.fault("заголовки: счёт неудач не сохранился: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String, for path: String?) {
        failurePath = path
        failure = message
    }

    /// Текст записи стал коротким или пустым: прежний ответ модели написан по
    /// другому тексту и врал бы на карточке (`SummaryStore.dropGenerated`).
    private func dropStaleAnswer(for path: String) {
        guard store.dropGenerated(path) else { return }
        note("заголовок: текст «\(Self.name(of: path))» короче \(Self.minimumCharacters) знаков — ответ модели снят, заголовок из первой фразы")
    }

    private func transcriptURL(for path: String) -> URL? {
        try? workspace?.fileURL(for: RecordTitle.transcriptPath(forAudio: path))
    }

    /// Текст расшифровки для модели — тот же разбор, что у экрана записи.
    nonisolated private static func readPlainText(at url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let markdown = try? WorkspaceStore.readTextFile(at: url) else { return nil }
            return TranscriptDocument.parse(markdown).plainText
        }.value
    }

    nonisolated private static func readSource(at url: URL) async -> Source? {
        await Task.detached(priority: .utility) {
            guard let markdown = try? WorkspaceStore.readTextFile(at: url) else { return nil }
            return Source(text: TranscriptDocument.parse(markdown).plainText)
        }.value
    }

    nonisolated private static func name(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Причина простоя — в журнал, но одна и та же причина подряд не повторяется:
    /// drain зовут на каждое возвращение, каждую заявку и каждые 5 секунд, пока
    /// мало памяти. Числа в строке (очередь, свободные мегабайты) повтором не
    /// считаются — сравнивается причина, а не текст.
    private func note(_ line: String, reason: String? = nil) {
        let key = reason ?? line
        guard key != lastNote else { return }
        lastNote = key
        Diagnostics.note(line)
    }
}
