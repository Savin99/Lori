import XCTest
@testable import LoriLocal

final class WikiTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "LoriWikiTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    @MainActor
    private func workspace() -> WorkspaceStore {
        let store = WorkspaceStore(rootURL: temporaryRoot)
        store.start()
        return store
    }

    func testHeadingWinsOverFilename() {
        let entry = WorkspaceEntry(relativePath: "Работа/note.md", isDirectory: false, size: 0, modifiedAt: .now)
        let withHeading = WikiIndex.note(at: entry, text: "# Планёрка\n\nтекст")
        let withoutHeading = WikiIndex.note(at: entry, text: "просто текст")

        XCTAssertEqual(withHeading.title, "Планёрка")
        XCTAssertEqual(withoutHeading.title, "note")
        XCTAssertEqual(withHeading.theme, "Работа")
    }

    func testNoteInRootHasNoTheme() {
        let entry = WorkspaceEntry(relativePath: "Мысли.md", isDirectory: false, size: 0, modifiedAt: .now)
        XCTAssertNil(WikiIndex.note(at: entry, text: "текст").theme)
    }

    func testTagsComeFromFrontMatterAndText() {
        let entry = WorkspaceEntry(relativePath: "Работа/n.md", isDirectory: false, size: 0, modifiedAt: .now)
        let digest = NoteDigest(
            title: "Планёрка",
            theme: "Работа",
            summary: "Итог.",
            highlights: ["Пункт про #оффер и #Найм"],
            decisions: [],
            tasks: [],
            tags: ["планёрка"]
        )
        let text = digest.markdown(audioPath: nil, transcriptPath: nil, created: .now)

        let note = WikiIndex.note(at: entry, text: text)

        XCTAssertEqual(note.tags, ["планёрка", "оффер", "найм"])
        // Заголовок раздела «## Важное» тегом быть не должен.
        XCTAssertFalse(note.tags.contains(""))
        XCTAssertFalse(note.tags.contains("важное"))
    }

    func testLinksAreParsedAndDeduplicated() {
        let entry = WorkspaceEntry(relativePath: "n.md", isDirectory: false, size: 0, modifiedAt: .now)
        let note = WikiIndex.note(
            at: entry,
            text: "См. [[Планёрка по найму]] и [[Оффер]], ещё раз [[планёрка по найму]]."
        )

        XCTAssertEqual(note.links, ["Планёрка по найму", "Оффер"])
    }

    @MainActor
    func testBacklinksAndUnresolvedLinks() throws {
        let store = workspace()
        try store.writeText("# Планёрка по найму\n\nОффер до пятницы.\n", at: "Работа/Планёрка по найму.md")
        try store.writeText("# Итоги недели\n\nСм. [[Планёрка по найму]] и [[Отпуск]].\n", at: "Работа/Итоги.md")

        let index = WikiIndex.build(store)
        let target = try XCTUnwrap(index.note(at: "Работа/Планёрка по найму.md"))
        let source = try XCTUnwrap(index.note(at: "Работа/Итоги.md"))

        XCTAssertEqual(index.backlinks(to: target).map(\.title), ["Итоги недели"])
        XCTAssertTrue(index.backlinks(to: source).isEmpty)
        // Ссылка на несуществующую заметку — это будущая тема, а не ошибка.
        XCTAssertEqual(index.unresolvedLinks(from: source), ["Отпуск"])
    }

    @MainActor
    func testLinkResolvesByFilenameToo() throws {
        let store = workspace()
        try store.writeText("текст без заголовка\n", at: "Личное/Отпуск.md")
        let index = WikiIndex.build(store)

        XCTAssertEqual(index.resolve(link: "Отпуск")?.path, "Личное/Отпуск.md")
        XCTAssertEqual(index.resolve(link: "отпуск")?.path, "Личное/Отпуск.md")
        XCTAssertNil(index.resolve(link: "Оффер"))
    }

    @MainActor
    func testThemesSkipAppFoldersAndSortByCount() throws {
        let store = workspace()
        try store.writeText("# A\n", at: "Работа/A.md")
        try store.writeText("# B\n", at: "Работа/B.md")
        try store.writeText("# C\n", at: "Личное/C.md")
        // Служебные папки приложения темой не считаются.
        try store.writeText("# T\n", at: "Transcripts/T.md")

        let index = WikiIndex.build(store)

        XCTAssertEqual(index.themes.map(\.name), ["Работа", "Личное"])
        XCTAssertEqual(index.themes.first?.count, 2)
        // Дословные расшифровки в вики не попадают вовсе: это сырьё,
        // а знание — обработанная заметка, которая на них ссылается.
        XCTAssertEqual(index.notes.count, 3)
        XCTAssertFalse(index.notes.contains { $0.path.hasPrefix("Transcripts/") })
    }

    @MainActor
    func testTopicToolsAnswerWithThemesAndPaths() throws {
        let store = workspace()
        try store.writeText("# Планёрка\n\n#найм\n", at: "Работа/Планёрка.md")

        let topics = BrainTools.execute(
            named: "list_topics",
            arguments: "{}",
            workspace: store,
            allowMemory: false
        )
        XCTAssertEqual(topics?.contains("Работа — 1 заметка"), true)
        XCTAssertEqual(topics?.contains("#найм — 1 заметка"), true)

        // Один инструмент отвечает и про папку, и про тег: человек называет «темой» и то и то.
        let byTheme = BrainTools.execute(
            named: "topic_notes",
            arguments: "{\"topic\": \"Работа\"}",
            workspace: store,
            allowMemory: false
        )
        let byTag = BrainTools.execute(
            named: "topic_notes",
            arguments: "{\"topic\": \"#найм\"}",
            workspace: store,
            allowMemory: false
        )

        XCTAssertEqual(byTheme?.contains("Работа/Планёрка.md"), true)
        XCTAssertEqual(byTag?.contains("Работа/Планёрка.md"), true)
        XCTAssertEqual(
            BrainTools.execute(
                named: "topic_notes",
                arguments: "{\"topic\": \"Вертолёты\"}",
                workspace: store,
                allowMemory: false
            )?.contains("заметок нет"),
            true
        )
    }
}
