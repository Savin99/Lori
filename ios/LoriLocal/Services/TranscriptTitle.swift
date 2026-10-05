import Foundation

/// Заголовок и сниппет карточки из самой расшифровки.
///
/// «Новая запись 48» не говорит ни о чём: чтобы вспомнить запись, приходится её
/// открывать. Название берётся из первых слов текста, а под ним — первые фразы,
/// как в списке писем.
enum TranscriptTitle {
    static let titleLimit = 42
    static let snippetLimit = 120

    /// Текст расшифровки без служебной обвязки: заголовка файла, подписи движка,
    /// предупреждений о пропусках и таймкодов реплик.
    static func plain(from markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") { continue }
            if line.hasPrefix(">") { continue }
            if line.hasPrefix("_Расшифровано:") { continue }
            // Таймкод реплики «**[0:00–0:05]**» в названии не нужен.
            if line.hasPrefix("**["), let close = line.range(of: "]**") {
                line = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            // Метка говорящего «S1:» (в старых файлах «Г1:») — тоже обвязка:
            // заголовок «S1: Здравствуйте» читается как мусор, а сниппету важны
            // слова, а не кто их сказал.
            if let mark = line.range(of: "^[SГ]\\d+:\\s*", options: .regularExpression) {
                line = String(line[mark.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            lines.append(line)
        }
        return lines.joined(separator: " ")
    }

    /// Название: первая фраза, обрезанная по слову. Точка в конце не нужна —
    /// это заголовок, а не предложение.
    static func title(from markdown: String) -> String? {
        let text = plain(from: markdown)
        guard !text.isEmpty else { return nil }

        // Границей считаем конец мысли: точку, вопрос, двоеточие или тире —
        // но только если она не в самом начале, иначе заголовок выйдет из двух слов.
        let sentenceEnd = text.firstIndex { ".!?…:—".contains($0) }
        var candidate = text
        if let sentenceEnd, text.distance(from: text.startIndex, to: sentenceEnd) >= 12 {
            candidate = String(text[text.startIndex..<sentenceEnd])
        }
        return shortened(candidate, limit: titleLimit)
    }

    /// Сниппет: продолжение текста под названием, одна-две строки.
    ///
    /// Именно продолжение, а не начало. Заголовок карточки — это первая фраза
    /// расшифровки, и сниппет, начинающийся оттуда же, дублировал её слово в
    /// слово: «То есть именно така…» сверху и «То есть именно такая внутренняя…»
    /// строкой ниже. Две строки на карточке — слишком дорогое место, чтобы
    /// тратить их на повтор.
    static func snippet(from markdown: String) -> String? {
        let text = plain(from: markdown)
        guard !text.isEmpty else { return nil }

        let rest = continuation(of: text)
        // Вся расшифровка уместилась в заголовок — продолжать нечем, и лучше
        // показать текст ещё раз, чем пустоту.
        return shortened(rest.isEmpty ? text : rest, limit: snippetLimit, ellipsis: true)
    }

    /// Текст с начала — для карточек, у которых заголовок не из расшифровки.
    static func head(from markdown: String) -> String? {
        let text = plain(from: markdown)
        guard !text.isEmpty else { return nil }
        return shortened(text, limit: snippetLimit, ellipsis: true)
    }

    /// Текст после того, что ушло в заголовок.
    static func continuation(of text: String) -> String {
        guard let head = title(from: text) else { return text }
        let clean = head.hasSuffix("…") ? String(head.dropLast()) : head
        guard let range = text.range(of: clean) else { return text }

        var rest = String(text[range.upperBound...])
        // Заголовок обрывается на границе мысли, и продолжение начинается с
        // её знака: «. Дальше…» читается как ошибка вёрстки.
        while let first = rest.first, ".!?…:—,".contains(first) || first.isWhitespace {
            rest.removeFirst()
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Обрезка по границе слова: «Планы по RAG для ОВи…» читается хуже, чем
    /// «Планы по RAG для…».
    static func shortened(_ text: String, limit: Int, ellipsis: Bool = false) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else {
            return clean.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—-"))
        }
        let cut = clean.prefix(limit)
        let word = cut.lastIndex(of: " ").map { String(cut[cut.startIndex..<$0]) } ?? String(cut)
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—-"))
        return ellipsis ? trimmed + "…" : trimmed
    }
}
