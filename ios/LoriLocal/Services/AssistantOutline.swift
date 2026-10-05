import Foundation

/// Оглавление охвата: строка на каждую запись.
///
/// Идёт в контекст **всегда**, в том числе когда текст самой записи в него не
/// поместился. Без оглавления «в записях этого нет» — не вывод из архива, а
/// следствие того, что модели показали выборку и не сказали об этом. С ним
/// модель видит весь список и может назвать запись, текст которой ей нужен.
enum AssistantOutline {
    /// Сколько знаков расшифровки идёт в строку, если своего описания у записи
    /// нет. Хватает, чтобы понять, о чём разговор, и не хватает, чтобы подменить
    /// собой текст: подменять его — задача самих фрагментов.
    static let headCharacters = 180

    /// Оглавление по источникам. `included` — пути записей, тексты которых в
    /// контекст вошли: модель должна различать «про это не говорили» и «текст
    /// этой записи тебе не показали».
    static func records(
        for sources: [AssistantSource],
        documents: [TranscriptDocument],
        included: Set<String>
    ) -> [ContextSnapshot.Record] {
        sources.enumerated().map { index, source in
            let document = index < documents.count ? documents[index] : TranscriptDocument.parse(source.markdown)
            let detail = source.detail.flatMap { $0.isEmpty ? nil : $0 }
                ?? TranscriptTitle.shortened(document.plainText, limit: headCharacters, ellipsis: true)
            return ContextSnapshot.Record(
                number: index + 1,
                path: source.path,
                title: source.title,
                date: source.date,
                topic: source.topic.flatMap { $0.isEmpty ? nil : $0 },
                detail: detail.isEmpty ? nil : detail,
                characters: source.markdown.count,
                // Длительность берётся из последнего таймкода расшифровки, а не
                // из аудио: файл ради одной строки в промпте не открывают, а у
                // движка без таймкодов её и не будет — тогда её просто нет.
                // Именно последнего таймкода, а не последней строки: реплика
                // режется на абзацы, и время стоит только у первого из них.
                seconds: document.lastStamp,
                included: included.contains(source.path)
            )
        }
    }

    /// Текст оглавления для промпта.
    ///
    /// Не влезло в бюджет — сначала уходят описания, потом самые старые записи
    /// целиком, и об этом пишется прямо в оглавлении. Молча укоротить список
    /// нельзя: модель решит, что записи и правда нет.
    static func text(
        _ records: [ContextSnapshot.Record],
        scopeTitle: String,
        budget: Int = AssistantSettings.outlineCharacters
    ) -> String {
        guard !records.isEmpty else { return "" }

        let full = render(records, scopeTitle: scopeTitle, details: true, hidden: 0)
        guard full.count > budget else { return full }

        let short = render(records, scopeTitle: scopeTitle, details: false, hidden: 0)
        guard short.count > budget else { return short }

        // Записи идут от новых к старым, значит обрезаем с конца.
        var kept = records.count
        while kept > 1 {
            kept -= 1
            let hidden = records.count - kept
            let text = render(Array(records.prefix(kept)), scopeTitle: scopeTitle, details: false, hidden: hidden)
            if text.count <= budget { return text }
        }
        return render(Array(records.prefix(1)), scopeTitle: scopeTitle, details: false, hidden: records.count - 1)
    }

    private static func render(
        _ records: [ContextSnapshot.Record],
        scopeTitle: String,
        details: Bool,
        hidden: Int
    ) -> String {
        let count = LoriFormat.plural(records.count + hidden, one: "запись", few: "записи", many: "записей")
        var parts = [
            "Оглавление охвата «\(scopeTitle)» — \(count). Тексты ниже есть не у всех.",
            "",
        ]
        for record in records {
            parts.append(line(of: record))
            if details, let detail = record.detail { parts.append(detail) }
        }
        if hidden > 0 {
            let more = LoriFormat.plural(hidden, one: "запись", few: "записи", many: "записей")
            parts.append("")
            parts.append("Ещё \(more) в оглавление не поместились — они старше перечисленных.")
        }
        return parts.joined(separator: "\n")
    }

    static func line(of record: ContextSnapshot.Record) -> String {
        var parts = ["[\(record.number)] \(stampFormatter.string(from: record.date)) · \(record.title)"]
        if let topic = record.topic { parts.append("тема: \(topic)") }
        if let seconds = record.seconds { parts.append(TranscriptSegment.stamp(seconds)) }
        parts.append(record.included ? "текст ниже" : "текста нет")
        return parts.joined(separator: " · ")
    }

    /// Дата абсолютная: `LoriFormat.stamp` для сегодняшней записи даёт одно
    /// время, и модель не отличит её от прошлогодней.
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = LoriFormat.locale
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        return formatter
    }()
}
