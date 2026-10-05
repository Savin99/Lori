import Foundation

/// Расшифровка, готовая уйти наружу файлом.
///
/// Раньше «Поделиться» отдавало системному листу голую строку, и получатель
/// вставлял её текстом в тело сообщения — вместе с разметкой Markdown, которая
/// без Lori читается как мусор: `**[0:00–0:12]** S1: …`. Файл с расширением
/// снимает это целиком: тип и кодировку получатель больше не угадывает, а имя
/// файла человек видит до того, как его откроет.
///
/// Модель нарочно не знает ни про UIKit, ни про сторы: имена говорящих, тема и
/// описание приходят готовыми значениями, поэтому её можно целиком проверить
/// тестами.
struct TranscriptExport: Sendable {
    /// Абзац расшифровки — то же, что строка на экране записи, но метка
    /// говорящего уже заменена именем: снаружи приложения кружков нет.
    struct Block: Sendable, Equatable {
        let start: TimeInterval?
        let end: TimeInterval?
        /// Время — границы отправленного куска, а не реплики. Пометка обязана
        /// доехать до файла: выдать границы куска за таймкод речи значит соврать.
        let isApproximate: Bool
        let speaker: String?
        let text: String

        /// «0:12», «0:12–0:34» — как в файле расшифровки.
        var range: String? {
            guard let start else { return nil }
            let from = TranscriptSegment.stamp(start)
            guard let end, end > start else { return from }
            return "\(from)–\(TranscriptSegment.stamp(end))"
        }

        /// Время с пометкой куска: «кусок 0:00–5:00».
        var markedRange: String? {
            guard let range else { return nil }
            return isApproximate ? "кусок \(range)" : range
        }
    }

    let title: String
    let recordedAt: Date
    let duration: TimeInterval?
    /// Описание записи, придуманное моделью заголовков.
    let detail: String?
    let topic: String?
    /// Полное имя движка, как оно записано в файле расшифровки.
    let engine: String?
    var mode: String? = nil
    /// Замечания к расшифровке: пропущенные участки и срывы. В файл идут
    /// обязательно — человек, получивший расшифровку, должен знать о дырах.
    let warnings: [String]
    let blocks: [Block]

    var isEmpty: Bool { blocks.isEmpty }

    /// Строка под заголовком: «27 августа 2026, 22:22 · 41:12 · тема: Работа».
    var meta: String {
        var parts = [Self.stampFormatter.string(from: recordedAt)]
        if let duration, duration > 0 { parts.append(TranscriptSegment.stamp(duration)) }
        if let topic, !topic.isEmpty { parts.append("тема: \(topic)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Сборка

    static func make(
        document: TranscriptDocument,
        title: String,
        recordedAt: Date,
        duration: TimeInterval? = nil,
        detail: String? = nil,
        topic: String? = nil,
        names: [String: String] = [:]
    ) -> TranscriptExport {
        TranscriptExport(
            title: title,
            recordedAt: recordedAt,
            // Длительность знает плеер, а он не всегда загружен. Тогда берём
            // последнее настоящее время из расшифровки — оно короче записи, но
            // это измеренное число, а не выдуманное.
            duration: (duration ?? 0) > 0 ? duration : document.lastStamp,
            detail: detail,
            topic: topic,
            engine: document.engine,
            mode: document.mode,
            warnings: document.warnings,
            blocks: document.lines.map { line in
                Block(
                    start: line.start,
                    end: line.end,
                    isApproximate: line.isApproximate,
                    speaker: line.speaker.map { names[$0] ?? $0 },
                    text: line.text
                )
            }
        )
    }

    /// Вход из списка записей: там расшифровка ещё не разобрана, на руках
    /// только текст файла.
    static func make(
        markdown: String,
        title: String,
        recordedAt: Date,
        duration: TimeInterval? = nil,
        detail: String? = nil,
        topic: String? = nil,
        names: [String: String] = [:]
    ) -> TranscriptExport {
        make(
            document: TranscriptDocument.parse(markdown),
            title: title,
            recordedAt: recordedAt,
            duration: duration,
            detail: detail,
            topic: topic,
            names: names
        )
    }

    // MARK: - Markdown

    /// Тот же костяк, что пишет `Transcript.markdown` в файл расшифровки, плюс
    /// то, чего в файле нет: дата, длительность, тема и описание записи. Файл —
    /// это текст записи, а экспорт человек читает отдельно от приложения, и
    /// шапка ему нужна.
    var markdown: String {
        var parts = ["# \(title)", "_\(meta)_"]
        if let detail, !detail.isEmpty { parts.append(detail) }
        if let engine, !engine.isEmpty { parts.append("_Расшифровано: \(engine)_") }
        if let mode, !mode.isEmpty { parts.append("_Режим: \(mode)_") }
        if !warnings.isEmpty { parts.append(warnings.map { "> \($0)" }.joined(separator: "\n")) }
        parts.append(contentsOf: blocks.map(Self.markdownBlock))
        return parts.joined(separator: "\n\n") + "\n"
    }

    private static func markdownBlock(_ block: Block) -> String {
        let text = block.speaker.map { "\($0): \(block.text)" } ?? block.text
        guard let range = block.markedRange else { return text }
        return "**[\(range)]** \(text)"
    }

    // MARK: - Имя файла

    func filename(for format: TranscriptExportFormat) -> String {
        "\(Self.safeName(title)).\(format.fileExtension)"
    }

    /// Имя файла видит получатель, поэтому берём заголовок записи, а не
    /// служебное `lori-20260904-slug`. Двоеточие из «Запись 22:22» и слэши
    /// файловая система не примет.
    static func safeName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        let clean = title.components(separatedBy: forbidden)
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let cut = String(clean.prefix(60)).trimmingCharacters(in: .whitespaces)
        // Точка первым знаком делает файл скрытым, пустое имя — безымянным.
        return cut.isEmpty || cut.hasPrefix(".") ? "Расшифровка" : cut
    }

    /// Дата абсолютная: `LoriFormat.stamp` для сегодняшней записи даёт одно
    /// время, а файл переживёт этот день.
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = LoriFormat.locale
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        return formatter
    }()
}

/// Формат экспорта. Формулировки те же, что в веб-интерфейсе Lori: продукт один,
/// и «Markdown (.md)» на телефоне не должен называться иначе, чем на Маке.
enum TranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case pdf
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .markdown: "Markdown (.md)"
        }
    }

    var note: String {
        switch self {
        case .pdf: "Удобно читать и отправлять"
        case .markdown: "Текст для дальнейшей работы"
        }
    }

    var icon: String {
        switch self {
        case .pdf: "doc.richtext"
        case .markdown: "doc.plaintext"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .markdown: "md"
        }
    }
}

extension TranscriptExport {
    /// Файл для листа «Поделиться». PDF считается вне главного актора: часовая
    /// расшифровка — это десятки страниц вёрстки, и кнопка не должна на них
    /// подвисать.
    func file(as format: TranscriptExportFormat) async throws -> URL {
        let name = filename(for: format)
        switch format {
        case .markdown:
            return try TranscriptExportFile.write(Data(markdown.utf8), name: name)
        case .pdf:
            let export = self
            let data = await Task.detached(priority: .userInitiated) {
                TranscriptPDF.data(for: export)
            }.value
            return try TranscriptExportFile.write(data, name: name)
        }
    }
}

/// Куда ложится экспорт.
enum TranscriptExportFile {
    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "LoriExport", directoryHint: .isDirectory)
    }

    /// Папка чистится **перед** записью, а не после закрытия листа: часть
    /// получателей — «Сохранить в Файлы», например — читает файл уже после
    /// того, как лист закрылся, и уборка «на выходе» выдёргивала бы файл
    /// из-под них. Рабочая папка для экспорта не годится вовсе: она видна
    /// в «Файлах», и служебные копии там были бы мусором рядом с записями.
    static func write(_ data: Data, name: String) throws -> URL {
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
