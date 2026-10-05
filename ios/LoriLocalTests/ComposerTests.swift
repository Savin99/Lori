import UIKit
import XCTest
@testable import LoriLocal

/// Состояния нижней панели. Они взаимоисключающие, и это главное, что здесь
/// проверяется: панель не должна одновременно предлагать записать и расшифровать.
@MainActor
final class ComposerModelTests: XCTestCase {
    func testEmptyPanelOffersRecording() {
        let model = ComposerModel()

        XCTAssertEqual(model.state(recording: false), .idle)
    }

    func testRecordingWinsOverEverything() {
        let model = ComposerModel()
        model.attach([URL(fileURLWithPath: "/tmp/Совещание.m4a")])

        XCTAssertEqual(model.state(recording: true), .recording)
    }

    /// Пока файл прикреплён, запись недоступна: кнопка микрофона превращается
    /// в «Расшифровать», и другого способа начать запись в панели нет.
    func testAttachedFileTurnsTheButtonIntoTranscribe() {
        let model = ComposerModel()
        model.attach([URL(fileURLWithPath: "/tmp/Совещание.m4a")])

        XCTAssertEqual(model.state(recording: false), .attached)
    }

    /// Подсказка про буфер ничего собой не закрывает: скопированное аудио может
    /// лежать там часами, и всё это время панель должна работать как обычно —
    /// в покое, с кнопкой записи на месте.
    func testClipboardHintNeverBlocksThePanel() {
        let model = ComposerModel()
        model.clipboard = .audio

        XCTAssertTrue(model.showsClipboardHint)
        XCTAssertEqual(model.state(recording: false), .idle, "подсказка не меняет состояние панели")
    }

    func testDismissedHintStaysHiddenUntilTheBufferChanges() {
        let model = ComposerModel()
        model.clipboard = .audio
        model.clipboardDismissed = true

        XCTAssertFalse(model.showsClipboardHint)
    }

    /// Ссылка на файл — это ещё не аудио: что за файлом, до чтения неизвестно,
    /// поэтому подсказки в панели нет, а пункт меню всё равно активен.
    func testFileURLInClipboardDoesNotClaimAudio() {
        let model = ComposerModel()
        model.clipboard = .fileURL

        XCTAssertFalse(model.showsClipboardHint)
        XCTAssertEqual(model.state(recording: false), .idle)
    }

    /// Прикреплённый файл важнее подсказки: она предлагала бы то, что уже сделано.
    func testHintHidesWhenAFileIsAlreadyAttached() {
        let model = ComposerModel()
        model.clipboard = .audio
        model.attach([URL(fileURLWithPath: "/tmp/Совещание.m4a")])

        XCTAssertFalse(model.showsClipboardHint)
    }

    func testSameFileIsNotAttachedTwice() {
        let model = ComposerModel()
        let url = URL(fileURLWithPath: "/tmp/Совещание.m4a")
        model.attach([url])
        model.attach([url])

        XCTAssertEqual(model.attached.count, 1)
    }

    func testClearingRemovesAttachedFiles() {
        let model = ComposerModel()
        model.attach([URL(fileURLWithPath: "/tmp/Совещание.m4a")])
        model.clear()

        XCTAssertTrue(model.attached.isEmpty)
        XCTAssertEqual(model.state(recording: false), .idle)
    }
}

/// Оценка времени расшифровки: она врёт до первого замера и не должна врать после.
@MainActor
final class TranscriptionSpeedTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appending(path: "speed-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func testCloudIsFasterThanThePhoneBeforeAnyMeasurement() {
        let speed = TranscriptionSpeed(url: url)
        let hour: TimeInterval = 2_832

        let phone = speed.estimate(audio: hour, engine: .gigaam, mode: nil)
        let cloud = speed.estimate(audio: hour, engine: .gemini, mode: nil)

        XCTAssertLessThan(cloud, phone)
        XCTAssertGreaterThan(cloud, 0)
    }

    /// Облако считает быстрее, но запись ещё надо отправить — это время
    /// обязано входить в оценку, иначе «~1 минута» превращается в пять.
    func testCloudEstimateIncludesUpload() {
        let speed = TranscriptionSpeed(url: url)
        let seconds: TimeInterval = 3_600

        let cloud = speed.estimate(audio: seconds, engine: .gemini, mode: nil)

        XCTAssertGreaterThan(cloud, seconds * 0.06)
    }

    func testMeasuredRunReplacesTheDefault() {
        let speed = TranscriptionSpeed(url: url)
        let before = speed.estimate(audio: 600, engine: .gigaam, mode: "rnnt")

        speed.record(audio: 600, spent: 600, engine: .gigaam, mode: "rnnt")
        let after = speed.estimate(audio: 600, engine: .gigaam, mode: "rnnt")

        XCTAssertGreaterThan(after, before, "медленный прогон должен поднять оценку")
        XCTAssertEqual(after, 600, accuracy: 1)
    }

    /// У точного варианта GigaAM своя скорость: одно среднее на движок
    /// врало бы обоим режимам сразу.
    func testModesAreMeasuredApart() {
        let speed = TranscriptionSpeed(url: url)
        speed.record(audio: 600, spent: 600, engine: .gigaam, mode: "rnnt")

        let other = speed.estimate(audio: 600, engine: .gigaam, mode: "ctc")

        XCTAssertNotEqual(other, 600, accuracy: 1)
    }

    func testAbsurdRunsAreIgnored() {
        let speed = TranscriptionSpeed(url: url)
        let before = speed.estimate(audio: 600, engine: .apple, mode: nil)

        speed.record(audio: 0, spent: 10, engine: .apple, mode: nil)
        speed.record(audio: 600, spent: 0, engine: .apple, mode: nil)

        XCTAssertEqual(speed.estimate(audio: 600, engine: .apple, mode: nil), before)
    }

    func testMeasurementSurvivesRestart() {
        TranscriptionSpeed(url: url).record(audio: 600, spent: 600, engine: .gigaam, mode: "rnnt")

        let restarted = TranscriptionSpeed(url: url)

        XCTAssertEqual(restarted.estimate(audio: 600, engine: .gigaam, mode: "rnnt"), 600, accuracy: 1)
    }

    /// Строка карточки: куда уйдёт запись и надолго ли. Слово «примерно»
    /// обязательно — это оценка, а не обещание.
    func testSummaryNamesThePlaceAndStaysApproximate() {
        let speed = TranscriptionSpeed(url: url)
        let cloud = EngineCatalog.descriptor(for: .gemini)
        let phone = EngineCatalog.descriptor(for: .gigaam)

        let cloudLine = speed.summary(audio: 2_832, engine: cloud, mode: nil)
        let phoneLine = speed.summary(audio: 2_832, engine: phone, mode: nil)

        XCTAssertTrue(cloudLine.hasPrefix("в облако · примерно "), cloudLine)
        XCTAssertTrue(phoneLine.hasPrefix("на телефоне · примерно "), phoneLine)
    }
}

/// Буфер обмена. Главное правило: наличие аудио определяется по типам,
/// а не чтением содержимого — иначе система показывает плашку о вставке.
final class ClipboardAudioTests: XCTestCase {
    private var pasteboard: UIPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = UIPasteboard(name: UIPasteboard.Name("ru.ilyaqa.lori.tests"), create: true)
    }

    override func tearDown() {
        UIPasteboard.remove(withName: pasteboard.name)
        super.tearDown()
    }

    func testAudioDataIsRecognized() {
        pasteboard.setData(Data([0, 1, 2]), forPasteboardType: "public.mp3")

        XCTAssertEqual(ClipboardAudio.content(in: pasteboard), .audio)
    }

    func testFileReferenceIsSeenButNotClaimedAsAudio() {
        pasteboard.url = URL(fileURLWithPath: "/tmp/Совещание.m4a")

        XCTAssertEqual(ClipboardAudio.content(in: pasteboard), .fileURL)
    }

    func testPlainTextIsNotOffered() {
        pasteboard.string = "просто текст"

        XCTAssertEqual(ClipboardAudio.content(in: pasteboard), .none)
    }

    func testConformanceDecidesInsteadOfAList() {
        XCTAssertTrue(ClipboardAudio.isAudio("public.mp3"))
        XCTAssertTrue(ClipboardAudio.isAudio("com.apple.m4a-audio"))
        XCTAssertFalse(ClipboardAudio.isAudio("public.plain-text"))
        XCTAssertFalse(ClipboardAudio.isAudio("совсем.не.тип"))
    }

    func testTakingFromAnEmptyBufferFails() async {
        await XCTAssertThrowsErrorAsync(try await ClipboardAudio.take(from: pasteboard)) { error in
            XCTAssertEqual(error as? ClipboardAudioError, .notAudio([]))
        }
    }

    func testReadyDataIsTakenFromTheBuffer() async throws {
        pasteboard.setData(Data([0, 1, 2, 3]), forPasteboardType: "public.mp3")

        let url = try await ClipboardAudio.take(from: pasteboard)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try Data(contentsOf: url), Data([0, 1, 2, 3]))
        XCTAssertEqual(url.pathExtension, "mp3")
        XCTAssertTrue(ImportInbox.isStaged(url), "вставленное ложится туда же, куда принесённое")
    }

    /// Тот самый случай, на котором «Вставить» отвечало «в буфере нет аудио»:
    /// тип объявлен, а данные поставщик отдаёт лениво и может не отдать вовсе.
    /// Отказ обязан называться своим именем, а не отрицать то, что человек
    /// только что прочитал в панели.
    func testPromisedButUnreadableAudioIsNotCalledMissing() {
        XCTAssertEqual(ClipboardAudio.failure(hasAudioType: true), .unreadable([]))
        XCTAssertEqual(ClipboardAudio.failure(hasAudioType: false), .notAudio([]))
    }

    /// Типы видны прямо в сообщении: разбираться с чужим буфером иначе
    /// приходится через переспросы «а что вы копировали».
    func testErrorNamesWhatWasActuallyInTheBuffer() {
        let error = ClipboardAudio.failure(hasAudioType: true, types: ["public.file-url", "public.url"])

        let text = error.errorDescription ?? ""
        XCTAssertTrue(text.contains("public.file-url"), text)
    }
}
