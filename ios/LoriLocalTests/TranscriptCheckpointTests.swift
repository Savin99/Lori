import XCTest
@testable import LoriLocal

/// Черновик готовых частей: ради него и заведён: шесть оплаченных ответов
/// не должны пропадать оттого, что система забрала процесс на седьмом.
final class TranscriptCheckpointTests: XCTestCase {
    private var audio: URL!

    override func setUpWithError() throws {
        audio = FileManager.default.temporaryDirectory.appending(path: "cp-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 2, at: audio)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: audio)
        try? FileManager.default.removeItem(at: TranscriptCheckpoint.directory)
    }

    private func fingerprint(
        model: String = "gemini-3.5-transcribe",
        mode: String = "accuracy",
        part: TimeInterval = 600,
        vocabulary: [String] = []
    ) -> String {
        TranscriptCheckpoint.fingerprint(
            audio: audio,
            engine: "gemini",
            model: model,
            mode: mode,
            partSeconds: part,
            vocabulary: vocabulary
        )
    }

    private func snapshot(_ fingerprint: String, cursor: TimeInterval = 600) -> TranscriptCheckpoint.Snapshot {
        TranscriptCheckpoint.Snapshot(
            fingerprint: fingerprint,
            cursor: cursor,
            pieces: [.init(start: 0, end: cursor, text: "Первая часть.", isApproximate: true)],
            warnings: ["Участок 0:00–10:00: замечание."],
            saved: Date()
        )
    }

    func testSavedDraftComesBack() {
        let key = fingerprint()
        TranscriptCheckpoint.save(snapshot(key))

        let loaded = TranscriptCheckpoint.load(fingerprint: key)

        XCTAssertEqual(loaded.cursor, 600)
        XCTAssertEqual(loaded.pieces.first?.text, "Первая часть.")
        XCTAssertEqual(loaded.warnings, ["Участок 0:00–10:00: замечание."], "замечания живут вместе с частями")
    }

    /// Отпечаток — не украшение. Поменяли модель, режим, длину части или словарь —
    /// прошлые части считались в других условиях, и склеивать их с новыми значит
    /// выдать смесь за цельную расшифровку.
    func testDraftIsNotReusedWhenConditionsChange() {
        TranscriptCheckpoint.save(snapshot(fingerprint()))

        XCTAssertTrue(TranscriptCheckpoint.load(fingerprint: fingerprint(model: "другая")).isEmpty)
        XCTAssertTrue(TranscriptCheckpoint.load(fingerprint: fingerprint(mode: "smart")).isEmpty)
        XCTAssertTrue(TranscriptCheckpoint.load(fingerprint: fingerprint(part: 300)).isEmpty)
        XCTAssertTrue(TranscriptCheckpoint.load(fingerprint: fingerprint(vocabulary: ["Лори"])).isEmpty)
        XCTAssertFalse(TranscriptCheckpoint.load(fingerprint: fingerprint()).isEmpty, "свой черновик на месте")
    }

    /// Запись перезаписали — черновик про старый звук, и продолжать по нему нельзя.
    func testDraftDiesWithTheRecording() throws {
        let key = fingerprint()
        TranscriptCheckpoint.save(snapshot(key))
        try AudioFixture.wav(seconds: 3, at: audio)

        XCTAssertTrue(TranscriptCheckpoint.load(fingerprint: fingerprint()).isEmpty)
    }

    func testOldDraftIsNotResurrected() {
        let key = fingerprint()
        var stale = snapshot(key)
        stale.saved = Date(timeIntervalSinceNow: -TranscriptCheckpoint.maximumAge - 60)
        TranscriptCheckpoint.save(stale, now: stale.saved)

        XCTAssertTrue(TranscriptCheckpoint.load(fingerprint: key).isEmpty, "недельной давности черновик не поднимаем")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: TranscriptCheckpoint.url(for: key).path),
            "и на диске он не остаётся"
        )
    }

    /// Расшифровка сошлась — черновик обязан уйти: иначе следующая расшифровка
    /// той же записи тем же движком подменилась бы старым текстом.
    func testDraftIsDroppedWhenWorkIsDone() {
        let key = fingerprint()
        TranscriptCheckpoint.save(snapshot(key))

        TranscriptCheckpoint.drop(fingerprint: key)

        XCTAssertTrue(TranscriptCheckpoint.load(fingerprint: key).isEmpty)
    }

    func testPruneRemovesAbandonedDrafts() {
        let key = fingerprint()
        var stale = snapshot(key)
        stale.saved = Date(timeIntervalSinceNow: -TranscriptCheckpoint.maximumAge - 60)
        TranscriptCheckpoint.save(stale, now: stale.saved)

        TranscriptCheckpoint.prune()

        XCTAssertFalse(FileManager.default.fileExists(atPath: TranscriptCheckpoint.url(for: key).path))
    }
}
