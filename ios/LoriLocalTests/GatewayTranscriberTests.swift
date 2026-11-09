import XCTest
@testable import LoriLocal

final class GatewayTranscriberTests: XCTestCase {
    private var audio: URL!
    private let keys = [TranscriptionSettings.subscriptionModeKey, TranscriptionSettings.subscriptionPartKey,
                        TranscriptionSettings.geminiPartKey, TranscriptionSettings.languageKey,
                        TranscriptionSettings.vocabularyKey, GatewaySettings.baseURLKey]
    override func setUpWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        audio = FileManager.default.temporaryDirectory.appending(path: "gateway-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 30, silenceAt: 16...17, at: audio)
    }
    override func tearDownWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: audio)
    }

    private func client(_ handler: @escaping @Sendable (URLRequest, Data) -> StubURLProtocol.Reply) -> GatewayClient {
        var client = GatewayClient(baseURL: URL(string: "https://stub.invalid/gateway")!, token: "fixture-token", session: StubURLProtocol.session(handler))
        client.pollInterval = 0.001
        return client
    }
    private static let result = #"{"state":"done","result":{"segments":[{"speaker":"S1","start":"09:59","text":"Речь первого."},{"speaker":"S2","start":"00:02","text":"Ответ второго."},{"speaker":"S1","start":null,"text":"Речь первого."}]}}"#

    func testRawAudioHeadersVocabularyAndEstimatedTimeAreNotSpeechTimestamps() async throws {
        UserDefaults.standard.set("speakers", forKey: TranscriptionSettings.subscriptionModeKey)
        UserDefaults.standard.set("en", forKey: TranscriptionSettings.languageKey)
        UserDefaults.standard.set("Лори, C++\n100% / вопрос?", forKey: TranscriptionSettings.vocabularyKey)
        let client = client { request, _ in
            request.httpMethod == "POST" ? .json(#"{"id":"part","state":"queued"}"#, status: 202) : .json(Self.result)
        }
        let transcript = try await GatewayTranscriber { client }.transcribe(audioURL: audio)
        let post = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(post.body, try Data(contentsOf: audio), "без multipart и JSON, исходный PCM")
        XCTAssertEqual(post.request.url?.path, "/gateway/v1/jobs")
        XCTAssertEqual(post.request.url?.query, "kind=transcribe")
        XCTAssertEqual(post.request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        XCTAssertEqual(post.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertEqual(post.request.value(forHTTPHeaderField: "X-Lori-Speakers"), "1")
        XCTAssertEqual(post.request.value(forHTTPHeaderField: "X-Lori-Language"), "en")
        let vocabulary = try XCTUnwrap(post.request.value(forHTTPHeaderField: "X-Lori-Vocabulary"))
        XCTAssertEqual(vocabulary.removingPercentEncoding, "Лори,C++,100% / вопрос?")
        XCTAssertFalse(vocabulary.contains("+"))
        XCTAssertEqual(post.request.value(forHTTPHeaderField: "X-Lori-Key")?.count, 64)
        XCTAssertEqual(client.transcribeTimeout, 600)
        XCTAssertEqual(GatewayClient(baseURL: client.baseURL, token: "fixture").pollInterval, 2)
        XCTAssertEqual(transcript.segments.map(\.text), ["S1: Речь первого.", "S2: Ответ второго.", "S1: Речь первого."], "повторы внутри одной части не теряются")
        XCTAssertTrue(transcript.words.isEmpty)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.isApproximate && $0.start == 0 && $0.end == 30 })
        XCTAssertTrue(transcript.markdown(title: "Тест", engine: "Gemini (подписка)").contains("**[кусок 0:00–0:30]**"))
        XCTAssertFalse(transcript.markdown(title: "Тест").contains("9:59"))
        XCTAssertTrue(transcript.warnings.contains { $0.contains("S1 в разных частях") })
    }

    func testVerbatimDoesNotAcceptSpeakerLabelsEvenIfServerReturnsThem() async throws {
        let client = client { request, _ in
            request.httpMethod == "POST" ? .json(#"{"id":"part","state":"queued"}"#, status: 202) : .json(Self.result)
        }
        let transcript = try await GatewayTranscriber { client }.transcribe(audioURL: audio)
        XCTAssertEqual(StubURLProtocol.requests.first?.request.value(forHTTPHeaderField: "X-Lori-Speakers"), "0")
        XCTAssertEqual(transcript.segments.first?.text, "Речь первого.")
        XCTAssertFalse(transcript.text.contains("S1:"))
        XCTAssertTrue(transcript.warnings.contains(GatewaySettings.transcriptionNotice))
    }

    func testPartsAlignToPauseOverlapMergeAndKeepRequestLocalSpeakers() async throws {
        UserDefaults.standard.set("speakers", forKey: TranscriptionSettings.subscriptionModeKey)
        let count = LockedValue(0)
        let client = client { request, _ in
            if request.httpMethod == "POST" {
                let index = count.mutate { $0 += 1; return $0 }
                return .json("{\"id\":\"part-\(index)\",\"state\":\"queued\"}", status: 202)
            }
            if request.url?.lastPathComponent == "part-1" {
                return .json(#"{"state":"done","result":{"segments":[{"speaker":"S1","start":"00:15","text":"Общий стык фразы."}]}}"#)
            }
            return .json(#"{"state":"done","result":{"segments":[{"speaker":"S2","start":"00:00","text":"Общий стык фразы."},{"speaker":"S1","start":"00:01","text":"Другой участник отвечает про задачи."}]}}"#)
        }
        let progress = LockedValue([(Int, Int)]())
        let transcript = try await GatewayTranscriber(partLimit: 20, clientProvider: { client }).transcribe(audioURL: audio) {
            a, b in progress.mutate { $0.append((a, b)) }
        }
        XCTAssertEqual(count.mutate { $0 }, 2)
        XCTAssertEqual(transcript.segments.count, 2, "дубль из перекрытия снят SegmentMerge")
        let first = try XCTUnwrap(transcript.segments.first)
        let last = try XCTUnwrap(transcript.segments.last)
        XCTAssertEqual(first.end, 17, accuracy: 1, "граница села на паузу до цели 20 с")
        XCTAssertEqual(first.end - last.start, AudioSplitter.defaultOverlap, accuracy: 0.01)
        XCTAssertEqual(last.end, 30, accuracy: 0.01)
        XCTAssertTrue(last.text.hasPrefix("S1:"), "S1 не переименовывается в человека из первой части")
        let posts = StubURLProtocol.requests.filter { $0.request.httpMethod == "POST" }
        XCTAssertNotEqual(posts[0].request.value(forHTTPHeaderField: "X-Lori-Key"), posts[1].request.value(forHTTPHeaderField: "X-Lori-Key"))
        XCTAssertEqual(posts[0].request.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
        XCTAssertEqual(progress.mutate { $0.last?.0 }, 2)
        XCTAssertEqual(progress.mutate { $0.last?.1 }, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    func testErrorsNameExactFailedPartAndDoNotExposeServerMessage() async throws {
        for (code, expected) in [("auth", "токен"), ("quota", "через 2 мин"), ("timeout", "не успел"), ("agent", "не смог")] {
            let client = client { request, _ in
                if request.httpMethod == "POST" { return .json(#"{"id":"bad","state":"queued"}"#, status: 202) }
                if request.httpMethod == "DELETE" { return .json(#"{"state":"cancelled"}"#) }
                return .json("{\"state\":\"failed\",\"error\":{\"code\":\"\(code)\",\"retryAfter\":120,\"message\":\"PRIVATE\"}}")
            }
            await XCTAssertThrowsErrorAsync(try await GatewayTranscriber { client }.transcribe(audioURL: audio)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Участок 0:00–0:30:"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
            }
        }
    }

    func testFailedSecondPartNamesItsRealBoundsAndNeverReportsCompletion() async throws {
        let count = LockedValue(0)
        let client = client { request, _ in
            if request.httpMethod == "POST" {
                let index = count.mutate { $0 += 1; return $0 }
                return .json("{\"id\":\"part-\(index)\",\"state\":\"queued\"}", status: 202)
            }
            if request.url?.lastPathComponent == "part-1" { return .json(Self.result) }
            return .json(#"{"state":"failed","error":{"code":"agent"}}"#)
        }
        let progress = LockedValue([(Int, Int)]())
        await XCTAssertThrowsErrorAsync(try await GatewayTranscriber(partLimit: 20, clientProvider: { client }).transcribe(audioURL: audio) {
            a, b in progress.mutate { $0.append((a, b)) }
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("–0:30:"))
            XCTAssertFalse(error.localizedDescription.contains("Участок 0:00"))
        }
        XCTAssertFalse(progress.mutate { $0.contains { $0.0 == $0.1 } })
    }

    func testFailedPartContinuesAndRetryAsksOnlyThatPartAfterCheckpointReload() async throws {
        let count = LockedValue(0)
        let client = client { request, _ in
            if request.httpMethod == "POST" {
                let index = count.mutate { $0 += 1; return $0 }
                return .json("{\"id\":\"part-\(index)\",\"state\":\"queued\"}", status: 202)
            }
            if request.url?.lastPathComponent == "part-2" { return .json(#"{"state":"failed","error":{"code":"quota","retryAfter":120}}"#) }
            return .json(Self.result)
        }
        let engine = GatewayTranscriber(partLimit: 12, clientProvider: { client })
        var firstError: PartTranscriptionError?
        do { _ = try await engine.transcribe(audioURL: audio) } catch let error as PartTranscriptionError { firstError = error }
        let failure = try XCTUnwrap(firstError)
        XCTAssertEqual(failure.progress.failedIndices, [1])
        let originalPosts = StubURLProtocol.requests.filter { $0.request.httpMethod == "POST" }
        XCTAssertGreaterThan(originalPosts.count, 2, "сбой второй части не останавливает следующую")
        XCTAssertEqual(failure.progress.completedCount, originalPosts.count - 1)
        if case let .failed(_, reset) = failure.progress.parts[1].phase { XCTAssertNotNil(reset) } else { XCTFail("нет сбоя") }
        let originalKey = originalPosts[1].request.value(forHTTPHeaderField: "X-Lori-Key")
        let source = try XCTUnwrap(audio)
        let transcript = try await TranscriptionParts.$retryPart.withValue(1) {
            try await GatewayTranscriber(partLimit: 12, clientProvider: { client }).transcribe(audioURL: source)
        }
        let posts = StubURLProtocol.requests.filter { $0.request.httpMethod == "POST" }
        XCTAssertEqual(posts.count, originalPosts.count + 1)
        XCTAssertEqual(posts.last?.request.value(forHTTPHeaderField: "X-Lori-Key"), originalKey)
        XCTAssertFalse(transcript.segments.isEmpty)
        let options = try JSONEncoder().encode(["0", TranscriptionSettings.language] + TranscriptionSettings.vocabulary).base64EncodedString()
        let fingerprint = TranscriptCheckpoint.fingerprint(audio: source, engine: "gemini-subscription", model: client.baseURL.absoluteString + "|" + source.path,
            mode: options, partSeconds: 12, vocabulary: TranscriptionSettings.vocabulary)
        XCTAssertNil(TranscriptCheckpoint.load(fingerprint: fingerprint).subscriptionParts, "готовая работа убирает черновик")
    }

    @MainActor
    func testServiceReloadsFailedPartsAndRetriesWithOriginalConditions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "part-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceStore(rootURL: root)
        workspace.start()
        try FileManager.default.copyItem(at: audio, to: root.appending(path: "a.wav"))
        try workspace.refresh()
        let entry = try workspace.entry(at: "a.wav")
        let count = LockedValue(0)
        let client = client { request, _ in
            if request.httpMethod == "POST" {
                let index = count.mutate { $0 += 1; return $0 }
                return .json("{\"id\":\"part-\(index)\",\"state\":\"queued\"}", status: 202)
            }
            if request.url?.lastPathComponent == "part-2" { return .json(#"{"state":"failed","error":{"code":"agent"}}"#) }
            return .json(Self.result)
        }
        let engine = GatewayTranscriber(partLimit: 20, clientProvider: { client })
        let archive = root.appending(path: "jobs.json")
        let service = TranscriptionService(engines: [.geminiSubscription: engine], interruptedStore: archive)
        XCTAssertTrue(service.enqueue(entry, in: workspace, using: .geminiSubscription))
        await eventually("сбой части") { service.isIdle }
        XCTAssertEqual(service.partProgress["a.wav"]?.failedIndices, [1])
        XCTAssertNil(workspace.existingTranscript(for: entry), "неполный текст не выдаётся за готовый")
        UserDefaults.standard.set("speakers", forKey: TranscriptionSettings.subscriptionModeKey)
        let restored = TranscriptionService(engines: [.geminiSubscription: engine], interruptedStore: archive)
        XCTAssertEqual(restored.partProgress["a.wav"]?.failedIndices, [1])
        restored.retryPart(1, entry: entry, in: workspace)
        await eventually("повтор части") { restored.isIdle }
        XCTAssertEqual(count.mutate { $0 }, 3, "повторяется одна из двух частей")
        XCTAssertNil(restored.failed["a.wav"])
        XCTAssertNil(restored.partProgress["a.wav"])
        XCTAssertNotNil(workspace.existingTranscript(for: entry))
        let last = try XCTUnwrap(StubURLProtocol.requests.last { $0.request.httpMethod == "POST" })
        XCTAssertEqual(last.request.value(forHTTPHeaderField: "X-Lori-Speakers"), "0", "режим прежний, хотя настройка уже изменена")
        XCTAssertTrue(InterruptedRecords.partFailures(from: archive).isEmpty)
    }

    func testQueuedGatewayDoesNotPretendTheModelIsListening() async throws {
        let polls = LockedValue(0)
        let started = LockedValue([Int]())
        let client = client { request, _ in
            if request.httpMethod == "POST" { return .json(#"{"id":"queued","state":"queued"}"#, status: 202) }
            let count = polls.mutate { $0 += 1; return $0 }
            if count == 1 { return .json(#"{"state":"queued"}"#) }
            if count == 2 { return .json(#"{"state":"running"}"#) }
            return .json(Self.result)
        }
        let prepared = try CloudAudio.prepare(audio)
        defer { prepared.discard() }
        _ = try await client.transcribe(audio: prepared, key: "queue", speakers: false, language: "ru", vocabulary: [],
            listening: { started.mutate { $0.append(polls.mutate { $0 }) } })
        XCTAssertEqual(started.mutate { $0 }, [2])
    }

    func testTimeoutAndCancellationDeleteAudioJob() async throws {
        for cancelling in [false, true] {
            var client = client { request, _ in
                if request.httpMethod == "POST" { return .json(#"{"id":"slow","state":"queued"}"#, status: 202) }
                if request.httpMethod == "DELETE" { return .json(#"{"state":"cancelled"}"#) }
                return .json(#"{"state":"running"}"#)
            }
            client.transcribeTimeout = cancelling ? 10 : 0.02
            let configuredClient = client
            let engine = GatewayTranscriber { configuredClient }
            let source = try XCTUnwrap(audio)
            let task = Task { try await engine.transcribe(audioURL: source) }
            if cancelling {
                while StubURLProtocol.requests.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
                task.cancel()
            }
            await XCTAssertThrowsErrorAsync(try await task.value) { error in
                if cancelling { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertTrue(error.localizedDescription.contains("не успел")) }
            }
            XCTAssertEqual(StubURLProtocol.requests.last?.request.httpMethod, "DELETE")
        }
    }

    func testEmptyResultAndMalformedSpeakerNeverCreateInventedContent() throws {
        let part = AudioSplitter.Part(url: audio, start: 600, length: 600, isOriginal: true)
        let response = try JSONDecoder().decode([GatewayClient.Segment].self, from: Data(#"[{"speaker":"S0","start":"02:11","text":"Текст"},{"speaker":null,"start":null,"text":"  "}]"#.utf8))
        let segments = GatewayTranscriber.segments(response, part: part, speakers: true)
        XCTAssertEqual(segments, [TranscriptSegment(start: 600, end: 1200, text: "Текст", isApproximate: true)])
    }

    func testAudioKeyIsStableAndSensitiveToPathIndexBoundsAndOptions() {
        func key(_ path: String = "a", _ index: Int = 0, _ start: Double = 0, _ end: Double = 600, _ identity: String = "", _ options: String = "") -> String {
            GatewayClient.audioKey(path: path, index: index, start: start, end: end, identity: identity, options: options)
        }
        XCTAssertEqual(key(), key())
        XCTAssertEqual(key().count, 64)
        for changed in [key("b"), key("a", 1), key("a", 0, 0.001), key("a", 0, 0, 599.999), key("a", 0, 0, 600, "changed"), key("a", 0, 0, 600, "", "speakers")] {
            XCTAssertNotEqual(key(), changed)
        }
        var request = URLRequest(url: URL(string: "https://stub.invalid/v1/jobs?kind=transcribe")!)
        request.httpMethod = "POST"
        request.setValue(key(), forHTTPHeaderField: "X-Lori-Key")
        request.httpBody = Data("export1".utf8)
        let first = BackgroundTranscriptionTransport.requestID(request, jobID: "same-job")
        request.httpBody = Data("export2".utf8)
        XCTAssertEqual(first, BackgroundTranscriptionTransport.requestID(request, jobID: "same-job"), "расписка не зависит от служебных байтов переэкспорта")
        request.setValue(key("b"), forHTTPHeaderField: "X-Lori-Key")
        XCTAssertNotEqual(first, BackgroundTranscriptionTransport.requestID(request, jobID: "same-job"))
    }

    func testBackgroundWakeReusesSubmissionReceiptAndDefersMissingPollWithoutSending() async throws {
        let job = TranscriptionJob.capture(kind: .geminiSubscription)
        defer { BackgroundTranscriptionTransport.shared.cancel(jobID: job.id) }
        let client = GatewayClient(baseURL: URL(string: "https://stub.invalid/gateway")!, token: "fixture", session: CloudSession.shared)
        var request = URLRequest(url: URL(string: "https://stub.invalid/gateway/v1/jobs?kind=transcribe")!)
        request.httpMethod = "POST"
        request.setValue("fixture-key", forHTTPHeaderField: "X-Lori-Key")
        let receipt = BackgroundTranscriptionTransport.requestID(request, jobID: job.id)
        try BackgroundTranscriptionTransport.saveReceipt(status: 202, headers: [:], url: request.url!,
                                                        body: Data(#"{"id":"received","state":"queued"}"#.utf8), for: receipt)
        let launched = BackgroundTranscriptionTransport.shared.launchedTransfers
        let prepared = try CloudAudio.prepare(audio)
        defer { prepared.discard() }
        await XCTAssertThrowsErrorAsync(try await TranscriptionJob.$current.withValue(job) {
            try await BackgroundTranscriptionTransport.$answersOnly.withValue(true) {
                try await client.transcribe(audio: prepared, key: "fixture-key", speakers: false, language: "ru", vocabulary: [])
            }
        }) { error in
            XCTAssertTrue(error is CancellationError, "ожидание без ответа откладывается, а не становится сетевой ошибкой")
        }
        XCTAssertEqual(BackgroundTranscriptionTransport.shared.launchedTransfers, launched)
        XCTAssertTrue(BackgroundTranscriptionTransport.shared.takeDeferral(forJob: job.id))
    }

    @MainActor
    func testReadinessRequiresBothAddressAndTokenAndNeverFallsBack() async {
        for address in [false, true] {
            for token in [false, true] {
                let directory = EngineDirectory(hasKey: { _ in token }, hasGatewayAddress: { address })
                XCTAssertEqual(directory.readiness(of: .geminiSubscription) == .ready, address && token)
            }
        }
        let unavailable = GatewayTranscriber { throw GatewayError(code: "configuration") }
        let available = await unavailable.isAvailable()
        XCTAssertFalse(available)
        let service = TranscriptionService(engines: [.geminiSubscription: unavailable])
        let problem = await service.unavailability(of: .geminiSubscription)
        XCTAssertTrue(problem?.localizedDescription.contains("адрес и токен") == true)
    }

    func testOwnPartLengthModeAndGatewayAddressSurviveJobSnapshot() throws {
        XCTAssertEqual(TranscriptionSettings.subscriptionPartSeconds, 600)
        UserDefaults.standard.set(5, forKey: TranscriptionSettings.geminiPartKey)
        XCTAssertEqual(TranscriptionSettings.subscriptionPartSeconds, 600)
        UserDefaults.standard.set(15, forKey: TranscriptionSettings.subscriptionPartKey)
        UserDefaults.standard.set("speakers", forKey: TranscriptionSettings.subscriptionModeKey)
        UserDefaults.standard.set("https://stub.invalid/first", forKey: GatewaySettings.baseURLKey)
        let job = TranscriptionJob.capture(kind: .geminiSubscription)
        UserDefaults.standard.set(30, forKey: TranscriptionSettings.subscriptionPartKey)
        UserDefaults.standard.set("verbatim", forKey: TranscriptionSettings.subscriptionModeKey)
        UserDefaults.standard.set("https://stub.invalid/other", forKey: GatewaySettings.baseURLKey)
        TranscriptionJob.$current.withValue(job) {
            XCTAssertEqual(TranscriptionSettings.subscriptionPartSeconds, 900)
            XCTAssertEqual(TranscriptionSettings.subscriptionMode, .speakers)
            XCTAssertEqual(GatewaySettings.baseURL?.absoluteString, "https://stub.invalid/first")
        }
        XCTAssertFalse(job.values.keys.contains { $0.lowercased().contains("token") })
    }
}
