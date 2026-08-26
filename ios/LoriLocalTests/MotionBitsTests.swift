import XCTest
@testable import LoriLocal

/// Числа и разрезка текста, на которых держится движение в чате.
/// Сами анимации проверяются глазами на снимках, а вот эти две вещи — тестом.
final class MotionBitsTests: XCTestCase {
    func testFractionIsNilWhenThereIsNothingToShow() {
        // Короткий файл идёт одним куском: процентов взять негде, и врать ими нельзя.
        XCTAssertNil(TranscriptionService.fraction(done: 0, total: 1))
        XCTAssertNil(TranscriptionService.fraction(done: 0, total: 0))
    }

    func testFractionCountsTheChunkInWork() {
        // «3 из 10» — это третий кусок в работе, то есть 0.3.
        XCTAssertEqual(TranscriptionService.fraction(done: 2, total: 10), 0.3)
        XCTAssertEqual(TranscriptionService.fraction(done: 0, total: 10), 0.1)
        XCTAssertEqual(TranscriptionService.fraction(done: 9, total: 10), 1.0)
        // Перебор в колбэке движка не должен давать больше единицы.
        XCTAssertEqual(TranscriptionService.fraction(done: 40, total: 10), 1.0)
    }

    func testFirstLinesKeepWholeWordsAndRespectTheLimit() {
        let text = """
        Так, по найму: первый кандидат сильнее в бэкенде, оффер нужен до пятницы,
        иначе его перехватят — у него ещё две компании в процессе.
        """
        let lines = MotionText.firstLines(of: text, limit: 3, charactersPerLine: 30)

        XCTAssertEqual(lines.count, 3)
        // Обрыв по лимиту строк видно по многоточию, а не по повисшему слову.
        XCTAssertTrue(lines[2].hasSuffix("…"), "последняя строка обрывается без многоточия: «\(lines[2])»")
        for line in lines {
            XCTAssertFalse(line.hasPrefix(" "), "строка начинается с пробела: «\(line)»")
            XCTAssertFalse(line.contains("  "), "двойной пробел в строке: «\(line)»")
        }
        // Слова не рвутся: каждая строка целиком состоит из слов исходника.
        let words = Set(text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
        let produced = lines.joined(separator: " ")
            .replacingOccurrences(of: "…", with: "")
            .split(separator: " ")
            .map(String.init)
        for word in produced {
            XCTAssertTrue(words.contains(word), "слово «\(word)» изменилось при разрезке")
        }
    }

    func testFirstLinesOnShortTextGiveOneLine() {
        XCTAssertEqual(MotionText.firstLines(of: "Коротко и всё", limit: 3), ["Коротко и всё"])
        XCTAssertTrue(MotionText.firstLines(of: "   ", limit: 3).isEmpty)
        XCTAssertTrue(MotionText.firstLines(of: "текст", limit: 0).isEmpty)
    }
}
