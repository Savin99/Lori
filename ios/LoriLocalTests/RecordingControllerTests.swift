import AVFoundation
import XCTest
@testable import LoriLocal

/// Запись в фоне: куски, пауза при прерываниях, восстановление после перезапуска,
/// склейка и постановка в расшифровку (владелец, 24 октября 2026).
///
/// Микрофон и Live Activity — понарошку (`RecordingTestSupport`), файлы кусков —
/// настоящие m4a. Уведомления звуковой сессии подаются в свой `NotificationCenter`
/// с тем же `userInfo`, что шлёт система.
@MainActor
final class RecordingControllerTests: XCTestCase {
    private var fixture: RecordingFixture!

    override func setUp() async throws {
        fixture = RecordingFixture()
    }

    override func tearDown() async throws {
        await fixture.cleanUp()
        fixture = nil
    }

    // MARK: - Старт, пауза, продолжение

    func testStartWritesSessionTraceAndStartsActivityWithoutTouchingTheList() async throws {
        let recorder = fixture.controller()
        try await recorder.start()

        XCTAssertEqual(recorder.phase, .recording)
        XCTAssertEqual(fixture.device.begins.map(\.lastPathComponent), ["part-1.m4a"])
        let session = try XCTUnwrap(try fixture.store.load(), "след записи обязан лечь на диск до начала куска")
        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(session.active, "part-1.m4a")

        await waitUntil { self.fixture.activity.starts == 1 }
        XCTAssertEqual(fixture.activity.endAllCount, 1, "хвост прошлой записи убирается до новой активности")
        XCTAssertEqual(fixture.activity.last?.phase, .recording)
        XCTAssertNotNil(fixture.activity.staleDates.last ?? nil, "идущая запись ставит срок годности активности")

        try fixture.workspace.refresh()
        XCTAssertTrue(fixture.workspace.audio.isEmpty, "недописанные куски не появляются ни в списке, ни в «Файлах»")
    }

    func testPauseClosesTheChunkAndResumeOpensANewOne() async throws {
        fixture.device.chunkSeconds = [2, 3]
        let recorder = fixture.controller()
        try await recorder.start()

        XCTAssertTrue(recorder.pause())
        XCTAssertEqual(recorder.phase, .paused)
        XCTAssertNil(recorder.pauseWords, "паузу поставил человек — объяснять нечего")
        XCTAssertEqual(fixture.device.ends, 1)
        XCTAssertEqual(fixture.device.deactivations, 1, "на паузе микрофон отпущен")
        var session = try XCTUnwrap(try fixture.store.load())
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(session.reason, .user)
        XCTAssertNil(session.active)
        XCTAssertEqual(session.chunks.count, 1)
        XCTAssertEqual(session.chunks[0].duration, 2, accuracy: 0.1, "длительность — по самому закрытому файлу")

        await waitUntil { self.fixture.activity.last?.phase == .paused }
        XCTAssertEqual(fixture.activity.last?.recorded ?? 0, 2, accuracy: 0.1)
        XCTAssertNil(fixture.activity.staleDates.last ?? nil, "на паузе активность не устаревает: Lori законно спит")

        XCTAssertTrue(recorder.resume())
        XCTAssertEqual(recorder.phase, .recording)
        XCTAssertEqual(fixture.device.begins.map(\.lastPathComponent), ["part-1.m4a", "part-2.m4a"])
        recorder.pause()
        session = try XCTUnwrap(try fixture.store.load())
        XCTAssertEqual(session.chunks.map(\.file), ["part-1.m4a", "part-2.m4a"])
        XCTAssertEqual(session.recorded, 5, accuracy: 0.2)
    }

    func testResumeThatCannotGetTheMicrophoneStaysPaused() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        recorder.pause()
        fixture.device.activateError = AudioCaptureError.microphoneBusy

        XCTAssertFalse(recorder.resume())
        XCTAssertEqual(recorder.phase, .paused)
        XCTAssertEqual(recorder.pauseWords, "микрофон занят")
        let session = try XCTUnwrap(try fixture.store.load())
        XCTAssertEqual(session.state, .paused, "на диске не должно остаться «идёт запись»")
        XCTAssertNil(session.active)
        await waitUntil { self.fixture.activity.last?.reason == "микрофон занят" }
    }

    func testRecordingWorksWithLiveActivitiesSwitchedOff() async throws {
        fixture.activity.areEnabled = false
        let recorder = fixture.controller()
        try await recorder.start()

        XCTAssertEqual(recorder.phase, .recording, "запись не зависит от Live Activity")
        await waitUntil { recorder.activityHint != nil }
        XCTAssertEqual(recorder.activityHint, RecordingController.activitiesOffHint)
        XCTAssertEqual(fixture.activity.starts, 0)
    }

    // MARK: - Прерывания

    /// Разговор состоялся — после него ждём «Продолжить», даже если система советует
    /// продолжить (решение владельца).
    func testConnectedCallPausesWithReasonAndWaitsForThePerson() async throws {
        let recorder = fixture.controller()
        try await recorder.start()

        fixture.calls.ring()
        postLegacyInterruption(.began)
        await waitUntil { recorder.phase == .paused }
        XCTAssertEqual(recorder.pauseWords, "звонок")
        XCTAssertEqual(fixture.device.ends, 1, "кусок закрыт файлом сразу")
        await waitUntil { self.fixture.activity.last?.reason == "звонок" }
        XCTAssertTrue(fixture.backgroundTimeTaken.contains("Lori: пауза от системы"), "островок успевает узнать о паузе")
        XCTAssertTrue(fixture.backgroundTimeTaken.contains("Lori: жду конца звонка"), "пока звенит, Lori не усыпят")

        fixture.calls.connect()
        await waitUntil { self.fixture.backgroundTimeReleased == self.fixture.backgroundTimeTaken.count }
        XCTAssertTrue(fixture.log.contains { $0.contains("звонок соединился") })

        // Звонок кончился, система советует продолжить — владелец решил ждать «Продолжить».
        fixture.calls.hangUp()
        postLegacyInterruption(.ended, shouldResume: true)
        await waitUntil { recorder.pauseWords == "звонок закончился" }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(recorder.phase, .paused)
        XCTAssertEqual(fixture.device.begins.count, 1, "после разговора запись не продолжилась сама")
        await waitUntil { self.fixture.activity.last?.reason == "звонок закончился" }
    }

    func testOtherAppInterruptionIsNamedAsSuch() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        postLegacyInterruption(.began)
        await waitUntil { recorder.phase == .paused }
        XCTAssertEqual(recorder.pauseWords, "другое приложение")
    }

    func testMutedMicrophoneInterruption() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        postLegacyInterruption(.began, reason: .builtInMicMuted)
        await waitUntil { recorder.phase == .paused }
        XCTAssertEqual(recorder.pauseWords, "микрофон отключён")
    }

    func testLostInputPausesRecording() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        fixture.center.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )
        await waitUntil { recorder.phase == .paused }
        XCTAssertEqual(recorder.pauseWords, "микрофон отключён")
    }

    func testMediaServicesResetPausesAsAudioFailure() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        fixture.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await waitUntil { recorder.phase == .paused }
        XCTAssertEqual(recorder.pauseWords, "сбой звука")
    }

    func testRecorderStoppingOnItsOwnPausesAsAudioFailure() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        fixture.device.failOnItsOwn()
        await waitUntil { recorder.phase == .paused }
        XCTAssertEqual(recorder.pauseWords, "сбой звука")
    }

    /// Рекордер встал, а следом пришло прерывание звонком: причиной обязан быть звонок.
    func testInterruptionRightAfterRecorderFailureNamesTheCall() async throws {
        fixture.inCall = true
        let recorder = fixture.controller()
        try await recorder.start()
        fixture.device.failOnItsOwn()
        postLegacyInterruption(.began)
        await waitUntil { recorder.phase == .paused }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(recorder.pauseWords, "звонок")
    }

    func testInterruptionDuringPersonsPauseKeepsTheirPause() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        recorder.pause()
        postLegacyInterruption(.began)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(recorder.pauseWords)
        XCTAssertEqual(try fixture.store.load()?.reason, .user)
    }

    func testWillTerminateClosesTheChunkSoNothingIsLost() async throws {
        fixture.device.chunkSeconds = [3]
        let recorder = fixture.controller()
        try await recorder.start()
        fixture.center.post(name: UIApplication.willTerminateNotification, object: nil)
        await waitUntil { recorder.phase == .paused }
        XCTAssertEqual(fixture.device.ends, 1)
        let session = try XCTUnwrap(try fixture.store.load())
        XCTAssertEqual(session.reason, .relaunch)
        XCTAssertEqual(session.chunks.count, 1)

        let relaunched = fixture.controller()
        relaunched.restoreSession()
        XCTAssertEqual(relaunched.phase, .paused)
        XCTAssertEqual(relaunched.pauseWords, "приложение перезапускалось")
        XCTAssertTrue(fixture.trash().isEmpty, "закрытый кусок не теряется и в корзину не идёт")
    }

    // MARK: - Восстановление

    func testProcessKilledMidChunkRestoresPausedAndTrashesTheOpenChunk() async throws {
        fixture.device.chunkSeconds = [2]
        let first = fixture.controller()
        try await first.start()
        first.pause()
        first.resume()
        try fixture.device.dieMidChunk()

        let relaunched = fixture.controller()
        relaunched.restoreSession()
        XCTAssertEqual(relaunched.phase, .paused)
        XCTAssertTrue(relaunched.isRestored)
        XCTAssertEqual(relaunched.pauseWords, "приложение перезапускалось")
        XCTAssertEqual(relaunched.elapsed, 2, accuracy: 0.1)
        XCTAssertNotNil(relaunched.lastError, "о потерянном куске говорится словами")
        let trash = fixture.trash()
        XCTAssertEqual(trash.count, 1, "оборванный кусок — в корзину, а не в никуда")
        XCTAssertTrue(trash.first?.hasSuffix("-оборвано.m4a") == true, "\(trash)")

        fixture.activity.adoptable = true
        await relaunched.reconcileActivity()
        XCTAssertEqual(fixture.activity.last?.phase, .paused)
        XCTAssertEqual(fixture.activity.last?.canDiscard, true, "у поднятой записи в островке есть «Удалить»")
        XCTAssertEqual(fixture.activity.last?.reason, "приложение перезапускалось")

        let path = await relaunched.finish()
        XCTAssertNotNil(path)
        let saved = fixture.root.appending(path: try XCTUnwrap(path))
        let duration = try await RecordingFiles.duration(of: saved)
        XCTAssertEqual(duration, 2, accuracy: 0.2)
    }

    func testRestoredCallPauseKeepsItsReason() async throws {
        fixture.inCall = true
        let first = fixture.controller()
        try await first.start()
        postLegacyInterruption(.began)
        await waitUntil { first.phase == .paused }

        let relaunched = fixture.controller()
        relaunched.restoreSession()
        XCTAssertEqual(relaunched.pauseWords, "звонок", "для человека ничего не поменялось — пауза из-за звонка")
        XCTAssertTrue(relaunched.isRestored)
        XCTAssertNil(relaunched.lastError)
    }

    func testResumeOfRestoredRecordingDropsDiscardFromTheIsland() async throws {
        let first = fixture.controller()
        try await first.start()
        first.pause()
        let relaunched = fixture.controller()
        relaunched.restoreSession()
        XCTAssertTrue(relaunched.resume())
        XCTAssertFalse(relaunched.isRestored)
        XCTAssertEqual(relaunched.activityState()?.canDiscard, false)
    }

    func testHangingActivityWithoutSessionIsEndedOnLaunch() async throws {
        let recorder = fixture.controller()
        recorder.restoreSession()
        await recorder.reconcileActivity()
        XCTAssertEqual(fixture.activity.endAllCount, 1)
        XCTAssertEqual(recorder.phase, .idle)
    }

    // MARK: - Конец и удаление

    func testFinishJoinsChunksIntoOneRecordingAndQueuesIt() async throws {
        fixture.device.chunkSeconds = [2, 3, 1.5]
        let recorder = fixture.controller()
        try await recorder.start()
        recorder.pause()
        recorder.resume()
        recorder.pause()
        recorder.resume()

        let finished = await recorder.finish()
        let path = try XCTUnwrap(finished)
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(fixture.recordings().count, 1)
        XCTAssertTrue(path.hasPrefix("Recordings/Recording-"))
        let duration = try await RecordingFiles.duration(of: fixture.root.appending(path: path))
        XCTAssertEqual(duration, 6.5, accuracy: 0.3, "склейка без потерь: сумма кусков")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path), "служебная папка убрана")

        XCTAssertTrue(fixture.transcription.state(for: path).isActive, "«Расшифровывать запись сразу» — запись в очереди")
        await waitUntil { !self.fixture.activity.ends.isEmpty }
        XCTAssertEqual(fixture.activity.ends.last?.final?.note, "Отправлено на расшифровку")
        await waitUntil { self.fixture.backgroundTimeReleased == self.fixture.backgroundTimeTaken.count }

        try fixture.workspace.refresh()
        XCTAssertEqual(fixture.workspace.audio.map(\.relativePath), [path], "в списке — одна запись, без кусков и временных файлов")
    }

    func testFinishWithoutAutoTranscribeOnlySaves() async throws {
        fixture.autoTranscribe = false
        let recorder = fixture.controller()
        try await recorder.start()
        await waitUntil { self.fixture.activity.starts == 1 }
        XCTAssertEqual(fixture.activity.last?.finishTitle, "Сохранить")
        XCTAssertEqual(fixture.activity.last?.finishOpensApp, false, "сохранить можно и в фоне")

        let finished = await recorder.finish()
        let path = try XCTUnwrap(finished)
        XCTAssertFalse(fixture.transcription.state(for: path).isActive)
        await waitUntil { !self.fixture.activity.ends.isEmpty }
        XCTAssertEqual(fixture.activity.ends.last?.final?.note, "Сохранено в Lori")
    }

    func testFinishButtonOpensLoriOnlyForTheEngineOnThePhone() async throws {
        fixture.engine = .gigaam
        let recorder = fixture.controller()
        try await recorder.start()
        await waitUntil { self.fixture.activity.starts == 1 }
        XCTAssertEqual(fixture.activity.last?.finishOpensApp, true, "заявку на фоновую расшифровку iOS примет только на виду")
        XCTAssertEqual(fixture.activity.last?.finishTitle, "Расшифровать")

        fixture.engine = .elevenLabs
        recorder.pause()
        await waitUntil { self.fixture.activity.last?.phase == .paused }
        XCTAssertEqual(fixture.activity.last?.finishOpensApp, false, "облачный движок — всё в фоне")
    }

    func testEmptyRecordingLeavesNoEmptyRecordInTheList() async throws {
        fixture.device.chunkSeconds = [0.01]
        let recorder = fixture.controller()
        try await recorder.start()
        let path = await recorder.finish()
        XCTAssertNil(path)
        XCTAssertTrue(fixture.recordings().isEmpty)
        XCTAssertNotNil(recorder.lastError)
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
    }

    func testDiscardMovesChunksToLoriTrash() async throws {
        fixture.device.chunkSeconds = [2, 1]
        let recorder = fixture.controller()
        try await recorder.start()
        recorder.pause()
        recorder.resume()
        await recorder.discard()

        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertTrue(fixture.recordings().isEmpty)
        let trash = fixture.trash()
        XCTAssertEqual(trash.count, 2, "удаление в Lori обратимо — куски в корзине")
        XCTAssertTrue(trash.allSatisfy { $0.contains("Recording-") && $0.contains("-часть-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
        XCTAssertNil(fixture.activity.ends.last?.final, "активность уходит сразу, без прощания")
    }

    func testStartFailureLeavesNothingBehind() async throws {
        fixture.device.beginError = AudioCaptureError.noRecording
        let recorder = fixture.controller()
        do {
            try await recorder.start()
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual(error as? AudioCaptureError, .noRecording)
        }
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertNil(try fixture.store.load())
        XCTAssertTrue(fixture.recordings().isEmpty)
        XCTAssertEqual(fixture.device.deactivations, 1)
    }

    // MARK: - Кнопки островка

    func testIslandButtonsReachTheRecordingThroughTheBridge() async throws {
        fixture.engine = .elevenLabs
        let recorder = fixture.controller()
        let previous = RecordingIntentBridge.handler
        RecordingIntentBridge.handler = recorder
        defer { RecordingIntentBridge.handler = previous }
        try await recorder.start()

        _ = try await PauseRecordingIntent().perform()
        XCTAssertEqual(recorder.phase, .paused)
        _ = try await ResumeRecordingIntent().perform()
        XCTAssertEqual(recorder.phase, .recording)
        _ = try await FinishRecordingIntent().perform()
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(fixture.recordings().count, 1)
    }

    func testButtonOnAFinishedRecordingClearsTheHangingActivity() async throws {
        let recorder = fixture.controller()
        let previous = RecordingIntentBridge.handler
        RecordingIntentBridge.handler = recorder
        defer { RecordingIntentBridge.handler = previous }
        _ = try await ResumeRecordingIntent().perform()
        XCTAssertEqual(recorder.phase, .idle, "без записи «Продолжить» ничего не начинает")
        XCTAssertEqual(fixture.activity.endAllCount, 1)
    }

    func testFinishLinkIsTheOneFromTheIsland() {
        XCTAssertTrue(RecordingController.isFinishLink(RecordingController.finishURL))
        XCTAssertEqual(RecordingController.finishURL.scheme, Bundle.main.bundleIdentifier, "схема ссылки — bundle ID этой сборки")
        XCTAssertFalse(RecordingController.isFinishLink(URL(fileURLWithPath: "/tmp/Inbox/Запись.m4a")))
        XCTAssertFalse(RecordingController.isFinishLink(URL(string: "lori-other://recording/finish")!))
    }

    // MARK: - Ревью 24 октября: смена куска

    /// Кусок закрывается сам, без паузы и без выключения сессии; повтор на стыке
    /// запоминается и отрезается при склейке.
    func testRotationClosesTheChunkWithoutPausingAndTrimsTheOverlap() async throws {
        fixture.device.chunkSeconds = [5, 5, 3]
        fixture.device.rotationOverlap = 0.3
        let recorder = fixture.controller()
        try await recorder.start()

        await recorder.rotateChunk()
        XCTAssertEqual(recorder.phase, .recording)
        XCTAssertEqual(fixture.device.deactivations, 0, "сессия звука не выключалась")
        var session = try XCTUnwrap(try fixture.store.load())
        XCTAssertEqual(session.chunks.map(\.file), ["part-1.m4a"])
        XCTAssertEqual(session.chunks[0].duration, 5, accuracy: 0.1, "закрытый кусок читается — его уже не потерять")
        XCTAssertEqual(session.active, "part-2.m4a")
        XCTAssertNil(session.incoming)
        XCTAssertEqual(session.activeTrim, 0.3, accuracy: 0.001)
        XCTAssertTrue(fixture.log.contains { $0.contains("part-1.m4a закрыт") && $0.contains("перекрытие 0,30") }, "\(fixture.log)")

        await recorder.rotateChunk()
        session = try XCTUnwrap(try fixture.store.load())
        XCTAssertEqual(session.chunks.map(\.trimStart), [0, 0.3])

        let finished = await recorder.finish()
        let path = try XCTUnwrap(finished)
        let duration = try await RecordingFiles.duration(of: fixture.root.appending(path: path))
        XCTAssertEqual(duration, 5 + 4.7 + 2.7, accuracy: 0.3, "повторы на двух стыках отрезаны")
        XCTAssertTrue(fixture.log.contains { $0.contains("повторов на стыках отрезано 0,60") }, "\(fixture.log)")
    }

    func testRotationWithGapIsLoggedAndKeepsEverything() async throws {
        fixture.device.chunkSeconds = [4, 2]
        fixture.device.rotationGap = 0.04
        let recorder = fixture.controller()
        try await recorder.start()
        await recorder.rotateChunk()
        let session = try XCTUnwrap(try fixture.store.load())
        XCTAssertEqual(session.activeTrim, 0, "без перекрытия отрезать нечего")
        XCTAssertTrue(fixture.log.contains { $0.contains("разрывом ≈ 0,04") }, "дыра называется в журнале: \(fixture.log)")
    }

    /// Таймер смены идёт сам, пока запись идёт, и встаёт на паузе.
    func testRotationTimerRunsOnlyWhileRecording() async throws {
        fixture.rotateEvery = .milliseconds(40)
        let recorder = fixture.controller()
        try await recorder.start()
        await waitUntil { self.fixture.device.rotations >= 2 }
        recorder.pause()
        let rotations = fixture.device.rotations
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.device.rotations, rotations, "на паузе куски не меняются")
    }

    /// Пауза посреди смены: новый кусок — сплошной повтор хвоста старого, он выбрасывается.
    func testPauseDuringRotationDropsTheDuplicateChunk() async throws {
        fixture.device.chunkSeconds = [3]
        fixture.device.holdRotation = true
        let recorder = fixture.controller()
        try await recorder.start()
        let rotation = Task { await recorder.rotateChunk() }
        await waitUntil { self.fixture.device.rotationIsHeld }
        XCTAssertEqual(try fixture.store.load()?.incoming, "part-2.m4a", "след смены — до её начала")

        recorder.pause()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.url(for: "part-2.m4a").path))
        fixture.device.releaseRotation()
        await rotation.value

        let session = try XCTUnwrap(try fixture.store.load())
        XCTAssertEqual(recorder.phase, .paused)
        XCTAssertEqual(session.chunks.map(\.file), ["part-1.m4a"])
        XCTAssertNil(session.active)
        XCTAssertNil(session.incoming)
        XCTAssertTrue(recorder.resume())
        XCTAssertEqual(fixture.device.begins.last?.lastPathComponent, "part-3.m4a", "номер выброшенного куска не повторяется")
    }

    /// Процесс умер посреди смены: оба открытых файла разбираются, закрытые куски целы.
    func testProcessKilledMidRotationKeepsClosedChunks() async throws {
        fixture.device.chunkSeconds = [5]
        let first = fixture.controller()
        try await first.start()
        await first.rotateChunk()
        fixture.device.holdRotation = true
        let rotation = Task { await first.rotateChunk() }
        await waitUntil { self.fixture.device.rotationIsHeld }
        try fixture.device.dieMidChunk()

        let relaunched = fixture.controller()
        relaunched.restoreSession()
        XCTAssertEqual(relaunched.phase, .paused)
        XCTAssertEqual(relaunched.elapsed, 5, accuracy: 0.1, "пять минут до смерти процесса — на месте")
        XCTAssertEqual(fixture.trash().filter { $0.hasSuffix("-оборвано.m4a") }.count, 2, "\(fixture.trash())")
        fixture.device.releaseRotation()
        await rotation.value
    }

    // MARK: - Ревью 24 октября: звонки

    /// Звонок так и не соединился (отклонён, пропущен) — запись продолжается сама,
    /// когда звонков больше нет.
    func testUnconnectedCallResumesByItselfWhenTheCallEnds() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        fixture.calls.ring()
        postLegacyInterruption(.began)
        await waitUntil { recorder.phase == .paused }
        XCTAssertEqual(recorder.pauseWords, "звонок")

        fixture.calls.hangUp()
        await waitUntil { recorder.phase == .recording }
        XCTAssertEqual(fixture.device.begins.count, 2)
        XCTAssertTrue(fixture.log.contains { $0.contains("продолжена сама — звонок не соединился") }, "\(fixture.log)")
        await waitUntil { self.fixture.activity.last?.phase == .recording }
        await waitUntil { self.fixture.backgroundTimeReleased == self.fixture.backgroundTimeTaken.count }
    }

    /// iOS сама советует продолжить, а звонок не соединялся — продолжаем, не дожидаясь CallKit.
    func testUnconnectedCallResumesOnTheSystemRecommendation() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        fixture.calls.ring()
        postLegacyInterruption(.began)
        await waitUntil { recorder.phase == .paused }
        postLegacyInterruption(.ended, shouldResume: true)
        await waitUntil { recorder.phase == .recording }
        XCTAssertTrue(fixture.log.contains { $0.contains("система советует продолжить") })
    }

    /// Конец прерывания без рекомендации — ждём, пока CallKit скажет, что звонков нет.
    func testUnconnectedCallWithoutRecommendationWaitsForTheCallToEnd() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        fixture.calls.ring()
        postLegacyInterruption(.began)
        await waitUntil { recorder.phase == .paused }
        postLegacyInterruption(.ended)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.phase, .paused)
        XCTAssertEqual(recorder.pauseWords, "звонок закончился")
        fixture.calls.hangUp()
        await waitUntil { recorder.phase == .recording }
    }

    /// Продолжить самой не вышло — пауза остаётся паузой из-за звонка, а не «микрофон занят».
    func testFailedAutoResumeKeepsTheCallAsTheReason() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        fixture.calls.ring()
        postLegacyInterruption(.began)
        await waitUntil { recorder.phase == .paused }
        fixture.device.activateError = AudioCaptureError.microphoneBusy
        fixture.calls.hangUp()
        await waitUntil { recorder.pauseWords == "звонок закончился" }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.phase, .paused)
        XCTAssertEqual(try fixture.store.load()?.reason, .call)
        await waitUntil { self.fixture.backgroundTimeReleased == self.fixture.backgroundTimeTaken.count }
    }

    /// «Продолжить» нажали, пока звонок ещё идёт: слова — «звонок», а не «микрофон занят».
    func testManualResumeDuringTheCallKeepsTheCallAsTheReason() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        fixture.calls.ring()
        postLegacyInterruption(.began)
        await waitUntil { recorder.phase == .paused }
        fixture.device.activateError = AudioCaptureError.microphoneBusy
        XCTAssertFalse(recorder.resume())
        XCTAssertEqual(recorder.pauseWords, "звонок")
        fixture.device.activateError = nil
        fixture.device.beginError = AudioCaptureError.noRecording
        XCTAssertFalse(recorder.resume())
        XCTAssertEqual(recorder.pauseWords, "звонок", "и когда не начался кусок — причина та же")
    }

    /// Рекордер встал сам, а следом пришло прерывание «микрофон выключен» (закрыт чехол):
    /// причина — его, а не «сбой звука». С `failureGrace = 0` тест падает.
    func testRecorderFailureWaitsForTheInterruptionToNameTheCause() async throws {
        fixture.failureGrace = .milliseconds(300)
        let recorder = fixture.controller()
        try await recorder.start()
        fixture.device.failOnItsOwn()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(recorder.phase, .recording, "за долю секунды пауза не ставится")
        postLegacyInterruption(.began, reason: .builtInMicMuted)
        await waitUntil { recorder.phase == .paused }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(recorder.pauseWords, "микрофон отключён")
    }

    // MARK: - Ревью 24 октября: сохранность

    /// `session.json` не читается — куски незаконченной записи в корзину, а не стираются.
    func testUnreadableSessionFileTrashesChunksInsteadOfDeletingThem() async throws {
        try FileManager.default.createDirectory(at: fixture.sessionDirectory, withIntermediateDirectories: true)
        try RecordingFiles.writeAAC(seconds: 2, to: fixture.store.url(for: "part-1.m4a"))
        try Data("{ не json".utf8).write(to: fixture.store.sessionURL)

        let recorder = fixture.controller()
        recorder.restoreSession()
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(fixture.trash().count, 1, "кусок в корзине")
        XCTAssertNotNil(recorder.lastError)
        XCTAssertTrue(fixture.log.contains { $0.contains("session.json не читается") })
    }

    /// «Записать» при оставшихся в папке кусках — они в корзину, а не под `rm`.
    func testStartTrashesLeftoverChunks() async throws {
        try FileManager.default.createDirectory(at: fixture.sessionDirectory, withIntermediateDirectories: true)
        try RecordingFiles.writeAAC(seconds: 2, to: fixture.store.url(for: "part-7.m4a"))
        let recorder = fixture.controller()
        try await recorder.start()
        XCTAssertEqual(recorder.phase, .recording)
        XCTAssertEqual(fixture.trash().count, 1)
        XCTAssertTrue(fixture.trash()[0].hasSuffix("part-7.m4a"))
    }

    /// Нечитаемый кусок при удачной склейке — в корзину, а не вместе с папкой сессии.
    func testFinishTrashesChunksThatDidNotMakeIt() async throws {
        fixture.device.chunkSeconds = [2, 2]
        let recorder = fixture.controller()
        try await recorder.start()
        recorder.pause()
        try RecordingFiles.writeUnclosedAAC(seconds: 2, to: fixture.store.url(for: "part-1.m4a"))
        recorder.resume()
        let finished = await recorder.finish()
        XCTAssertNotNil(finished)
        XCTAssertEqual(fixture.recordings().count, 1)
        XCTAssertEqual(fixture.trash().count, 1, "\(fixture.trash())")
        XCTAssertTrue(fixture.trash()[0].contains("не-прочиталось"))
        XCTAssertTrue(fixture.log.contains { $0.contains("не прочиталось 1 — в корзине") })
    }

    /// Процесс убит между переносом готовой записи и уборкой: при запуске запись не
    /// поднимается второй раз, а сессия закрывается и запись встаёт в очередь.
    func testRelaunchAfterAssemblyClosesTheSessionAndQueues() async throws {
        let destination = "Recordings/Recording-2026-10-24T10-00-00Z.m4a"
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "Recordings"), withIntermediateDirectories: true)
        try RecordingFiles.writeAAC(seconds: 4, to: fixture.root.appending(path: destination))
        var session = RecordingSession(startedAt: .now)
        for name in ["part-1.m4a", "part-2.m4a"] {
            _ = session.takeChunkName()
            try FileManager.default.createDirectory(at: fixture.sessionDirectory, withIntermediateDirectories: true)
            try RecordingFiles.writeAAC(seconds: 2, to: fixture.store.url(for: name))
            session.chunks.append(.init(file: name, duration: 2))
        }
        session.state = .paused
        session.destination = destination
        try fixture.store.save(session)

        let recorder = fixture.controller()
        recorder.restoreSession()
        XCTAssertEqual(recorder.phase, .idle, "собранная запись второй раз не поднимается")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
        XCTAssertTrue(fixture.trash().isEmpty, "вошедшие в запись куски — не в корзину: их звук в записи")
        await recorder.reconcileActivity()
        XCTAssertTrue(fixture.transcription.state(for: destination).isActive, "в очередь — как после обычного «Расшифровать»")
    }

    func testRelaunchWithDestinationButNoFileRestoresTheRecording() async throws {
        var session = RecordingSession(startedAt: .now)
        _ = session.takeChunkName()
        try FileManager.default.createDirectory(at: fixture.sessionDirectory, withIntermediateDirectories: true)
        try RecordingFiles.writeAAC(seconds: 2, to: fixture.store.url(for: "part-1.m4a"))
        session.chunks.append(.init(file: "part-1.m4a", duration: 2))
        session.state = .paused
        session.destination = "Recordings/Recording-нет.m4a"
        try fixture.store.save(session)

        let recorder = fixture.controller()
        recorder.restoreSession()
        XCTAssertEqual(recorder.phase, .paused, "склейка не дошла до переноса — запись на месте")
        XCTAssertNil(try fixture.store.load()?.destination)
    }

    // MARK: - Ревью 24 октября: островок и старт

    /// Прощание записи без активности не закрывает активность новой записи.
    func testFarewellWithoutActivityLeavesTheNextRecordingsActivity() async throws {
        fixture.farewell = .milliseconds(150)
        fixture.activity.areEnabled = false
        let recorder = fixture.controller()
        try await recorder.start()
        _ = await recorder.finish()

        fixture.activity.areEnabled = true
        try await recorder.start()
        await waitUntil { self.fixture.activity.starts == 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(fixture.activity.isRunning, "активность новой записи жива")
        XCTAssertTrue(fixture.activity.ends.isEmpty, "\(fixture.activity.ends.map(\.token))")
    }

    /// Пока куски склеиваются, островок говорит «Сохраняю…» без кнопок.
    func testFinishingShowsSavingInTheIsland() async throws {
        let recorder = fixture.controller()
        try await recorder.start()
        await waitUntil { self.fixture.activity.starts == 1 }
        _ = await recorder.finish()
        await waitUntil { !self.fixture.activity.ends.isEmpty }
        let phases = fixture.activity.history.map(\.phase)
        let saving = try XCTUnwrap(phases.firstIndex(of: .saving), "\(phases)")
        XCTAssertEqual(phases.last, .finished)
        XCTAssertLessThan(saving, phases.count - 1)
        XCTAssertFalse(fixture.activity.history[saving].showsButtons)
    }

    /// «Стоп», нажатый, пока `start()` ещё ждёт ActivityKit, не теряется.
    func testStopDuringStartIsCarriedOutAfterStart() async throws {
        fixture.activity.holdEndAll = true
        let recorder = fixture.controller()
        let starting = Task { try await recorder.start() }
        await waitUntil { self.fixture.activity.endAllIsHeld }
        XCTAssertEqual(recorder.phase, .recording, "запись уже идёт, «Стоп» на экране")
        let stopped = await recorder.finish()
        XCTAssertNil(stopped, "сейчас — только запомнить")
        fixture.activity.releaseEndAll()
        try await starting.value
        await waitUntil { recorder.phase == .idle }
        XCTAssertEqual(fixture.recordings().count, 1, "«Стоп» исполнен после старта")
    }

    // MARK: - Помощники

    private func postLegacyInterruption(
        _ type: AVAudioSession.InterruptionType,
        reason: AVAudioSession.InterruptionReason? = nil,
        shouldResume: Bool = false
    ) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if let reason { info[AVAudioSessionInterruptionReasonKey] = reason.rawValue }
        if shouldResume { info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue }
        fixture.center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: info)
    }
}
