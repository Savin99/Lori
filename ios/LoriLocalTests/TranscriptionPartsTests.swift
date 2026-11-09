import XCTest
@testable import LoriLocal

final class TranscriptionPartsTests: XCTestCase {
    func testByteShareListeningClockAndLateUploadCannotRewind() {
        var progress = TranscriptionParts(parts: [.init(start: 0, end: 600), .init(start: 598, end: 1200)])
        XCTAssertNil(progress.parts[0].phase.uploadShare)
        progress.apply(.phase(0, .sending(sent: 40, expected: 100)))
        XCTAssertEqual(progress.parts[0].phase.uploadShare, 0.4)
        XCTAssertTrue(progress.title().contains("Отправляю часть 1 из 2"))
        XCTAssertEqual(TranscriptionParts.Phase.sending(sent: -10, expected: 100).uploadShare, 0)
        XCTAssertEqual(TranscriptionParts.Phase.sending(sent: 200, expected: 100).uploadShare, 1)
        XCTAssertNil(TranscriptionParts.Phase.sending(sent: 10, expected: -1).uploadShare)
        let start = Date(timeIntervalSince1970: 100)
        progress.apply(.phase(0, .listening(since: start)))
        progress.apply(.phase(0, .listening(since: start.addingTimeInterval(5))))
        progress.apply(.phase(0, .sending(sent: 99, expected: 100)))
        XCTAssertEqual(progress.detail(now: start.addingTimeInterval(38)), "0:38")
        XCTAssertEqual(progress.title(), "Слушает часть 1 из 2")
        progress.apply(.phase(0, .complete))
        progress.apply(.phase(0, .listening(since: .now)))
        XCTAssertEqual(progress.completedCount, 1)
        XCTAssertEqual(progress.activeIndex, 1)
    }
    func testFailureRetryAndArchivePreserveReasonResetTimeAndConfiguration() throws {
        var progress = TranscriptionParts(parts: [.init(start: 0, end: 600, phase: .complete), .init(start: 600, end: 1200)])
        let reset = Date().addingTimeInterval(120)
        progress.apply(.phase(1, .failed(reason: "Квота", retryAt: reset)))
        XCTAssertEqual(progress.title(), "Готово, кроме части 2")
        XCTAssertTrue(progress.detail()?.contains("10:00–20:00 не расшифровано · Квота · повтор в") == true)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let job = TranscriptionJob.capture(kind: .geminiSubscription)
        try InterruptedRecords.saveJobs([:], partFailures: ["a": .init(configuration: job, progress: progress)], to: file)
        XCTAssertEqual(InterruptedRecords.partFailures(from: file)["a"]?.progress, progress)
        XCTAssertEqual(InterruptedRecords.partFailures(from: file)["a"]?.configuration, job)
        XCTAssertTrue(InterruptedRecords.load(from: file).isEmpty, "неуспех не запускается автоматически")
        progress.apply(.phase(1, .waiting))
        progress.apply(.phase(1, .sending(sent: 20, expected: 100)))
        XCTAssertTrue(progress.failedIndices.isEmpty)
        XCTAssertEqual(progress.parts[0].phase, .complete)
        XCTAssertEqual(progress.parts[1].phase.uploadShare, 0.2)
        progress.apply(.phase(20, .complete))
        XCTAssertEqual(progress.parts.count, 2)
    }
}
