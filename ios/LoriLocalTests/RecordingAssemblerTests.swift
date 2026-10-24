import AVFoundation
import XCTest
@testable import LoriLocal

/// Склейка кусков записи и разбор уведомлений звуковой сессии.
final class RecordingAssemblerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appending(path: "LoriAssembler-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testChunksJoinWithoutReencodingAndKeepTheirLength() async throws {
        let chunks = try [1.5, 2.0, 2.5].enumerated().map { index, seconds in
            let url = folder.appending(path: "part-\(index + 1).m4a")
            try RecordingFiles.writeAAC(seconds: seconds, to: url, frequency: 220 + 110 * Double(index))
            return url
        }
        let output = folder.appending(path: "out/Recording.m4a")
        let outcome = try await RecordingAssembler.assemble(chunks, into: output, workDirectory: folder)

        XCTAssertFalse(outcome.reencoded, "куски одного рекордера склеиваются сквозным экспортом")
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertEqual(outcome.duration, 6, accuracy: 0.3)
        let duration = try XCTUnwrap(RecordingAudio.duration(of: output), "итог читается как обычный m4a")
        XCTAssertEqual(duration, 6, accuracy: 0.3)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(RecordingAssembler.temporaryPrefix) }
        XCTAssertTrue(leftovers.isEmpty, "временный файл склейки не остаётся")
    }

    func testUnreadableChunkIsSkippedNotFatal() async throws {
        let good1 = folder.appending(path: "part-1.m4a")
        let broken = folder.appending(path: "part-2.m4a")
        let good2 = folder.appending(path: "part-3.m4a")
        try RecordingFiles.writeAAC(seconds: 2, to: good1)
        try RecordingFiles.writeAAC(seconds: 2, to: broken)
        try RecordingFiles.cutTail(of: broken)
        try RecordingFiles.writeAAC(seconds: 1, to: good2)
        XCTAssertNil(RecordingAudio.duration(of: broken), "m4a без оглавления не читается — на этом держится проверка кусков")

        let output = folder.appending(path: "Recording.m4a")
        let outcome = try await RecordingAssembler.assemble([good1, broken, good2], into: output, workDirectory: folder)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.duration, 3, accuracy: 0.3)
    }

    func testSingleChunkIsMovedAsIs() async throws {
        let chunk = folder.appending(path: "part-1.m4a")
        try RecordingFiles.writeAAC(seconds: 2, to: chunk)
        let bytes = try Data(contentsOf: chunk)
        let output = folder.appending(path: "Recording.m4a")
        let outcome = try await RecordingAssembler.assemble([chunk], into: output, workDirectory: folder)
        XCTAssertEqual(try Data(contentsOf: output), bytes, "один кусок не перекладывается экспортом")
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.path))
        XCTAssertEqual(outcome.duration, 2, accuracy: 0.1)
    }

    func testNothingReadableIsAnHonestError() async throws {
        let broken = folder.appending(path: "part-1.m4a")
        try Data("ftyp".utf8).write(to: broken)
        await XCTAssertThrowsErrorAsync(
            try await RecordingAssembler.assemble([broken], into: self.folder.appending(path: "R.m4a"), workDirectory: self.folder)
        ) { error in
            XCTAssertEqual(error as? RecordingAssembler.Failure, .nothingToSave)
        }
    }

    // MARK: - Уведомления звуковой сессии

    func testLegacyInterruptionReasons() {
        let began = AVAudioSession.InterruptionType.began.rawValue
        XCTAssertEqual(
            RecordingInterruptions.legacy([AVAudioSessionInterruptionTypeKey: began], inCall: true),
            .interrupted(.call)
        )
        XCTAssertEqual(
            RecordingInterruptions.legacy([AVAudioSessionInterruptionTypeKey: began], inCall: false),
            .interrupted(.otherApp)
        )
        XCTAssertEqual(
            RecordingInterruptions.legacy([
                AVAudioSessionInterruptionTypeKey: began,
                AVAudioSessionInterruptionReasonKey: AVAudioSession.InterruptionReason.builtInMicMuted.rawValue,
            ], inCall: true),
            .interrupted(.microphoneLost),
            "закрытый чехол — это не звонок, даже если звонок идёт"
        )
        XCTAssertEqual(
            RecordingInterruptions.legacy([
                AVAudioSessionInterruptionTypeKey: began,
                AVAudioSessionInterruptionReasonKey: AVAudioSession.InterruptionReason.routeDisconnected.rawValue,
            ], inCall: false),
            .interrupted(.microphoneLost)
        )
        XCTAssertEqual(
            RecordingInterruptions.legacy([AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue], inCall: false),
            .interruptionEnded
        )
        XCTAssertEqual(RecordingInterruptions.legacy(nil, inCall: false), .ignore)
    }

    /// Ветка iOS 27 (`didBecomeInactiveNotification`). Контекст системы в тесте не
    /// создать (`init` недоступен), поэтому проверяется разбор его полей.
    func testDeactivationContextMapping() {
        XCTAssertEqual(
            RecordingInterruptions.deactivation(bySystem: false, interruption: nil, hasInterruptionContext: false, inCall: true),
            .ignore,
            "свою же деактивацию на паузе за прерывание не считаем"
        )
        XCTAssertEqual(
            RecordingInterruptions.deactivation(bySystem: true, interruption: .default, hasInterruptionContext: true, inCall: true),
            .interrupted(.call)
        )
        XCTAssertEqual(
            RecordingInterruptions.deactivation(bySystem: true, interruption: .default, hasInterruptionContext: true, inCall: false),
            .interrupted(.otherApp)
        )
        XCTAssertEqual(
            RecordingInterruptions.deactivation(bySystem: true, interruption: nil, hasInterruptionContext: false, inCall: false),
            .interrupted(.audioFailure)
        )
    }

    func testRouteChangePausesOnlyWhenTheInputIsGone() {
        let unavailable = [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        XCTAssertEqual(
            RecordingInterruptions.routeChange(unavailable, previousInputs: ["AirPods"], currentInputs: ["Built-In"]),
            .interrupted(.microphoneLost)
        )
        XCTAssertEqual(
            RecordingInterruptions.routeChange(unavailable, previousInputs: ["Built-In"], currentInputs: ["Built-In"]),
            .ignore,
            "выдернули наушники без микрофона — запись идёт дальше"
        )
        XCTAssertEqual(
            RecordingInterruptions.routeChange(unavailable, previousInputs: ["Built-In"], currentInputs: []),
            .interrupted(.microphoneLost)
        )
        XCTAssertEqual(
            RecordingInterruptions.routeChange(
                [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.noSuitableRouteForCategory.rawValue],
                previousInputs: nil,
                currentInputs: []
            ),
            .interrupted(.microphoneLost)
        )
        XCTAssertEqual(
            RecordingInterruptions.routeChange(
                [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue],
                previousInputs: ["Built-In"],
                currentInputs: ["AirPods"]
            ),
            .ignore
        )
    }

    // MARK: - Слова

    func testPauseWordsAreShortAndHuman() {
        XCTAssertNil(RecordingPauseReason.user.words)
        XCTAssertEqual(RecordingPauseReason.call.words, "звонок")
        XCTAssertEqual(RecordingPauseReason.otherApp.words, "другое приложение")
        XCTAssertEqual(RecordingPauseReason.microphoneLost.words, "микрофон отключён")
        XCTAssertEqual(RecordingPauseReason.audioFailure.words, "сбой звука")
        XCTAssertEqual(RecordingPauseReason.relaunch.words, "приложение перезапускалось")
        XCTAssertEqual(RecordingPauseReason.call.endedWords, "звонок закончился")
    }

    func testActivityHeadlineHasNoWordRecording() {
        typealias State = RecordingActivityAttributes.ContentState
        func state(_ phase: State.Phase, reason: String? = nil, note: String? = nil) -> State {
            State(phase: phase, timerStart: .now, recorded: 754, reason: reason, finishOpensApp: false, finishTitle: "Расшифровать", canDiscard: false, note: note)
        }
        XCTAssertEqual(RecordingActivityCopy.headline(state(.recording)), "Lori")
        XCTAssertEqual(RecordingActivityCopy.headline(state(.paused)), "Пауза")
        XCTAssertEqual(RecordingActivityCopy.headline(state(.paused, reason: "звонок")), "Пауза · звонок")
        XCTAssertEqual(RecordingActivityCopy.headline(state(.finished, note: "Отправлено на расшифровку")), "Отправлено на расшифровку")
        for phase in [State.Phase.recording, .paused] {
            XCTAssertFalse(RecordingActivityCopy.headline(state(phase)).contains("Запись"), "владелец: островок незаметный")
        }
        // Таймер на паузе стоит на записанном.
        let paused = state(.paused)
        XCTAssertEqual(try XCTUnwrap(paused.pauseTime).timeIntervalSince(paused.timerStart), 754, accuracy: 0.001)
        XCTAssertNil(state(.recording).pauseTime)
        XCTAssertTrue(paused.timerRange.contains(try XCTUnwrap(paused.pauseTime)))
    }
}
