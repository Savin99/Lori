import Foundation

/// Один выбор для обоих действий панели: экспорт и копирование всегда относятся
/// к открытой вкладке. Пустая вкладка не отдаёт вместо себя расшифровку.
enum RecordingContent {
    case summary(RecordingSummaryStore.Entry)
    case report(String)
    case transcript(TranscriptDocument)

    func copiedText(names: [String: String]) -> String {
        switch self {
        case .summary(let entry):
            let summary = entry.summary
            var parts = ["## Итог"]
            if !summary.brief.isEmpty { parts.append(summary.brief) }
            for section in summary.sections {
                let rows: [String]
                if section.title == "Задачи" {
                    rows = summary.tasks.filter { !$0.text.isEmpty }.map { task in
                        let mark = entry.completedTasks.contains(task.text) ? "x" : " "
                        var named = task
                        named.owner = task.owner.map { names[$0] ?? $0 }
                        return "- [\(mark)] " + named.displayText
                    }
                } else { rows = section.items.map { "- " + $0 } }
                parts.append("### \(section.title)\n\n" + rows.joined(separator: "\n"))
            }
            if entry.stale { parts.append("_Итог устарел: текст расшифровки изменился._") }
            return parts.joined(separator: "\n\n")
        case .report(let markdown): return markdown
        case .transcript(let document):
            return document.lines.map { line in
                line.speaker.map { "\(names[$0] ?? $0): \(line.text)" } ?? line.text
            }.joined(separator: "\n\n")
        }
    }

    func export(title: String, recordedAt: Date, duration: TimeInterval?, topic: String?, names: [String: String]) -> TranscriptExport {
        switch self {
        case .summary:
            return .report(markdown: "# Итог — \(title)\n\n" + copiedText(names: names) + "\n", title: "Итог — " + title, recordedAt: recordedAt)
        case .report(let markdown):
            return .report(markdown: markdown, title: "Отчёт — " + title, recordedAt: recordedAt)
        case .transcript(let document):
            return .make(document: document, title: title, recordedAt: recordedAt, duration: duration, topic: topic, names: names)
        }
    }
}
