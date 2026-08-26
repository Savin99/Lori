import XCTest
@testable import LoriLocal

final class WorkspaceStoreTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "LoriWorkspaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    @MainActor
    func testWritesReadsAndListsTextFile() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()

        try workspace.writeText("Привет, Lori", at: "notes/hello.md")

        XCTAssertEqual(try workspace.readText(at: "notes/hello.md"), "Привет, Lori")
        let rootEntries = try workspace.entries(at: "")
        XCTAssertEqual(rootEntries.map(\.relativePath), ["notes"])
        XCTAssertEqual(rootEntries.first?.isDirectory, true)
        XCTAssertEqual(try workspace.entries(at: "notes").map(\.relativePath), ["notes/hello.md"])
    }

    @MainActor
    func testRejectsTraversalOutsideWorkspace() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()

        XCTAssertThrowsError(try workspace.writeText("no", at: "../outside.md")) { error in
            XCTAssertEqual(error as? WorkspaceError, .unsafePath)
        }
    }

    @MainActor
    func testMoveToTrashIsRecoverableMove() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        try workspace.writeText("draft", at: "draft.md")

        try workspace.moveToTrash("draft.md")

        XCTAssertThrowsError(try workspace.readText(at: "draft.md"))
        let trash = temporaryRoot.appending(path: ".LoriTrash", directoryHint: .isDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
    }

    @MainActor
    func testRenameKeepsFolderAndExtension() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        try workspace.writeText("текст", at: "Дела/черновик.md")

        let renamed = try workspace.renameItem(at: "Дела/черновик.md", toName: "План на неделю")

        XCTAssertEqual(renamed, "Дела/План на неделю.md")
        XCTAssertEqual(try workspace.readText(at: renamed), "текст")
    }

    @MainActor
    func testRenameRejectsPathAndHiddenNames() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        try workspace.writeText("текст", at: "заметка.md")

        for badName in ["../побег", "папка/файл", ".скрытый", ""] {
            XCTAssertThrowsError(try workspace.renameItem(at: "заметка.md", toName: badName)) { error in
                XCTAssertEqual(error as? WorkspaceError, .invalidName)
            }
        }
        XCTAssertEqual(try workspace.readText(at: "заметка.md"), "текст")
    }

    @MainActor
    func testNoteFilenameComesFromFirstLine() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()

        let path = try workspace.createNote(content: "# Идеи по Lori\n\nПервая мысль")

        XCTAssertEqual(path, "Идеи по Lori.md")
        XCTAssertEqual(try workspace.readText(at: path), "# Идеи по Lori\n\nПервая мысль")
    }

    @MainActor
    func testNoteFilenameFallsBackToDateAndStaysUnique() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()

        let first = try workspace.createNote(content: "   ")
        let second = try workspace.createNote(content: "")

        XCTAssertTrue(first.hasPrefix("Заметка "), first)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try workspace.entries(at: "").count, 2)
    }

    @MainActor
    func testNoteFilenameNeverBecomesHiddenFile() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()

        let path = try workspace.createNote(content: ".gitignore и прочее")

        XCTAssertFalse(path.hasPrefix("."), path)
        XCTAssertEqual(try workspace.entries(at: "").map(\.relativePath), [path])
    }

    @MainActor
    func testCreatesNamedFolderInsideWorkspace() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()

        let path = try workspace.createFolder(named: "Рудн")

        XCTAssertEqual(path, "Рудн")
        XCTAssertEqual(try workspace.entries(at: "").map(\.relativePath), ["Рудн"])
        XCTAssertThrowsError(try workspace.createFolder(named: "../outside")) { error in
            XCTAssertEqual(error as? WorkspaceError, .invalidFolderName)
        }
    }
}
