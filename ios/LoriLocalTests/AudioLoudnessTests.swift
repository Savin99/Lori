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

    /// Уровень — громкость кадров (RMS), а не пик: у синуса амплитуды 0,5 это
    /// 0,5/√2 ≈ 0,354. До 6 октября тест ждал 0,5 — пик, которым уровень мерился
    /// раньше; пик сменён потому, что одного щелчка хватало, чтобы назвать тихую
    /// минуту речью. Проверяемое свойство то же: уровень меряется по
    /// расшифрованному времени, а без речи его нет.
    func testSpeechLevelIsMeasuredOnTranscribedTime() throws {
        let url = file("level")
        try AudioFixture.wav(seconds: 60, levels: [(0...30, 0.5)], at: url)

        let level = try XCTUnwrap(AudioLoudness.speechLevel(in: url, speech: [0...30]))

        XCTAssertEqual(level, 0.5 / Float(2).squareRoot(), accuracy: 0.05)
        XCTAssertNil(
            AudioLoudness.speechLevel(in: url, speech: []),
            "мерить уровень не по чему — значит его нет, а не ноль"
        )
    }

    /// Реплики в живой расшифровке короче окна прослушивания: три–пять секунд.
    /// Первая версия требовала реплику длиной в окно и на такой записи не мерила
    /// ничего — порог падал к абсолютному, то есть к шуму комнаты.
    ///
    /// Ожидание — 0,5/√2, а не 0,5: уровень теперь громкость кадров, а не пик
    /// (см. `testSpeechLevelIsMeasuredOnTranscribedTime`).
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

        XCTAssertEqual(level, 0.5 / Float(2).squareRoot(), accuracy: 0.05)
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
    ///
    /// Во второй проверке требование снижено до трёх секунд, а было пять: выброс
    /// длится четыре секунды, и прежние десятисекундные окна засчитывали его
    /// целым окном, то есть за десять. Окна теперь по полсекунды, и выброс
    /// считается за свои четыре. Смысл проверки прежний: тот же выброс находится,
    /// как только требование ниже его длины, — дело в правиле, а не в пороге.
    func testIsolatedNoiseIsNotTreatedAsLostSpeech() throws {
        let url = file("blip")
        try AudioFixture.wav(seconds: 150, levels: [(0...30, 0.5), (100...104, 0.5)], at: url)

        let threshold = AudioLoudness.threshold(
            speechLevel: AudioLoudness.speechLevel(in: url, speech: [0...30])
        )

        XCTAssertNil(AudioLoudness.sound(in: url, range: 40...150, louderThan: threshold))
        XCTAssertNotNil(
            AudioLoudness.sound(in: url, range: 40...150, louderThan: threshold, sustain: 3),
            "а если столько не требовать, тот же выброс находится — значит дело в правиле, а не в пороге"
        )
    }

    /// За концом файла слушать нечего, и пустое чтение не должно выглядеть тишиной
    /// длиной в вечность: `levels` там просто кончается. (Функция называлась
    /// `peaks`, пока окна несли пик; теперь они несут громкость кадров — имя
    /// сменилось, проверка та же.)
    func testListeningStopsAtTheEndOfTheFile() throws {
        let url = file("short")
        try AudioFixture.wav(seconds: 20, levels: [(0...20, 0.5)], at: url)

        XCTAssertTrue(AudioLoudness.levels(in: url, range: 40...80).isEmpty)
        let inside = AudioLoudness.levels(in: url, range: 0...80)
        XCTAssertFalse(inside.isEmpty)
        XCTAssertLessThanOrEqual(
            inside.last?.range.upperBound ?? 0,
            20 + AudioLoudness.window,
            "за концом записи окон нет"
        )
    }

    // MARK: - Тишина с помехами против речи (6 октября 2026)

    /// Запись «речь — участок — речь» с шумом комнаты, как у владельца: минута
    /// разговора, потом проверяемый участок, потом снова минута разговора.
    private func conversation(
        around middle: [Float]
    ) throws -> (url: URL, gap: ClosedRange<TimeInterval>, speech: [ClosedRange<TimeInterval>]) {
        let url = file("conversation")
        try SyntheticSound.write(SyntheticSound.conversation(around: middle), to: url)
        let end = 60 + Double(middle.count) / SyntheticSound.rate
        return (url, 60...end, [0...60, end...(end + 60)])
    }

    private func peak(_ url: URL, at start: TimeInterval, length: TimeInterval) throws -> Float {
        try AudioSamples.load(from: url, at: start, length: length).reduce(0) { max($0, abs($1)) }
    }

    /// Уровень речи по прежнему правилу: медиана пиков десятисекундных окон.
    private func oldPeakLevel(_ url: URL, over speech: [ClosedRange<TimeInterval>]) throws -> Float {
        var peaks: [Float] = []
        for range in speech {
            for start in stride(from: range.lowerBound, to: range.upperBound, by: 10) {
                peaks.append(try peak(url, at: start, length: 10))
            }
        }
        peaks.sort()
        return peaks[peaks.count / 2]
    }

    /// **Случай владельца.** Минута тишины посреди разговора со щелчками громче
    /// речи, стуками по столу, двумя приступами кашля и клавиатурой — не
    /// потерянная речь, и плашки над ней быть не должно.
    func testClicksKnocksCoughsAndTypingInASilentMinuteAreNotSpeech() throws {
        let take = try conversation(around: SyntheticSound.busySilence(speech: 0.1, seed: 11))
        let level = AudioLoudness.speechLevel(in: take.url, speech: take.speech)

        XCTAssertEqual(AudioLoudness.verdict(in: take.url, range: take.gap, speechLevel: level), .silence)

        // Свидетель: прежнее правило — пик в окне 10 с против −12 dB от медианы
        // пиков речи, громких окон на полминуты — назвало бы эту минуту пропуском.
        // Без этой проверки зелёный тест мог бы просто не воспроизводить случай.
        let oldThreshold = try oldPeakLevel(take.url, over: take.speech) * AudioLoudness.quietShare
        let loud = try stride(from: take.gap.lowerBound, to: take.gap.upperBound, by: 10).filter {
            try peak(take.url, at: $0, length: 10) >= oldThreshold
        }
        XCTAssertGreaterThanOrEqual(loud.count, 3, "фикстура обязана ловить прежнее правило: \(loud)")
    }

    /// Короткий участок, как «20:17–20:34» у владельца: семнадцать секунд с
    /// приступом кашля и щелчком — тишина, а те же семнадцать секунд речи — речь.
    func testShortGapIsJudgedByWhatFillsIt() throws {
        var coughing = SyntheticSound.noise(seconds: 17, rms: 0.1 * 0.018, seed: 41)
        SyntheticSound.add(SyntheticSound.coughFit(rms: 0.14, seed: 42), to: &coughing, at: 6)
        SyntheticSound.add(SyntheticSound.click(peak: 0.36), to: &coughing, at: 2.5)
        SyntheticSound.add(SyntheticSound.click(peak: 0.36), to: &coughing, at: 13.4)
        let silent = try conversation(around: coughing)
        XCTAssertEqual(
            AudioLoudness.verdict(
                in: silent.url,
                range: silent.gap,
                speechLevel: AudioLoudness.speechLevel(in: silent.url, speech: silent.speech)
            ),
            .silence,
            "кашель — короче фразы"
        )

        let spoken = try conversation(around: SyntheticSound.speechLike(seconds: 17, level: 0.1, seed: 43))
        let verdict = AudioLoudness.verdict(
            in: spoken.url,
            range: spoken.gap,
            speechLevel: AudioLoudness.speechLevel(in: spoken.url, speech: spoken.speech)
        )
        guard case .speech = verdict else { return XCTFail("17 секунд речи — потерянная речь: \(verdict)") }
    }

    /// Речь тише остального разговора — всё ещё речь: собеседник дальше от
    /// телефона. Это ровно тот пропуск, ради которого проверка и написана.
    func testQuieterSpeechFillingTheGapIsStillLostSpeech() throws {
        // −8 dB от речи вокруг.
        let take = try conversation(around: SyntheticSound.speechLike(seconds: 60, level: 0.04, seed: 21))
        let level = AudioLoudness.speechLevel(in: take.url, speech: take.speech)

        guard case let .speech(found) = AudioLoudness.verdict(in: take.url, range: take.gap, speechLevel: level) else {
            return XCTFail("речь на 8 dB тише остальной — всё ещё речь")
        }
        XCTAssertGreaterThanOrEqual(found.lowerBound, take.gap.lowerBound, "\(found)")
        XCTAssertLessThanOrEqual(found.upperBound, take.gap.upperBound, "\(found)")
        XCTAssertGreaterThan(found.upperBound - found.lowerBound, 45, "и названа почти целиком: \(found)")
    }

    /// Приступы кашля один за другим — не разговор: самый длинный короче фразы.
    func testCoughFitsAreNotPhrases() throws {
        var coughing = SyntheticSound.noise(seconds: 60, rms: 0.1 * 0.018, seed: 51)
        for (index, at) in [4.0, 13.0, 21.5, 30.0, 41.0, 52.0].enumerated() {
            SyntheticSound.add(SyntheticSound.coughFit(rms: 0.14, seed: 52 + UInt64(index)), to: &coughing, at: at)
        }
        let take = try conversation(around: coughing)
        let level = AudioLoudness.speechLevel(in: take.url, speech: take.speech)

        XCTAssertEqual(AudioLoudness.verdict(in: take.url, range: take.gap, speechLevel: level), .silence)
    }

    /// Ровный шум на 9 dB тише речи — кондиционер при тихих собеседниках. Порог
    /// −12 dB от речи его пропускает, поправка на фон участка — нет.
    func testSteadyNoiseNearQuietSpeechIsNotSpeech() throws {
        let take = try conversation(around: SyntheticSound.noise(seconds: 60, rms: 0.0355, seed: 31))
        let level = AudioLoudness.speechLevel(in: take.url, speech: take.speech)

        XCTAssertEqual(AudioLoudness.verdict(in: take.url, range: take.gap, speechLevel: level), .silence)
        XCTAssertNotNil(
            AudioLoudness.sound(in: take.url, range: take.gap, louderThan: AudioLoudness.threshold(speechLevel: level)),
            "без поправки на фон тот же шум прошёл бы порог — ради этого поправка и есть"
        )
    }

    /// Звук ровной громкости на уровне речи — музыка, телевизор — это «что-то
    /// звучит, а текста нет», и поправка на фон его не прячет: потолок поправки
    /// стоит ниже уровня речи.
    func testSoundAsLoudAsSpeechIsStillSound() throws {
        let url = file("steady")
        try AudioFixture.wav(seconds: 180, levels: [(0...180, 0.5)], at: url)
        let level = AudioLoudness.speechLevel(in: url, speech: [0...60, 120...180])

        guard case .speech = AudioLoudness.verdict(in: url, range: 60...120, speechLevel: level) else {
            return XCTFail("ровный звук на уровне речи — звук")
        }
    }

    /// Проба уровня речи — четыре секунды, а реплики бывают по полторы. Проба
    /// читает и тишину за репликой, но в счёт идут только окна внутри речи: иначе
    /// уровень утянуло бы к нулю, а с ним и порог.
    func testSpeechLevelIgnoresSilenceAroundShortReplies() throws {
        let url = file("replies")
        try AudioFixture.wav(seconds: 30, levels: [(0...1.5, 0.5), (10...11.5, 0.5), (20...21.5, 0.5)], at: url)

        let level = try XCTUnwrap(AudioLoudness.speechLevel(in: url, speech: [0...1.5, 10...11.5, 20...21.5]))

        XCTAssertEqual(level, 0.5 / Float(2).squareRoot(), accuracy: 0.05)
    }

    /// Нечего слушать — это не тишина. За концом файла и без файла вердикт
    /// «не читается»: спрятать плашку можно, только услышав тишину.
    func testNothingToHearIsNotSilence() throws {
        let url = file("short-verdict")
        try AudioFixture.wav(seconds: 20, levels: [(0...20, 0.5)], at: url)
        let missing = FileManager.default.temporaryDirectory.appending(path: "нет-такого-\(UUID().uuidString).wav")

        XCTAssertEqual(AudioLoudness.verdict(in: url, range: 40...80, speechLevel: 0.35), .unreadable)
        XCTAssertEqual(AudioLoudness.verdict(in: missing, range: 0...10, speechLevel: 0.35), .unreadable)
    }
}
