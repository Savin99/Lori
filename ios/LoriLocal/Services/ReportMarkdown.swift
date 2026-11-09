import Foundation

/// Text разбирает строчную разметку, но не рисует маркеры Markdown-списков.
/// Отделяем их от текста: перенос строки остаётся под текстом, вложенность видна.
enum ReportMarkdown {
    struct Row: Equatable {
        let text: String
        var heading = false
        var marker: String? = nil
        var indent = 0
    }

    static func rows(_ markdown: String) -> [Row] {
        markdown.components(separatedBy: .newlines).compactMap { line in
            let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
            let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let text = String(line.dropFirst(leading.count)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let hashes = text.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), text.dropFirst(hashes).hasPrefix(" ") {
                return Row(text: String(text.dropFirst(hashes + 1)), heading: true)
            }
            if let match = text.range(of: #"^(?:[-+*]|[0-9]{1,9}[.)])\s+"#, options: .regularExpression) {
                let token = text[match].trimmingCharacters(in: .whitespaces)
                let marker = ["-", "+", "*"].contains(token) ? "•" : token
                return Row(text: String(text[match.upperBound...]), marker: marker, indent: indent)
            }
            return Row(text: text)
        }
    }
}
