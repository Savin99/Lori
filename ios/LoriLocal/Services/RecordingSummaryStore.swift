import Combine
import Foundation

/// Итоги отдельно от имён: ручной заголовок защищён, а итог можно обновлять.
@MainActor
final class RecordingSummaryStore: ObservableObject {
    struct Entry: Codable, Equatable, Sendable {
        let summary: RecordingSummary
        let fingerprint: String
        let createdAt: Date
        let source: String
        var stale: Bool
        var completedTasks: Set<String> = []

        private enum CodingKeys: String, CodingKey { case summary, fingerprint, createdAt, source, stale, completedTasks }
        init(summary: RecordingSummary, fingerprint: String, createdAt: Date, source: String, stale: Bool, completedTasks: Set<String> = []) {
            self.summary = summary; self.fingerprint = fingerprint; self.createdAt = createdAt
            self.source = source; self.stale = stale; self.completedTasks = completedTasks
        }
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            self.init(summary: try box.decode(RecordingSummary.self, forKey: .summary),
                      fingerprint: try box.decode(String.self, forKey: .fingerprint),
                      createdAt: try box.decode(Date.self, forKey: .createdAt), source: try box.decode(String.self, forKey: .source),
                      stale: try box.decode(Bool.self, forKey: .stale),
                      completedTasks: try box.decodeIfPresent(Set<String>.self, forKey: .completedTasks) ?? [])
        }
    }
    @Published private(set) var entries: [String: Entry] = [:]
    private let url: URL
    private(set) var isUnreadable = false

    init(url: URL? = nil) {
        self.url = url ?? SummaryStore.defaultURL.deletingLastPathComponent().appending(path: "recording-summaries.json")
        load()
    }

    func entry(for path: String) -> Entry? { entries[path] }
    func isUpToDate(_ path: String, fingerprint: String) -> Bool {
        guard let entry = entries[path] else { return false }
        return !entry.stale && entry.fingerprint == fingerprint
    }

    @discardableResult
    func store(_ summary: RecordingSummary, for path: String, fingerprint: String) -> Bool {
        change {
            let completed = (entries[path]?.completedTasks ?? []).intersection(summary.tasks.map(\.text))
            entries[path] = Entry(summary: summary, fingerprint: fingerprint, createdAt: .now, source: "gateway", stale: false, completedTasks: completed)
        }
    }

    @discardableResult
    func toggleTask(_ text: String, for path: String) -> Bool {
        guard entries[path]?.summary.tasks.contains(where: { $0.text == text }) == true else { return false }
        return change {
            if entries[path]?.completedTasks.contains(text) == true { entries[path]?.completedTasks.remove(text) }
            else { entries[path]?.completedTasks.insert(text) }
        }
    }

    func markStale(_ path: String, fingerprint: String? = nil) {
        guard let entry = entries[path], !entry.stale, fingerprint == nil || fingerprint != entry.fingerprint else { return }
        _ = change { entries[path]?.stale = true }
    }
    func move(from old: String, to new: String) {
        guard old != new else { return }
        _ = change { if let entry = entries.removeValue(forKey: old) { entries[new] = entry } }
    }
    func forget(_ path: String) { _ = change { entries[path] = nil } }

    private func change(_ mutation: () -> Void) -> Bool {
        if isUnreadable { load() }
        guard !isUnreadable else { return false }
        let previous = entries
        mutation()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            entries = previous
            Diagnostics.fault("итоги: не удалось сохранить файл")
            return false
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { isUnreadable = false; return }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { isUnreadable = true; Diagnostics.fault("итоги: файл не читается, сохранять поверх нельзя"); return }
        do {
            entries = try JSONDecoder().decode([String: Entry].self, from: data)
            isUnreadable = false
        } catch {
            // Уникальное имя не перезаписывает предыдущую копию повреждения.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(UUID().uuidString).json")
            do {
                try data.write(to: backup, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                Diagnostics.fault("итоги: повреждённый файл сохранён в \(backup.lastPathComponent)")
                entries = [:]
                isUnreadable = false
            } catch { isUnreadable = true; Diagnostics.fault("итоги: копия не сохранилась, сохранять поверх нельзя") }
        }
    }
}
