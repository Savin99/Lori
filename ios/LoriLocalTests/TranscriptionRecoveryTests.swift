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

// MARK: - Фоновая расшифровка не обрывается (24 октября 2026)

/// Доля для полосы фоновой задачи, запись, оставленная ждать системную передачу, и
/// пробуждение системой после убитого процесса.
///
/// Свой класс в этом файле, а не свой файл: новый файл тестов требует пересборки
/// `LoriLocal.xcodeproj` через xcodegen, а проект в эти дни правит соседняя ветка.
@MainActor
final class BackgroundTransferTests: XCTestCase {
    private var fixture: QueueFixture!
    private let restored = [
        TranscriptionSettings.engineKey, TranscriptionSettings.concurrencyKey,
        TranscriptionSettings.elevenLabsBaseURLKey, TranscriptionSettings.elevenLabsModelKey,
        TranscriptionSettings.elevenLabsModeKey, TranscriptionSettings.vocabularyKey,
        TranscriptionSettings.languageKey, TranscriptionSettings.timecodesKey,
        TranscriptionSettings.speakerLabelsKey,
    ]
    private var saved: [String: Any] = [:]

    override func setUp() async throws {
        saved = [:]
        for key in restored {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        StubURLProtocol.reset()
        for key in restored { UserDefaults.standard.removeObject(forKey: key) }
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
    }

    /// Ждёт, пока главная очередь отдаст всё, что в неё положили раньше: доклады
    /// транспорта о фазе запроса приходят через `DispatchQueue.main` и по порядку.
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: Доля для полосы фоновой задачи

    /// Формула целиком: загрузка меряется байтами, ожидание ответа — оценкой по времени,
    /// которая движется и через час, а «готово» не ставит никто, кроме завершения. Потолок
    /// 0,95 — множитель всей доли: первая версия обрезала по нему, и тест поймал, что
    /// оценка ожидания вставала на 18-й минуте.
    func testBackgroundShareMeasuresTheUploadAndEstimatesTheAnswerBelowOne() {
        typealias Service = TranscriptionService
        typealias Request = Service.RequestProgress
        let single = Service.Parts(done: 0, total: 1)
        let ceiling = Service.inFlightCeiling

        // Аудио ещё готовится, запроса нет — мерить нечего: оценка по времени, как велит контракт.
        let preparing = Service.backgroundShare(parts: single, request: nil, elapsed: 60)
        XCTAssertEqual(preparing.source, .estimate)
        XCTAssertEqual(preparing.value, ceiling * Service.elapsedShare(seconds: 60), accuracy: 1e-12)
        XCTAssertGreaterThan(preparing.value, 0, "ноль на подготовке планировщик принимает за подвисшую задачу")
        let threeHours = Service.backgroundShare(parts: nil, request: nil, elapsed: 3 * 3600).value
        let threeHoursAndSecond = Service.backgroundShare(parts: nil, request: nil, elapsed: 3 * 3600 + 1).value
        XCTAssertGreaterThan(threeHoursAndSecond, threeHours, "и оценка без доли не упирается в потолок: прежняя прямая стояла с 27-й минуты")
        XCTAssertEqual(Service.backgroundShare(parts: nil, request: nil, elapsed: 60), preparing,
                       "движок ещё ни разу не сказал о частях — то же самое")

        // Загрузка: половина куска — это отправка тела, доля по байтам системы.
        let sending = Service.backgroundShare(parts: single, request: Request(sent: 0.4, sending: 3), elapsed: 70)
        XCTAssertEqual(sending.source, .upload)
        XCTAssertEqual(sending.value, ceiling * 0.2, accuracy: 1e-12)

        // Объём неизвестен — оценка по времени отправки. Здесь раньше стояло
        // `XCTAssertEqual(unknown.value, 0)`: тест закреплял неподвижную полосу на всю
        // отправку, ровно то, за что планировщик снимает задачу (ревью 24 октября 2026).
        let unknown = Service.backgroundShare(parts: single, request: Request(sent: nil, sending: 60), elapsed: 70)
        XCTAssertEqual(unknown.source, .uploadEstimate)
        XCTAssertGreaterThan(unknown.value, 0)
        XCTAssertGreaterThan(
            Service.backgroundShare(parts: single, request: Request(sent: nil, sending: 61), elapsed: 71).value, unknown.value,
            "и движется со временем"
        )
        // Байты стоят — время всё равно двигает, но в половину загрузки и не выше.
        let stuck = Service.backgroundShare(parts: single, request: Request(sent: 0.1, sending: 600), elapsed: 700)
        XCTAssertEqual(stuck.source, .uploadEstimate)
        XCTAssertGreaterThan(stuck.value, ceiling * 0.05)
        XCTAssertLessThan(stuck.value, ceiling * Service.uploadWeight, "отправка не выдаётся за ожидание ответа")

        // Тело ушло: от половины и дальше — оценка по времени ожидания.
        let justSent = Service.backgroundShare(parts: single, request: Request(sent: 1, sending: 10, waited: 0), elapsed: 90)
        XCTAssertEqual(justSent.source, .answer)
        XCTAssertEqual(justSent.value, ceiling * 0.5, accuracy: 1e-12)
        let twoMinutes = Service.backgroundShare(parts: single, request: Request(sent: 1, sending: 130, waited: Service.answerHalfTime), elapsed: 210)
        XCTAssertEqual(twoMinutes.value, ceiling * 0.75, accuracy: 1e-12, "за `answerHalfTime` закрыта половина остатка")

        var previous = justSent.value
        for minute in 1...180 {
            let waited = Double(minute) * 60
            let value = Service.backgroundShare(parts: single, request: Request(sent: 1, sending: waited, waited: waited), elapsed: 0).value
            XCTAssertGreaterThan(value, previous, "оценка обязана двигаться и на \(minute)-й минуте ожидания")
            XCTAssertLessThan(value, ceiling, "идущая запись не доходит до потолка, пока ответа нет")
            previous = value
        }
        let hour = Service.backgroundShare(parts: single, request: Request(sent: 1, sending: 3600, waited: 3600), elapsed: 0).value
        let hourAndSecond = Service.backgroundShare(parts: single, request: Request(sent: 1, sending: 3601, waited: 3601), elapsed: 0).value
        XCTAssertGreaterThan(
            (hourAndSecond - hour) * Double(TranscriptionRunway.unitsPerRecord), 1,
            "и через час за секунду полоса сдвигается хотя бы на единицу"
        )
        // Повтор загрузки в той же части (ElevenLabs без словаря) ожидание не обнуляет.
        let retry = Service.backgroundShare(parts: single, request: Request(sent: 0.1, sending: 300, waited: 200), elapsed: 300)
        XCTAssertEqual(retry.source, .answer)
        XCTAssertGreaterThan(retry.value, justSent.value)

        // Ответ в руках («1 из 1»), запись разбирается и сохраняется — потолок, но не сотня.
        let answered = Service.backgroundShare(parts: Service.Parts(done: 1, total: 1), request: nil, elapsed: 300)
        XCTAssertEqual(answered.source, .parts)
        XCTAssertEqual(answered.value, ceiling, accuracy: 1e-12)
        XCTAssertLessThan(answered.value, 1, "сотню ставит только настоящее завершение")

        // По частям: готовые части плюс доля текущей.
        let parts = Service.Parts(done: 3, total: 9)
        XCTAssertEqual(Service.backgroundShare(parts: parts, request: Request(sent: 0.5, sending: 0), elapsed: 0).value,
                       ceiling * 3.25 / 9, accuracy: 1e-12)
        XCTAssertEqual(Service.backgroundShare(parts: parts, request: Request(sent: 1, sending: 0, waited: 0), elapsed: 0).value,
                       ceiling * 3.5 / 9, accuracy: 1e-12)
        let local = Service.backgroundShare(parts: Service.Parts(done: 3, total: 10), request: nil, elapsed: 1800)
        XCTAssertEqual(local.source, .parts)
        XCTAssertEqual(local.value, ceiling * 0.3, accuracy: 1e-12, "у записи с частями оценка по времени не подменяет измеренное")
    }

    func testTransferPhaseIsReadFromTheSystemCounters() {
        XCTAssertEqual(TransferPhase.from(sent: 0, expected: 100).sentShare, 0)
        XCTAssertEqual(TransferPhase.from(sent: 45, expected: 100).sentShare ?? -1, 0.45, accuracy: 1e-12)
        XCTAssertEqual(TransferPhase.from(sent: 100, expected: 100), .awaiting, "тело ушло целиком — ждём ответ")
        XCTAssertEqual(TransferPhase.from(sent: 120, expected: 100), .awaiting)
        XCTAssertEqual(
            TransferPhase.from(sent: 0, expected: 0), .awaiting,
            "тела нет вовсе (GET, задача, подхваченная у системы после перезапуска) — ждём ответ, а не «объём неизвестен»"
        )
        let unknown = TransferPhase.from(sent: 10, expected: -1)
        XCTAssertTrue(unknown.isSending)
        XCTAssertNil(unknown.sentShare, "долю из неизвестного объёма не выдумываем")
        XCTAssertFalse(TransferPhase.awaiting.isSending)
    }

    /// Часы запроса части не сбрасываются опросами и повтором: доля растёт через все фазы.
    /// Раньше каждая фаза начинала ожидание с нуля — опросы Gemini (каждый GET приходит
    /// ожиданием, ответ его сбрасывал) и вторая загрузка ElevenLabs без словаря держали
    /// полосу на месте.
    func testRequestClockIsNotResetByPollsOrARetry() async throws {
        fixture = try QueueFixture(files: ["Облако.m4a"])
        let gate = QueueGate()
        let service = TranscriptionService(
            engines: [.elevenLabs: QueueEngine(gate: gate)],
            interruptedStore: fixture.store,
            availableMemory: { 0 }
        )
        let path = "Облако.m4a"
        service.enqueue(try fixture.entry(path), in: fixture.workspace, using: .elevenLabs)
        await gate.waitForArrivals(1)
        // Доклады — по порядку и со своим временем: так тест не зависит от часов.
        let start = Date()
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        var shares: [Double] = []
        func sample(_ seconds: TimeInterval) { shares.append(service.backgroundShare(for: path, now: at(seconds)).value) }

        // ElevenLabs: загрузка, ожидание, отказ из-за словаря и вторая загрузка с нуля.
        service.transferChanged(path, .sending(sent: 0, expected: 100), now: at(0)); sample(1)
        service.transferChanged(path, .sending(sent: 60, expected: 100), now: at(5)); sample(6)
        service.transferChanged(path, .awaiting, now: at(10)); sample(20)
        service.transferChanged(path, .answered, now: at(30)); sample(31)
        service.transferChanged(path, .sending(sent: 0, expected: 100), now: at(32)); sample(33)
        service.transferChanged(path, .sending(sent: 50, expected: 100), now: at(40)); sample(41)
        // Gemini: опросы — каждый GET приходит ожиданием, ответ приходит через секунды.
        for poll in 0..<5 {
            let t = 50 + Double(poll) * 10
            service.transferChanged(path, .awaiting, now: at(t)); sample(t + 1)
            service.transferChanged(path, .answered, now: at(t + 2)); sample(t + 3)
        }
        for (index, pair) in zip(shares, shares.dropFirst()).enumerated() {
            XCTAssertLessThan(pair.0, pair.1, "доля обязана расти на шаге \(index + 1): \(shares)")
        }
        XCTAssertEqual(
            service.backgroundShare(for: path, now: at(100)).source, .answer,
            "после первого ожидания часть идёт временем, и повтор загрузки её не откатывает"
        )
        await gate.openAll()
        await service.waitForDrain()
    }

    // MARK: Карточка и экран

    /// Доля загрузки подписана «Отправляю», а не «Расшифровываю»: в конце загрузки
    /// запись ещё не расшифрована. Ждём ответ — полоса бегущим отрезком, без процента.
    func testCardSaysSendingWithTheUploadShareThenWaitsForTheService() throws {
        let sending = try XCTUnwrap(RecordStatus.make(state: .sending(0.453), hasTranscript: false, fraction: nil, remaining: nil))
        XCTAssertEqual(sending.text, "Отправляю · 45%")
        XCTAssertEqual(sending.fraction, 0.453)
        XCTAssertTrue(sending.showsBar)
        XCTAssertNil(sending.action)
        XCTAssertEqual(sending.tone, .working)
        XCTAssertEqual(RecordStatus.make(state: .sending(nil), hasTranscript: false, fraction: nil, remaining: nil)?.text, "Отправляю")

        let waiting = try XCTUnwrap(RecordStatus.make(state: .awaitingService, hasTranscript: true, fraction: 0.4, remaining: 30))
        XCTAssertEqual(waiting.text, "Жду ответ сервиса")
        XCTAssertNil(waiting.fraction, "сколько ждать ответа, не знает никто — процента нет")
        XCTAssertTrue(waiting.showsBar)
        XCTAssertNil(waiting.action, "ни «Продолжить», ни «Повторить»: запись не прервана")

        for state in [TranscriptionRecordState.sending(0.1), .awaitingService] {
            XCTAssertTrue(state.isActive, "\(state): запись занята")
            XCTAssertFalse(state.allowsRename, "\(state): задание держит путь")
        }
    }

    /// Запись одним запросом получает фазу от транспорта (здесь движок докладывает сам —
    /// так же, как транспорт, через `BackgroundTranscriptionTransport.report`).
    func testServiceShowsTheTransferPhaseOfASingleRequestRecord() async throws {
        fixture = try QueueFixture(files: ["Облако.m4a"])
        let gate = QueueGate()
        let service = TranscriptionService(
            engines: [.elevenLabs: ReportingEngine(gate: gate)],
            interruptedStore: fixture.store,
            availableMemory: { 0 }
        )
        let path = "Облако.m4a"
        service.enqueue(try fixture.entry(path), in: fixture.workspace, using: .elevenLabs)

        await gate.waitForArrivals(1)
        await drainMainQueue()
        XCTAssertEqual(service.state(for: path), .sending(0.3))
        XCTAssertEqual(service.progressText(for: path), "отправляю запись · 30%")
        XCTAssertNil(service.progressFraction(for: path), "доля загрузки не выдаётся за долю расшифровки")
        XCTAssertEqual(service.backgroundShare(for: path).source, .upload)

        await gate.release()
        await gate.waitForArrivals(2)
        await drainMainQueue()
        XCTAssertEqual(service.state(for: path), .awaitingService)
        XCTAssertEqual(service.progressText(for: path), "жду ответ сервиса")
        XCTAssertEqual(service.backgroundShare(for: path).source, .answer)
        XCTAssertGreaterThanOrEqual(
            service.backgroundShare(for: path).value,
            TranscriptionService.inFlightCeiling * TranscriptionService.uploadWeight,
            "тело ушло — половина куска сделана"
        )

        await gate.release()
        await service.waitForDrain()
        XCTAssertNoThrow(try fixture.workspace.readText(at: "Transcripts/Облако.md"))
        XCTAssertTrue(service.transfer.isEmpty, "после записи фаза не висит")
    }

    // MARK: Истечение фонового времени

    /// Главное правило захода: истечение не трогает облачную запись, чей запрос у
    /// системной передачи, — она не «Прервано», не отменена и доделывается, когда
    /// приходит ответ. Локальная рядом прерывается, как и раньше.
    func testExpiryLeavesACloudRecordInSystemTransferAndInterruptsALocalOne() async throws {
        fixture = try QueueFixture(files: ["Облако.m4a", "Телефон.m4a"])
        UserDefaults.standard.set(2, forKey: TranscriptionSettings.concurrencyKey)
        let gate = QueueGate()
        let asked = Asked()
        let service = TranscriptionService(
            engines: [.elevenLabs: QueueEngine(gate: gate), .gigaam: QueueEngine(gate: gate)],
            interruptedStore: fixture.store,
            availableMemory: { 0 },
            transfers: .init(holds: { asked.ids.append($0); return true }, hasAnswer: { _ in false }, takeDeferral: { _ in false })
        )
        service.enqueue(try fixture.entry("Облако.m4a"), in: fixture.workspace, using: .elevenLabs)
        service.enqueue(try fixture.entry("Телефон.m4a"), in: fixture.workspace, using: .gigaam)
        await gate.waitForArrivals(2)

        let parked = service.interruptEverything()
        XCTAssertEqual(parked, ["Облако.m4a"])
        XCTAssertEqual(asked.ids.count, 1, "у локального движка у системы ничего нет — его и не спрашиваем")
        XCTAssertEqual(service.state(for: "Облако.m4a"), .awaitingService, "не «Прервано»: ответ придёт сам")
        XCTAssertFalse(service.isInterrupted("Облако.m4a"))
        XCTAssertEqual(service.state(for: "Телефон.m4a"), .interrupted)
        XCTAssertEqual(
            InterruptedRecords.load(from: fixture.store),
            ["Облако.m4a": .elevenLabs, "Телефон.m4a": .gigaam],
            "облачная запись остаётся в файле: убьют процесс — её доделает пробуждение по расписке"
        )

        await gate.openAll()
        let outcome = await service.waitForDrain()
        XCTAssertEqual(outcome?.succeeded, ["Облако.m4a"], "оставленная ждать запись доделана, а не отменена")
        XCTAssertEqual(outcome?.interrupted, ["Телефон.m4a"])
        XCTAssertNoThrow(try fixture.workspace.readText(at: "Transcripts/Облако.md"))
        XCTAssertThrowsError(try fixture.workspace.readText(at: "Transcripts/Телефон.md"))
        XCTAssertEqual(InterruptedRecords.load(from: fixture.store), ["Телефон.m4a": .gigaam])
    }

    /// Облачная запись, у которой у системы ничего нет (готовит аудио, разбирает ответ),
    /// прерывается как раньше: продолжение по расписке ничего не отправит заново.
    func testExpiryInterruptsACloudRecordThatHoldsNothingAtTheSystem() async throws {
        fixture = try QueueFixture(files: ["Облако.m4a"])
        let gate = QueueGate()
        let service = TranscriptionService(
            engines: [.elevenLabs: QueueEngine(gate: gate)],
            interruptedStore: fixture.store,
            availableMemory: { 0 },
            transfers: .init(holds: { _ in false })
        )
        service.enqueue(try fixture.entry("Облако.m4a"), in: fixture.workspace, using: .elevenLabs)
        await gate.waitForArrivals(1)

        XCTAssertEqual(service.interruptEverything(), [])
        XCTAssertEqual(service.state(for: "Облако.m4a"), .interrupted)
        await gate.openAll()
        let outcome = await service.waitForDrain()
        XCTAssertEqual(outcome?.interrupted, ["Облако.m4a"])
    }

    /// Человек вернулся, пока запись ждала систему: она снова обычная идущая запись.
    func testReturnToTheAppTurnsAParkedRecordBackIntoARunningOne() async throws {
        fixture = try QueueFixture(files: ["Облако.m4a"])
        let gate = QueueGate()
        let service = TranscriptionService(
            engines: [.elevenLabs: QueueEngine(gate: gate)],
            interruptedStore: fixture.store,
            availableMemory: { 0 },
            transfers: .init(holds: { _ in true })
        )
        service.enqueue(try fixture.entry("Облако.m4a"), in: fixture.workspace, using: .elevenLabs)
        await gate.waitForArrivals(1)
        service.applicationDidEnterBackground()
        XCTAssertEqual(service.interruptEverything(), ["Облако.m4a"])
        XCTAssertEqual(service.state(for: "Облако.m4a"), .awaitingService)

        service.applicationDidBecomeActive(in: fixture.workspace)
        XCTAssertEqual(service.state(for: "Облако.m4a"), .running, "на экране фаза видна вживую, а не по отметке")
        await gate.openAll()
        await service.waitForDrain()
        XCTAssertNoThrow(try fixture.workspace.readText(at: "Transcripts/Облако.md"))
    }

    /// Оставленная ждать запись проснулась и пошла дальше — готовит следующую часть, у
    /// системы ничего не держа, — и окно кончилось снова. Её обязаны прервать по-настоящему:
    /// раньше отметка «ждёт систему» оставалась, отмена её пропускала, и запись числилась
    /// «Прервано», продолжая работать и сохраняя текст.
    func testParkedRecordThatMovedOnIsInterruptedOnTheNextExpiry() async throws {
        fixture = try QueueFixture(files: ["Облако.m4a"])
        let gate = QueueGate()
        let holds = Toggle(true)
        let service = TranscriptionService(
            engines: [.elevenLabs: QueueEngine(gate: gate)],
            interruptedStore: fixture.store,
            availableMemory: { 0 },
            transfers: .init(holds: { _ in holds.value })
        )
        let path = "Облако.m4a"
        service.enqueue(try fixture.entry(path), in: fixture.workspace, using: .elevenLabs)
        await gate.waitForArrivals(1)
        XCTAssertEqual(service.interruptEverything(), [path])

        holds.value = false
        XCTAssertEqual(service.interruptEverything(), [], "у системы больше ничего нет — ждать нечего")
        XCTAssertEqual(service.state(for: path), .interrupted)

        await gate.openAll()
        let outcome = await service.waitForDrain()
        XCTAssertEqual(outcome?.interrupted, [path])
        XCTAssertThrowsError(
            try fixture.workspace.readText(at: "Transcripts/Облако.md"),
            "прерванная запись отменена и текст не сохранила — продолжит при возвращении"
        )
    }

    // MARK: Постановка из фона

    /// «Расшифровать» из Dynamic Island, когда Lori не на экране: запись обязана пойти
    /// сразу под запасным окном, а не ждать в очереди возвращения в приложение. Раньше
    /// `admit` шёл до `batchDidStart`, окна ещё не было, и запись оставалась в очереди.
    ///
    /// Состояние приложения — из хука: первая версия теста ставила `isActive = false`, а
    /// `batchDidStart` спрашивал `UIApplication` (в тестовом хосте он активен) и шёл веткой
    /// подачи заявки, а не фоновой.
    func testRecordQueuedFromTheBackgroundStartsUnderTheGraceWindow() async throws {
        fixture = try QueueFixture(files: ["Из фона.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate, kind: .elevenLabs)
        let system = FakeSystem(active: false)
        let runway = TranscriptionRunway(service: service, hooks: system.hooks())
        service.runway = runway
        service.applicationDidEnterBackground()

        service.enqueue(try fixture.entry("Из фона.m4a"), in: fixture.workspace, using: .elevenLabs)
        XCTAssertEqual(system.submitted, [], "из фона заявку не подать — и не подаём")
        XCTAssertTrue(system.isOpen("Lori transcription"), "открыто запасное окно")
        XCTAssertNil(service.queuePosition(for: "Из фона.m4a"), "запись не осталась ждать в очереди")
        XCTAssertTrue(service.isActive("Из фона.m4a"))
        XCTAssertTrue(runway.canExecuteInBackground, "её держит запасное окно")

        await gate.waitForArrivals(1)
        await gate.openAll()
        await service.waitForDrain()
        XCTAssertNoThrow(try fixture.workspace.readText(at: "Transcripts/Из фона.md"))
        XCTAssertFalse(system.isOpen("Lori transcription"), "пачка кончилась — окно отпущено")
    }

    /// Локальной записи, поставленной из фона, 30 секунд запасного окна не хватит: она
    /// ждёт в очереди и идёт, когда Lori откроют, а не начинает считать, чтобы тут же стать
    /// «Прервано».
    func testLocalRecordQueuedFromTheBackgroundWaitsForTheApp() async throws {
        fixture = try QueueFixture(files: ["Телефон.m4a"])
        let gate = QueueGate()
        let service = fixture.service(gate: gate, kind: .gigaam)
        let system = FakeSystem(active: false)
        let runway = TranscriptionRunway(service: service, hooks: system.hooks())
        service.runway = runway
        service.applicationDidEnterBackground()

        service.enqueue(try fixture.entry("Телефон.m4a"), in: fixture.workspace, using: .gigaam)
        XCTAssertEqual(service.queuePosition(for: "Телефон.m4a"), 1, "ждёт в очереди")
        XCTAssertEqual(service.state(for: "Телефон.m4a"), .queued(position: 1, waitsForMemory: false))

        system.active = true
        service.applicationDidBecomeActive(in: fixture.workspace)
        await gate.waitForArrivals(1)
        XCTAssertTrue(service.isActive("Телефон.m4a"), "Lori открыли — пошла")
        await gate.openAll()
        await service.waitForDrain()
        XCTAssertNoThrow(try fixture.workspace.readText(at: "Transcripts/Телефон.md"))
    }

    // MARK: Пробуждение системой после убитого процесса

    nonisolated private static let receiptAnswer = #"{"text":"Ответ из расписки.","language_code":"rus","words":[{"text":"Ответ","start":0.0,"end":0.3,"type":"word"},{"text":" ","start":0.3,"end":0.35,"type":"spacing"},{"text":"из","start":0.35,"end":0.5,"type":"word"},{"text":" ","start":0.5,"end":0.55,"type":"spacing"},{"text":"расписки.","start":0.55,"end":0.95,"type":"word"}]}"#

    /// Задание ElevenLabs и ровно тот запрос, который его движок отправит для этой записи:
    /// запрос записывается подставной сессией, а не собирается в тесте руками — расписка
    /// подходит только к байт-в-байт тому же телу.
    private func cloudJob(for url: URL) async throws -> (job: TranscriptionJob, requestID: String) {
        // Адрес, которого нет: если транспорт всё-таки отправит запрос, тест увидит это
        // по ошибке записи, а не по счёту за чужую расшифровку.
        UserDefaults.standard.set("https://stub.invalid/v1", forKey: TranscriptionSettings.elevenLabsBaseURLKey)
        let job = TranscriptionJob.capture(kind: .elevenLabs)
        let recorder = ElevenLabsTranscriber(session: StubURLProtocol.session { _, _ in .json(Self.receiptAnswer) }, keyProvider: { "тест-ключ" })
        _ = try await TranscriptionJob.$current.withValue(job) { try await recorder.transcribe(audioURL: url) }
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        var request = URLRequest(url: try XCTUnwrap(sent.request.url))
        request.httpMethod = sent.request.httpMethod
        request.httpBody = sent.body
        return (job, BackgroundTranscriptionTransport.requestID(request, jobID: job.id))
    }

    /// Пробуждение с пределом времени: настоящая фоновая сессия в тестовом хосте отвечает
    /// за миллисекунды, но зависни она — тест обязан упасть, а не повесить весь прогон.
    private func wake(_ service: TranscriptionService) async throws -> TranscriptionService.SystemWakeReport {
        let finished = expectation(description: "пробуждение доделано")
        let box = WakeBox()
        let workspace = fixture.workspace
        Task { @MainActor in
            box.report = await service.finishAfterSystemWake(in: workspace)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 60)
        return try XCTUnwrap(box.report)
    }

    private func wakeService() -> TranscriptionService {
        TranscriptionService(
            engines: [.elevenLabs: ElevenLabsTranscriber(keyProvider: { "тест-ключ" }), .gigaam: QueueEngine(gate: QueueGate())],
            interruptedStore: fixture.store,
            availableMemory: { 0 }
        )
    }

    /// Процесс убили, пока запрос был у системы; ответ пришёл распиской, система подняла
    /// приложение в фоне. Запись доделывается по расписке — без нового запроса, — а
    /// локальная рядом не поднимается вовсе.
    func testWakeFinishesARecordFromItsReceiptWithoutANewRequest() async throws {
        fixture = try QueueFixture()
        let audio = fixture.root.appending(path: "Облако.wav")
        try AudioFixture.wav(at: audio)
        try fixture.addAudio("Телефон.m4a")
        try fixture.workspace.refresh()
        let (job, requestID) = try await cloudJob(for: audio)
        defer { BackgroundTranscriptionTransport.shared.cancel(jobID: job.id) }
        try BackgroundTranscriptionTransport.saveReceipt(
            status: 200, headers: ["Content-Type": "application/json"],
            url: URL(string: "https://stub.invalid/v1/speech-to-text")!,
            body: Data(Self.receiptAnswer.utf8), for: requestID
        )
        let local = TranscriptionJob.capture(kind: .gigaam)
        try InterruptedRecords.saveJobs(["Облако.wav": job, "Телефон.m4a": local], to: fixture.store)
        XCTAssertTrue(BackgroundTranscriptionTransport.shared.hasAnswer(forJob: job.id))

        let service = wakeService()
        XCTAssertTrue(service.isInterrupted("Облако.wav"), "после перезапуска запись «Прервано» — до пробуждения")
        let launched = BackgroundTranscriptionTransport.shared.launchedTransfers
        let requests = StubURLProtocol.requests.count

        let report = try await wake(service)

        XCTAssertEqual(report.resumed, ["Облако.wav"], "локальная по пробуждению не поднимается")
        XCTAssertEqual(report.outcome?.succeeded, ["Облако.wav"])
        let text = try fixture.workspace.readText(at: "Transcripts/Облако.md")
        XCTAssertTrue(text.contains("Ответ из расписки."), text)
        XCTAssertEqual(BackgroundTranscriptionTransport.shared.launchedTransfers, launched, "ни одной новой передачи")
        XCTAssertEqual(StubURLProtocol.requests.count, requests)
        XCTAssertNil(service.error(for: "Облако.wav"))
        XCTAssertTrue(service.isInterrupted("Телефон.m4a"))
        XCTAssertEqual(InterruptedRecords.load(from: fixture.store), ["Телефон.m4a": .gigaam])
        XCTAssertFalse(BackgroundTranscriptionTransport.shared.hasAnswer(forJob: job.id), "расписка убрана вместе с заданием")
    }

    /// По заданию есть ответ, но не на тот запрос, который нужен сейчас (у задания по
    /// частям — ответ на прошлую часть): в фоне новый запрос не уходит. Запись остаётся
    /// «Прервано» со своим заданием — не ошибка и не отмена — и продолжится при возвращении.
    func testWakeDoesNotSendARequestThatHasNoAnswerYet() async throws {
        fixture = try QueueFixture()
        let audio = fixture.root.appending(path: "Облако.wav")
        try AudioFixture.wav(at: audio)
        try fixture.workspace.refresh()
        let (job, _) = try await cloudJob(for: audio)
        defer { BackgroundTranscriptionTransport.shared.cancel(jobID: job.id) }
        try BackgroundTranscriptionTransport.saveReceipt(
            status: 200, headers: ["Content-Type": "application/json"],
            url: URL(string: "https://stub.invalid/v1/speech-to-text")!,
            body: Data(Self.receiptAnswer.utf8), for: job.id + "_" + String(repeating: "0", count: 64)
        )
        try InterruptedRecords.saveJobs(["Облако.wav": job], to: fixture.store)

        let service = wakeService()
        let launched = BackgroundTranscriptionTransport.shared.launchedTransfers

        let report = try await wake(service)

        XCTAssertEqual(report.resumed, ["Облако.wav"])
        XCTAssertEqual(BackgroundTranscriptionTransport.shared.launchedTransfers, launched, "в фоне новая отправка не начата")
        XCTAssertTrue(service.isInterrupted("Облако.wav"), "запись ждёт возвращения в Lori")
        XCTAssertNil(service.error(for: "Облако.wav"), "это не ошибка сервиса")
        XCTAssertThrowsError(try fixture.workspace.readText(at: "Transcripts/Облако.md"), "без ответа ничего не сохранено")
        XCTAssertEqual(InterruptedRecords.jobs(from: fixture.store)["Облако.wav"]?.id, job.id, "задание то же — продолжение, а не новая отправка")
    }
}

@MainActor
private final class WakeBox {
    var report: TranscriptionService.SystemWakeReport?
}

/// Переключатель, который тест меняет по ходу, а сервис читает в своём замыкании.
@MainActor
private final class Toggle {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

/// Кого сервис спрашивал о системной передаче.
@MainActor
private final class Asked {
    var ids: [String] = []
}

/// Движок, который докладывает фазы запроса так же, как транспорт, — через
/// `BackgroundTranscriptionTransport.report` — и ждёт шлагбаума на каждой.
private struct ReportingEngine: Transcribing {
    let name = "ElevenLabs · проверка"
    let gate: QueueGate

    func isAvailable() async -> Bool { true }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        progress(0, 1)
        BackgroundTranscriptionTransport.report?(.sending(sent: 30, expected: 100))
        await gate.arrive("отправка")
        BackgroundTranscriptionTransport.report?(.awaiting)
        await gate.arrive("ожидание")
        BackgroundTranscriptionTransport.report?(.answered)
        progress(1, 1)
        return Transcript(text: "готово")
    }
}
