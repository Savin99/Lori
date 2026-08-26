import Foundation

/// Заметка глазами вики: чем она называется, к какой теме относится,
/// какие у неё теги и на что она ссылается.
struct WikiNote: Identifiable, Equatable {
    let path: String
    let title: String
    /// Папка первого уровня. Для заметки в корне — nil.
    let theme: String?
    let tags: [String]
    /// Имена заметок из `[[двойных скобок]]`.
    let links: [String]

    var id: String { path }
}

/// Название темы или тега вместе с числом заметок.
struct WikiTopic: Identifiable, Equatable {
    let name: String
    let count: Int

    var id: String { name }
}

/// Вики поверх обычных файлов: темы — это папки, теги берутся из front matter
/// и из `#решётки` в тексте, связи — из `[[двойных скобок]]`.
///
/// Отдельной базы нет намеренно: всё, что видит вики, лежит в заметках, поэтому
/// её нельзя расстроить с реальностью, а человек правит связи прямо в тексте.
struct WikiIndex: Equatable {
    let notes: [WikiNote]

    static let empty = WikiIndex(notes: [])
    /// Папки, которые вики не показывает: там лежит сырьё, а не знание.
    /// `Inbox` не исключён — принесённые файлы это содержание, а не служебка.
    static let skippedFolders: Set<String> = ["Recordings", "Transcripts", "Models"]

    @MainActor
    static func build(_ workspace: WorkspaceStore) -> WikiIndex {
        var found: [WikiNote] = []
        var queue = [""]
        while let directory = queue.popLast() {
            guard let items = try? workspace.entries(at: directory) else { continue }
            for item in items {
                if item.isDirectory {
                    guard !skippedFolders.contains(item.name) else { continue }
                    queue.append(item.relativePath)
                    continue
                }
                guard item.name.lowercased().hasSuffix(".md"),
                      let text = try? workspace.readText(at: item.relativePath) else { continue }
                found.append(note(at: item, text: text))
            }
        }
        return WikiIndex(notes: found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }

    static func note(at entry: WorkspaceEntry, text: String) -> WikiNote {
        let meta = NoteMeta.parse(text)
        let body = NoteMeta.body(of: text)
        let parts = entry.relativePath.split(separator: "/").map(String.init)
        return WikiNote(
            path: entry.relativePath,
            title: title(of: body, fallback: entry.displayName),
            theme: parts.count > 1 ? parts[0] : nil,
            tags: mergedTags(meta: meta.tags, body: body),
            links: links(in: body)
        )
    }

    /// Заголовок берётся из первой строки `# …`, иначе из имени файла:
    /// имя файла у обработанной заметки и так собрано из заголовка.
    static func title(of body: String, fallback: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            let title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? fallback : title
        }
        return fallback
    }

    static func links(in body: String) -> [String] {
        matches(in: body, pattern: "\\[\\[([^\\]\\[]{1,80})\\]\\]")
    }

    /// Теги из текста. `## Заголовок` тегом не считается: после решётки должна
    /// идти буква или цифра, а перед ней — начало строки или пробел.
    static func inlineTags(in body: String) -> [String] {
        matches(in: body, pattern: "(?:^|\\s)#([\\p{L}\\p{N}][\\p{L}\\p{N}_-]{1,23})")
            .map { $0.lowercased() }
    }

    private static func mergedTags(meta: [String], body: String) -> [String] {
        var seen = Set<String>()
        return (meta.map { $0.lowercased() } + inlineTags(in: body)).filter { seen.insert($0).inserted }
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var result: [String] = []
        var seen = Set<String>()
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[captured]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
            result.append(value)
        }
        return result
    }

    // MARK: - Срезы

    var themes: [WikiTopic] {
        var counts: [String: Int] = [:]
        for note in notes {
            guard let theme = note.theme, !DigestService.nonThemeFolders.contains(theme) else { continue }
            counts[theme, default: 0] += 1
        }
        return sorted(counts)
    }

    var tags: [WikiTopic] {
        var counts: [String: Int] = [:]
        for note in notes {
            for tag in note.tags { counts[tag, default: 0] += 1 }
        }
        return sorted(counts)
    }

    func notes(inTheme theme: String) -> [WikiNote] {
        notes.filter { $0.theme?.lowercased() == theme.lowercased() }
    }

    func notes(withTag tag: String) -> [WikiNote] {
        notes.filter { $0.tags.contains(tag.lowercased()) }
    }

    func note(at path: String) -> WikiNote? {
        notes.first { $0.path == path }
    }

    /// Заметка по имени из `[[ссылки]]`. Сначала точное совпадение заголовка,
    /// потом имя файла: человек ссылается и так, и так.
    func resolve(link: String) -> WikiNote? {
        let needle = link.lowercased()
        if let byTitle = notes.first(where: { $0.title.lowercased() == needle }) { return byTitle }
        return notes.first { note in
            let name = (note.path as NSString).lastPathComponent
            return (name as NSString).deletingPathExtension.lowercased() == needle
        }
    }

    /// Кто ссылается на эту заметку. Обратные ссылки нигде не хранятся —
    /// они считаются из прямых, иначе их пришлось бы синхронизировать.
    func backlinks(to note: WikiNote) -> [WikiNote] {
        let names: Set<String> = [
            note.title.lowercased(),
            ((note.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased(),
        ]
        return notes.filter { candidate in
            candidate.path != note.path && candidate.links.contains { names.contains($0.lowercased()) }
        }
    }

    /// Ссылки, у которых нет заметки: в вики это будущие темы, а не ошибка.
    func unresolvedLinks(from note: WikiNote) -> [String] {
        note.links.filter { resolve(link: $0) == nil }
    }

    private func sorted(_ counts: [String: Int]) -> [WikiTopic] {
        counts
            .map { WikiTopic(name: $0.key, count: $0.value) }
            .sorted {
                $0.count != $1.count
                    ? $0.count > $1.count
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
