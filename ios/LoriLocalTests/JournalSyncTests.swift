import XCTest
@testable import LoriLocal

final class JournalSyncTests: XCTestCase {
    private var directory: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "lori-journal-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsSuite = "JournalSyncTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSync(
        handler: @escaping @Sendable (URLRequest, Data) -> StubURLProtocol.Reply,
        journalURL: URL? = nil,
        configured: Bool = true
    ) -> JournalSync {
        let outbox = directory.appending(path: "outbox.log")
        let journal = journalURL ?? directory.appending(path: "journal.txt")
        let endpoint: JournalSync.Endpoint? = configured
            ? .init(baseURL: URL(string: "https://stub.invalid/gateway")!, token: "test-token-12345")
            : nil
        return JournalSync(
            outboxURL: outbox,
            journalURL: journal,
            session: StubURLProtocol.session(handler),
            defaults: defaults,
            endpointProvider: { endpoint },
            hasConfiguredBaseURL: { configured },
            build: "21",
            osVersion: "27.2",
            deviceModel: "iPhone17,2",
            enabled: true,
            debounce: 60,
            urgentDebounce: 60
        )
    }

    func testEnqueueAndFlushShipsLinesWithMetadataAndClearsOutbox() async throws {
        let sync = makeSync { _, _ in .json(#"{"ok":true}"#) }
        sync.enqueue("23.11 15:40:00 передача: старт POST\n")
        sync.enqueue("23.11 15:40:30 передача: стоит без движения\n")
        await sync.flushAndWait()

        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.path, "/gateway/v1/logs")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-12345")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "text/plain; charset=utf-8")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-Lori-Build"), "21")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-Lori-iOS"), "27.2")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-Lori-Device"), "iPhone17,2")
        let body = String(data: sent.body, encoding: .utf8)
        XCTAssertEqual(body, "23.11 15:40:00 передача: старт POST\n23.11 15:40:30 передача: стоит без движения\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "outbox.log").path))
    }

    func testFailedUploadPreservesOutboxAndSucceedsOnRetry() async throws {
        let attempt = LockedValue(0)
        let sync = makeSync { _, _ in
            let current = attempt.mutate { $0 += 1; return $0 }
            return current == 1 ? .json(#"{"error":{"code":"queue"}}"#, status: 503) : .json(#"{"ok":true}"#)
        }
        sync.enqueue("23.11 15:41:00 первая строка\n")
        await sync.flushAndWait()
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "outbox.log").path))

        sync.enqueue("23.11 15:41:10 вторая строка\n")
        await sync.flushAndWait()
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        let secondBody = String(data: try XCTUnwrap(StubURLProtocol.requests.last?.body), encoding: .utf8)
        XCTAssertEqual(secondBody, "23.11 15:41:00 первая строка\n23.11 15:41:10 вторая строка\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "outbox.log").path))
    }

    func testInitialCatchupShipsPreviousJournalTailOnce() async throws {
        let journal = directory.appending(path: "journal.txt")
        try "23.11 15:00:00 старый сбой на 2%\n".write(to: journal, atomically: true, encoding: .utf8)
        let sync = makeSync(handler: { _, _ in .json(#"{"ok":true}"#) }, journalURL: journal)
        sync.start()
        await sync.flushAndWait()

        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let body = String(data: try XCTUnwrap(StubURLProtocol.requests.first?.body), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("[предыдущий журнал устройства до включения автоотправки]"), body)
        XCTAssertTrue(body.contains("23.11 15:00:00 старый сбой на 2%"), body)

        // Второй запуск тот же старый журнал повторно не отправляет.
        sync.start()
        await sync.flushAndWait()
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testUnconfiguredGatewayDoesNotWriteOutboxOrSend() async {
        let sync = makeSync(handler: { _, _ in .json(#"{"ok":true}"#) }, configured: false)
        sync.start()
        sync.enqueue("23.11 15:42:00 строка без шлюза\n")
        await sync.flushAndWait()
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "outbox.log").path))
    }

    // MARK: - UploadStallTracker

    func testStallTrackerWarnsThenAbortsWhenUploadStaysFrozenAtTwoPercent() {
        typealias Tracker = BackgroundTranscriptionTransport.UploadStallTracker
        var tracker = Tracker(taskIdentifier: 7, endpoint: "api.elevenlabs.io/v1/speech-to-text", expected: 10 * 1024 * 1024, lastSent: 0)
        // Первые 2% ушли в буфер сокета — это не зависание.
        let twoPercent = Int64(204_800)
        XCTAssertEqual(tracker.recordProgress(sent: twoPercent, expected: 10 * 1024 * 1024), .none)

        // Тик 1: ещё рано.
        XCTAssertEqual(tracker.recordTick(liveSent: twoPercent, isRunning: true), .none)
        // Тик 2 (~30 с без движения): предупреждение в журнал.
        XCTAssertEqual(tracker.recordTick(liveSent: twoPercent, isRunning: true), .warn(percent: 1, sentKB: 200, expectedKB: 10240))
        // Тики 3..5: повторного предупреждения нет, ещё не сбрасываем.
        XCTAssertEqual(tracker.recordTick(liveSent: twoPercent, isRunning: true), .none)
        XCTAssertEqual(tracker.recordTick(liveSent: twoPercent, isRunning: true), .none)
        XCTAssertEqual(tracker.recordTick(liveSent: twoPercent, isRunning: true), .none)
        // Тик 6 (~90 с без движения): сбрасываем зависшую задачу.
        XCTAssertEqual(tracker.recordTick(liveSent: twoPercent, isRunning: true), .abort(percent: 1, sentKB: 200, expectedKB: 10240))
    }

    func testStallTrackerResetsOnProgressDetectsSilentRestartAndReportsMilestones() {
        typealias Tracker = BackgroundTranscriptionTransport.UploadStallTracker
        let total: Int64 = 4 * 1024 * 1024
        var tracker = Tracker(taskIdentifier: 9, endpoint: "api.elevenlabs.io/v1/speech-to-text", expected: total, lastSent: 0)

        XCTAssertEqual(tracker.recordProgress(sent: 100 * 1024, expected: total), .none)
        XCTAssertEqual(tracker.recordTick(liveSent: 100 * 1024, isRunning: true), .none)
        XCTAssertEqual(tracker.recordTick(liveSent: 100 * 1024, isRunning: true), .warn(percent: 2, sentKB: 100, expectedKB: 4096))

        // Появилось движение — счётчик сбросился, пересекли 25%.
        XCTAssertEqual(tracker.recordProgress(sent: 1024 * 1024, expected: total), .milestone(25))
        XCTAssertEqual(tracker.stalledTicks, 0)
        // Если задача не в .running (например, приостановлена), тик не считается зависанием.
        XCTAssertEqual(tracker.recordTick(liveSent: 1024 * 1024, isRunning: false), .none)
        XCTAssertEqual(tracker.stalledTicks, 0)

        // Тихий перезапуск nsurlsessiond назад (с 25% на 1%).
        XCTAssertEqual(tracker.recordProgress(sent: 40 * 1024, expected: total), .restarted(fromPercent: 25, toPercent: 0))
        // Отправка дошла до 100% — дальше ждём ответ сервиса, сторож снимается.
        XCTAssertEqual(tracker.recordProgress(sent: total, expected: total), .finishedSending)
        XCTAssertEqual(tracker.recordTick(liveSent: total, isRunning: true), .none)
    }

    func testDescribeEndpointDropsQueryAndSecretParameters() {
        let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text?key=secret-token&kind=transcribe")!
        XCTAssertEqual(BackgroundTranscriptionTransport.describeEndpoint(url), "api.elevenlabs.io/v1/speech-to-text")
    }
}
