import XCTest
@testable import LoriLocal

/// Контроль полноты: модель может вернуть правдоподобный текст, начав с середины
/// записи. Единственный способ это заметить — сравнить время реплик с длиной аудио.
final class TranscriptCoverageTests: XCTestCase {
    private func segment(_ from: TimeInterval, _ to: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(start: from, end: to, text: "реплика")
    }

    func testOverlappingSegmentsCountOnce() {
        let merged = TranscriptCoverage.merged([segment(0, 10), segment(8, 15), segment(30, 40)])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.upperBound, 15)
        XCTAssertEqual(TranscriptCoverage.covered([segment(0, 10), segment(8, 15)]), 15)
    }

    /// Ровно случай владельца: GigaAM распознал первые полторы минуты, Gemini начал позже.
    func testMissingBeginningIsAGap() {
        let gaps = TranscriptCoverage.gaps(in: [segment(100, 300)], duration: 300)

        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.lowerBound, 0)
        XCTAssertEqual(gaps.first?.upperBound, 100)
        XCTAssertEqual(TranscriptCoverage.describe(gaps[0]), "0:00–1:40")
    }

    func testGapAtTheEndAndInTheMiddle() {
        let gaps = TranscriptCoverage.gaps(in: [segment(0, 60), segment(90, 120)], duration: 200)

        XCTAssertEqual(gaps.map(\.lowerBound), [60, 120])
        XCTAssertEqual(gaps.map(\.upperBound), [90, 200])
    }

    /// Паузы между фразами пропусками не считаются, иначе предупреждений будет больше,
    /// чем текста.
    func testShortSilenceIsNotAGap() {
        XCTAssertTrue(TranscriptCoverage.gaps(in: [segment(0, 30), segment(33, 60)], duration: 60).isEmpty)
        XCTAssertEqual(TranscriptCoverage.gaps(in: [segment(0, 30), segment(45, 60)], duration: 60).count, 1)
    }

    func testShareIsClampedAndSafe() {
        XCTAssertEqual(TranscriptCoverage.share([segment(0, 50)], duration: 100), 0.5)
        XCTAssertEqual(TranscriptCoverage.share([segment(0, 150)], duration: 100), 1)
        XCTAssertEqual(TranscriptCoverage.share([], duration: 0), 0)
    }

    /// Предупреждения должны доезжать до файла расшифровки: иначе человек решит,
    /// что на пропущенном участке была тишина.
    func testWarningsLandInMarkdown() {
        let transcript = Transcript(
            text: "текст",
            segments: [segment(0, 10)],
            warnings: ["Пропуск 0:00–1:40: модель не вернула текст для этого участка."]
        )

        let markdown = transcript.markdown(title: "Встреча", engine: "Gemini")

        XCTAssertTrue(markdown.contains("> Пропуск 0:00–1:40"), markdown)
        XCTAssertTrue(markdown.contains("_Расшифровано: Gemini_"))
    }
}
