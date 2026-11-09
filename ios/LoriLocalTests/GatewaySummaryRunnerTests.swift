import Combine
import XCTest
@testable import LoriLocal

@MainActor
final class GatewaySummaryRunnerTests: XCTestCase {
    private var root: URL!
    private var store: SummaryStore!
    private var recaps: RecordingSummaryStore!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "gateway-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SummaryStore(url: root.appending(path: "titles.json"))
        recaps = RecordingSummaryStore(url: root.appending(path: "recaps.json"))
    }
    override func tearDown() async throws {
        StubURLProtocol.reset()
        try FileManager.default.removeItem(at: root)
    }
    private func client(failing: Bool = false, release: LockedValue<Bool>? = nil) -> GatewayClient {
        var client = GatewayClient(baseURL: URL(string: "https://stub.invalid/gateway")!, token: "fixture", session: StubURLProtocol.session { request, _ in
            if failing { return .json(#"{"error":{"code":"queue"}}"#, status: 503) }
            if request.httpMethod == "POST" { return .json(#"{"id":"job","state":"queued"}"#, status: 202) }
            if let release, !release.mutate({ $0 }) { return .json(#"{"state":"running"}"#) }
            return .json("{\"state\":\"done\",\"result\":\(GatewayClientTests.annotation)}")
        })
        client.pollInterval = 0.01
        return client
    }
    private func runner(client: GatewayClient, source: AnnotationSource = .gateway, autoSummary: Bool = true) -> SummaryRunner {
        SummaryRunner(models: SummaryModelStore(root: root), store: store, availableMemory: { 1 }, isForeground: { false }, summarize: { _, _, _ in
            XCTFail("Шлюз не запускает Qwen")
            return .init(title: "", detail: "")
        }, recordingSummaries: recaps, sourceProvider: { source }, gatewayProvider: { client }, autoSummaryProvider: { autoSummary })
    }

    func testGatewayBypassesWeightsMemoryForegroundAndRecordingAndProtectsManualTitle() async throws {
        let client = client()
        let runner = runner(client: client)
        let recording = CurrentValueSubject<Bool, Never>(true)
        runner.follow(recording: recording.eraseToAnyPublisher())
        store.setManual(title: "Моё имя", for: "a.wav")
        let text = String(repeating: "Вся запись целиком. ", count: 3000)
        runner.transcriptSaved(path: "a.wav", text: text)
        await eventually("итог и заголовок") { runner.pendingCount == 0 }
        XCTAssertEqual(store.title(for: "a.wav"), "Моё имя")
        XCTAssertEqual(store.detail(for: "a.wav"), "Обсудили выпуск.")
        XCTAssertNotNil(recaps.entry(for: "a.wav"))
        let post = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: post.body) as? [String: String])?["transcript"], text.trimmingCharacters(in: .whitespacesAndNewlines))
        runner.transcriptSaved(path: "a.wav", text: text)
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "тот же текст не посылается второй раз")
    }

    func testAutomaticSummaryCanBeOffWhileGatewayStillMakesTitles() async {
        let runner = runner(client: client(), autoSummary: false)
        runner.transcriptSaved(path: "a.wav", text: "Новая запись")
        await eventually("заголовок без автоматического итога") { runner.pendingCount == 0 }
        XCTAssertEqual(store.title(for: "a.wav"), "Выпуск Лори")
        XCTAssertNil(recaps.entry(for: "a.wav"))
        runner.requestSummary(for: "a.wav", text: "Новая запись")
        await eventually("явный итог при выключенном автомате") { runner.pendingCount == 0 }
        XCTAssertNotNil(recaps.entry(for: "a.wav"))
    }

    func testExplicitTitleReplacesManualOnlyAfterSuccess() async {
        let runner = runner(client: client())
        store.setManual(title: "Моё имя", for: "a.wav")
        XCTAssertEqual(runner.requestTitle(for: "a.wav", text: "Короткая запись."), .queued)
        XCTAssertEqual(store.title(for: "a.wav"), "Моё имя")
        await eventually("ответ по заголовку") { runner.pendingCount == 0 }
        XCTAssertEqual(store.title(for: "a.wav"), "Выпуск Лори")
    }

    func testUnavailableGatewayKeepsQueueAndShowsReasonWithoutFallback() async {
        let runner = runner(client: client(failing: true))
        store.setManual(title: "Моё имя", for: "a.wav")
        runner.transcriptSaved(path: "a.wav", text: "Достаточно даже короткой записи.")
        await eventually("ошибка шлюза") { runner.running == nil && runner.failure != nil }
        XCTAssertEqual(runner.pendingCount, 1)
        XCTAssertTrue(runner.waitingReason?.contains("занят") == true)
        XCTAssertEqual(store.title(for: "a.wav"), "Моё имя")
        let saved = try? Data(contentsOf: store.pendingQueueURL)
        let text = saved.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(text.contains("a.wav"))
        XCTAssertFalse(text.contains("Достаточно"), "очередь содержит путь, а не расшифровку")
    }

    func testTextChangeMarksOldSummaryStaleWhileReplacementRuns() async {
        let release = LockedValue(false)
        let runner = runner(client: client(release: release))
        recaps.store(RecordingSummaryTests.summary, for: "a.wav", fingerprint: SummaryStore.fingerprint(of: "Старый текст"))
        store.store(title: "Старый", detail: "Описание", for: "a.wav", source: SummaryStore.fingerprint(of: "Старый текст"))
        runner.transcriptSaved(path: "a.wav", text: "Изменённый текст")
        XCTAssertEqual(recaps.entry(for: "a.wav")?.stale, true)
        XCTAssertEqual(store.entry(for: "a.wav")?.stale, true)
        release.mutate { $0 = true }
        await eventually("обновлённый итог") { runner.pendingCount == 0 }
        XCTAssertEqual(recaps.entry(for: "a.wav")?.stale, false)
        XCTAssertEqual(recaps.entry(for: "a.wav")?.fingerprint, SummaryStore.fingerprint(of: "Изменённый текст"))
        runner.move(from: "a.wav", to: "b.wav")
        XCTAssertNotNil(recaps.entry(for: "b.wav"))
        runner.forget("b.wav")
        XCTAssertNil(recaps.entry(for: "b.wav"))
    }

    func testExplicitSummaryUsesGatewayWithLocalTitlesWithoutReplacingManualName() async {
        let runner = runner(client: client(), source: .local)
        store.setManual(title: "Моё имя", for: "a.wav")
        // Даже разрешённая прежней просьбой замена имени не относится к «Сделать итог».
        store.allowGeneratedTitle(for: "a.wav")
        runner.requestSummary(for: "a.wav", text: "Короткий текст")
        await eventually("итог при локальном источнике заголовков") { runner.pendingCount == 0 }
        XCTAssertNotNil(recaps.entry(for: "a.wav"))
        XCTAssertEqual(store.title(for: "a.wav"), "Моё имя")
    }
}
