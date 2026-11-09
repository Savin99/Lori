import XCTest
@testable import LoriLocal

final class ReportMarkdownTests: XCTestCase {
    func testBulletedNumberedAndNestedListsSeparateMarkersFromInlineMarkdown() {
        let rows = ReportMarkdown.rows("# Отчёт\n\n- **Главное**\n  + Вложенный\n    3. Третий\n\t* Ещё\n2) Второй\nОбычный текст\n---")
        XCTAssertEqual(rows.map(\.text), ["Отчёт", "**Главное**", "Вложенный", "Третий", "Ещё", "Второй", "Обычный текст", "---"])
        XCTAssertEqual(rows.map(\.marker), [nil, "•", "•", "3.", "•", "2)", nil, nil])
        XCTAssertEqual(rows.map(\.indent), [0, 0, 2, 4, 4, 0, 0, 0])
        XCTAssertTrue(rows[0].heading)
    }
}
