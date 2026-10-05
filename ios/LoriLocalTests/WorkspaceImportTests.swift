import XCTest
@testable import LoriLocal

/// Импорт в рабочую папку: имя уникально по базе (расшифровка лежит по базе), дата — момент
/// импорта, копия целиком или никак, неподдерживаемое не копируется.
///
/// Свой файл, а не `WorkspaceStoreTests`: тот — про переименование и чужие правки.
@MainActor
final class WorkspaceImportTests: XCTestCase {
    private let manager = FileManager.default
    private var root: URL!
    private var sources: URL!
    private var workspace: WorkspaceStore!

    override func setUpWithError() throws {
        root = manager.temporaryDirectory.appending(path: "LoriImportWS-\(UUID().uuidString)", directoryHint: .isDirectory)
        sources = manager.temporaryDirectory.appending(path: "LoriImportSrc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: sources, withIntermediateDirectories: true)
        workspace = WorkspaceStore(rootURL: root)
        workspace.start()
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: root)
        try? manager.removeItem(at: sources)
    }

    /// Файл «снаружи», в своей папке: так приходит выбранное в «Файлах».
    @discardableResult
    private func source(_ name: String, bytes: [UInt8] = [1, 2, 3], in folder: String? = nil, modified: Date? = nil) throws -> URL {
        let directory = folder.map { sources.appending(path: $0, directoryHint: .isDirectory) } ?? sources!
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data(bytes).write(to: url)
        if let modified { try manager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    /// Уже лежащее в рабочей папке — запись или расшифровка.
    private func existing(_ relativePath: String) throws {
        let url = root.appending(path: relativePath)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("уже было".utf8).write(to: url)
    }

    private func importedNames() throws -> [String] {
        try manager.contentsOfDirectory(atPath: root.appending(path: "Imported").path).sorted()
    }

    // MARK: - Имя

    func testNameIsKeptAsGiven() async throws {
        let path = try await workspace.importFileAsync(from: try source("Совещание 27.08.m4a"))

        XCTAssertEqual(path, "Imported/Совещание 27.08.m4a")
        XCTAssertEqual(try Data(contentsOf: root.appending(path: path)), Data([1, 2, 3]))
    }

    /// `Совещание.m4a` и `Совещание.mp3` делили бы `Transcripts/Совещание.md`.
    func testSameBaseWithAnotherExtensionGetsANumber() async throws {
        let first = try await workspace.importFileAsync(from: try source("Совещание.m4a"))
        let second = try await workspace.importFileAsync(from: try source("Совещание.mp3", in: "другая"))

        XCTAssertEqual(first, "Imported/Совещание.m4a")
        XCTAssertEqual(second, "Imported/Совещание 2.mp3")
    }

    /// Та же база в `Recordings/` и `Imported/` — тоже одна расшифровка на двоих.
    func testBaseTakenInAnotherFolderIsTakenForImportsToo() async throws {
        try existing("Recordings/Совещание.m4a")

        let path = try await workspace.importFileAsync(from: try source("Совещание.m4a"))

        XCTAssertEqual(path, "Imported/Совещание 2.m4a")
    }

    /// Текст мог пережить удалённое аудио: новая запись под тем же именем не должна ни
    /// затереть его, ни сразу выглядеть «уже расшифрованной».
    func testAnExistingTranscriptReservesItsBase() async throws {
        try existing("Transcripts/Лекция.md")

        let path = try await workspace.importFileAsync(from: try source("Лекция.mp3"))

        XCTAssertEqual(path, "Imported/Лекция 2.mp3")
    }

    func testNumbersAlreadyTakenAreSkipped() async throws {
        try existing("Imported/Планёрка.m4a")
        try existing("Imported/Планёрка 2.mp3")
        try existing("Recordings/Планёрка 3.wav")

        let path = try await workspace.importFileAsync(from: try source("Планёрка.aac"))

        XCTAssertEqual(path, "Imported/Планёрка 4.aac")
    }

    /// Файловая система не различает регистр: «СОВЕЩАНИЕ» — это то же «Совещание».
    func testCaseDoesNotMakeABaseDifferent() async throws {
        try existing("Recordings/совещание.m4a")

        let path = try await workspace.importFileAsync(from: try source("СОВЕЩАНИЕ.MP3"))

        XCTAssertEqual(path, "Imported/СОВЕЩАНИЕ 2.MP3")
    }

    /// И не различает форму юникода: «й» одним знаком и «и» с краткой — одно имя.
    func testUnicodeNormalisationDoesNotMakeABaseDifferent() async throws {
        let composed = "Йога"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.unicodeScalars), Array(decomposed.unicodeScalars), "тест бессмыслен без разницы")
        try existing("Transcripts/\(composed).md")

        let path = try await workspace.importFileAsync(from: try source("\(decomposed).m4a"))

        XCTAssertTrue(path.hasSuffix(" 2.m4a"), path)
    }

    /// Чужая база в корзине не мешает: оттуда ничего не показывается и не ищется.
    func testTrashDoesNotReserveNames() async throws {
        try existing(".LoriTrash/UUID-Совещание.m4a")
        try existing(".LoriTrash/Совещание.m4a")

        let path = try await workspace.importFileAsync(from: try source("Совещание.m4a"))

        XCTAssertEqual(path, "Imported/Совещание.m4a")
    }

    /// Два импорта разом выбирали бы одно имя — файла ещё нет ни у одного. Бронь не даёт.
    func testTwoImportsAtOnceDoNotPickTheSameName() async throws {
        let first = try source("Запись.m4a", bytes: [1], in: "а")
        let second = try source("Запись.m4a", bytes: [2], in: "б")
        let third = try source("Запись.mp3", bytes: [3], in: "в")
        let store = workspace!

        async let one = store.importFileAsync(from: first)
        async let two = store.importFileAsync(from: second)
        async let three = store.importFileAsync(from: third)
        let paths = try await [one, two, three]

        XCTAssertEqual(Set(paths).count, 3, "три разных пути: \(paths)")
        let bases = Set(paths.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension })
        XCTAssertEqual(bases.count, 3, "и три разные базы — три разные расшифровки: \(paths)")
        XCTAssertEqual(try importedNames().count, 3)
    }

    /// После импорта бронь снимается: удалили запись — то же имя снова свободно.
    func testNameIsFreeAgainOnceTheRecordIsGone() async throws {
        let first = try await workspace.importFileAsync(from: try source("Звонок.m4a"))
        try manager.removeItem(at: root.appending(path: first))

        let again = try await workspace.importFileAsync(from: try source("Звонок.m4a"))

        XCTAssertEqual(again, "Imported/Звонок.m4a")
    }

    // MARK: - Формат

    func testUnsupportedFormatIsRejectedAndNothingIsCopied() async throws {
        for name in ["Голосовое.ogg", "Голосовое.opus", "Музыка.flac", "Без расширения"] {
            let file = try source(name)

            do {
                _ = try await workspace.importFileAsync(from: file)
                XCTFail("\(name) должен быть отклонён")
            } catch let error as ImportError {
                XCTAssertEqual(error, .unsupportedFormat(fileName: name))
            }
            XCTAssertTrue(manager.fileExists(atPath: file.path), "оригинал на месте")
        }
        let leftovers = (try? manager.contentsOfDirectory(atPath: root.appending(path: "Imported").path)) ?? []
        XCTAssertEqual(leftovers, [], "в рабочую папку ничего не попало")
    }

    func testUppercaseExtensionsAreAccepted() async throws {
        let path = try await workspace.importFileAsync(from: try source("ЗАПИСЬ.M4A"))

        XCTAssertEqual(path, "Imported/ЗАПИСЬ.M4A")
        try workspace.refresh()
        XCTAssertEqual(workspace.audio.map(\.relativePath), [path], "и такая запись в списке видна")
    }

    // MARK: - Дата

    /// Копия сохраняет дату оригинала, и месячной давности запись ушла бы в середину списка.
    /// Поэтому дата — момент импорта: свежедобавленное всегда наверху.
    func testImportedFileGetsTheMomentOfImportAsItsDate() async throws {
        let longAgo = Date(timeIntervalSinceNow: -60 * 24 * 3600)
        let file = try source("Старая запись.m4a", modified: longAgo)
        try existing("Recordings/Вчерашняя.m4a")
        try manager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -24 * 3600)],
            ofItemAtPath: root.appending(path: "Recordings/Вчерашняя.m4a").path
        )
        let before = Date()

        let path = try await workspace.importFileAsync(from: file)

        let stamped = try workspace.entry(at: path).modifiedAt
        XCTAssertGreaterThanOrEqual(stamped.timeIntervalSince(before), -1)
        XCTAssertLessThan(abs(stamped.timeIntervalSinceNow), 30)
        try workspace.refresh()
        XCTAssertEqual(workspace.audio.first?.relativePath, path, "новая запись — первая в списке «новые сверху»")
        XCTAssertEqual(
            try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 ?? 0,
            longAgo.timeIntervalSince1970,
            accuracy: 1,
            "а у оригинала дата прежняя: чужой файл не трогаем"
        )
    }

    func testAnExplicitDateIsHonoured() async throws {
        let date = Date(timeIntervalSince1970: 1_900_000_000)

        let path = try await workspace.importFileAsync(from: try source("Запись.m4a"), modifiedAt: date)

        XCTAssertEqual(try workspace.entry(at: path).modifiedAt.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Целиком или никак

    func testNothingButTheFinalFileIsLeftAfterASuccessfulImport() async throws {
        _ = try await workspace.importFileAsync(from: try source("Запись.m4a"))

        XCTAssertEqual(try importedNames(), ["Запись.m4a"], "ни одного скрытого остатка")
    }

    func testAFailedCopyLeavesNothingBehind() async throws {
        let missing = sources.appending(path: "Пропала.m4a")

        do {
            _ = try await workspace.importFileAsync(from: missing)
            XCTFail("копировать нечего — должна быть ошибка")
        } catch {
            // ожидаемо
        }

        XCTAssertEqual(try importedNames(), [])
    }

    /// Упал процесс посреди копии — на старте остаток убирается, а чужое не трогается.
    func testStaleLeftoversAreRemovedAtStartAndOnlyThose() throws {
        try existing("Imported/Моя запись.m4a")
        try existing("Imported/.lori-import-\(UUID().uuidString).partial")
        try existing("Imported/.чужой-скрытый-файл")
        try existing("Imported/.lori-import-похоже.но-не-то")

        WorkspaceStore(rootURL: root).start()

        XCTAssertEqual(
            Set(try manager.contentsOfDirectory(atPath: root.appending(path: "Imported").path)),
            ["Моя запись.m4a", ".чужой-скрытый-файл", ".lori-import-похоже.но-не-то"]
        )
    }

    /// Недокопированное не должно попадать в список записей, пока идёт копия.
    func testPartialCopyIsHiddenFromTheRecordList() throws {
        try existing("Imported/.lori-import-\(UUID().uuidString).partial")
        try existing("Imported/Готовая.m4a")

        try workspace.refresh()

        XCTAssertEqual(workspace.audio.map(\.relativePath), ["Imported/Готовая.m4a"])
    }

    // MARK: - Синхронный вариант

    func testSynchronousImportFollowsTheSameRules() throws {
        try existing("Recordings/Совещание.m4a")
        let before = Date()

        let renamed = try workspace.importFile(from: try source("Совещание.mp3", modified: Date(timeIntervalSince1970: 1_000_000_000)))

        XCTAssertEqual(renamed, "Imported/Совещание 2.mp3")
        XCTAssertGreaterThanOrEqual(try workspace.entry(at: renamed).modifiedAt.timeIntervalSince(before), -1)
        XCTAssertThrowsError(try workspace.importFile(from: try source("Голосовое.ogg"))) { error in
            XCTAssertEqual(error as? ImportError, .unsupportedFormat(fileName: "Голосовое.ogg"))
        }
        XCTAssertEqual(try importedNames(), ["Совещание 2.mp3"])
    }

    /// Импорт в другую папку работает и держит те же правила.
    func testImportIntoAnotherFolder() async throws {
        let path = try await workspace.importFileAsync(from: try source("Запись.m4a"), into: "Мои/Записи")

        XCTAssertEqual(path, "Мои/Записи/Запись.m4a")
        let second = try await workspace.importFileAsync(from: try source("Запись.mp3"), into: "Мои/Записи")
        XCTAssertEqual(second, "Мои/Записи/Запись 2.mp3")
    }

    func testPathEscapingFolderIsRefused() async throws {
        do {
            _ = try await workspace.importFileAsync(from: try source("Запись.m4a"), into: "../снаружи")
            XCTFail("выход из рабочей папки недопустим")
        } catch {
            XCTAssertEqual(error as? WorkspaceError, .unsafePath)
        }
    }
}
