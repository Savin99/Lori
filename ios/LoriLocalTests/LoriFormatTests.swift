import XCTest
@testable import LoriLocal

final class LoriFormatTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    func testStampShowsTimeForToday() {
        let stamp = LoriFormat.stamp(now.addingTimeInterval(-600), now: now, calendar: calendar)
        XCTAssertTrue(stamp.contains(":"), stamp)
        XCTAssertFalse(stamp.contains("вчера"), stamp)
    }

    func testStampMarksYesterday() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertTrue(LoriFormat.stamp(yesterday, now: now, calendar: calendar).hasPrefix("вчера, "))
    }

    func testStampKeepsYearForOtherYears() {
        let old = calendar.date(byAdding: .year, value: -2, to: now)!
        XCTAssertTrue(LoriFormat.stamp(old, now: now, calendar: calendar).contains("2024"))
    }

    func testGroupTitles() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(LoriFormat.groupTitle(now, now: now, calendar: calendar), "Сегодня")
        XCTAssertEqual(LoriFormat.groupTitle(yesterday, now: now, calendar: calendar), "Вчера")
        XCTAssertFalse(LoriFormat.groupTitle(
            calendar.date(byAdding: .day, value: -5, to: now)!, now: now, calendar: calendar
        ).isEmpty)
    }

    func testRussianPluralForms() {
        XCTAssertEqual(LoriFormat.noteCount(0), "0 заметок")
        XCTAssertEqual(LoriFormat.noteCount(1), "1 заметка")
        XCTAssertEqual(LoriFormat.noteCount(2), "2 заметки")
        XCTAssertEqual(LoriFormat.noteCount(5), "5 заметок")
        XCTAssertEqual(LoriFormat.noteCount(11), "11 заметок")
        XCTAssertEqual(LoriFormat.noteCount(21), "21 заметка")
        XCTAssertEqual(LoriFormat.noteCount(112), "112 заметок")
    }

    func testRelativeLabels() {
        XCTAssertEqual(LoriFormat.relative(now.addingTimeInterval(-30), now: now, calendar: calendar), "сейчас")
        XCTAssertEqual(LoriFormat.relative(now.addingTimeInterval(-600), now: now, calendar: calendar), "10 мин")
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(LoriFormat.relative(yesterday, now: now, calendar: calendar), "вчера")
        XCTAssertFalse(LoriFormat.relative(
            calendar.date(byAdding: .day, value: -9, to: now)!, now: now, calendar: calendar
        ).isEmpty)
    }

    func testDurationFormat() {
        XCTAssertEqual(LoriFormat.duration(0), "0:00")
        XCTAssertEqual(LoriFormat.duration(7.8), "0:07")
        XCTAssertEqual(LoriFormat.duration(723), "12:03")
    }
}
