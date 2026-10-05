import XCTest
@testable import LoriLocal

/// Время из текста ответа. Штатные поля таймкодов сервис не принимает, поэтому
/// время просят словами — и разбирать его надо надёжно.
final class StampedTranscriptTests: XCTestCase {
    func testLinesWithBracketedTimeBecomeSegments() {
        let text = """
        [0:00] Так, идём дальше.
        [0:21] Под базой знаний мы что будем понимать?
        [1:05] Какая-то интегрированная база.
        """

        let segments = StampedTranscript.segments(from: text, offset: 0, end: 120)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1].start, 21)
        XCTAssertEqual(segments[1].text, "Под базой знаний мы что будем понимать?")
        XCTAssertEqual(segments[0].end, 21, "реплика длится до следующей метки")
    }

    /// Отправленный фрагмент мог начинаться не с нуля — время сдвигается.
    func testOffsetShiftsTime() {
        let segments = StampedTranscript.segments(from: "[0:10] Речь.", offset: 300, end: 600)

        XCTAssertEqual(segments.first?.start, 310)
    }

    /// Разные написания времени, которые встречаются в ответах моделей.
    func testCommonStampShapes() {
        XCTAssertEqual(StampedTranscript.leadingStamp("[1:23] раз")?.start, 83)
        XCTAssertEqual(StampedTranscript.leadingStamp("(01:23) два")?.start, 83)
        XCTAssertEqual(StampedTranscript.leadingStamp("1:01:05 — три")?.start, 3665)
        XCTAssertEqual(StampedTranscript.leadingStamp("00:12: четыре")?.start, 12)
        XCTAssertEqual(StampedTranscript.leadingStamp("[1:23] пять")?.text, "пять")
        XCTAssertNil(StampedTranscript.leadingStamp("Просто речь без времени."))
    }

    /// Продолжение реплики без метки не должно терять текст.
    func testUnstampedContinuationJoinsPreviousLine() {
        let text = "[0:05] Начало реплики,\nа это её продолжение.\n[0:30] Следующая."

        let segments = StampedTranscript.segments(from: text, offset: 0, end: 60)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Начало реплики, а это её продолжение.")
    }

    /// Обычный текст без времени разбирать нечего — иначе он развалится на куски.
    func testPlainTextIsNotTreatedAsStamped() {
        XCTAssertFalse(StampedTranscript.looksStamped("Просто длинный текст расшифровки без всякого времени."))
    }
}
