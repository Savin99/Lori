import Foundation

/// Разобранный файл расшифровки.
///
/// На экране записи нужен не сырой Markdown, а строки с временем: по тапу
/// плеер перематывается на нужное место, и это точнее любых «минус пятнадцать секунд».
struct TranscriptDocument: Equatable, Sendable {
    struct Line: Identifiable, Equatable, Sendable {
        let id: Int
        /// Время начала реплики. nil — у движка таймкодов нет.
        let start: TimeInterval?
        /// Конец реплики. Экрану он не нужен — перематывают по началу, — но в
        /// файле расшифровки стоит диапазон, и экспорт без конца был бы беднее
        /// того файла, из которого его собрали.
        let end: TimeInterval?
        let text: String
        /// Время — границы куска аудио, а не реплики: в интерфейсе помечается «≈».
        let isApproximate: Bool
        /// Метка говорящего («S1»), если реплика с ней. В `text` метки уже нет:
        /// на экране она рисуется отдельным цветным кружком, а не текстом.
        let speaker: String?

        init(
            id: Int,
            start: TimeInterval?,
            end: TimeInterval? = nil,
            text: String,
            isApproximate: Bool,
            speaker: String? = nil
        ) {
            self.id = id
            self.start = start
            self.end = end
            self.text = text
            self.isApproximate = isApproximate
            self.speaker = speaker
        }
    }

    let engine: String?
    var mode: String? = nil
    /// Замечания из файла: например, про пропущенные участки записи.
    let warnings: [String]
    let lines: [Line]

    /// Текст для экспорта и «Скопировать»: метки говорящих возвращаются в текст,
    /// снаружи приложения кружков нет.
    var plain: String {
        lines
            .map { line in line.speaker.map { "\($0): \(line.text)" } ?? line.text }
            .joined(separator: "\n\n")
    }

    var isEmpty: Bool { lines.isEmpty }

    /// Короткое имя движка для экрана: всё до первой запятой.
    ///
    /// В файле лежит полное имя вида «GigaAM v3 CTC (int8), на этом iPhone» — вторая
    /// половина повторяет иконку локальности, которая стоит рядом, и в строке она
    /// только съедает место.
    var engineShort: String? {
        guard let engine, !engine.isEmpty else { return nil }
        let head = engine.split(separator: ",").first.map(String.init) ?? engine
        let clean = head.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : clean
    }

    var processingLabel: String? {
        guard let name = engineShort else { return nil }
        return mode.map { name + " · " + $0 } ?? name
    }

    /// Оставалась ли запись на телефоне. Разбирается по хвосту имени, и это надёжно:
    /// строку писали мы сами (`Transcribing.name`), а у локальных движков хвост —
    /// «на этом iPhone» или «на устройстве». nil — движок неизвестен, и тогда честнее
    /// не рисовать иконку вовсе, чем угадать не ту: спутать облако с телефоном здесь
    /// значит соврать про то, уходила ли запись наружу.
    var engineStayedOnDevice: Bool? {
        guard let engine, !engine.isEmpty else { return nil }
        let lowered = engine.lowercased()
        if lowered.contains("iphone") || lowered.contains("устройстве") { return true }
        if lowered.contains("openai") || lowered.contains("gemini") || lowered.contains("api") || lowered.contains("elevenlabs") { return false }
        return nil
    }

    /// Текст расшифровки без таймкодов, меток и служебных строк — то, что читает
    /// модель заголовков.
    var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// Метка говорящего в начале реплики: «S1: …», в старых файлах — «Г1: …».
    /// Возвращает метку (всегда в латинском виде) и текст без неё.
    static func speakerMark(in text: String) -> (label: String, rest: String)? {
        guard let range = text.range(of: "^[SГ]\\d+:\\s*", options: .regularExpression) else { return nil }
        let label = text[range]
            .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            .replacingOccurrences(of: "Г", with: "S")
        let rest = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (label, rest)
    }

    static let empty = TranscriptDocument(engine: nil, warnings: [], lines: [])

    static func parse(_ markdown: String) -> TranscriptDocument {
        var engine: String?
        var mode: String?
        var warnings: [String] = []
        var lines: [Line] = []

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("_Расшифровано:") {
                let value = line.dropFirst("_Расшифровано:".count)
                engine = String(value.hasSuffix("_") ? value.dropLast() : value)
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("_Режим:"), line.hasSuffix("_") {
                mode = String(line.dropFirst("_Режим:".count).dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix(">") {
                warnings.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if let stamped = stamped(line) {
                let mark = speakerMark(in: stamped.text)
                let text = mark?.rest ?? stamped.text
                // Реплика со временем тоже бывает стеной: у Gemini в «Точности»
                // одна реплика — это целая отправленная часть, десять минут речи.
                let blocks = mark == nil ? paragraphs(of: text) : [text]
                for (offset, block) in blocks.enumerated() {
                    lines.append(Line(
                        id: lines.count,
                        // Время стоит только у первого абзаца. Оно принадлежит
                        // реплике целиком, а расставить секунды абзацам по доле
                        // знаков — значит назвать время, которого не измеряли.
                        start: offset == 0 ? stamped.start : nil,
                        end: offset == 0 ? stamped.end : nil,
                        text: block,
                        isApproximate: stamped.isApproximate,
                        speaker: mark?.label
                    ))
                }
            } else {
                let mark = speakerMark(in: line)
                let text = mark?.rest ?? line
                // Реплику с меткой говорящего не трогаем: она и так короткая,
                // а разрез посреди чужих слов превратил бы одного человека в двух.
                let blocks = mark == nil ? paragraphs(of: text) : [text]
                for block in blocks {
                    lines.append(Line(
                        id: lines.count,
                        start: nil,
                        text: block,
                        isApproximate: false,
                        speaker: mark?.label
                    ))
                }
            }
        }
        return TranscriptDocument(engine: engine, mode: mode, warnings: warnings, lines: lines)
    }

    /// Длина абзаца, после которой текст режется дальше.
    ///
    /// Движок без таймкодов возвращает расшифровку одним куском, и на экране
    /// это сплошная простыня в несколько экранов высотой: глаз теряет строку,
    /// а вернуться к нужному месту нечем — таймкодов-то нет. Абзацы не дают
    /// точности, но дают за что зацепиться.
    static let paragraphLimit = 320

    /// Режем по границам предложений, а не по числу знаков: обрыв посреди
    /// фразы читается как ошибка распознавания, хотя это всего лишь вёрстка.
    static func paragraphs(of text: String) -> [String] {
        guard text.count > paragraphLimit else { return [text] }

        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { part, _, _, _ in
            if let part, !part.isEmpty { sentences.append(part) }
        }
        guard sentences.count > 1 else { return [text] }

        var blocks: [String] = []
        var current = ""
        for sentence in sentences {
            if !current.isEmpty, current.count + sentence.count > paragraphLimit {
                blocks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            current += sentence
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { blocks.append(tail) }
        return blocks.isEmpty ? [text] : blocks
    }

    /// Последнее время в расшифровке — по нему меряют длительность записи,
    /// когда открывать аудио ради одной строки незачем.
    ///
    /// Не `lines.last?.start`: реплика режется на абзацы, время стоит только у
    /// первого из них, и последняя строка почти всегда без времени. Берётся
    /// последнее настоящее.
    var lastStamp: TimeInterval? {
        lines.compactMap(\.start).last
    }

    /// Есть ли в расшифровке хоть одно время. Нет — экран объясняет почему,
    /// а не оставляет человека гадать, куда делась перемотка по тапу.
    var hasTimecodes: Bool {
        lines.contains { $0.start != nil }
    }

    /// Реплика вида `**[0:34–1:12]** текст`, как её пишет `Transcript.markdown`.
    private static func stamped(
        _ line: String
    ) -> (start: TimeInterval, end: TimeInterval?, text: String, isApproximate: Bool)? {
        guard line.hasPrefix("**["), let close = line.range(of: "]**") else { return nil }
        var inside = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
        let isApproximate = inside.hasPrefix("кусок")
        if isApproximate {
            inside = inside.replacingOccurrences(of: "кусок", with: "").trimmingCharacters(in: .whitespaces)
        }
        let bounds = inside.split(whereSeparator: { $0 == "–" || $0 == "-" }).map(String.init)
        guard let seconds = Self.seconds(inBound: bounds.first ?? inside) else { return nil }
        let text = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        // Конца может не быть вовсе: в старых файлах и у части движков стоит
        // одно время, а не диапазон. Тогда честнее ничего, чем начало дважды.
        let end = bounds.count > 1 ? Self.seconds(inBound: bounds[1]) : nil
        return (seconds, end.map { max($0, seconds) }, text, isApproximate)
    }

    /// «1:05:20» → 3920. Часы, минуты и секунды в любом количестве.
    private static func seconds(inBound bound: String) -> TimeInterval? {
        let parts = bound.trimmingCharacters(in: .whitespaces)
            .split(separator: ":")
            .compactMap { TimeInterval($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
