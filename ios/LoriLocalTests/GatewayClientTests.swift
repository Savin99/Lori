import XCTest
@testable import LoriLocal

final class GatewayClientTests: XCTestCase {
    static let annotation = #"{"title":"Выпуск Лори","description":"Обсудили выпуск.","summary":{"brief":"Анна проверит запись.","highlights":["Проверка качества"],"decisions":[],"tasks":["Анна — завтра"],"openQuestions":["Словарь?"]}}"#
    override func tearDown() { StubURLProtocol.reset() }

    func client(_ handler: @escaping @Sendable (URLRequest, Data) -> StubURLProtocol.Reply) -> GatewayClient {
        var client = GatewayClient(baseURL: URL(string: "https://stub.invalid/gateway")!, token: "fixture-token", session: StubURLProtocol.session(handler))
        client.pollInterval = 0.01
        return client
    }

    func testLifecycleAndFullPayload() async throws {
        let polls = LockedValue(0)
        let client = client { request, _ in
            if request.httpMethod == "POST" { return .json(#"{"id":"job-1","state":"queued"}"#, status: 202) }
            let count = polls.mutate { $0 += 1; return $0 }
            if count == 1 { return .json(#"{"state":"queued"}"#) }
            if count == 2 { return .json(#"{"state":"running"}"#) }
            return .json("{\"state\":\"done\",\"result\":\(Self.annotation)}")
        }
        let text = String(repeating: "Полная расшифровка. ", count: 2000)
        let answer = try await client.annotate(path: "Imported/a.m4a", transcript: text, language: "ru")
        XCTAssertEqual(answer.summary.tasks, ["Анна — завтра"])
        XCTAssertEqual(StubURLProtocol.requests.count, 4)
        let post = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(post.request.url?.path, "/gateway/v1/jobs")
        XCTAssertEqual(post.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: post.body) as? [String: String])
        XCTAssertEqual(payload["transcript"], text)
        XCTAssertEqual(payload["kind"], "annotate")
        XCTAssertEqual(payload["key"], GatewayClient.key(kind: .annotate, path: "Imported/a.m4a", transcript: text))
        XCTAssertEqual(client.annotateTimeout, 300)
        XCTAssertEqual(client.reportTimeout, 600)
    }

    func testJobAndHTTPErrorsUseCodesAndRetryAfter() async {
        for code in ["auth", "quota", "rate", "queue", "timeout", "agent", "invalid", "size", "missing"] {
            let client = client { _, _ in .json("{\"error\":{\"code\":\"\(code)\",\"message\":\"PRIVATE TRANSCRIPT\",\"retryAfter\":120}}", status: 429) }
            await XCTAssertThrowsErrorAsync(try await client.annotate(path: "a", transcript: "Текст")) { error in
                XCTAssertEqual((error as? GatewayError)?.code, code)
                XCTAssertEqual((error as? GatewayError)?.retryAfter, 120)
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE TRANSCRIPT"))
            }
        }
        let client = client { request, _ in
            request.httpMethod == "POST" ? .json(#"{"id":"a","state":"queued"}"#, status: 202)
            : .json(#"{"state":"failed","error":{"code":"quota","retryAfter":60}}"#)
        }
        await XCTAssertThrowsErrorAsync(try await client.report(path: "a", transcript: "Текст")) { error in
            XCTAssertEqual((error as? GatewayError)?.code, "quota")
        }
    }

    func testTimeoutAndCancellationDeleteJob() async throws {
        for cancelling in [false, true] {
            var client = client { request, _ in
                if request.httpMethod == "POST" { return .json(#"{"id":"slow","state":"queued"}"#, status: 202) }
                if request.httpMethod == "DELETE" { return .json(#"{"state":"cancelled"}"#) }
                return .json(#"{"state":"running"}"#)
            }
            client.annotateTimeout = cancelling ? 10 : 0.03
            let task = Task { try await client.annotate(path: "a", transcript: "Текст") }
            if cancelling {
                while StubURLProtocol.requests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
                task.cancel()
            }
            await XCTAssertThrowsErrorAsync(try await task.value) { error in
                if cancelling { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual((error as? GatewayError)?.code, "timeout") }
            }
            XCTAssertEqual(StubURLProtocol.requests.last?.request.httpMethod, "DELETE")
        }
    }

    func testReportResultAndUnknownState() async throws {
        let client = client { request, _ in
            request.httpMethod == "POST" ? .json(#"{"id":"r","state":"queued"}"#, status: 202)
                : .json(##"{"state":"done","result":{"markdown":"# Отчёт\n\nСуть."}}"##)
        }
        let markdown = try await client.report(path: "a", transcript: "Текст")
        XCTAssertEqual(markdown, "# Отчёт\n\nСуть.")
        let invalid = self.client { request, _ in
            request.httpMethod == "POST" ? .json(#"{"id":"r","state":"queued"}"#, status: 202) : .json(#"{"state":"unexpected"}"#)
        }
        await XCTAssertThrowsErrorAsync(try await invalid.report(path: "a", transcript: "Текст")) { error in
            XCTAssertEqual((error as? GatewayError)?.code, "response")
        }
    }

    func testConnectionHealthThenUsageWithStaleTime() async throws {
        let client = client { request, _ in
            if request.url?.path.hasSuffix("health") == true { return .json(#"{"ok":true}"#) }
            return .json(#"{"groups":[{"name":"Gemini Models","buckets":[{"id":"w","window":"week","remainingFraction":0.96,"resetTime":null},{"id":"h","window":"5h","remainingFraction":0.98}]}],"cachedAt":"2026-11-09T09:15:00.000Z","stale":true}"#)
        }
        let usage = try await client.checkConnection()
        XCTAssertTrue(usage.status.contains("Подключение работает · неделя 96%, 5 часов 98%"))
        XCTAssertTrue(usage.status.contains("по данным на"))
        XCTAssertEqual(StubURLProtocol.requests.map { $0.request.url?.lastPathComponent }, ["health", "usage"])
    }

    func testKeyStableAcrossWhitespaceButChangesWithContentPathOrKind() {
        let key = GatewayClient.key(kind: .annotate, path: "a", transcript: "Слова \n из записи")
        XCTAssertEqual(key.count, 64)
        XCTAssertEqual(key, GatewayClient.key(kind: .annotate, path: "a", transcript: "Слова из записи"))
        XCTAssertNotEqual(key, GatewayClient.key(kind: .report, path: "a", transcript: "Слова из записи"))
        XCTAssertNotEqual(key, GatewayClient.key(kind: .annotate, path: "b", transcript: "Слова из записи"))
        XCTAssertNotEqual(key, GatewayClient.key(kind: .annotate, path: "a", transcript: "Другие слова"))
    }

    func testConfiguredDefaultIsRememberedWithoutSilentFallback() {
        let suite = "GatewaySettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(GatewaySettings.resolveSource(defaults: defaults, configured: false), .local)
        XCTAssertEqual(GatewaySettings.resolveSource(defaults: defaults, configured: true), .gateway)
        XCTAssertEqual(GatewaySettings.resolveSource(defaults: defaults, configured: false), .gateway)
        defaults.set("local", forKey: GatewaySettings.sourceKey)
        XCTAssertEqual(GatewaySettings.resolveSource(defaults: defaults, configured: true), .local)
    }

    func testAddressValidationAndBundledTokenScope() {
        for text in ["", "мусор", "ftp://host/gateway", "https://", "https://a b/gateway", "https://user:pass@host/gateway", "https://host/gateway?token=x"] {
            XCTAssertNil(GatewaySettings.validatedURL(text), text)
        }
        let bundled = GatewaySettings.validatedURL("https://lori.example/gateway")!
        XCTAssertTrue(BundledAPIKeys.allowsBundledGateway(at: bundled, bundled: bundled))
        for text in ["http://lori.example/gateway", "https://other.example/gateway", "https://lori.example/other", "https://lori.example:8443/gateway"] {
            XCTAssertFalse(BundledAPIKeys.allowsBundledGateway(at: URL(string: text)!, bundled: bundled))
        }
        XCTAssertNotNil(GatewaySettings.validatedURL("http://127.0.0.1:18890/gateway"))
        XCTAssertEqual(KeychainAccount.gateway.rawValue, "lori-gateway-token")
        XCTAssertNil(BundledAPIKeys.gatewayURL, "в QA нет личного адреса")
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
