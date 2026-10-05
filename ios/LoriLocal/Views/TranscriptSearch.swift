import SwiftUI

/// Находка поиска: файл рабочей папки и строка, в которой совпало.
struct SearchHit: Identifiable, Hashable, Sendable {
    let entry: WorkspaceEntry
    /// Строка из текста заметки; nil — значит совпало только имя.
    let snippet: String?

    var id: String { entry.relativePath }
}

/// Поиск по расшифровкам: текст внутри `Transcripts` плюс названия самих записей.
///
/// Содержимое читается один раз, на открытие поиска: перечитывать все файлы
/// на каждое нажатие клавиши слишком дорого, а рабочая папка личная и небольшая.
@MainActor
final class TranscriptSearchStore: ObservableObject {
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var indexedCount = 0

    private struct Document: Sendable {
        let entry: WorkspaceEntry
        let name: String
        let text: String
    }

    private struct Candidate: Sendable {
        let entry: WorkspaceEntry
        let url: URL
    }

    private var documents: [Document] = []
    private var query = ""
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    /// Индексируются расшифровки (по тексту) и записи (по названию): запись без
    /// расшифровки тоже должна находиться, иначе её не отыскать вообще никак.
    func reindex(_ workspace: WorkspaceStore) {
        indexTask?.cancel()
        searchTask?.cancel()
        isIndexing = true
        hits = []
        let candidates = ((try? workspace.entries(at: "Transcripts")) ?? [])
            .filter { !$0.isDirectory }
            .compactMap { entry -> Candidate? in
                guard let url = try? workspace.readableTextURL(at: entry.relativePath) else { return nil }
                return Candidate(entry: entry, url: url)
            }
        let audio = workspace.audio

        indexTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                var result = candidates.map { candidate in
                    Document(
                        entry: candidate.entry,
                        name: candidate.entry.name.lowercased(),
                        text: (try? WorkspaceStore.readTextFile(at: candidate.url)) ?? ""
                    )
                }
                result += audio.map {
                    Document(entry: $0, name: $0.name.lowercased(), text: "")
                }
                return result
            }.value
            guard !Task.isCancelled, let self else { return }
            self.documents = found
            self.indexedCount = found.count
            self.isIndexing = false
            self.indexTask = nil
            self.scheduleSearch(delay: false)
        }
    }

    func apply(_ query: String) {
        self.query = query
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            searchTask?.cancel()
            hits = []
            return
        }
        scheduleSearch(delay: true)
    }

    func clear() {
        searchTask?.cancel()
        query = ""
        hits = []
    }

    private func scheduleSearch(delay: Bool) {
        searchTask?.cancel()
        let documents = documents
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            hits = []
            return
        }
        searchTask = Task { [weak self] in
            if delay {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            let found = await Task.detached(priority: .userInitiated) {
                documents
                    .compactMap { document -> SearchHit? in
                        if document.name.contains(needle) {
                            return SearchHit(
                                entry: document.entry,
                                snippet: Self.matchingLine(in: document.text, needle: needle)
                            )
                        }
                        guard let line = Self.matchingLine(in: document.text, needle: needle) else { return nil }
                        return SearchHit(entry: document.entry, snippet: line)
                    }
                    .sorted { lhs, rhs in
                        if lhs.entry.isDirectory != rhs.entry.isDirectory { return lhs.entry.isDirectory }
                        return lhs.entry.modifiedAt > rhs.entry.modifiedAt
                    }
            }.value
            guard !Task.isCancelled, let self, self.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle else { return }
            self.hits = found
            self.searchTask = nil
        }
    }

    /// Первая строка с совпадением, обрезанная до читаемой длины.
    nonisolated private static func matchingLine(in text: String, needle: String) -> String? {
        guard !text.isEmpty else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.lowercased().contains(needle) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            return trimmed.count > 110 ? "\(trimmed.prefix(110))…" : trimmed
        }
        return nil
    }
}

/// Строка поиска. Отдельная от `NoteCard`: здесь важно не время правки,
/// а что совпало и где это лежит.
struct SearchResultRow: View {
    let hit: SearchHit

    private var location: String? {
        let parent = URL(fileURLWithPath: hit.entry.relativePath).deletingLastPathComponent().path
        let trimmed = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/."))
        return trimmed.isEmpty ? nil : trimmed
    }

    private var symbol: String {
        if hit.entry.isDirectory { return "folder.fill" }
        return hit.entry.isAudio ? "waveform" : "doc.text"
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .font(LoriFont.control)
                .foregroundStyle(LoriPalette.lime)
                .frame(width: 38, height: 38)
                .background(LoriPalette.limeSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text(hit.entry.displayName)
                    .font(LoriFont.cardTitle)
                    .foregroundStyle(LoriPalette.ink)
                    .lineLimit(1)
                if let snippet = hit.snippet {
                    Text(snippet)
                        .font(LoriFont.meta)
                        .foregroundStyle(LoriPalette.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else if !hit.entry.isDirectory {
                    Text(LoriFormat.stamp(hit.entry.modifiedAt))
                        .font(LoriFont.meta)
                        .foregroundStyle(LoriPalette.muted)
                }
                if let location {
                    Label(location, systemImage: "folder")
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.muted.opacity(0.8))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(minHeight: 66)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(LoriPalette.line, lineWidth: 1))
    }
}

/// Поле поиска в шапке. Рамка — по правилу проекта: обведён только ввод.
struct TranscriptSearchBar: View {
    @Binding var query: String
    var focus: FocusState<Bool>.Binding
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(LoriFont.control)
                    .foregroundStyle(LoriPalette.muted)
                TextField("Поиск по расшифровкам", text: $query)
                    .font(LoriFont.body)
                    .foregroundStyle(LoriPalette.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused(focus)
                if !query.isEmpty {
                    Button {
                        query = ""
                        focus.wrappedValue = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(LoriFont.body)
                            .foregroundStyle(LoriPalette.muted.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить поиск")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(LoriPalette.card, in: Capsule())
            .overlay(Capsule().stroke(LoriPalette.line, lineWidth: 1))

            Button("Отмена", action: cancel)
                .font(LoriFont.body)
                .foregroundStyle(LoriPalette.ink)
        }
    }
}
