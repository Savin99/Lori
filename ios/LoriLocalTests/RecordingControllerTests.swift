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
        let session = try XCTUnwrap(fixture.store.load(), "след записи обязан лечь на диск до начала куска")
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
        var session = try XCTUnwrap(fixture.store.load())
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
        session = try XCTUnwrap(fixture.store.load())
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
        let session = try XCTUnwrap(fixture.store.load())
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

    func testCallPausesWithReasonAndWaitsForThePerson() async throws {
        fixture.inCall = true
        let recorder = fixture.controller()
        try await recorder.start()

        postLegacyInterruption(.began)
        await waitUntil { recorder.phase == .paused }
        XCTAssertEqual(recorder.pauseWords, "звонок")
        XCTAssertEqual(fixture.device.ends, 1, "кусок закрыт файлом сразу")
        await waitUntil { self.fixture.activity.last?.reason == "звонок" }
        XCTAssertTrue(fixture.backgroundTimeTaken.contains("Lori: пауза от системы"), "островок успевает узнать о паузе")
        await waitUntil { self.fixture.backgroundTimeReleased == self.fixture.backgroundTimeTaken.count }

        // Звонок кончился, система советует продолжить — владелец решил ждать «Продолжить».
        postLegacyInterruption(.ended, shouldResume: true)
        await waitUntil { recorder.pauseWords == "звонок закончился" }
        XCTAssertEqual(recorder.phase, .paused)
        XCTAssertEqual(fixture.device.begins.count, 1, "запись не продолжилась сама")
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
        XCTAssertEqual(fixture.store.load()?.reason, .user)
    }

    func testWillTerminateClosesTheChunkSoNothingIsLost() async throws {
        fixture.device.chunkSeconds = [3]
        let recorder = fixture.controller()
        try await recorder.start()
        fixture.center.post(name: UIApplication.willTerminateNotification, object: nil)
        await waitUntil { recorder.phase == .paused }
        XCTAssertEqual(fixture.device.ends, 1)
        let session = try XCTUnwrap(fixture.store.load())
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
        XCTAssertNil(fixture.store.load())
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
