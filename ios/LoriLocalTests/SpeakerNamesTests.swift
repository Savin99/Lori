import XCTest
@testable import LoriLocal

/// Имена говорящих. Формат `.md` при этом не меняется — проверяется как раз то,
/// что имя живёт отдельно и переживает всё, что происходит с самой записью.
@MainActor
final class SpeakerNamesTests: XCTestCase {
    private var url: URL!
    private let record = "Recordings/Планёрка.m4a"

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appending(path: "speakers-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func testUnnamedSpeakerStaysItsLabel() {
        let names = SpeakerNames(url: url)

        XCTAssertEqual(names.name(of: "S1", in: record), "S1")
        XCTAssertFalse(names.isNamed("S1", in: record))
    }

    /// Метка одна на всю запись, поэтому и имя — сразу по всей записи.
    func testNamingAppliesToTheWholeRecord() {
        let names = SpeakerNames(url: url)
        names.rename("S1", to: "Лёша", in: record)

        XCTAssertEqual(names.name(of: "S1", in: record), "Лёша")
        XCTAssertEqual(names.name(of: "S2", in: record), "S2", "второй говорящий не задет")
    }

    func testNamesAreKeptPerRecord() {
        let names = SpeakerNames(url: url)
        names.rename("S1", to: "Лёша", in: record)

        XCTAssertEqual(names.name(of: "S1", in: "Recordings/Другая.m4a"), "S1")
    }

    /// Пустое имя — это возврат к метке, а не имя из пустой строки.
    func testEmptyNameRestoresTheLabel() {
        let names = SpeakerNames(url: url)
        names.rename("S1", to: "Лёша", in: record)

        names.rename("S1", to: "   ", in: record)

        XCTAssertEqual(names.name(of: "S1", in: record), "S1")
        XCTAssertFalse(names.isNamed("S1", in: record))
    }

    func testNamesSurviveRestart() {
        SpeakerNames(url: url).rename("S2", to: "Аня", in: record)

        XCTAssertEqual(SpeakerNames(url: url).name(of: "S2", in: record), "Аня")
    }

    /// Запись переименовали — имена переезжают вместе с ней, иначе остаются
    /// сиротами под старым путём.
    func testNamesFollowTheRecord() {
        let names = SpeakerNames(url: url)
        names.rename("S1", to: "Лёша", in: record)

        names.move(from: record, to: "Recordings/Планёрка по бюджету.m4a")

        XCTAssertEqual(names.name(of: "S1", in: "Recordings/Планёрка по бюджету.m4a"), "Лёша")
        XCTAssertEqual(names.name(of: "S1", in: record), "S1")
    }

    func testForgettingRemovesOnlyThatRecord() {
        let names = SpeakerNames(url: url)
        names.rename("S1", to: "Лёша", in: record)
        names.rename("S1", to: "Аня", in: "Recordings/Другая.m4a")

        names.forget(record)

        XCTAssertEqual(names.name(of: "S1", in: record), "S1")
        XCTAssertEqual(names.name(of: "S1", in: "Recordings/Другая.m4a"), "Аня")
    }

    /// Снаружи приложения кружков нет, и «S1» ничего не значит: в копию,
    /// шаринг и Obsidian уходит имя.
    func testExportedTextCarriesNamesInsteadOfLabels() {
        let names = SpeakerNames(url: url)
        names.rename("S1", to: "Лёша", in: record)

        let text = names.applied(to: "S1: Привет.\n\nS2: Здравствуй.", in: record)

        XCTAssertEqual(text, "Лёша: Привет.\n\nS2: Здравствуй.")
    }

    func testExportIsUntouchedWithoutNames() {
        let names = SpeakerNames(url: url)

        XCTAssertEqual(names.applied(to: "S1: Привет.", in: record), "S1: Привет.")
    }
}
