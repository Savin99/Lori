import XCTest
@testable import LoriLocal

/// Приём принесённого снаружи. Проверяются настоящие папки, а не подставные:
/// половина смысла этого сервиса — знать, что `Documents/Inbox` виден человеку
/// в «Файлах» и обязан оставаться пустым, а промежуточное место — нет.
final class ImportInboxTests: XCTestCase {
    private let manager = FileManager.default

    override func setUp() {
        super.setUp()
        try? manager.removeItem(at: ImportInbox.staging)
        try? manager.removeItem(at: ImportInbox.systemInbox)
    }

    override func tearDown() {
        try? manager.removeItem(at: ImportInbox.staging)
        try? manager.removeItem(at: ImportInbox.systemInbox)
        super.tearDown()
    }

    /// Файл из «Поделиться» именно переносится: копия оставила бы оригинал
    /// лежать на виду в «Файлах», среди записей человека.
    func testFileFromShareLeavesTheVisibleInbox() throws {
        let source = try inboxFile(named: "Совещание.m4a")

        let staged = try ImportInbox.stage(source)

        XCTAssertTrue(ImportInbox.isStaged(staged))
        XCTAssertFalse(manager.fileExists(atPath: source.path), "в Documents/Inbox не должно остаться ничего")
        XCTAssertEqual(try Data(contentsOf: staged), Data([1, 2, 3]))
    }

    /// Файл из «Файлов» — чужой, и его нельзя ни переносить, ни удалять.
    func testFileFromElsewhereIsCopied() throws {
        let source = try outsideFile(named: "Чужая запись.m4a")
        defer { try? manager.removeItem(at: source) }

        let staged = try ImportInbox.stage(source)

        XCTAssertTrue(manager.fileExists(atPath: source.path), "оригинал остаётся у владельца")
        XCTAssertTrue(manager.fileExists(atPath: staged.path))
    }

    func testTwoFilesWithOneNameDoNotOverwriteEachOther() throws {
        let first = try ImportInbox.stage(try inboxFile(named: "Новая запись.m4a"))
        let second = try ImportInbox.stage(try inboxFile(named: "Новая запись.m4a"))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(ImportInbox.waiting().count, 2)
        XCTAssertEqual(second.pathExtension, "m4a", "расширение обязано пережить переименование")
    }

    /// Пока приложение было закрыто, система могла сложить в Inbox несколько
    /// файлов — они не должны потеряться до первого `onOpenURL`.
    func testEverythingWaitingSinceTheAppWasClosedIsPickedUp() throws {
        _ = try inboxFile(named: "Раз.m4a")
        _ = try inboxFile(named: "Два.m4a")

        let taken = ImportInbox.drainSystemInbox()

        XCTAssertEqual(taken.count, 2)
        XCTAssertEqual(ImportInbox.waiting().count, 2)
        XCTAssertFalse(
            manager.fileExists(atPath: ImportInbox.systemInbox.path),
            "Documents виден в «Файлах»: пустой Inbox не должен там оставаться"
        )
    }

    func testForgettingRemovesOnlyOurOwnFiles() throws {
        let staged = try ImportInbox.stage(try inboxFile(named: "Совещание.m4a"))
        let outside = try outsideFile(named: "Не наше.m4a")
        defer { try? manager.removeItem(at: outside) }

        ImportInbox.forget(staged)
        ImportInbox.forget(outside)

        XCTAssertFalse(manager.fileExists(atPath: staged.path))
        XCTAssertTrue(manager.fileExists(atPath: outside.path), "чужой файл удалять нельзя")
    }

    func testNothingWaitsWhenNothingWasBrought() {
        XCTAssertEqual(ImportInbox.waiting(), [])
        XCTAssertEqual(ImportInbox.drainSystemInbox(), [])
    }

    // MARK: - Подготовка

    private func inboxFile(named name: String) throws -> URL {
        try manager.createDirectory(at: ImportInbox.systemInbox, withIntermediateDirectories: true)
        let url = ImportInbox.systemInbox.appending(path: name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    private func outsideFile(named name: String) throws -> URL {
        let url = manager.temporaryDirectory.appending(path: "\(UUID().uuidString) \(name)")
        try Data([4, 5, 6]).write(to: url)
        return url
    }
}
