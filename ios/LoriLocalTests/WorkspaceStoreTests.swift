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

    // MARK: - Имя записи — это заголовок, который набрал человек

    /// Запись «Встреча.m4a» с расшифровкой в рабочей папке.
    @MainActor
    private func recordWithTranscript(_ name: String = "Встреча", in folder: String = "") throws -> WorkspaceStore {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        let directory = folder.isEmpty ? temporaryRoot! : temporaryRoot.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appending(path: "\(name).m4a")
        try Data("звук".utf8).write(to: audio)
        _ = try workspace.saveTranscript(Transcript(text: "Текст расшифровки."), for: audio, engine: "Стаб")
        try workspace.refresh()
        return workspace
    }

    /// **Регрессия.** Точка в имени («27.08») принималась за расширение: запись
    /// теряла «.m4a» и пропадала из списка, а расшифровка становилась «Совещание 27.md».
    @MainActor
    func testDotInTheNameKeepsTheAudioExtension() throws {
        let workspace = try recordWithTranscript()

        let renamed = try workspace.renameRecording(at: "Встреча.m4a", toName: "Совещание 27.08")

        XCTAssertEqual(renamed, "Совещание 27.08.m4a")
        XCTAssertEqual(workspace.audio.map(\.relativePath), ["Совещание 27.08.m4a"], "запись осталась в списке")
        let moved = try workspace.entry(at: renamed)
        XCTAssertEqual(workspace.existingTranscript(for: moved), "Transcripts/Совещание 27.08.md")
        XCTAssertTrue(try workspace.readText(at: "Transcripts/Совещание 27.08.md").contains("Текст расшифровки."))
    }

    /// Знаки, которые файловая система не примет, в имени файла заменяются, а не
    /// отвергаются: заголовок человек видит ровно таким, как набрал.
    @MainActor
    func testPathCharactersAreReplacedInsteadOfRejected() throws {
        let workspace = try recordWithTranscript(in: "Recordings")

        let renamed = try workspace.renameRecording(at: "Recordings/Встреча.m4a", toName: "Итоги: план/факт")

        XCTAssertEqual(renamed, "Recordings/Итоги- план-факт.m4a", "папка та же, «/» и «:» стали «-»")
        XCTAssertNotNil(try? workspace.readText(at: "Transcripts/Итоги- план-факт.md"), "расшифровка с тем же именем")
    }

    /// Имя, которое уже занято, — понятная ошибка, и обе записи на месте.
    @MainActor
    func testTakenNameIsRefusedInPlainRussian() throws {
        let workspace = try recordWithTranscript("А")
        try Data("звук".utf8).write(to: temporaryRoot.appending(path: "Б.m4a"))
        try workspace.refresh()

        XCTAssertThrowsError(try workspace.renameRecording(at: "Б.m4a", toName: "А")) { error in
            XCTAssertEqual(error as? WorkspaceError, .nameTaken)
            XCTAssertEqual(error.localizedDescription, "Запись с таким именем уже есть")
        }
        XCTAssertEqual(Set(workspace.audio.map(\.relativePath)), ["А.m4a", "Б.m4a"])
    }

    /// Чужая (или осиротевшая) расшифровка с тем же именем тоже занимает имя:
    /// иначе запись без текста молча получила бы чужой.
    @MainActor
    func testNameOfAnExistingTranscriptIsTaken() throws {
        let workspace = WorkspaceStore(rootURL: temporaryRoot)
        workspace.start()
        try workspace.writeText("# Сирота\n\nЧужой текст.", at: "Transcripts/Сирота.md")
        try Data("звук".utf8).write(to: temporaryRoot.appending(path: "Новая.m4a"))
        try workspace.refresh()

        XCTAssertThrowsError(try workspace.renameRecording(at: "Новая.m4a", toName: "Сирота")) { error in
            XCTAssertEqual(error as? WorkspaceError, .nameTaken)
        }
    }

    /// Длинный заголовок режется так, чтобы имя файла и его копия в корзине
    /// (с приставкой UUID) уложились в предел файловой системы — 255 байт.
    @MainActor
    func testLongTitleFitsTheFileSystemLimit() throws {
        let workspace = try recordWithTranscript()
        let long = String(repeating: "Очень длинное название встречи ", count: 12)

        let renamed = try workspace.renameRecording(at: "Встреча.m4a", toName: long)

        let name = (renamed as NSString).lastPathComponent
        XCTAssertTrue(name.hasSuffix(".m4a"))
        XCTAssertLessThanOrEqual(name.utf8.count, RecordTitle.maxFileNameBytes)
        XCTAssertTrue(long.hasPrefix((name as NSString).deletingPathExtension))
        try workspace.moveToTrash(renamed)
    }

    /// Точка в начале сделала бы файл скрытым — запись пропала бы из списка.
    @MainActor
    func testLeadingDotsAreDropped() throws {
        let workspace = try recordWithTranscript()

        let renamed = try workspace.renameRecording(at: "Встреча.m4a", toName: "...и так далее")

        XCTAssertEqual(renamed, "и так далее.m4a")
        XCTAssertEqual(workspace.audio.map(\.relativePath), ["и так далее.m4a"])
    }

    /// Тот же заголовок — ни одного движения файлов.
    @MainActor
    func testSameNameMovesNothing() throws {
        let workspace = try recordWithTranscript()

        XCTAssertEqual(try workspace.renameRecording(at: "Встреча.m4a", toName: " Встреча "), "Встреча.m4a")
        XCTAssertNotNil(try? workspace.readText(at: "Transcripts/Встреча.md"))
    }

    /// Смена одного регистра букв — тоже переименование, а не «имя занято», даже
    /// там, где файловая система регистр не различает (симулятор на Mac).
    @MainActor
    func testChangingOnlyTheCaseWorks() throws {
        let workspace = try recordWithTranscript("встреча")

        let renamed = try workspace.renameRecording(at: "встреча.m4a", toName: "Встреча")

        XCTAssertEqual(renamed, "Встреча.m4a")
        XCTAssertEqual(workspace.audio.map(\.relativePath), ["Встреча.m4a"])
        let moved = try workspace.entry(at: renamed)
        XCTAssertEqual(workspace.existingTranscript(for: moved), "Transcripts/Встреча.md")
    }
}
