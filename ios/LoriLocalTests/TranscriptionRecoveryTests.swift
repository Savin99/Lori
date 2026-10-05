import XCTest
@testable import LoriLocal

final class TranscriptionRecoveryTests: XCTestCase {
    func testCorruptJobPathCannotBecomeACleanupDirectory() throws {
        let data = try JSONEncoder().encode(TranscriptionJob.capture(kind: .gigaam))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for id in ["", ".", "..", "../Models", "../../Documents", "/", "Transfers"] {
            object["id"] = id
            let corrupt = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(TranscriptionJob.self, from: corrupt), id)
        }
    }

    @MainActor func testTestHelpersAreDisabledInPersonalBundle() {
        XCTAssertFalse(RecoveryProbe.allowsDiagnostics(in: "ru.ilyaqa.lori.local"))
        XCTAssertFalse(RecoveryProbe.allowsDiagnostics(in: nil))
        XCTAssertTrue(RecoveryProbe.allowsDiagnostics(in: "ru.ilyaqa.lori.local.qa"))
        if Bundle.main.bundleIdentifier != "ru.ilyaqa.lori.local.qa" {
            XCTAssertFalse(RecoveryProbe.enabled)
            XCTAssertFalse(ImportInbox.isResetRequested)
        }
        XCTAssertEqual(TranscriptionRunway.taskIdentifier, (Bundle.main.bundleIdentifier ?? "") + ".transcribe")
        XCTAssertEqual(BackgroundTranscriptionTransport.identifier,
                       (Bundle.main.bundleIdentifier ?? "") + ".transcription-transfer")
    }

    func testHistoricalModeAndModelRemainExactAndLegacyModeUnknown() {
        let source = "# Интервью\n\n_Расшифровано: ElevenLabs · scribe_v2_\n\n_Режим: Дословно_\n\nТекст"
        let parsed = TranscriptDocument.parse(source)
        XCTAssertEqual(parsed.engine, "ElevenLabs · scribe_v2")
        XCTAssertEqual(parsed.mode, "Дословно")
        XCTAssertEqual(parsed.plainText, "Текст")
        let exported = TranscriptExport.make(document: parsed, title: "Тест", recordedAt: .now)
        XCTAssertEqual(TranscriptDocument.parse(exported.markdown).mode, "Дословно")
        XCTAssertEqual(exported.engine, parsed.engine)
        XCTAssertNil(TranscriptDocument.parse("_Расшифровано: ElevenLabs · scribe_v2_\nТекст").mode)
    }

    func testSavedJobsPreserveLegacyCloudWithoutAuthorizingItsResume() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let job = TranscriptionJob.capture(kind: .gigaam)
        try InterruptedRecords.saveJobs(["new.m4a": job], legacy: ["old.m4a": .gemini], to: url)
        XCTAssertEqual(InterruptedRecords.load(from: url), ["new.m4a": .gigaam, "old.m4a": .gemini])
        XCTAssertEqual(InterruptedRecords.jobs(from: url), ["new.m4a": job])
    }

    func testSettingsSnapshotSurvivesGlobalChangesAndSerialization() throws {
        let key = TranscriptionSettings.elevenLabsModelKey
        let old = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(old, forKey: key) }
        UserDefaults.standard.set("scribe_v2", forKey: key)
        let job = TranscriptionJob.capture(kind: .elevenLabs)
        let restored = try JSONDecoder().decode(TranscriptionJob.self, from: JSONEncoder().encode(job))
        UserDefaults.standard.set("another_model", forKey: key)
        TranscriptionJob.$current.withValue(restored) {
            XCTAssertEqual(TranscriptionSettings.elevenLabsModel, "scribe_v2")
        }
        XCTAssertEqual(TranscriptionSettings.elevenLabsModel, "another_model")
    }

    func testCheckpointRestoresWordsAndRejectsDifferentChunking() throws {
        let job = TranscriptionJob.capture(kind: .gigaam)
        defer { try? FileManager.default.removeItem(at: job.directory) }
        let words = [TranscriptWord(start: 0.2, end: 1.0, text: "Привет")]
        let saved = LocalTranscriptCheckpoint(bounds: [0, 100, 80, 180], next: 1, words: words, coveredUntil: 1.0)
        try saved.save(job: job)
        let restored = LocalTranscriptCheckpoint.load(job: job, ranges: [0..<100, 80..<180])
        XCTAssertEqual(restored.next, 1)
        XCTAssertEqual(restored.words, words)
        XCTAssertEqual(restored.coveredUntil, 1.0)
        XCTAssertEqual(LocalTranscriptCheckpoint.load(job: job, ranges: [0..<180]).next, 0)
    }

    func testGeminiUploadIdentityIgnoresTemporaryFilename() {
        let job = TranscriptionJob.capture(kind: .gemini)
        TranscriptionJob.$current.withValue(job) {
            let first = GeminiTranscriber.uploadName(data: Data("audio".utf8), original: "random-one.flac")
            XCTAssertEqual(first, GeminiTranscriber.uploadName(data: Data("audio".utf8), original: "random-two.flac"))
            XCTAssertNotEqual(first, GeminiTranscriber.uploadName(data: Data("different".utf8), original: "random-one.flac"))
        }
    }

    func testTransferIdentityIsStableAcrossResumeAndDistinctAcrossJobsAndBodies() {
        var request = URLRequest(url: URL(string: "https://example.com/transcribe")!)
        request.httpMethod = "POST"
        request.httpBody = Data("audio1".utf8)
        let first = BackgroundTranscriptionTransport.requestID(request, jobID: "job1")
        XCTAssertEqual(first, BackgroundTranscriptionTransport.requestID(request, jobID: "job1"))
        XCTAssertNotEqual(first, BackgroundTranscriptionTransport.requestID(request, jobID: "job2"))
        request.httpBody = Data("audio2".utf8)
        XCTAssertNotEqual(first, BackgroundTranscriptionTransport.requestID(request, jobID: "job1"))
    }
}
