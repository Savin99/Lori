import UniformTypeIdentifiers
import XCTest
import AppIntents
@testable import LoriLocal

/// Формат принесённого файла проверяется на входе: то, что приложение не расшифрует,
/// не должно доезжать до рабочей папки и пропадать там из списка.
final class ImportFormatTests: XCTestCase {
    private let manager = FileManager.default
    private var outside: URL!

    override func setUpWithError() throws {
        try? manager.removeItem(at: ImportInbox.staging)
        try? manager.removeItem(at: ImportInbox.systemInbox)
        outside = manager.temporaryDirectory.appending(path: "LoriImportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: outside)
        try? manager.removeItem(at: ImportInbox.staging)
        try? manager.removeItem(at: ImportInbox.systemInbox)
    }

    private func outsideFile(_ name: String, bytes: [UInt8] = [4, 5, 6]) throws -> URL {
        let url = outside.appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }

    private func inboxFile(_ name: String) throws -> URL {
        try manager.createDirectory(at: ImportInbox.systemInbox, withIntermediateDirectories: true)
        let url = ImportInbox.systemInbox.appending(path: name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    // MARK: - Какие форматы

    /// Текст отказа называет форматы так, как их назвал бы человек, — и обязан совпадать с
    /// тем, что приложение и правда принимает. Добавили расширение в `audioExtensions`, а
    /// в тексте забыли — тест падает.
    func testTheListedFormatsAreExactlyTheAcceptedExtensions() {
        let tokens = ImportInbox.supportedFormatsTitle
            .replacingOccurrences(of: " и ", with: ", ")
            .components(separatedBy: ", ")
        let listed = Set(tokens.map { $0.lowercased() == "aiff" ? ["aiff", "aif"] : [$0.lowercased()] }.flatMap { $0 })
        XCTAssertEqual(listed, WorkspaceEntry.audioExtensions)
    }

    func testEveryAcceptedExtensionPassesInAnyCase() {
        for suffix in WorkspaceEntry.audioExtensions {
            XCTAssertTrue(ImportInbox.isSupported(fileName: "Запись.\(suffix)"), suffix)
            XCTAssertTrue(ImportInbox.isSupported(fileName: "Запись.\(suffix.uppercased())"), suffix.uppercased())
        }
    }

    func testOtherFormatsAreNotSupported() {
        for suffix in ["ogg", "oga", "opus", "flac", "wma", "amr", "webm", "mka", "txt", "pdf", "png"] {
            XCTAssertFalse(ImportInbox.isSupported(fileName: "Запись.\(suffix)"), suffix)
        }
        XCTAssertFalse(ImportInbox.isSupported(fileName: "Без расширения"))
        XCTAssertFalse(ImportInbox.isSupported(fileName: ".m4a"), "скрытый файл без имени — не запись")
    }

    // MARK: - Отказ при приёме

    func testUnsupportedFileIsRejectedBeforeAnythingIsCopied() throws {
        for suffix in ["ogg", "opus", "flac"] {
            let source = try outsideFile("Голосовое.\(suffix)")

            XCTAssertThrowsError(try ImportInbox.stage(source), suffix) { error in
                XCTAssertEqual(error as? ImportError, .unsupportedFormat(fileName: "Голосовое.\(suffix)"))
            }
            XCTAssertTrue(manager.fileExists(atPath: source.path), "чужой файл остаётся у владельца")
        }
        XCTAssertEqual(ImportInbox.waiting(), [], "в промежуточную папку ничего не легло")
    }

    /// Копия из «Поделиться» не чужая: отвергнутую оставлять на виду в «Файлах» нельзя.
    func testRejectedFileFromTheVisibleInboxIsRemoved() throws {
        let shared = try inboxFile("Голосовое.opus")

        XCTAssertThrowsError(try ImportInbox.stage(shared))

        XCTAssertFalse(manager.fileExists(atPath: shared.path))
        XCTAssertEqual(ImportInbox.waiting(), [])
    }

    func testRejectionNamesTheFileTheFormatAndWhatIsSupported() throws {
        let error = ImportError.unsupportedFormat(fileName: "Голосовое.OGG")
        let text = try XCTUnwrap(error.errorDescription)

        XCTAssertTrue(text.contains("Голосовое.OGG"), text)
        XCTAssertTrue(text.contains(".ogg"), text)
        for name in ["M4A", "MP3", "WAV", "AAC", "CAF", "AIFF", "MP4", "MOV"] {
            XCTAssertTrue(text.contains(name), "\(name) в: \(text)")
        }
        XCTAssertFalse(text.contains("\n"), "тексты для человека — одной строкой")
        XCTAssertFalse(text.contains("  "), "двойной пробел из склейки литералов")
    }

    func testFileWithoutExtensionIsRejectedWithItsOwnExplanation() throws {
        let source = try outsideFile("Просто файл")

        XCTAssertThrowsError(try ImportInbox.stage(source)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("нет расширения"), text)
            XCTAssertTrue(text.contains("Просто файл"), text)
        }
    }

    // MARK: - Несколько файлов

    func testStageAllKeepsTheGoodOnesInOrderAndReportsTheBadOnes() throws {
        let sources = [
            try outsideFile("Один.m4a"),
            try outsideFile("Два.opus"),
            try outsideFile("Три.mp3"),
            try outsideFile("Четыре.flac"),
            try outsideFile("Пять.wav"),
        ]

        let report = ImportInbox.stageAll(sources)

        XCTAssertEqual(report.staged.map(\.lastPathComponent), ["Один.m4a", "Три.mp3", "Пять.wav"])
        XCTAssertEqual(report.rejected.map(\.name), ["Два.opus", "Четыре.flac"])
        for rejection in report.rejected {
            XCTAssertTrue(rejection.message.contains(rejection.name), rejection.message)
        }
        XCTAssertEqual(Set(ImportInbox.waiting().map(\.lastPathComponent)), ["Один.m4a", "Три.mp3", "Пять.wav"])
        XCTAssertTrue(report.staged.allSatisfy(ImportInbox.isStaged))
    }

    func testStageAllOfNothingIsEmpty() {
        XCTAssertEqual(ImportInbox.stageAll([]), ImportInbox.StagingReport())
    }

    /// Одинаковые имена в одном выборе не сливаются: «Запись.m4a» из двух папок — две записи.
    func testSameNamesInOnePickStayApart() throws {
        let other = outside.appending(path: "Другая папка", directoryHint: .isDirectory)
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        let first = try outsideFile("Запись.m4a", bytes: [1])
        let second = other.appending(path: "Запись.m4a")
        try Data([2]).write(to: second)

        let report = ImportInbox.stageAll([first, second])

        XCTAssertEqual(report.staged.map(\.lastPathComponent), ["Запись.m4a", "Запись 2.m4a"])
        XCTAssertEqual(try Data(contentsOf: report.staged[0]), Data([1]))
        XCTAssertEqual(try Data(contentsOf: report.staged[1]), Data([2]))
    }

    // MARK: - Входящие из «Поделиться»

    func testSystemInboxReportsRejectedFilesAndStillClearsTheFolder() throws {
        _ = try inboxFile("Хорошая.m4a")
        _ = try inboxFile("Плохая.opus")
        _ = try inboxFile("Ещё хорошая.mp3")

        let report = ImportInbox.collectSystemInbox()

        XCTAssertEqual(Set(report.staged.map(\.lastPathComponent)), ["Хорошая.m4a", "Ещё хорошая.mp3"])
        XCTAssertEqual(report.rejected.map(\.name), ["Плохая.opus"])
        XCTAssertFalse(manager.fileExists(atPath: ImportInbox.systemInbox.path), "Documents виден в «Файлах»")
    }

    /// Прежний вызов отдаёт только принятые — и тоже не оставляет отвергнутых на виду.
    func testDrainStillReturnsOnlyWhatWasTaken() throws {
        _ = try inboxFile("Хорошая.m4a")
        _ = try inboxFile("Плохая.ogg")

        let taken = ImportInbox.drainSystemInbox()

        XCTAssertEqual(taken.map(\.lastPathComponent), ["Хорошая.m4a"])
        XCTAssertFalse(manager.fileExists(atPath: ImportInbox.systemInbox.path))
    }

    /// Принять не вышло по причине, не связанной с форматом, — файл не стирается: тихо
    /// потерять то, что человек отправил в Lori, хуже, чем оставить папку на виду.
    func testSystemInboxKeepsAFileThatCouldNotBeTaken() throws {
        let shared = try inboxFile("Хорошая.m4a")
        // Вместо промежуточной папки — обычный файл: класть в неё нельзя.
        try manager.createDirectory(at: ImportInbox.staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("файл вместо папки".utf8).write(to: ImportInbox.staging)

        let report = ImportInbox.collectSystemInbox()

        XCTAssertTrue(report.staged.isEmpty)
        XCTAssertEqual(report.rejected.map(\.name), ["Хорошая.m4a"])
        XCTAssertTrue(manager.fileExists(atPath: shared.path), "файл на месте")
        XCTAssertTrue(manager.fileExists(atPath: ImportInbox.systemInbox.path))
    }

    // MARK: - Быстрые команды

    func testIntentFileWithoutExtensionGetsItFromItsType() throws {
        let m4a = try XCTUnwrap(UTType("com.apple.m4a-audio"))
        let file = IntentFile(data: Data([7, 8]), filename: "Recording", type: m4a)

        let staged = try ImportInbox.stage(file)

        XCTAssertEqual(staged.lastPathComponent, "Recording.m4a")
        XCTAssertEqual(try Data(contentsOf: staged), Data([7, 8]))
    }

    func testIntentFileKeepsItsOwnExtension() throws {
        let file = IntentFile(data: Data([1]), filename: "Звонок.mp3", type: UTType.mp3)

        XCTAssertEqual(try ImportInbox.stage(file).lastPathComponent, "Звонок.mp3")
    }

    func testIntentFileOfAnUnsupportedTypeIsRejected() throws {
        // Тип известен не на каждой версии системы: тогда проверять нечего.
        guard let ogg = UTType("org.xiph.ogg-audio") else { throw XCTSkip("в этой системе нет типа Ogg") }
        let file = IntentFile(data: Data([1]), filename: "Голосовое", type: ogg)

        XCTAssertThrowsError(try ImportInbox.stage(file)) { error in
            XCTAssertEqual(error as? ImportError, .unsupportedFormat(fileName: "Голосовое.ogg"))
        }
        XCTAssertEqual(ImportInbox.waiting(), [])
    }

    func testIntentFileWithNoNameAtAllIsStillTaken() throws {
        let m4a = try XCTUnwrap(UTType("com.apple.m4a-audio"))

        let staged = try ImportInbox.stage(IntentFile(data: Data([1]), filename: "", type: m4a))

        XCTAssertEqual(staged.lastPathComponent, "Запись.m4a")
    }

    func testCompletingExtension() {
        let m4a = UTType("com.apple.m4a-audio")
        XCTAssertEqual(ImportInbox.completingExtension(of: "Звонок", with: m4a), "Звонок.m4a")
        XCTAssertEqual(ImportInbox.completingExtension(of: "Звонок.wav", with: m4a), "Звонок.wav", "своё расширение главнее")
        XCTAssertEqual(ImportInbox.completingExtension(of: "Звонок", with: nil), "Звонок")
        XCTAssertEqual(ImportInbox.completingExtension(of: "", with: m4a), "Запись.m4a")
    }

    // MARK: - Имена

    func testFreeNameSurvivesCollisionsAndKeepsTheExtension() throws {
        try manager.createDirectory(at: ImportInbox.staging, withIntermediateDirectories: true)
        var names: [String] = []
        for _ in 0..<4 {
            let url = ImportInbox.free(named: "Совещание.m4a")
            names.append(url.lastPathComponent)
            try Data([1]).write(to: url)
        }

        XCTAssertEqual(names, ["Совещание.m4a", "Совещание 2.m4a", "Совещание 3.m4a", "Совещание 4.m4a"])
    }

    /// «/» сделал бы из имени вложенную папку, а точка в начале — скрытый файл, которого
    /// нет в списке записей.
    func testFreeNameCleansWhatWouldBreakTheFile() {
        XCTAssertEqual(ImportInbox.free(named: "а/б.m4a").lastPathComponent, "а-б.m4a")
        XCTAssertEqual(ImportInbox.free(named: ".скрытая.m4a").lastPathComponent, "скрытая.m4a")
        XCTAssertEqual(ImportInbox.free(named: "  Пробелы  .m4a").lastPathComponent, "Пробелы  .m4a")
        XCTAssertEqual(ImportInbox.free(named: "").lastPathComponent, "Запись.m4a")
        XCTAssertEqual(ImportInbox.free(named: "...").lastPathComponent, "Запись.m4a")
    }
}
