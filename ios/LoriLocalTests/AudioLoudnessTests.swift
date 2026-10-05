import XCTest
@testable import LoriLocal

/// Тишина против потерянной речи. Ровно этого различения приложению и не хватало,
/// когда владелец увидел четыре плашки «похоже на пропуск» на одной записи.
final class AudioLoudnessTests: XCTestCase {
    private var files: [URL] = []

    override func tearDownWithError() throws {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        files = []
    }

    private func file(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "loud-\(name)-\(UUID().uuidString).wav")
        files.append(url)
        return url
    }

    func testDigitalSilenceHasNoSound() throws {
        let url = file("zeros")
        try AudioFixture.wav(seconds: 40, at: url)

        XCTAssertNil(AudioLoudness.sound(in: url, range: 0...40, louderThan: AudioLoudness.floor))
    }

    /// Отрезок называется по месту звука, а не по границам пропуска: плашка должна
    /// показывать, где речь, а переспрос — просить именно её.
    func testSoundIsFoundWhereItIs() throws {
        let url = file("tone")
        // Звука должно быть больше `sustain`: этот тест про «где», а не про «сколько».
        try AudioFixture.wav(seconds: 90, levels: [(20...60, 0.5)], at: url)

        let sound = AudioLoudness.sound(in: url, range: 0...90, louderThan: AudioLoudness.floor)

        let found = try XCTUnwrap(sound)
        XCTAssertLessThanOrEqual(found.lowerBound, 20, "начало звука не пропущено: \(found)")
        XCTAssertGreaterThanOrEqual(found.upperBound, 60, "конец звука не обрезан: \(found)")
        // Окно прослушивания — десять секунд, дальше него отрезок расползаться не должен.
        XCTAssertGreaterThanOrEqual(found.lowerBound, 20 - AudioLoudness.window, "\(found)")
        XCTAssertLessThanOrEqual(found.upperBound, 60 + AudioLoudness.window, "\(found)")
    }

    func testSpeechLevelIsMeasuredOnTranscribedTime() throws {
        let url = file("level")
        try AudioFixture.wav(seconds: 60, levels: [(0...30, 0.5)], at: url)

        let level = try XCTUnwrap(AudioLoudness.speechLevel(in: url, speech: [0...30]))

        XCTAssertEqual(level, 0.5, accuracy: 0.05)
        XCTAssertNil(
            AudioLoudness.speechLevel(in: url, speech: []),
            "мерить уровень не по чему — значит его нет, а не ноль"
        )
    }

    /// Реплики в живой расшифровке короче окна прослушивания: три–пять секунд.
    /// Первая версия требовала реплику длиной в окно и на такой записи не мерила
    /// ничего — порог падал к абсолютному, то есть к шуму комнаты.
    func testShortRepliesAreEnoughToMeasureSpeech() throws {
        let url = file("short-replies")
        try AudioFixture.wav(
            seconds: 60,
            levels: [(0...4, 0.5), (6...10, 0.5), (12...16, 0.5)],
            at: url
        )

        let level = try XCTUnwrap(
            AudioLoudness.speechLevel(in: url, speech: [0...4, 6...10, 12...16]),
            "по репликам в четыре секунды уровень речи обязан считаться"
        )

        XCTAssertEqual(level, 0.5, accuracy: 0.05)
    }

    /// **Главный тест этой пары.** Абсолютный порог на настоящей записи бесполезен:
    /// в молчании есть шум комнаты, и он громче цифрового нуля. Порог, посчитанный
    /// от уровня речи, отличает шум от речи, а абсолютный — нет.
    func testRoomNoiseIsNotMistakenForLostSpeech() throws {
        let url = file("noise")
        try AudioFixture.wav(seconds: 70, levels: [(0...30, 0.5), (40...70, 0.005)], at: url)

        let level = AudioLoudness.speechLevel(in: url, speech: [0...30])
        let threshold = AudioLoudness.threshold(speechLevel: level)

        XCTAssertNil(
            AudioLoudness.sound(in: url, range: 40...70, louderThan: threshold),
            "шум на 40 dB тише речи — это молчание, а не потерянный текст"
        )
        XCTAssertNotNil(
            AudioLoudness.sound(in: url, range: 40...70, louderThan: AudioLoudness.floor),
            "а абсолютный порог тот же шум принимает за речь — ради этого порог и относительный"
        )
    }

    /// Тихая реплика от шума отличается: она в разы, а не на порядки тише речи.
    /// Порог стоит на −12 dB, и реплика на −8 dB его проходит.
    func testQuietSpeechIsStillSpeech() throws {
        let url = file("quiet")
        try AudioFixture.wav(seconds: 70, levels: [(0...30, 0.5), (40...70, 0.2)], at: url)

        let threshold = AudioLoudness.threshold(
            speechLevel: AudioLoudness.speechLevel(in: url, speech: [0...30])
        )

        XCTAssertNotNil(AudioLoudness.sound(in: url, range: 40...70, louderThan: threshold))
    }

    /// Скрип стула посреди тихой минуты — не пропущенная речь. Разговор занимает
    /// участок целиком, одиночный выброс — нет, и переспрашивать его незачем.
    func testIsolatedNoiseIsNotTreatedAsLostSpeech() throws {
        let url = file("blip")
        try AudioFixture.wav(seconds: 150, levels: [(0...30, 0.5), (100...104, 0.5)], at: url)

        let threshold = AudioLoudness.threshold(
            speechLevel: AudioLoudness.speechLevel(in: url, speech: [0...30])
        )

        XCTAssertNil(AudioLoudness.sound(in: url, range: 40...150, louderThan: threshold))
        XCTAssertNotNil(
            AudioLoudness.sound(in: url, range: 40...150, louderThan: threshold, sustain: 5),
            "а если полминуты не требовать, тот же выброс находится — значит дело в правиле, а не в пороге"
        )
    }

    /// За концом файла слушать нечего, и пустое чтение не должно выглядеть тишиной
    /// длиной в вечность: `peaks` там просто кончается.
    func testListeningStopsAtTheEndOfTheFile() throws {
        let url = file("short")
        try AudioFixture.wav(seconds: 20, levels: [(0...20, 0.5)], at: url)

        XCTAssertTrue(AudioLoudness.peaks(in: url, range: 40...80).isEmpty)
        let inside = AudioLoudness.peaks(in: url, range: 0...80)
        XCTAssertFalse(inside.isEmpty)
        XCTAssertLessThanOrEqual(
            inside.last?.range.upperBound ?? 0,
            20 + AudioLoudness.window,
            "за концом записи окон нет"
        )
    }
}
