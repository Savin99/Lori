import Combine
import Foundation
import UIKit

/// Запуск модели заголовков после расшифровки.
///
/// Работает по одной записи за раз, только когда памяти заведомо хватает и
/// только пока приложение на переднем плане. Память: у приложения на iPhone
/// предел около трёх гигабайт, и модель на 2,3 из них нельзя запускать «на
/// авось» — система убивает процесс без предупреждения. Передний план — см.
/// `postpone`: в фоне тот же запуск гасит процесс изнутри MLX.
@MainActor
final class SummaryRunner: ObservableObject {
    @Published private(set) var running: String?
    @Published var failure: String?

    private let models: SummaryModelStore
    private let store: SummaryStore
    private let availableMemory: @Sendable () -> UInt64
    private let isForeground: @MainActor () -> Bool
    private let summarize: @Sendable (SummaryVariant, URL, String) async throws -> Summarizer.Summary

    private struct Postponed: Codable {
        let path: String
        let text: String
        let force: Bool
    }
    private var postponed: [Postponed] = []
    // Ошибка одной записи не останавливает остальные. Неудачные заявки
    // остаются на диске и повторяются при следующем возвращении в приложение.
    private var failedThisPass: Set<String> = []
    private var task: Task<Void, Never>?
    private var memoryRetry: Task<Void, Never>?
    private var transcriptionPauses = 0
    private let queueURL: URL
    private var modelSubscription: AnyCancellable?
    private weak var workspace: WorkspaceStore?
    private weak var transcription: TranscriptionService?
    @Published private(set) var waitingReason: String?
    @Published private(set) var pendingCount = 0

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
        if let data = try? Data(contentsOf: queueURL),
           let saved = try? JSONDecoder().decode([Postponed].self, from: data) { postponed = saved }
        pendingCount = postponed.count
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
            case .notEnoughMemory: "Сейчас мало свободной памяти для модели заголовков. Закройте пару приложений и попробуйте снова."
            }
        }
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
        return SummaryVariant.allCases.contains(where: models.isInstalled) ? .notEnoughMemory : .noWeights
    }

    /// Источник событий — сервис и сохранённые файлы, а не onChange во View.
    func connect(to workspace: WorkspaceStore, transcription: TranscriptionService) {
        self.workspace = workspace
        self.transcription = transcription
    }

    func summarize(path: String, text: String, force: Bool = false) {
        guard force || store.needsSummary(for: path) else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 80 else { return }
        failedThisPass.remove(path)
        postponed.removeAll { $0.path == path }
        postponed.append(Postponed(path: path, text: clean, force: force))
        persist()
        drain()
    }

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
        failedThisPass.removeAll()
        recoverMissingSummaries()
        drain()
    }

    /// После перезапуска находим также результаты, записанные перед убийством процесса,
    /// когда callback ещё не успел сохранить очередь заголовков. Читаем по одному файлу.
    private func recoverMissingSummaries() {
        guard let workspace else { return }
        for entry in (try? workspace.audioEntries()) ?? [] {
            guard store.needsSummary(for: entry.relativePath),
                  !postponed.contains(where: { $0.path == entry.relativePath }),
                  let path = workspace.existingTranscript(for: entry),
                  let text = try? workspace.readText(at: path) else { continue }
            let plain = TranscriptDocument.parse(text).plainText
            if plain.count > 80 { postponed.append(Postponed(path: entry.relativePath, text: plain, force: false)) }
        }
        persist()
    }

    private func persist() {
        pendingCount = postponed.count
        do {
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(postponed).write(to: queueURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { failure = "Не удалось сохранить очередь заголовков: \(error.localizedDescription)" }
    }

    private func drain() {
        guard transcriptionPauses == 0, running == nil, !postponed.isEmpty else { return }
        guard isForeground() else { waitingReason = "Заголовки продолжатся после возвращения в Lori"; return }
        guard transcription?.isIdle != false else { waitingReason = "Заголовки ждут завершения расшифровки"; return }
        guard let variant = choose() else {
            waitingReason = obstacle()?.message
            if obstacle() == .notEnoughMemory, memoryRetry == nil {
                memoryRetry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self else { return }
                    self.memoryRetry = nil
                    self.drain()
                }
            }
            return
        }
        postponed.removeAll { !$0.force && !store.needsSummary(for: $0.path) }
        guard let next = postponed.first(where: { !failedThisPass.contains($0.path) }) else {
            persist()
            waitingReason = postponed.isEmpty ? nil : "Не удалось создать заголовок. Повторю при возвращении в Lori"
            return
        }
        if let workspace, (try? workspace.entry(at: next.path)) == nil {
            postponed.removeAll { $0.path == next.path }; persist(); drain(); return
        }
        running = next.path
        waitingReason = nil
        failure = nil
        let directory = models.directory(of: variant)
        task = Task { [weak self] in
            guard let self else { return }
            var completed = false
            do {
                let summary = try await self.summarize(variant, directory, next.text)
                try Task.checkCancellation()
                guard self.store.store(title: summary.title, detail: summary.detail, for: next.path, force: next.force) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                completed = true
            } catch {
                if Task.isCancelled {
                    self.waitingReason = "Заголовки продолжатся после возвращения в Lori"
                } else {
                    self.failedThisPass.insert(next.path)
                    self.failure = error.localizedDescription
                    self.waitingReason = "Не удалось создать заголовок. Повторю при возвращении в Lori"
                }
            }
            // Не удаляем более свежую заявку, пришедшую во время генерации.
            if completed {
                self.postponed.removeAll { $0.path == next.path && $0.text == next.text }
                self.failedThisPass.remove(next.path)
            }
            self.persist()
            self.running = nil
            self.task = nil
            // Ошибка остаётся на диске, но не запускает бесконечный цикл запросов.
            if !Task.isCancelled || self.isForeground() { self.drain() }
        }
    }
}
