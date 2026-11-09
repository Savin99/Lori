import Combine
import Foundation

/// Отчёт — обычный Markdown в рабочей папке. Старый файл жив до успешного
/// ответа: сетевой сбой и отмена не оставляют вместо него пустой документ.
@MainActor
final class ReportRunner: ObservableObject {
    @Published private(set) var running: Set<String> = []
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var completed: [String: UUID] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let client: @MainActor () throws -> GatewayClient

    init(client: @escaping @MainActor () throws -> GatewayClient = { try GatewayClient.configured() }) { self.client = client }

    nonisolated static func path(for recording: String) -> String {
        "Reports/" + (recording as NSString).lastPathComponent.replacingLastExtensionWithMarkdown
    }

    static func read(for path: String, in workspace: WorkspaceStore) throws -> String {
        try workspace.readText(at: Self.path(for: path))
    }

    static func write(_ markdown: String, for path: String, in workspace: WorkspaceStore) throws {
        // Запись уже могла переехать или оказаться в корзине, пока шёл запрос.
        _ = try workspace.fileURL(for: path)
        try workspace.writeText(markdown, at: Self.path(for: path))
    }

    func generate(path: String, transcript: String, title: String, workspace: WorkspaceStore) {
        guard tasks[path] == nil else { return }
        failures[path] = nil
        running.insert(path)
        tasks[path] = Task { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            defer { running.remove(path); tasks[path] = nil }
            do {
                let markdown = try await client().report(path: path, transcript: transcript, title: title, language: TranscriptionSettings.language)
                try Task.checkCancellation()
                try Self.write(markdown, for: path, in: workspace)
                completed[path] = UUID()
            } catch {
                guard !Task.isCancelled else { return }
                failures[path] = (error as? GatewayError)?.localizedDescription ?? "Не удалось сохранить отчёт. Попробуй ещё раз."
            }
        }
    }

    func cancel(_ path: String) { tasks[path]?.cancel() }
    func forget(_ path: String) {
        cancel(path)
        failures[path] = nil
        completed[path] = nil
    }
}

private extension String {
    var replacingLastExtensionWithMarkdown: String { (self as NSString).deletingPathExtension + ".md" }
}
