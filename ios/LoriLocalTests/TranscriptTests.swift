import XCTest
@testable import LoriLocal

final class TranscriptTests: XCTestCase {
    // blank = 6
    private let pieces = ["\u{2581}привет", "\u{2581}мир", ".", "\u{2581}как", "\u{2581}дела", "?"]

    private func vocabulary() throws -> SentencePieceVocabulary {
        try SentencePieceVocabulary(pieces: pieces)
    }

    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptWord {
        TranscriptWord(start: start, end: end, text: text)
    }

    func testStampFormats() {
        XCTAssertEqual(TranscriptSegment.stamp(0), "0:00")
        XCTAssertEqual(TranscriptSegment.stamp(7.9), "0:07")
        XCTAssertEqual(TranscriptSegment.stamp(723), "12:03")
        XCTAssertEqual(TranscriptSegment.stamp(3_920), "1:05:20")
    }

    func testMarkdownWithoutSegmentsIsPlainText() {
        XCTAssertEqual(Transcript(text: "просто текст").markdown(title: "Запись"), "# Запись\n\nпросто текст\n")
    }

    func testMarkdownShowsTimeRange() {
        let transcript = Transcript(text: "привет мир.", segments: [
            TranscriptSegment(start: 0, end: 1.2, text: "привет мир."),
            TranscriptSegment(start: 72.5, end: 75, text: "как дела?"),
        ])
        XCTAssertEqual(
            transcript.markdown(title: "Звонок"),
            "# Звонок\n\n**[0:00–0:01]** привет мир.\n\n**[1:12–1:15]** как дела?\n"
        )
    }

    /// Выключенные «Таймкоды реплик»: время из файла уходит, а метки говорящих
    /// и предупреждения о пропусках остаются — они не про время.
    func testMarkdownWithoutStampsKeepsSpeakersAndWarnings() {
        let transcript = Transcript(
            text: "Г1: привет. Г2: привет.",
            segments: [
                TranscriptSegment(start: 0, end: 1, text: "Г1: привет."),
                TranscriptSegment(start: 2, end: 3, text: "Г2: привет."),
            ],
            warnings: ["Похоже на пропуск 0:05–1:10."]
        )
        let markdown = transcript.markdown(title: "Звонок", stamps: false)
        XCTAssertFalse(markdown.contains("**["), "времени в файле нет")
        XCTAssertTrue(markdown.contains("Г1: привет."))
        XCTAssertTrue(markdown.contains("> Похоже на пропуск"), "предупреждение не потерялось")
    }

    // MARK: слова

    /// Кусок с маркером «▁» открывает новое слово, сам маркер в текст не попадает.
    func testWordsSplitOnWordStartMarker() throws {
        let words = TranscriptWordBuilder().words(
            tokens: [0, 1, 2],
            tokenFrames: [0, 5, 6],
            vocabulary: try vocabulary(),
            frameDuration: 0.04
        )
        XCTAssertEqual(words.map(\.text), ["привет", "мир."])
        XCTAssertEqual(words[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(words[0].end, 0.04, accuracy: 1e-9, "конец — кадр последнего токена плюс один")
        XCTAssertEqual(words[1].start, 0.2, accuracy: 1e-9)
        XCTAssertEqual(words[1].end, 0.28, accuracy: 1e-9)
    }

    func testWordsRespectOffset() throws {
        let words = TranscriptWordBuilder().words(
            tokens: [0], tokenFrames: [10], vocabulary: try vocabulary(),
            frameDuration: 0.04, offset: 25
        )
        XCTAssertEqual(words.first?.start ?? 0, 25.4, accuracy: 1e-9)
    }

    func testMismatchedInputGivesNoWords() throws {
        XCTAssertTrue(TranscriptWordBuilder().words(
            tokens: [0, 1], tokenFrames: [0], vocabulary: try vocabulary(), frameDuration: 0.04
        ).isEmpty)
    }

    // MARK: реплики

    func testSegmentsSplitOnSentenceEnd() {
        let segments = TranscriptAssembler().segments(from: [
            word("привет", 0, 0.5), word("мир.", 0.5, 1), word("как", 1.1, 1.4), word("дела?", 1.4, 1.8),
        ])
        XCTAssertEqual(segments.map(\.text), ["привет мир.", "как дела?"])
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 1)
    }

    func testSegmentsSplitOnLongPause() {
        let segments = TranscriptAssembler(pauseSeconds: 0.8).segments(from: [
            word("привет", 0, 0.5), word("мир", 5, 5.4),
        ])
        XCTAssertEqual(segments.map(\.text), ["привет", "мир"])
    }

    func testShortPauseKeepsOneSegment() {
        let segments = TranscriptAssembler(pauseSeconds: 0.8).segments(from: [
            word("привет", 0, 0.5), word("мир", 0.6, 1),
        ])
        XCTAssertEqual(segments.map(\.text), ["привет мир"])
    }

    // MARK: перекрытие кусков

    /// Слова из перекрытия отбрасываются: этот звук уже расшифрован предыдущим куском.
    func testMergeDropsWordsFromOverlap() {
        let assembler = TranscriptAssembler()
        var accumulated = [word("первый", 0, 1), word("кусок", 1, 2)]

        assembler.merge(
            into: &accumulated,
            words: [word("кусок", 1.1, 2.1), word("второй", 2.5, 3)],
            coveredUntil: 2
        )

        XCTAssertEqual(accumulated.map(\.text), ["первый", "кусок", "второй"], "дубль из перекрытия убран")
    }

    func testMergeKeepsEverythingWhenNothingCoveredYet() {
        let assembler = TranscriptAssembler()
        var accumulated: [TranscriptWord] = []
        assembler.merge(into: &accumulated, words: [word("раз", 0, 1)], coveredUntil: 0)
        XCTAssertEqual(accumulated.map(\.text), ["раз"])
    }

    func testTranscriptFromWordsBuildsTextAndSegments() {
        let transcript = TranscriptAssembler().transcript(from: [
            word("привет", 0, 0.5), word("мир.", 0.5, 1),
        ])
        XCTAssertEqual(transcript.text, "привет мир.")
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.words.count, 2)
    }
}
