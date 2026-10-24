import Accelerate
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

    /// Смена куска с перекрытием (ревью 24 октября 2026): новый рекордер пошёл раньше,
    /// чем встал старый, и при склейке повтор отрезается. Здесь — насколько точно.
    ///
    /// Исходник — шум с известным зерном, 6 с. Кусок A — первые 3,0 с, кусок B — с 2,7 с
    /// до конца (повтор 0,3 с), `trimStart` = 0,3. В склейке корреляцией ищется сдвиг
    /// относительно исходника до стыка и после (сдвиг L: склейка[p] = исходник[p + L]):
    /// разница сдвигов — ошибка отреза в отсчётах (меньше нуля — часть повтора
    /// осталась, больше — выпал кусок звука). Сквозной экспорт
    /// режет по пакетам AAC (1024 отсчёта ≈ 23 мс) — это и потолок допуска.
    func testOverlapIsCutWithinOnePacket() async throws {
        let rate = RecordingFiles.rate
        let reference = RecordingFiles.noise(seconds: 6)
        let seam = Int(3.0 * rate)
        let overlap = Int(0.3 * rate)
        let first = folder.appending(path: "part-1.m4a")
        let second = folder.appending(path: "part-2.m4a")
        try RecordingFiles.writeAAC(samples: reference[0..<seam], to: first)
        try RecordingFiles.writeAAC(samples: reference[(seam - overlap)...], to: second)

        let output = folder.appending(path: "Recording.m4a")
        let outcome = try await RecordingAssembler.assemble(
            [.init(url: first), .init(url: second, trimStart: 0.3)],
            into: output,
            workDirectory: folder
        )
        XCTAssertFalse(outcome.reencoded)
        XCTAssertEqual(outcome.trimmed, 0.3, accuracy: 0.001)
        XCTAssertEqual(outcome.duration, 6.0, accuracy: 0.05, "повтор отрезан: длина как у исходника")

        let decoded = try await RecordingFiles.decode(output)
        XCTAssertEqual(Double(decoded.count) / rate, 6.0, accuracy: 0.05)
        let before = [1.5, 2.5].map { lag(of: decoded, against: reference, at: Int($0 * rate)) }
        let after = [3.5, 4.5].map { lag(of: decoded, against: reference, at: Int($0 * rate)) }
        let error = after[0] - before[1]
        // Так же, как её читают движки расшифровки (`AudioSamples`, `CloudAudio`).
        let file = try AVAudioFile(forReading: output)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let plain = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let plainBefore = [1.5, 2.5].map { lag(of: plain, against: reference, at: Int($0 * rate)) }
        let plainAfter = [3.5, 4.5].map { lag(of: plain, against: reference, at: Int($0 * rate)) }

        // Для сравнения — стык паузы, без перекрытия: что лишнего видит `AVAudioFile`
        // на любом стыке, независимо от смены кусков.
        let third = folder.appending(path: "part-3.m4a")
        try RecordingFiles.writeAAC(samples: reference[seam...], to: third)
        let paused = folder.appending(path: "Paused.m4a")
        _ = try await RecordingAssembler.assemble([first, third], into: paused, workDirectory: folder)
        let pausedFile = try AVAudioFile(forReading: paused)
        let pausedBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pausedFile.processingFormat, frameCapacity: AVAudioFrameCount(pausedFile.length)))
        try pausedFile.read(into: pausedBuffer)
        let pausedPlain = Array(UnsafeBufferPointer(start: pausedBuffer.floatChannelData![0], count: Int(pausedBuffer.frameLength)))
        let pausedAfter = lag(of: pausedPlain, against: reference, at: Int(3.5 * rate))

        let report = "AVAssetReader: длина \(decoded.count), сдвиг до стыка \(before), после \(after), ошибка отреза \(error) отсчётов = \(String(format: "%.1f", Double(error) / rate * 1000)) мс\n"
            + "AVAudioFile, стык смены: длина \(plain.count), сдвиг до стыка \(plainBefore), после \(plainAfter)\n"
            + "AVAudioFile, стык паузы без перекрытия: длина \(pausedPlain.count), сдвиг после \(pausedAfter)"
        let attachment = XCTAttachment(string: report)
        attachment.name = "seam-measurement"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(before[0], before[1], "до стыка сдвиг постоянный: \(report)")
        XCTAssertEqual(after[0], after[1], "после стыка сдвиг постоянный: \(report)")
        XCTAssertLessThanOrEqual(abs(error), 1024, "повтор отрезан с точностью до пакета AAC: \(report)")
        // `AVAudioFile` списков правок склейки не видит: на каждом стыке лишние пакеты.
        // Потолок — четыре пакета, а не 0,3 с повтора: регрессия «повтор не режется» упадёт.
        XCTAssertLessThanOrEqual(abs(plainAfter[0] - plainBefore[1]), 4096, report)
    }

    /// Сдвиг окна склейки относительно исходника, в отсчётах: где корреляция больше всего.
    private func lag(of output: [Float], against reference: [Float], at position: Int, window: Int = 4096, search: Int = 4410) -> Int {
        let start = position - search
        guard start >= 0, position + window <= output.count, start + 2 * search + window <= reference.count else { return .max }
        var result = [Float](repeating: 0, count: 2 * search + 1)
        reference.withUnsafeBufferPointer { signal in
            output.withUnsafeBufferPointer { filter in
                vDSP_conv(
                    signal.baseAddress! + start, 1,
                    filter.baseAddress! + position, 1,
                    &result, 1,
                    vDSP_Length(result.count), vDSP_Length(window)
                )
            }
        }
        var peak: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(result, 1, &peak, &index, vDSP_Length(result.count))
        return Int(index) - search
    }

    /// Предыдущий кусок не прочитался — повтор в начале следующего остаётся: это
    /// единственная копия того звука.
    func testOverlapStaysWhenThePreviousChunkIsLost() async throws {
        let lost = folder.appending(path: "part-1.m4a")
        let kept = folder.appending(path: "part-2.m4a")
        let next = folder.appending(path: "part-3.m4a")
        try RecordingFiles.writeAAC(seconds: 2, to: lost)
        try RecordingFiles.writeUnclosedAAC(seconds: 2, to: lost)
        try RecordingFiles.writeAAC(seconds: 2, to: kept)
        try RecordingFiles.writeAAC(seconds: 2, to: next)
        let outcome = try await RecordingAssembler.assemble(
            [.init(url: lost), .init(url: kept, trimStart: 0.4), .init(url: next, trimStart: 0.4)],
            into: folder.appending(path: "Recording.m4a"),
            workDirectory: folder
        )
        XCTAssertEqual(outcome.unreadable, [lost])
        XCTAssertEqual(outcome.trimmed, 0.4, accuracy: 0.001, "отрезан только повтор у третьего: второй шёл после пропавшего")
        XCTAssertEqual(outcome.duration, 3.6, accuracy: 0.1)
    }

    func testUnreadableChunkIsSkippedNotFatal() async throws {
        let good1 = folder.appending(path: "part-1.m4a")
        let broken = folder.appending(path: "part-2.m4a")
        let good2 = folder.appending(path: "part-3.m4a")
        try RecordingFiles.writeAAC(seconds: 2, to: good1)
        try RecordingFiles.writeUnclosedAAC(seconds: 2, to: broken)
        try RecordingFiles.writeAAC(seconds: 1, to: good2)
        XCTAssertNil(RecordingAudio.duration(of: broken), "незакрытый m4a не читается — на этом держится проверка кусков")

        let output = folder.appending(path: "Recording.m4a")
        let outcome = try await RecordingAssembler.assemble([good1, broken, good2], into: output, workDirectory: folder)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.unreadable, [broken], "нечитаемый кусок называется — вызывающий отложит его в корзину")
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
            .interruptionEnded(shouldResume: false)
        )
        XCTAssertEqual(
            RecordingInterruptions.legacy([
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ], inCall: false),
            .interruptionEnded(shouldResume: true),
            "рекомендацию продолжить видно — по ней Lori продолжает после несоединившегося звонка"
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
        XCTAssertEqual(
            RecordingInterruptions.deactivation(bySystem: true, interruption: nil, hasInterruptionContext: false, inCall: false, inputLost: true),
            .interrupted(.microphoneLost),
            "без контекста, но входа нет — это микрофон, а не сбой звука"
        )
        XCTAssertEqual(RecordingInterruptions.resumption(shouldResume: true), .interruptionEnded(shouldResume: true))
        XCTAssertEqual(RecordingInterruptions.resumption(shouldResume: false), .interruptionEnded(shouldResume: false))
        XCTAssertTrue(RecordingInterruptions.inputLost(currentInputs: [], inputAvailable: true))
        XCTAssertTrue(RecordingInterruptions.inputLost(currentInputs: ["Built-In"], inputAvailable: false))
        XCTAssertFalse(RecordingInterruptions.inputLost(currentInputs: ["Built-In"], inputAvailable: true))
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
        XCTAssertEqual(RecordingActivityCopy.headline(state(.saving)), "Сохраняю…")
        XCTAssertFalse(state(.saving).showsButtons, "пока куски склеиваются, нажимать нечего")
        XCTAssertNotNil(state(.saving).pauseTime, "таймер стоит, пока сохраняется")
        XCTAssertTrue(state(.recording).showsButtons)
        XCTAssertTrue(state(.paused).showsButtons)
        XCTAssertFalse(state(.finished).showsButtons)
        // Таймер на паузе стоит на записанном.
        let paused = state(.paused)
        XCTAssertEqual(try XCTUnwrap(paused.pauseTime).timeIntervalSince(paused.timerStart), 754, accuracy: 0.001)
        XCTAssertNil(state(.recording).pauseTime)
        XCTAssertTrue(paused.timerRange.contains(try XCTUnwrap(paused.pauseTime)))
    }
}
