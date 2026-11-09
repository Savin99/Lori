import Foundation

/// Text разбирает строчную разметку, но не рисует маркеры Markdown-списков.
/// Отделяем их от текста: перенос строки остаётся под текстом, вложенность видна.
enum ReportMarkdown {
    struct Row: Equatable {
        let text: String
        var heading = false
        var marker: String? = nil
        var indent = 0
        var timestamp: TimeInterval? = nil
        var headingLevel = 0
    }

    static func rows(_ markdown: String) -> [Row] {
        var discussion = false
        return markdown.components(separatedBy: .newlines).compactMap { line in
            let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
            let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let text = String(line.dropFirst(leading.count)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let hashes = text.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), text.dropFirst(hashes).hasPrefix(" ") {
                let title = String(text.dropFirst(hashes + 1))
                discussion = title.lowercased().contains("ход обсуждения")
                return Row(text: title, heading: true, headingLevel: hashes)
            }
            if let match = text.range(of: #"^(?:[-+*]|[0-9]{1,9}[.)])\s+"#, options: .regularExpression) {
                let token = text[match].trimmingCharacters(in: .whitespaces)
                let marker = ["-", "+", "*"].contains(token) ? "•" : token
                return timedRow(String(text[match.upperBound...]), marker: marker, indent: indent, discussion: discussion)
            }
            return timedRow(text, discussion: discussion)
        }
    }

    /// Только ведущая метка пункта обсуждения. Не ищем время внутри прозы и
    /// не исправляем невалидные секунды: сомнительное время остаётся текстом.
    private static func timedRow(_ text: String, marker: String? = nil, indent: Int = 0, discussion: Bool) -> Row {
        guard discussion, let match = text.range(of: #"^\[([0-9]{1,6}):([0-9]{2})\]\s+"#, options: .regularExpression) else {
            return Row(text: text, marker: marker, indent: indent)
        }
        let stamp = text[match].trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[1] < 60 else { return Row(text: text, marker: marker, indent: indent) }
        let body = String(text[match.upperBound...])
        guard !body.isEmpty else { return Row(text: text, marker: marker, indent: indent) }
        return Row(text: body, marker: marker, indent: indent, timestamp: TimeInterval(parts[0] * 60 + parts[1]))
    }
}
