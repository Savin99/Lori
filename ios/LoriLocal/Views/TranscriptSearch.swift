import SwiftUI

/// Находка поиска: запись и строка её расшифровки, в которой совпало.
///
/// Одна находка на запись. Раньше расшифровка и аудио индексировались отдельно,
/// и запись, у которой совпали и имя, и текст, выходила в результатах дважды.
struct SearchHit: Identifiable, Hashable, Sendable {
    /// Сама запись — её и открывает тап, а не файл расшифровки.
    let entry: WorkspaceEntry
    /// Тот же заголовок, что на карточке (`RecordTitle`), а не имя файла.
    let title: String
    /// Строка расшифровки с совпадением, без разметки; nil — совпал только заголовок.
    let snippet: String?
    /// Что искали — чтобы выделить совпадение в строке.
    let needle: String

    var id: String { entry.relativePath }
}

/// Поиск по записям: по заголовкам, которые видны на карточках, и по тексту расшифровок.
///
/// Содержимое читается один раз, на открытие поиска: перечитывать все файлы
/// на каждое нажатие клавиши слишком дорого, а рабочая папка личная и небольшая.
@MainActor
final class TranscriptSearchStore: ObservableObject {
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var indexedCount = 0

    /// Запись в индексе: заголовок, имя файла и реплики расшифровки уже без
    /// таймкодов, меток говорящих и служебных строк.
    struct Document: Sendable, Equatable {
        let entry: WorkspaceEntry
        let title: String
        let name: String
        let lines: [String]
    }

    private struct Candidate: Sendable {
        let entry: WorkspaceEntry
        let title: String
        let transcript: URL?
    }

    private var documents: [Document] = []
    private var query = ""
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    /// Индексируются все записи: запись без расшифровки тоже должна находиться по
    /// заголовку, иначе её не отыскать вообще никак. Заголовки считает экран — они
    /// живут в хранилищах главного актора, а файлы читаются уже фоном.
    ///
    /// `keepingHits` — пересборка под открытым поиском (`refresh`): находки остаются
    /// на экране, пока не готовы новые, и «Готовлю поиск…» не мигает.
    func reindex(_ workspace: WorkspaceStore, keepingHits: Bool = false, title: (WorkspaceEntry) -> String) {
        indexTask?.cancel()
        searchTask?.cancel()
        if !keepingHits {
            isIndexing = true
            hits = []
        }
        let candidates = workspace.audio.map { entry in
            Candidate(
                entry: entry,
                title: title(entry),
                transcript: workspace.existingTranscript(for: entry).flatMap { try? workspace.readableTextURL(at: $0) }
            )
        }

        indexTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                candidates.map { candidate in
                    let markdown = candidate.transcript.flatMap { try? WorkspaceStore.readTextFile(at: $0) } ?? ""
                    return Document(
                        entry: candidate.entry,
                        title: candidate.title,
                        name: candidate.entry.displayName,
                        // Тот же разбор, что у экрана записи: в сниппет не попадут ни
                        // `**[0:34–1:12]**`, ни «S1:», ни строки `_Расшифровано:_`.
                        lines: TranscriptDocument.parse(markdown).lines.map(\.text)
                    )
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.documents = found
            self.indexedCount = found.count
            self.isIndexing = false
            self.indexTask = nil
            self.scheduleSearch(delay: false)
        }
    }

    /// Рабочая папка поменялась, пока поиск открыт: запись, открытую из поиска,
    /// удалили или переименовали на её экране. Находки без файла снимаются сразу —
    /// иначе тап открыл бы то, чего уже нет, — а индекс пересобирается фоном, и
    /// переименованная запись возвращается под новым заголовком.
    func refresh(_ workspace: WorkspaceStore, title: (WorkspaceEntry) -> String) {
        let present = Set(workspace.audio.map(\.relativePath))
        hits = Self.present(hits, in: present)
        documents.removeAll { !present.contains($0.entry.relativePath) }
        reindex(workspace, keepingHits: true, title: title)
    }

    /// Находки, чья запись ещё лежит в рабочей папке.
    nonisolated static func present(_ hits: [SearchHit], in paths: Set<String>) -> [SearchHit] {
        hits.filter { paths.contains($0.entry.relativePath) }
    }

    func apply(_ query: String) {
        self.query = query
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
                Self.hits(in: documents, needle: needle)
            }.value
            guard !Task.isCancelled, let self,
                  self.query.trimmingCharacters(in: .whitespacesAndNewlines) == needle else { return }
            self.hits = found
            self.searchTask = nil
        }
    }

    // MARK: - Совпадения

    /// Регистр и «ё/е» не важны: в расшифровке «всё» и «все» пишутся как придётся.
    nonisolated static let matching: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Находки по индексу: сначала совпавшие заголовком, потом текстом, внутри — новые
    /// сверху. Заголовок — то, что человек помнит о записи, и такое совпадение
    /// почти всегда то, что он искал.
    nonisolated static func hits(in documents: [Document], needle: String) -> [SearchHit] {
        let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var byTitle: [SearchHit] = []
        var byText: [SearchHit] = []
        for document in documents {
            let line = document.lines.lazy.compactMap { line in
                line.range(of: needle, options: matching, locale: LoriFormat.locale).map { (line, $0) }
            }.first
            let snippet = line.map { excerpt(of: $0.0, around: $0.1) }
            let titleMatches = document.title.range(of: needle, options: matching, locale: LoriFormat.locale) != nil
                || document.name.range(of: needle, options: matching, locale: LoriFormat.locale) != nil
            let hit = SearchHit(entry: document.entry, title: document.title, snippet: snippet, needle: needle)
            if titleMatches {
                byTitle.append(hit)
            } else if snippet != nil {
                byText.append(hit)
            }
        }
        let newestFirst: (SearchHit, SearchHit) -> Bool = { $0.entry.modifiedAt > $1.entry.modifiedAt }
        return byTitle.sorted(by: newestFirst) + byText.sorted(by: newestFirst)
    }

    /// Кусок реплики вокруг совпадения. Реплика бывает абзацем в несколько сотен
    /// знаков, и совпадение в её конце в две строки сниппета не попало бы: показываем
    /// немного до и побольше после, с многоточиями там, где текст обрезан.
    nonisolated static func excerpt(of line: String, around match: Range<String.Index>, limit: Int = 120) -> String {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.count > limit else { return clean }
        let before = 40
        var start = line.index(match.lowerBound, offsetBy: -before, limitedBy: line.startIndex) ?? line.startIndex
        // Начинаем со слова, а не с его середины.
        if start > line.startIndex, let space = line[start..<match.lowerBound].firstIndex(where: \.isWhitespace) {
            start = line.index(after: space)
        }
        // Совпадение целиком внутри куска, даже если оно само длиннее предела.
        var end = max(line.index(start, offsetBy: limit, limitedBy: line.endIndex) ?? line.endIndex, match.upperBound)
        if end < line.endIndex, let space = line[match.upperBound..<end].lastIndex(where: \.isWhitespace) {
            end = space
        }
        let body = line[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return (start > line.startIndex ? "…" : "") + body + (end < line.endIndex ? "…" : "")
    }
}

/// Строка поиска: заголовок записи, строка с совпадением и когда записано.
/// Дата здесь к месту — в отличие от списка, заголовков дней в поиске нет.
struct SearchResultRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(highlighted(hit.title, base: LoriFont.cardTitle, strong: LoriFont.cardTitle))
                .foregroundStyle(LoriPalette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let snippet = hit.snippet {
                Text(highlighted(snippet, base: LoriFont.meta, strong: LoriFont.meta.weight(.semibold)))
                    .foregroundStyle(LoriPalette.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Text(LoriFormat.stamp(hit.entry.modifiedAt))
                .font(LoriFont.small)
                .foregroundStyle(LoriPalette.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(LoriPalette.line, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("searchHit")
    }

    /// Совпадение выделено плотнее и цветом текста — глаз находит, за что зацепилось.
    private func highlighted(_ text: String, base: Font, strong: Font) -> AttributedString {
        var result = AttributedString(text)
        result.font = base
        guard let range = text.range(of: hit.needle, options: TranscriptSearchStore.matching, locale: LoriFormat.locale),
              let lower = AttributedString.Index(range.lowerBound, within: result),
              let upper = AttributedString.Index(range.upperBound, within: result) else { return result }
        result[lower..<upper].font = strong
        result[lower..<upper].foregroundColor = LoriPalette.ink
        return result
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
                TextField("Поиск по записям", text: $query)
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
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить поиск")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, query.isEmpty ? 16 : 2)
            .frame(height: 48)
            .background(LoriPalette.card, in: Capsule())
            .overlay(Capsule().stroke(LoriPalette.line, lineWidth: 1))

            Button("Отмена", action: cancel)
                .font(LoriFont.body)
                .foregroundStyle(LoriPalette.ink)
                .frame(minHeight: 44)
        }
    }
}
