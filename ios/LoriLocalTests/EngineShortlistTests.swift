import XCTest
@testable import LoriLocal

/// Быстрый выбор движка — шит из панели и подменю «Расшифровать заново».
/// Владелец, 6 октября 2026: «в селекторе не нужно показывать модели, которых
/// нет». Показываются только готовые движки, а в шите ещё и выбранный — даже
/// неготовый: движок не подменяется сам. Полный список остаётся в настройках.
@MainActor
final class EngineShortlistTests: XCTestCase {
    override func setUpWithError() throws {
        // Готовность GigaAM читает выбранный вариант модели из настроек.
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.gigaAMVariantKey)
    }

    private func kinds(_ engines: [EngineDescriptor]) -> [TranscriptionEngineKind] {
        engines.map(\.kind)
    }

    func testOnlyReadyEnginesAreOffered() {
        let shown = EngineShortlist.engines(EngineCatalog.all, ready: [.gemini, .apple], keeping: nil)

        XCTAssertEqual(kinds(shown), [.apple, .gemini], "только готовые — и в порядке каталога, а не множества")
    }

    func testSelectedEngineStaysWhenNotReady() {
        let groups = EngineShortlist.groups(onlyReady: true, ready: [.apple], keeping: .gemini)

        XCTAssertEqual(groups.map(\.title), ["На телефоне", "В облаке"])
        XCTAssertEqual(kinds(groups[0].engines), [.apple])
        XCTAssertEqual(kinds(groups[1].engines), [.gemini], "выбранный без ключа не пропадает — иначе выглядело бы, что движок подменился")
    }

    func testEmptySectionDisappears() {
        let local = EngineShortlist.groups(onlyReady: true, ready: [.apple], keeping: .gigaam)
        XCTAssertEqual(local.map(\.title), ["На телефоне"], "облако без единого готового движка — раздела нет")
        XCTAssertEqual(kinds(local[0].engines), [.gigaam, .apple])

        let cloud = EngineShortlist.groups(onlyReady: true, ready: [.openAI], keeping: .openAI)
        XCTAssertEqual(cloud.map(\.title), ["В облаке"], "и наоборот: нет готовых на телефоне — нет и раздела")
    }

    func testEverythingReadyShowsEverythingInCatalogOrder() {
        let groups = EngineShortlist.groups(onlyReady: true, ready: Set(TranscriptionEngineKind.allCases), keeping: .gigaam)

        XCTAssertEqual(kinds(groups[0].engines), [.gigaam, .whisper, .apple])
        XCTAssertEqual(kinds(groups[1].engines), [.openAI, .gemini, .elevenLabs])
    }

    func testSettingsScreenKeepsTheFullList() {
        let groups = EngineShortlist.groups(onlyReady: false, ready: [], keeping: .gigaam)

        XCTAssertEqual(groups.map(\.title), ["На телефоне", "В облаке"], "в настройках оба раздела всегда")
        XCTAssertEqual(kinds(groups.flatMap(\.engines)), TranscriptionEngineKind.allCases, "там качают модели и вводят ключи — все движки")
    }

    func testActionMenuHasNoSelectedException() {
        // Подменю «Расшифровать заново» — действие, а не выбор: неготовый движок
        // остановился бы на первом же шаге.
        let shown = EngineShortlist.engines(EngineCatalog.all, ready: [.apple], keeping: nil)

        XCTAssertEqual(kinds(shown), [.apple])
    }

    func testReadinessComesFromTheDirectory() {
        let directory = EngineDirectory(
            hasKey: { $0 == .gemini },
            hasModel: { _ in false },
            hasWhisperModel: { false }
        )

        XCTAssertEqual(directory.readyKinds, [.apple, .gemini], "GigaAM без весов, Whisper без папки, облако без ключа — не готовы")
        let groups = EngineShortlist.groups(onlyReady: true, ready: directory.readyKinds, keeping: .gigaam)
        XCTAssertEqual(kinds(groups[0].engines), [.gigaam, .apple])
        XCTAssertEqual(directory.readiness(of: .gigaam).badge, "Скачать модель", "выбранный остаётся со своим бейджем")
        XCTAssertEqual(kinds(groups[1].engines), [.gemini])
    }

    func testWhisperWithoutModelIsHidden() {
        let directory = EngineDirectory(hasKey: { _ in true }, hasModel: { _ in true }, hasWhisperModel: { false })

        XCTAssertEqual(directory.readiness(of: .whisper), .unavailable("Нет модели"))
        XCTAssertFalse(directory.readyKinds.contains(.whisper), "«Нет модели» — тоже не готов")
        let shown = EngineShortlist.engines(EngineCatalog.all, ready: directory.readyKinds, keeping: .apple)
        XCTAssertEqual(kinds(shown), [.gigaam, .apple, .openAI, .gemini, .elevenLabs])
    }

    func testSettingsRowSaysWhereTheRestIs() {
        XCTAssertEqual(
            EngineShortlist.settingsTitle(ready: [.apple], keeping: .gigaam),
            "Другие движки — в настройках"
        )
        XCTAssertEqual(
            EngineShortlist.settingsTitle(ready: Set(TranscriptionEngineKind.allCases), keeping: .gigaam),
            "Настройки движков",
            "готовы все — «другим» взяться неоткуда"
        )
        XCTAssertEqual(
            EngineShortlist.settingsTitle(ready: Set(TranscriptionEngineKind.allCases).subtracting([.whisper]), keeping: .whisper),
            "Настройки движков",
            "неготовый, но выбранный виден в шите — значит, спрятанных нет"
        )
    }
}
