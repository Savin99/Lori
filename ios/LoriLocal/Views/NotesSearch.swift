import SwiftUI

/// Находка поиска: запись рабочей папки и строка, в которой совпало.
struct SearchHit: Identifiable, Hashable {
    let entry: WorkspaceEntry
    /// Строка из текста заметки; nil — значит совпало только имя.
    let snippet: String?

    var id: String { entry.relativePath }
}

/// Поиск по всей рабочей папке, а не только по её корню: главная показывает корень,
/// но заметка чаще всего лежит внутри папки, и поиск по одному корню бесполезен.
///
/// Содержимое читается один раз, на открытие поиска: перечитывать все файлы
/// на каждое нажатие клавиши слишком дорого, а рабочая папка личная и небольшая.
@MainActor
final class NotesSearchStore: ObservableObject {
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var indexedCount = 0

    private struct Document {
        let entry: WorkspaceEntry
        let name: String
        let text: String
    }

    private var documents: [Document] = []
    private var query = ""

    /// Обход в ширину: `entries(at:)` уже отсекает скрытое, симлинки и `.LoriTrash`,
    /// поэтому свой обход не расширяет песочницу.
    func reindex(_ workspace: WorkspaceStore) {
        isIndexing = true
        defer { isIndexing = false }

        var found: [Document] = []
        var queue = [""]
        while let directory = queue.popLast() {
            guard let items = try? workspace.entries(at: directory) else { continue }
            for item in items {
                if item.isDirectory {
                    queue.append(item.relativePath)
                    found.append(Document(entry: item, name: item.name.lowercased(), text: ""))
                } else {
                    // Аудио и всё нетекстовое ищется по имени: `readText` на них честно падает.
                    let text = item.isAudio ? "" : ((try? workspace.readText(at: item.relativePath)) ?? "")
                    found.append(Document(entry: item, name: item.name.lowercased(), text: text))
                }
            }
        }
        documents = found
        indexedCount = found.count
        apply(query)
    }

    func apply(_ query: String) {
        self.query = query
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            hits = []
            return
        }
        hits = documents
            .compactMap { document -> SearchHit? in
                if document.name.contains(needle) {
                    return SearchHit(entry: document.entry, snippet: matchingLine(in: document.text, needle: needle))
                }
                guard let line = matchingLine(in: document.text, needle: needle) else { return nil }
                return SearchHit(entry: document.entry, snippet: line)
            }
            .sorted { lhs, rhs in
                if lhs.entry.isDirectory != rhs.entry.isDirectory { return lhs.entry.isDirectory }
                return lhs.entry.modifiedAt > rhs.entry.modifiedAt
            }
    }

    func clear() {
        query = ""
        hits = []
    }

    /// Первая строка с совпадением, обрезанная до читаемой длины.
    private func matchingLine(in text: String, needle: String) -> String? {
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
                .font(.system(size: 17, weight: .medium))
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
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(LoriPalette.line, lineWidth: 1))
    }
}

/// Поле поиска в шапке. Рамка — по правилу проекта: обведён только ввод.
struct NotesSearchBar: View {
    @Binding var query: String
    var focus: FocusState<Bool>.Binding
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(LoriPalette.muted)
                TextField("Поиск по заметкам", text: $query)
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
                            .font(.system(size: 16))
                            .foregroundStyle(LoriPalette.muted.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить поиск")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(.white.opacity(0.9), in: Capsule())
            .overlay(Capsule().stroke(LoriPalette.line, lineWidth: 1))

            Button("Отмена", action: cancel)
                .font(LoriFont.body)
                .foregroundStyle(LoriPalette.ink)
        }
    }
}
