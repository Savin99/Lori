import Foundation

/// Обработанная выжимка из расшифровки: то, что человек читает вместо дословного текста.
/// Дословный текст никуда не девается — он остаётся в `Transcripts/` и открывается
/// переключателем в карточке.
struct NoteDigest: Equatable, Sendable {
    var title: String
    /// Название тематической папки, в которую ложится заметка.
    var theme: String
    var summary: String
    var highlights: [String]
    var decisions: [String]
    var tasks: [String]
    var tags: [String]

    static let fallbackTheme = "Заметки"
    static let fallbackTitle = "Без названия"

    /// Приводит ответ модели к пригодному виду: пустые пункты, кавычки-обёртки,
    /// слэши в названии папки и слишком длинные строки чинятся здесь, а не в интерфейсе.
    func normalized() -> NoteDigest {
        NoteDigest(
            title: NoteDigest.cleanTitle(title),
            theme: NoteDigest.cleanTheme(theme),
            summary: NoteDigest.cleanLine(summary),
            highlights: NoteDigest.cleanList(highlights),
            decisions: NoteDigest.cleanList(decisions),
            tasks: NoteDigest.cleanList(tasks),
            tags: NoteDigest.cleanTags(tags)
        )
    }

    /// Полный текст заметки: front matter со связями плюс читаемое тело.
    /// Front matter — источник правды о связи «аудио ↔ расшифровка ↔ заметка»:
    /// он переживает переименование и переезд файла, чего не переживёт внешний индекс.
    func markdown(audioPath: String?, transcriptPath: String?, created: Date) -> String {
        var lines = ["---", "lori: digest"]
        if let audioPath, !audioPath.isEmpty { lines.append("audio: \(audioPath)") }
        if let transcriptPath, !transcriptPath.isEmpty { lines.append("transcript: \(transcriptPath)") }
        lines.append("theme: \(theme)")
        if !tags.isEmpty { lines.append("tags: \(tags.joined(separator: ", "))") }
        lines.append("created: \(ISO8601DateFormatter().string(from: created))")
        lines.append("---")
        lines.append("")
        lines.append("# \(title)")

        if !summary.isEmpty {
            lines.append("")
            lines.append(summary)
        }
        appendSection("Важное", items: highlights, to: &lines)
        appendSection("Решения", items: decisions, to: &lines)
        appendSection("Задачи", items: tasks, to: &lines, checkbox: true)
        return lines.joined(separator: "\n") + "\n"
    }

    private func appendSection(
        _ title: String,
        items: [String],
        to lines: inout [String],
        checkbox: Bool = false
    ) {
        guard !items.isEmpty else { return }
        lines.append("")
        lines.append("## \(title)")
        for item in items {
            lines.append(checkbox ? "- [ ] \(item)" : "- \(item)")
        }
    }

    /// Имя файла заметки. Символы, недопустимые в пути, убираются здесь:
    /// `WorkspaceStore` на них честно падает, и тогда заметка просто не сохранится.
    var filename: String {
        let cleaned = NoteDigest.sanitizeName(title)
        return cleaned.isEmpty ? "\(NoteDigest.fallbackTitle).md" : "\(cleaned).md"
    }

    static func sanitizeName(_ raw: String) -> String {
        var name = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\r\n\t*?\"<>|"))
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name
    }

    private static func cleanTitle(_ raw: String) -> String {
        var value = cleanLine(raw)
        value = value.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        while let first = value.first, first == "«" || first == "\"" { value.removeFirst() }
        while let last = value.last, last == "»" || last == "\"" || last == "." { value.removeLast() }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackTitle : String(trimmed.prefix(80))
    }

    private static func cleanTheme(_ raw: String) -> String {
        let value = sanitizeName(cleanLine(raw))
        guard !value.isEmpty, value != "..", value != ".LoriTrash" else { return fallbackTheme }
        return String(value.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanLine(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanList(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.compactMap { item -> String? in
            var value = cleanLine(item)
            value = value.replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression)
            value = value.replacingOccurrences(of: "^\\[[ xX]\\]\\s*", with: "", options: .regularExpression)
            guard !value.isEmpty else { return nil }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    private static func cleanTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.compactMap { item -> String? in
            let value = cleanLine(item)
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: " ", with: "-")
                .lowercased()
            guard !value.isEmpty, value.count <= 24 else { return nil }
            guard seen.insert(value).inserted else { return nil }
            return value
        }
    }
}

/// Ответ модели. Ключи повторяют схему из промпта; все поля необязательные,
/// потому что модель нередко опускает пустые списки.
struct NoteDigestPayload: Decodable {
    var title: String?
    var theme: String?
    var summary: String?
    var highlights: [String]?
    var decisions: [String]?
    var tasks: [String]?
    var tags: [String]?

    var digest: NoteDigest {
        NoteDigest(
            title: title ?? "",
            theme: theme ?? "",
            summary: summary ?? "",
            highlights: highlights ?? [],
            decisions: decisions ?? [],
            tasks: tasks ?? [],
            tags: tags ?? []
        ).normalized()
    }

    /// Модель охотно оборачивает JSON в ```json и добавляет фразу до и после,
    /// поэтому вырезаем первый объект по фигурным скобкам, а не парсим строку целиком.
    static func parse(_ raw: String) throws -> NoteDigestPayload {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            throw DigestError.notJSON
        }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8) else { throw DigestError.notJSON }
        do {
            return try JSONDecoder().decode(NoteDigestPayload.self, from: data)
        } catch {
            throw DigestError.notJSON
        }
    }
}

enum DigestError: LocalizedError, Equatable {
    case notJSON
    case emptySource
    case missingKey

    var errorDescription: String? {
        switch self {
        case .notJSON: "Модель ответила не тем форматом — обработка не удалась. Попробуй ещё раз."
        case .emptySource: "В расшифровке нет текста, обрабатывать нечего."
        case .missingKey: "Добавь ключ модели в настройках Lori: обработка расшифровки идёт через неё."
        }
    }
}

/// Служебные поля заметки, вынутые из front matter.
struct NoteMeta: Equatable, Sendable {
    var isDigest = false
    var audio: String?
    var transcript: String?
    var theme: String?
    var tags: [String] = []

    /// Разбор front matter вида `---\nkey: value\n---`. Полноценный YAML тут не нужен
    /// и был бы лишней зависимостью: своих полей ровно шесть, все — плоские строки.
    static func parse(_ text: String) -> NoteMeta {
        var meta = NoteMeta()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return meta }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[trimmed.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "lori": meta.isDigest = value == "digest"
            case "audio": meta.audio = value.isEmpty ? nil : value
            case "transcript": meta.transcript = value.isEmpty ? nil : value
            case "theme": meta.theme = value.isEmpty ? nil : value
            case "tags":
                meta.tags = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "") }
                    .filter { !$0.isEmpty }
            default: continue
            }
        }
        return meta
    }

    /// Тело заметки без front matter: интерфейсу служебные строки показывать незачем.
    static func body(of text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return text }
        guard let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return text
        }
        return lines[(closing + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Дословный текст, приведённый к читаемому виду **без участия модели**:
/// метки времени убираются, сплошная стена речи разбивается на абзацы.
/// Слова не меняются — это по-прежнему та же расшифровка, поэтому приём годится
/// и как запасной вариант «Важного», когда ключа модели нет.
enum TranscriptReadability {
    /// Сколько предложений и знаков собирается в один абзац.
    static let sentencesPerParagraph = 4
    static let charactersPerParagraph = 420

    static func plainText(fromMarkdown markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let body = lines.first?.hasPrefix("#") == true ? Array(lines.dropFirst()) : lines
        return body
            .map { line in
                line.replacingOccurrences(
                    of: "\\*\\*\\[[^\\]]*\\]\\*\\*\\s*",
                    with: "",
                    options: .regularExpression
                )
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func paragraphs(from text: String) -> [String] {
        let blocks = text
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var result: [String] = []
        for block in blocks {
            result.append(contentsOf: split(block))
        }
        return result
    }

    static func readable(fromMarkdown markdown: String) -> String {
        paragraphs(from: plainText(fromMarkdown: markdown)).joined(separator: "\n\n")
    }

    /// Разрез идёт только по концу предложения, поэтому слово или мысль не рвётся.
    /// Если знаков препинания нет вовсе (движок Apple их не ставит), абзац остаётся один —
    /// врать переносами посреди фразы хуже, чем оставить как есть.
    private static func split(_ block: String) -> [String] {
        var paragraphs: [String] = []
        var current = ""
        var collected = 0

        for sentence in sentences(in: block) {
            current = current.isEmpty ? sentence : "\(current) \(sentence)"
            collected += 1
            if collected >= sentencesPerParagraph || current.count >= charactersPerParagraph {
                paragraphs.append(current)
                current = ""
                collected = 0
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }

    private static func sentences(in block: String) -> [String] {
        var result: [String] = []
        var current = ""
        let iterator = Array(block)
        var index = 0
        while index < iterator.count {
            let character = iterator[index]
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "…" {
                // Точка внутри «т.е.» или сокращения не заканчивает предложение:
                // разрез признаётся только перед пробелом и заглавной буквой.
                let next = index + 1 < iterator.count ? iterator[index + 1] : " "
                let after = index + 2 < iterator.count ? iterator[index + 2] : "А"
                if next == " " || next == "\n" {
                    if after.isUppercase || after.isNumber {
                        result.append(current.trimmingCharacters(in: .whitespaces))
                        current = ""
                        index += 2
                        continue
                    }
                }
            }
            index += 1
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}
