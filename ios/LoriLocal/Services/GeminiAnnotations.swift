import Foundation

/// Разбор ответа Gemini на расшифровку.
///
/// У модели расшифровки есть нативные тайминги слов: `start_offset`/`end_offset` и,
/// при включённом разделении говорящих, `speaker`. Точное место этих полей в ответе
/// зависит от версии интерфейса, поэтому ответ просматривается целиком: ищем объекты,
/// похожие на слово со временем. Это надёжнее, чем угадывать путь и получить пустоту.
enum GeminiAnnotations {
    struct Word: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let speaker: String?
    }

    /// Все слова с таймингами, какие нашлись в ответе.
    static func words(in json: Any) -> [Word] {
        var found: [Word] = []
        collect(json, into: &found)
        return found.sorted { $0.start < $1.start }
    }

    static func words(from data: Data) -> [Word] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return words(in: json)
    }

    private static func collect(_ node: Any, into found: inout [Word]) {
        if let object = node as? [String: Any] {
            if let word = word(from: object) { found.append(word) }
            for value in object.values { collect(value, into: &found) }
            return
        }
        if let array = node as? [Any] {
            for value in array { collect(value, into: &found) }
        }
    }

    /// Слово — это объект с текстом и началом. Названия полей у разных версий
    /// интерфейса отличаются, поэтому принимаем все встречающиеся варианты.
    private static func word(from object: [String: Any]) -> Word? {
        let textKeys = ["word", "text", "transcript"]
        let startKeys = ["start_offset", "startOffset", "start_seconds", "startSeconds", "start", "startTime"]
        let endKeys = ["end_offset", "endOffset", "end_seconds", "endSeconds", "end", "endTime"]

        guard let text = textKeys.compactMap({ object[$0] as? String }).first,
              !text.trimmingCharacters(in: .whitespaces).isEmpty,
              let start = startKeys.compactMap({ seconds(object[$0]) }).first else { return nil }
        let end = endKeys.compactMap { seconds(object[$0]) }.first ?? start
        let speaker = ["speaker", "speaker_label", "speakerTag", "speaker_tag"]
            .compactMap { value in
                if let text = object[value] as? String { return text }
                if let number = object[value] as? Int { return "S\(number)" }
                return nil
            }
            .first
        return Word(
            start: start,
            end: max(end, start),
            text: text.trimmingCharacters(in: .whitespaces),
            speaker: speaker?.trimmingCharacters(in: .whitespaces)
        )
    }

    /// Время приходит числом, строкой «1.5» или протобуфной «1.500s».
    static func seconds(_ value: Any?) -> TimeInterval? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return TimeInterval(number) }
        guard var text = value as? String else { return nil }
        if text.hasSuffix("s") { text.removeLast() }
        if let plain = TimeInterval(text) { return plain }
        let parts = text.split(separator: ":").compactMap { TimeInterval($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Реплики из слов: подряд идущие слова одного говорящего с короткими паузами.
    /// Метка говорящего приписывается к тексту — в файле расшифровки ей больше негде жить.
    static func segments(from words: [Word], pause: TimeInterval = 0.8, offset: TimeInterval = 0) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var current: [Word] = []

        func flush() {
            defer { current = [] }
            guard let first = current.first, let last = current.last else { return }
            let body = current.map(\.text).joined(separator: " ")
            let speaker = first.speaker.flatMap { $0.isEmpty ? nil : $0 }
            result.append(TranscriptSegment(
                start: first.start + offset,
                end: last.end + offset,
                text: speaker.map { "\(label(for: $0)): \(body)" } ?? body
            ))
        }

        for word in words {
            if let previous = current.last {
                let sameSpeaker = previous.speaker == word.speaker
                if !sameSpeaker || word.start - previous.end >= pause { flush() }
            }
            current.append(word)
            // Конец предложения закрывает реплику: так текст читается абзацами.
            if let last = word.text.last, ".!?…".contains(last) { flush() }
        }
        flush()
        return result
    }
}


extension GeminiAnnotations {
    /// Метка говорящего для текста. Сервис отдаёт то номер («1», «speaker_2»,
    /// живой ответ 28 августа — «spk:0» со счётом с нуля), то имя, если его
    /// подсказали. Номер показываем как «S1» (владелец выбрал латиницу — «Г1»
    /// читалось как мусор), имя — как есть. «Г» принимается ради старых файлов.
    static func label(for speaker: String) -> String {
        let lower = speaker.lowercased()
        let digits = speaker.filter(\.isNumber)
        let letters = speaker.filter { $0.isLetter }
        if lower.hasPrefix("spk"), let number = Int(digits) { return "S\(number + 1)" }
        if !digits.isEmpty, letters.isEmpty || lower.hasPrefix("speaker") || lower.hasPrefix("г") || lower.hasPrefix("s") {
            return "S\(digits)"
        }
        return speaker
    }

    /// Текст расшифровки из ответа, каким бы ни была его форма.
    ///
    /// У интерфейса расшифровки ответ приходит не там же, где у обычной модели:
    /// пустая расшифровка на устройстве получилась именно из-за того, что разбор
    /// искал текст по заранее известному пути. Поэтому ответ просматривается
    /// целиком, а из найденного берётся самое похожее на расшифровку.
    static func text(in json: Any) -> String? {
        var candidates: [String] = []
        harvest(json, into: &candidates)
        guard !candidates.isEmpty else { return nil }
        // Самая длинная строка — это и есть расшифровка: имена моделей, идентификаторы
        // и признаки состояния всегда короче.
        return candidates.max { $0.count < $1.count }
    }

    static func text(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return text(in: json)
    }

    /// Ключи, по которым в ответах лежит собственно текст.
    private static let textKeys = [
        "text", "transcript", "output_text", "outputText", "content", "value", "utterance",
    ]

    private static func harvest(_ node: Any, into found: inout [String]) {
        if let object = node as? [String: Any] {
            for key in textKeys {
                if let value = object[key] as? String, isTranscriptLike(value) {
                    found.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            for value in object.values { harvest(value, into: &found) }
            return
        }
        if let array = node as? [Any] {
            for value in array { harvest(value, into: &found) }
        }
    }

    /// Отсекаем служебные строки: идентификаторы, состояния, имена моделей.
    private static func isTranscriptLike(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return false }
        guard trimmed.contains(" ") else { return false }
        let service = ["ACTIVE", "PROCESSING", "completed", "model_output", "interaction"]
        return !service.contains(where: { trimmed == $0 })
    }
}


extension GeminiAnnotations {
    /// Причина остановки генерации, где бы сервис её ни положил.
    ///
    /// Читать её надо и на **удачном** ответе. `MAX_TOKENS` при непустом тексте —
    /// это расшифровка, оборванная посреди участка: текст выглядит нормальным, а
    /// всё, что шло после обрыва, не пришло. Раньше такой ответ принимался молча и
    /// вылезал потом «пропуском» в середине записи. Форма поля у разных точек
    /// входа своя, поэтому ответ просматривается целиком — как и при поиске слов.
    static func finish(in json: Any) -> String? {
        var found: [String] = []
        collectFinish(json, into: &found)
        // Обрыв важнее штатной остановки: в ответе с несколькими кандидатами
        // хватит одного оборванного, чтобы участок был неполным.
        return found.first(where: { isLengthCut($0) }) ?? found.first
    }

    static func finish(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return finish(in: json)
    }

    /// Остановка по длине ответа, а не по концу речи.
    static func isLengthCut(_ reason: String?) -> Bool {
        guard let reason else { return false }
        let upper = reason.uppercased()
        return upper.contains("MAX_TOKEN") || upper.contains("MAX_OUTPUT") || upper.contains("LENGTH")
    }

    private static let finishKeys = ["finishReason", "finish_reason", "stopReason", "stop_reason"]

    private static func collectFinish(_ node: Any, into found: inout [String]) {
        if let object = node as? [String: Any] {
            for key in finishKeys {
                if let value = object[key] as? String, !value.isEmpty { found.append(value) }
            }
            for value in object.values { collectFinish(value, into: &found) }
            return
        }
        if let array = node as? [Any] {
            for value in array { collectFinish(value, into: &found) }
        }
    }
}
