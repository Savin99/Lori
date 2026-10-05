import XCTest
@testable import LoriLocal

/// Оценка оставшегося времени и её формат. Числа тут человек читает на ходу,
/// поэтому важнее внятность, чем точность.
final class ProgressEstimateTests: XCTestCase {
    func testEstimateUsesElapsedShare() {
        // Половина работы за минуту — значит осталось около минуты.
        let left = try? XCTUnwrap(TranscriptionService.estimate(elapsed: 60, fraction: 0.5))
        XCTAssertEqual(left ?? 0, 60, accuracy: 0.1)
    }

    /// В самом начале оценка врёт слишком сильно, чтобы её показывать.
    func testNoEstimateAtTheVeryStart() {
        XCTAssertNil(TranscriptionService.estimate(elapsed: 2, fraction: 0.01))
    }

    /// В конце показывать нечего.
    func testNoEstimateWhenDone() {
        XCTAssertNil(TranscriptionService.estimate(elapsed: 100, fraction: 1))
    }

    /// Секунды округляются до пятёрок, минуты склоняются.
    func testHumanReadableFormat() {
        XCTAssertEqual(LoriFormat.approximate(38), "40 сек")
        XCTAssertEqual(LoriFormat.approximate(2), "5 сек", "«0 сек» читается как сбой, а не как оценка")
        XCTAssertEqual(LoriFormat.approximate(61), "1 минута")
        XCTAssertEqual(LoriFormat.approximate(150), "3 минуты")
        XCTAssertEqual(LoriFormat.approximate(400), "7 минут")
        XCTAssertEqual(LoriFormat.approximate(660), "11 минут")
    }
}
