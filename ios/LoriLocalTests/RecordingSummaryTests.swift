import PDFKit
import XCTest
@testable import LoriLocal

@MainActor
final class RecordingSummaryTests: XCTestCase {
    private var root: URL!
    static let summary = RecordingSummary(brief: "Обсудили выпуск Лори.", highlights: ["Качество записи"], decisions: [], tasks: ["Анна проверит завтра"], openQuestions: [])
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "recap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: root) }

    func testStoreReloadStalenessMoveAndForget() throws {
        let url = root.appending(path: "recaps.json")
        let store = RecordingSummaryStore(url: url)
        XCTAssertTrue(store.store(Self.summary, for: "a.m4a", fingerprint: "one"))
        let reloaded = RecordingSummaryStore(url: url)
        XCTAssertEqual(reloaded.entry(for: "a.m4a")?.summary, Self.summary)
        XCTAssertEqual(reloaded.entry(for: "a.m4a")?.source, "gateway")
        XCTAssertNotNil(reloaded.entry(for: "a.m4a")?.createdAt)
        reloaded.markStale("a.m4a", fingerprint: "one")
        XCTAssertTrue(reloaded.isUpToDate("a.m4a", fingerprint: "one"))
        reloaded.markStale("a.m4a", fingerprint: "two")
        XCTAssertFalse(reloaded.isUpToDate("a.m4a", fingerprint: "one"))
        reloaded.move(from: "a.m4a", to: "b.m4a")
        XCTAssertNil(reloaded.entry(for: "a.m4a"))
        XCTAssertEqual(reloaded.entry(for: "b.m4a")?.stale, true)
        reloaded.forget("b.m4a")
        XCTAssertTrue(RecordingSummaryStore(url: url).entries.isEmpty)
    }

    func testCorruptFileIsCopiedBeforeAnyWrite() throws {
        let url = root.appending(path: "recaps.json")
        let bytes = Data("{ damaged".utf8)
        try bytes.write(to: url)
        let store = RecordingSummaryStore(url: url)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("corrupt-") })
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertTrue(store.store(Self.summary, for: "a", fingerprint: "one"))
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertEqual(RecordingSummaryStore(url: url).entry(for: "a")?.summary, Self.summary)
    }

    func testSummaryPrecedesTranscriptInBothExportFormatsAndEmptySectionsHide() throws {
        let entry = RecordingSummaryStore.Entry(summary: Self.summary, fingerprint: "one", createdAt: .now, source: "gateway", stale: true)
        let payload = TranscriptExport.make(markdown: "# Запись\n\nТекст расшифровки.", title: "Выпуск", recordedAt: .now, summary: entry)
        XCTAssertTrue(payload.markdown.contains("## Итог"))
        XCTAssertFalse(payload.markdown.contains("### Решения"))
        XCTAssertFalse(payload.markdown.contains("### Открытые вопросы"))
        XCTAssertTrue(payload.markdown.contains("Итог устарел"))
        let summaryRange = try XCTUnwrap(payload.markdown.range(of: "Обсудили выпуск"))
        let transcriptRange = try XCTUnwrap(payload.markdown.range(of: "Текст расшифровки"))
        XCTAssertLessThan(summaryRange.lowerBound, transcriptRange.lowerBound)
        let pdf = try XCTUnwrap(PDFDocument(data: TranscriptPDF.data(for: payload)))
        let text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(text.contains("Анна проверит завтра"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "Обсудили выпуск")).lowerBound,
                          try XCTUnwrap(text.range(of: "Текст расшифровки")).lowerBound)
    }

    func testReportWriteRenameTrashAndCollisionKeepFiles() throws {
        let workspace = WorkspaceStore(rootURL: root)
        try workspace.writeText("звук", at: "a.wav")
        try workspace.writeText("расшифровка", at: "Transcripts/a.md")
        try ReportRunner.write("# Отчёт\n\nИсходный текст.", for: "a.wav", in: workspace)
        XCTAssertEqual(try ReportRunner.read(for: "a.wav", in: workspace), "# Отчёт\n\nИсходный текст.")
        try workspace.writeText("чужой отчёт", at: "Reports/Занято.md")
        XCTAssertThrowsError(try workspace.renameRecording(at: "a.wav", toName: "Занято"))
        XCTAssertEqual(try ReportRunner.read(for: "a.wav", in: workspace), "# Отчёт\n\nИсходный текст.")
        let renamed = try workspace.renameRecording(at: "a.wav", toName: "Проверка")
        XCTAssertEqual(renamed, "Проверка.wav")
        XCTAssertEqual(try ReportRunner.read(for: renamed, in: workspace), "# Отчёт\n\nИсходный текст.")
        XCTAssertThrowsError(try workspace.fileURL(for: "Reports/a.md"))
        try workspace.moveToTrash(renamed)
        XCTAssertThrowsError(try workspace.fileURL(for: "Reports/Проверка.md"))
        let trash = try FileManager.default.contentsOfDirectory(at: root.appending(path: ".LoriTrash"), includingPropertiesForKeys: nil)
        XCTAssertTrue(trash.contains { $0.lastPathComponent.hasSuffix("-Проверка.md") })
        XCTAssertTrue(trash.contains { $0.lastPathComponent.hasSuffix("-Проверка.wav") })
    }

    func testFailedReportDoesNotReplaceExistingFile() async throws {
        let workspace = WorkspaceStore(rootURL: root)
        try workspace.writeText("звук", at: "a.wav")
        try ReportRunner.write("Старый отчёт", for: "a.wav", in: workspace)
        let client = GatewayClient(baseURL: URL(string: "https://stub.invalid")!, token: "fixture", session: StubURLProtocol.session { _, _ in
            .json(#"{"error":{"code":"quota","retryAfter":60}}"#, status: 429)
        })
        let runner = ReportRunner(client: { client })
        runner.generate(path: "a.wav", transcript: "Текст", title: "Запись", workspace: workspace)
        await eventually("ошибка отчёта") { !runner.running.contains("a.wav") }
        XCTAssertNotNil(runner.failures["a.wav"])
        XCTAssertEqual(try ReportRunner.read(for: "a.wav", in: workspace), "Старый отчёт")
        StubURLProtocol.reset()
    }

    func testReportExportPreservesMarkdownAndRussianPDF() throws {
        let markdown = "# Отчёт\n\n## Решения\n\n- Анна проверит качество."
        let payload = TranscriptExport.report(markdown: markdown, title: "Отчёт — Проверка")
        XCTAssertEqual(payload.markdown, markdown)
        let pdf = try XCTUnwrap(PDFDocument(data: TranscriptPDF.data(for: payload)))
        XCTAssertTrue(pdf.string?.contains("Анна проверит качество.") == true)
    }
}
