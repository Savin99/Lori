import XCTest
@testable import LoriLocal

final class ReportMarkdownTests: XCTestCase {
    func testBulletedNumberedAndNestedListsSeparateMarkersFromInlineMarkdown() {
        let rows = ReportMarkdown.rows("# Отчёт\n\n- **Главное**\n  + Вложенный\n    3. Третий\n\t* Ещё\n2) Второй\nОбычный текст\n---")
        XCTAssertEqual(rows.map(\.text), ["Отчёт", "**Главное**", "Вложенный", "Третий", "Ещё", "Второй", "Обычный текст", "---"])
        XCTAssertEqual(rows.map(\.marker), [nil, "•", "•", "3.", "•", "2)", nil, nil])
        XCTAssertEqual(rows.map(\.indent), [0, 0, 2, 4, 4, 0, 0, 0])
        XCTAssertTrue(rows[0].heading)
    }
    func testOnlyDiscussionLeadingTimeBecomesAChip() {
        let rows = ReportMarkdown.rows("## Суть\n[00:42] просто текст\n## Ход обсуждения\n- [00:42] Первая тема\n2. [65:03] Длинная запись\n[4:15] Вторая тема\n- [00:99] Невалидные секунды\n- Время внутри [00:10] текста\n## Решения\n- [00:42] уже другой раздел")
        XCTAssertEqual(rows.compactMap(\.timestamp), [42, 3903, 255])
        XCTAssertEqual(rows[3].text, "Первая тема")
        XCTAssertEqual(rows[6].text, "[00:99] Невалидные секунды")
        XCTAssertEqual(rows.last?.text, "[00:42] уже другой раздел")
        XCTAssertNil(ReportMarkdown.rows("## Ход обсуждения\n- Нет меток").last?.timestamp)
    }

    func testReportInputKeepsOnlyRealTimesAndSpeakerNames() {
        let document = TranscriptDocument.parse("**[0:42–1:00]** S1: Первая тема\n**[кусок 1:00–5:00]** S2: Примерное время\nS1: Без времени")
        XCTAssertEqual(document.reportText(names: ["S1": "Анна"]), "[00:42] Анна: Первая тема\nS2: Примерное время\nАнна: Без времени")
        XCTAssertFalse(document.plainText.contains("00:42"), "annotate по-прежнему получает очищенный текст")
    }

    func testSpeechShareUsesDurationsAndDoesNotInventMissingBounds() {
        let document = TranscriptDocument.parse("**[0:00–0:30]** S1: Длинная\n**[0:30–0:35]** S2: Короткая\n**[0:40–0:45]** S2: Ещё")
        XCTAssertEqual(document.speechShares["S1"], 0.75)
        XCTAssertEqual(document.speechShares["S2"], 0.25)
        XCTAssertTrue(TranscriptDocument.parse("**[0:00]** S1: Без конца").speechShares.isEmpty)
        XCTAssertTrue(TranscriptDocument.parse("**[кусок 0:00–5:00]** S1: Примерно").speechShares.isEmpty)
    }

    @MainActor func testCurrentTabExportAndCopyDoNotMixContents() {
        let summary = RecordingSummary(brief: "Суть встречи", highlights: [], decisions: ["Решили"], tasks: [.init(text: "Проверить", owner: "Анна", due: "завтра")], openQuestions: [])
        let entry = RecordingSummaryStore.Entry(summary: summary, fingerprint: "fixture", createdAt: .now, source: "gateway", stale: false, completedTasks: ["Проверить"])
        let document = TranscriptDocument.parse("**[0:00–0:10]** S1: Секрет расшифровки")
        let contents: [RecordingContent] = [.summary(entry), .report("# Отчёт\n\nТекст отчёта"), .transcript(document)]
        let exports = contents.map { $0.export(title: "Встреча", recordedAt: .now, duration: 10, topic: nil, names: ["S1": "Анна"]) }
        XCTAssertTrue(exports[0].markdown.contains("- [x] Проверить — Анна, завтра"))
        XCTAssertFalse(exports[0].markdown.contains("Секрет расшифровки"))
        XCTAssertFalse(exports[0].markdown.contains("Текст отчёта"))
        XCTAssertEqual(exports[1].markdown, "# Отчёт\n\nТекст отчёта")
        XCTAssertTrue(exports[2].markdown.contains("Анна: Секрет расшифровки"))
        XCTAssertFalse(exports[2].markdown.contains("Суть встречи"))
        XCTAssertEqual(contents[2].copiedText(names: ["S1": "Анна"]), "Анна: Секрет расшифровки")
        for item in exports { XCTAssertGreaterThan(TranscriptPDF.data(for: item).count, 500) }
    }

    @MainActor func testPlayingLineChangesOnlyWithinActualSpeech() {
        let cursor = TranscriptPlaybackCursor()
        cursor.configure(TranscriptDocument.parse("**[0:00–0:10]** S1: Один\n**[0:20–0:30]** S2: Два\n**[кусок 0:30–1:00]** S1: Примерно").lines)
        cursor.update(position: 5, playing: true); XCTAssertEqual(cursor.activeLineID, 0)
        cursor.update(position: 15, playing: true); XCTAssertNil(cursor.activeLineID)
        cursor.update(position: 20, playing: true); XCTAssertEqual(cursor.activeLineID, 1)
        cursor.update(position: 25, playing: false); XCTAssertNil(cursor.activeLineID)
        cursor.update(position: 40, playing: true); XCTAssertNil(cursor.activeLineID)
    }
}
