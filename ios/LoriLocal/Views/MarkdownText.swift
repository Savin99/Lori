import SwiftUI

/// Блок разметки в ответе модели.
///
/// Модель отвечает Markdown’ом всегда, даже если её об этом не просили. SwiftUI сам
/// умеет только строчную разметку (и только через `AttributedString`), а списки,
/// заголовки и код не умеет вовсе — поэтому блоки разбираем сами, а внутри строки
/// разметку отдаём системе.
enum MarkdownBlock: Identifiable, Equatable {
    case heading(String, level: Int)
    case bullet(String)
    case numbered(String, number: String)
    case quote(String)
    case code(String)
    case paragraph(String)

    var id: String {
        switch self {
        case let .heading(text, level): "h\(level)-\(text)"
        case let .bullet(text): "b-\(text)"
        case let .numbered(text, number): "n\(number)-\(text)"
        case let .quote(text): "q-\(text)"
        case let .code(text): "c-\(text)"
        case let .paragraph(text): "p-\(text)"
        }
    }

    /// Разбор построчный: настоящий парсер Markdown тут не нужен, а его отсутствие
    /// не должно приводить к тому, что человек читает «**жирный**» решётками.
    static func blocks(from text: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var code: [String]?

        for rawLine in text.replacingOccurrences(of: "\r", with: "").split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Ограждение кода собирается целиком: внутри разметку разбирать нельзя.
            if trimmed.hasPrefix("```") {
                if let collected = code {
                    result.append(.code(collected.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }

            guard !trimmed.isEmpty else { continue }

            if let level = headingLevel(of: trimmed) {
                let title = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty {
                    result.append(.heading(title, level: level))
                    continue
                }
            }
            if trimmed.hasPrefix("> ") {
                result.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }
            if let item = listItem(in: trimmed) {
                result.append(.bullet(item))
                continue
            }
            if let (number, item) = numberedItem(in: trimmed) {
                result.append(.numbered(item, number: number))
                continue
            }
            // Разделитель `---` в ответе модели рисовать нечем и незачем.
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), trimmed.count >= 3 {
                continue
            }
            result.append(.paragraph(trimmed))
        }

        if let collected = code, !collected.isEmpty {
            // Ограждение не закрылось — текст всё равно надо показать.
            result.append(.code(collected.joined(separator: "\n")))
        }
        return result
    }

    private static func headingLevel(of line: String) -> Int? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        return level
    }

    private static func listItem(in line: String) -> String? {
        for marker in ["- ", "* ", "• ", "+ "] where line.hasPrefix(marker) {
            var item = String(line.dropFirst(marker.count))
            // Чекбокс из ответа модели показываем как обычный пункт: отмечать его нечем.
            for box in ["[ ] ", "[x] ", "[X] "] where item.hasPrefix(box) {
                item = String(item.dropFirst(box.count))
            }
            return item.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedItem(in line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let item = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty else { return nil }
        return (String(digits), item)
    }

    /// Строчная разметка — системой. `**жирный**`, `` `код` ``, ссылки и курсив
    /// она разбирает сама; на непонятной строке возвращаем её как есть.
    static func inline(_ text: String) -> AttributedString {
        // Чекбокс посреди строки Markdown разбирает как пустую ссылку и рисует
        // серым квадратом. Заменяем его на настоящий знак.
        var source = text
        for (box, glyph) in [("`[ ]`", "☐"), ("`[x]`", "☑"), ("[ ]", "☐"), ("[x]", "☑"), ("[X]", "☑")] {
            source = source.replacingOccurrences(of: box, with: glyph)
        }
        return (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}

/// Ответ модели с разметкой. Отдельная View, потому что тем же занят и текст выжимки.
struct MarkdownText: View {
    let text: String
    var font: Font = LoriFont.bubble

    private var blocks: [MarkdownBlock] { MarkdownBlock.blocks(from: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case let .heading(value, level):
                    Text(MarkdownBlock.inline(value))
                        .font(level <= 2 ? LoriFont.cardTitle : LoriFont.control)
                        .foregroundStyle(LoriPalette.ink)
                        .padding(.top, 4)
                case let .bullet(value):
                    row(marker: "•", value)
                case let .numbered(value, number):
                    row(marker: "\(number).", value)
                case let .quote(value):
                    Text(MarkdownBlock.inline(value))
                        .font(font)
                        .foregroundStyle(LoriPalette.muted)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(LoriPalette.line)
                                .frame(width: 2)
                        }
                case let .code(value):
                    ScrollView(.horizontal) {
                        Text(value)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(LoriPalette.ink)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                    .scrollIndicators(.hidden)
                    .background(LoriPalette.bubble, in: RoundedRectangle(cornerRadius: 12))
                case let .paragraph(value):
                    Text(MarkdownBlock.inline(value))
                        .font(font)
                        .foregroundStyle(LoriPalette.ink)
                        .lineSpacing(4)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(marker: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(font)
                .foregroundStyle(LoriPalette.lime)
                .frame(minWidth: 14, alignment: .trailing)
            Text(MarkdownBlock.inline(value))
                .font(font)
                .foregroundStyle(LoriPalette.ink)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
