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

    /// Главный экран показывает записи откуда угодно из рабочей папки,
    /// но не сами расшифровки и не корзину.
    @MainActor
    func testAudioListIsRecursiveAndSkipsTranscripts() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        let recordings = temporaryRoot.appending(path: "Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data("звук".utf8).write(to: recordings.appending(path: "Встреча.m4a"))
        try Data("звук".utf8).write(to: temporaryRoot.appending(path: "Принесённое.mp3"))
        try workspace.writeText("# Встреча", at: "Transcripts/Встреча.md")
        try workspace.writeText("не аудио", at: "Recordings/заметка.md")

        try workspace.refresh()

        XCTAssertEqual(
            Set(workspace.audio.map(\.relativePath)),
            ["Recordings/Встреча.m4a", "Принесённое.mp3"]
        )
    }

    /// Расшифровка на запись одна: иначе после трёх попыток разными движками
    /// в папке лежат «Встреча.md», «Встреча 2.md», «Встреча 3.md».
    @MainActor
    func testSaveTranscriptReplacesPreviousRun() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        let audio = temporaryRoot.appending(path: "Встреча.m4a")
        try Data("звук".utf8).write(to: audio)

        let first = try workspace.saveTranscript(Transcript(text: "Первый прогон"), for: audio, engine: "Стаб")
        let second = try workspace.saveTranscript(Transcript(text: "Второй прогон"), for: audio, engine: "Другой стаб")

        XCTAssertEqual(first, "Transcripts/Встреча.md")
        XCTAssertEqual(second, first)
        let saved = try workspace.readText(at: second)
        XCTAssertTrue(saved.contains("Второй прогон"))
        XCTAssertFalse(saved.contains("Первый прогон"))
        XCTAssertTrue(saved.contains("_Расшифровано: Другой стаб_"), "чей это текст, должно быть видно в файле")
        XCTAssertEqual(try workspace.entries(at: "Transcripts").count, 1)
    }

    /// Переименование записи должно двигать и расшифровку: она ищется по имени
    /// аудиофайла, и раньше текст оставался сиротой — на экране он пропадал,
    /// и запись приходилось прогонять заново.
    @MainActor
    func testRenamingRecordingMovesItsTranscript() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        let audio = temporaryRoot.appending(path: "Встреча.m4a")
        try Data("звук".utf8).write(to: audio)
        _ = try workspace.saveTranscript(Transcript(text: "Текст расшифровки."), for: audio, engine: "Стаб")
        try workspace.refresh()

        let renamed = try workspace.renameRecording(at: "Встреча.m4a", toName: "Планёрка.m4a")

        let moved = try workspace.entry(at: renamed)
        let transcript = try XCTUnwrap(
            workspace.existingTranscript(for: moved),
            "текст должен переехать вместе с записью"
        )
        XCTAssertEqual(transcript, "Transcripts/Планёрка.md")
        XCTAssertTrue(try workspace.readText(at: transcript).contains("Текст расшифровки."))
        XCTAssertNil(try? workspace.readText(at: "Transcripts/Встреча.md"), "старого файла не остаётся")
    }

    /// Запись без расшифровки переименовывается как прежде.
    @MainActor
    func testRenamingRecordingWithoutTranscript() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        try Data("звук".utf8).write(to: temporaryRoot.appending(path: "Встреча.m4a"))
        try workspace.refresh()

        let renamed = try workspace.renameRecording(at: "Встреча.m4a", toName: "Без текста.m4a")

        XCTAssertEqual(renamed, "Без текста.m4a")
    }
}
