import XCTest
@testable import LoriLocal

/// Плашки «Пропуск A–B», уже лежащие в файлах расшифровок, сверяются со звуком:
/// над тишиной они не показываются ни на экране, ни в экспорте, а файл остаётся
/// как был. Повод — запись владельца 43:28 с плашками над настоящей тишиной.
final class GapRecheckTests: XCTestCase {
    private var files: [URL] = []

    override func tearDownWithError() throws {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        files = []
    }

    private func temp(_ name: String, _ suffix: String = "wav") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "recheck-\(name)-\(UUID().uuidString).\(suffix)")
        files.append(url)
        return url
    }

    /// Плашка в том виде, в каком её пишет ElevenLabs: участок 1:00–2:00.
    private let silentGap = "Пропуск 1:00–2:00: в ответе сервиса нет текста для этого участка."
    /// Замечание о сорвавшемся ответе — не о тишине, его не сверяют.
    private let loop = "Участок 0:00–5:00: модель зациклилась (повтор), расшифровки этого участка нет."

    /// Расшифровка записи «речь — участок — речь»: реплики на речи и плашки в
    /// конце файла, как их пишет `Transcript.markdown`.
    private func markdown(warnings: [String]) -> String {
        Transcript(
            text: "",
            segments: [
                TranscriptSegment(start: 0, end: 30, text: "S1: Первая половина разговора до паузы."),
                TranscriptSegment(start: 30, end: 60, text: "S2: Ответ на неё, тоже до паузы."),
                TranscriptSegment(start: 120, end: 150, text: "S1: Разговор после паузы."),
                TranscriptSegment(start: 150, end: 180, text: "S2: И его окончание."),
            ],
            warnings: warnings
        ).markdown(title: "Тест", engine: "ElevenLabs · scribe_v2", mode: "Дословно")
    }

    private func recording(around middle: [Float]) throws -> URL {
        let url = temp("audio")
        try SyntheticSound.write(SyntheticSound.conversation(around: middle), to: url)
        return url
    }

    // MARK: - Разбор плашки

    func testGapRangeIsReadFromTheWarning() {
        XCTAssertEqual(
            TranscriptCoverage.gap(in: "Пропуск 4:19–5:19: в ответе сервиса нет текста для этого участка."),
            259...319
        )
        XCTAssertEqual(
            TranscriptCoverage.gap(in: "Пропуск 20:17–20:34: в ответе сервиса нет текста для этого участка."),
            1217...1234
        )
        XCTAssertEqual(TranscriptCoverage.gap(in: "Пропуск 32:20–33:37: слов для этого участка сервис не дал."), 1940...2017)
        // Старые сборки (до 3 сентября 2026) писали иначе — такие файлы у владельца есть.
        XCTAssertEqual(TranscriptCoverage.gap(in: "Похоже на пропуск 0:10–0:20: в ответе сервиса нет текста."), 10...20)
        XCTAssertEqual(TranscriptCoverage.gap(in: "Пропуск 1:02:03–1:05:00: текста нет"), 3723...3900)
        let range: ClosedRange<TimeInterval> = 3723...3900
        XCTAssertEqual(TranscriptCoverage.gap(in: "Пропуск \(TranscriptCoverage.describe(range)): …"), range, "обратное к describe")

        XCTAssertNil(TranscriptCoverage.gap(in: loop), "срыв ответа — не пропуск, звук там не спрашивают")
        XCTAssertNil(TranscriptCoverage.gap(in: "Участок 59:28–1:24:06: ответ сервиса оборвался по длине."))
        XCTAssertNil(TranscriptCoverage.gap(in: "Пропуск: без отрезка"))
    }

    // MARK: - Сверка со звуком

    /// **Случай владельца.** Плашка над минутой тишины со щелчками и кашлем не
    /// показывается; замечание о сорвавшемся ответе остаётся на месте.
    func testWarningOverSilenceIsHiddenAndOthersStay() async throws {
        let audio = try recording(around: SyntheticSound.busySilence(speech: 0.1, seed: 81))
        let document = TranscriptDocument.parse(markdown(warnings: [silentGap, loop]))
        let recheck = GapRecheck(storage: temp("verdicts", "json"))

        let shown = await recheck.visible(in: document, audio: audio)

        XCTAssertEqual(shown, [loop])
        XCTAssertEqual(document.warnings, [silentGap, loop], "разобранный файл не меняется — прячет только экран")
    }

    /// Плашка над речью, которой нет в тексте, — настоящая, и она остаётся.
    func testWarningOverSpeechStays() async throws {
        let audio = try recording(around: SyntheticSound.speechLike(seconds: 60, level: 0.05, seed: 82))
        let document = TranscriptDocument.parse(markdown(warnings: [silentGap, loop]))
        let recheck = GapRecheck(storage: temp("verdicts", "json"))

        let shown = await recheck.visible(in: document, audio: audio)

        XCTAssertEqual(shown, [silentGap, loop])
    }

    /// Записи нет — услышать тишину нечем, и плашка остаётся.
    func testWarningStaysWhenTheAudioIsGone() async throws {
        let document = TranscriptDocument.parse(markdown(warnings: [silentGap]))
        let recheck = GapRecheck(storage: temp("verdicts", "json"))
        let gone = temp("gone")

        let withoutURL = await recheck.visible(in: document, audio: nil)
        let withMissingFile = await recheck.visible(in: document, audio: gone)

        XCTAssertEqual(withoutURL, [silentGap])
        XCTAssertEqual(withMissingFile, [silentGap])
    }

    /// Участок за концом записи (файл заменили, расшифровка от другого звука) —
    /// тоже не тишина: про то, чего не слышали, утверждать нечего.
    func testWarningStaysWhenTheRangeIsBeyondTheRecording() async throws {
        let audio = try recording(around: SyntheticSound.busySilence(speech: 0.1, seed: 83))
        let beyond = "Пропуск 5:00–6:00: в ответе сервиса нет текста для этого участка."
        let document = TranscriptDocument.parse(markdown(warnings: [beyond]))
        let recheck = GapRecheck(storage: temp("verdicts", "json"))

        let shown = await recheck.visible(in: document, audio: audio)

        XCTAssertEqual(shown, [beyond])
    }

    /// Вердикт помнится — и после перезапуска: открыть экран записи второй раз не
    /// стоит ни одного чтения звука. Записали файл заново — слушаем заново.
    func testVerdictIsRememberedPerRecording() async throws {
        let audio = try recording(around: SyntheticSound.busySilence(speech: 0.1, seed: 84))
        let storage = temp("verdicts", "json")
        let document = TranscriptDocument.parse(markdown(warnings: [silentGap]))
        let counter = JudgeCounter()
        func recheck() -> GapRecheck {
            GapRecheck(storage: storage, judge: { url, range, level in
                counter.add()
                return AudioLoudness.verdict(in: url, range: range, speechLevel: level)
            })
        }

        let first = recheck()
        let shownFirst = await first.visible(in: document, audio: audio)
        let shownAgain = await first.visible(in: document, audio: audio)
        XCTAssertEqual(shownFirst, [])
        XCTAssertEqual(shownAgain, [])
        XCTAssertEqual(counter.count, 1, "второе открытие звук не слушает")

        let afterRelaunch = await recheck().visible(in: document, audio: audio)
        XCTAssertEqual(afterRelaunch, [])
        XCTAssertEqual(counter.count, 1, "после перезапуска вердикт берётся из файла")

        // Тот же путь, другой звук: теперь в участке речь.
        try SyntheticSound.write(
            SyntheticSound.conversation(around: SyntheticSound.speechLike(seconds: 61, level: 0.05, seed: 85)),
            to: audio
        )
        let afterRewrite = await recheck().visible(in: document, audio: audio)
        XCTAssertEqual(counter.count, 2, "запись сменилась — вердикт считается заново")
        XCTAssertEqual(afterRewrite, [silentGap], "и в новой записи под плашкой речь")
    }

    // MARK: - Экспорт

    /// Файл, отправленный человеку, не несёт ложной тревоги, которую экран уже
    /// спрятал: ни в Markdown, ни в замечаниях, из которых вёрстается PDF.
    func testExportDropsTheSilentGapButKeepsTheRest() async throws {
        let audio = try recording(around: SyntheticSound.busySilence(speech: 0.1, seed: 86))
        let export = TranscriptExport.make(
            markdown: markdown(warnings: [silentGap, loop]),
            title: "Тест",
            recordedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )

        let shown = await export.hidingSilentGaps(audio: audio, recheck: GapRecheck(storage: temp("verdicts", "json")))

        XCTAssertEqual(shown.warnings, [loop], "PDF вёрстается из этих замечаний")
        XCTAssertFalse(shown.markdown.contains("Пропуск 1:00–2:00"), shown.markdown)
        XCTAssertTrue(shown.markdown.contains("> \(loop)"), shown.markdown)
        XCTAssertEqual(shown.blocks, export.blocks, "текст расшифровки уходит целиком")
        XCTAssertEqual(export.warnings, [silentGap, loop], "исходный экспорт не тронут")
    }

    /// Без записи экспорт уходит как есть: спрятать тревогу можно, только
    /// услышав тишину.
    func testExportWithoutAudioKeepsEveryWarning() async throws {
        let export = TranscriptExport.make(
            markdown: markdown(warnings: [silentGap, loop]),
            title: "Тест",
            recordedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )

        let shown = await export.hidingSilentGaps(audio: nil, recheck: GapRecheck(storage: temp("verdicts", "json")))

        XCTAssertEqual(shown.warnings, [silentGap, loop])
    }
}

/// Сколько раз слушали звук. Судья зовётся из фоновой задачи, отсюда замок.
private final class JudgeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func add() { lock.withLock { value += 1 } }
}
