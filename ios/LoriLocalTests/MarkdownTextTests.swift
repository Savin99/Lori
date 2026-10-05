import XCTest
@testable import LoriLocal

/// Разбор Markdown. Расшифровка хранится в Markdown (заголовок, таймкоды жирным), и без разбора
/// человек читал «**Где это записано:**» вместе с решётками и обратными кавычками.
final class MarkdownTextTests: XCTestCase {
    func testHeadingsBulletsAndNumbers() {
        let blocks = MarkdownBlock.blocks(from: """
        ## Где это записано

        - `Работа/Оффер.md` — оффер до пятницы
        * второй пункт
        1. первый шаг
        2) второй шаг
        """)

        XCTAssertEqual(blocks, [
            .heading("Где это записано", level: 2),
            .bullet("`Работа/Оффер.md` — оффер до пятницы"),
            .bullet("второй пункт"),
            .numbered("первый шаг", number: "1"),
            .numbered("второй шаг", number: "2"),
        ])
    }

    func testCodeFenceKeepsItsLinesAndIsNotParsed() {
        let blocks = MarkdownBlock.blocks(from: """
        Вот команда:
        ```bash
        - не список
        # не заголовок
        ```
        конец
        """)

        XCTAssertEqual(blocks, [
            .paragraph("Вот команда:"),
            .code("- не список\n# не заголовок"),
            .paragraph("конец"),
        ])
    }

    func testUnclosedFenceStillShowsItsText() {
        // Оборванный ответ не должен прятать текст целиком.
        let blocks = MarkdownBlock.blocks(from: "Смотри:\n```\nтекст без закрытия")
        XCTAssertEqual(blocks, [.paragraph("Смотри:"), .code("текст без закрытия")])
    }

    func testCheckboxBecomesPlainItemAndRulerIsDropped() {
        let blocks = MarkdownBlock.blocks(from: "- [ ] позвонить\n\n---\n\nдальше")
        XCTAssertEqual(blocks, [.bullet("позвонить"), .paragraph("дальше")])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        // «#найм» — это тег, а не заголовок.
        XCTAssertEqual(MarkdownBlock.blocks(from: "#найм и #оффер"), [.paragraph("#найм и #оффер")])
    }

    func testQuoteIsSeparateBlock() {
        XCTAssertEqual(MarkdownBlock.blocks(from: "> цитата\nобычная строка"), [
            .quote("цитата"),
            .paragraph("обычная строка"),
        ])
    }

    func testInlineMarkupIsResolvedAndNeverShownRaw() {
        let bold = MarkdownBlock.inline("**Где это записано:**")
        XCTAssertEqual(String(bold.characters), "Где это записано:")

        let code = MarkdownBlock.inline("путь `Работа/Оффер.md` внутри")
        XCTAssertEqual(String(code.characters), "путь Работа/Оффер.md внутри")

        // Незакрытая разметка остаётся текстом — падать тут нельзя.
        XCTAssertEqual(String(MarkdownBlock.inline("**без пары").characters), "**без пары")

        // Чекбокс посреди строки Markdown рисовал серым квадратом пустую ссылку.
        XCTAssertEqual(
            String(MarkdownBlock.inline("задача: [ ] выкатить").characters),
            "задача: ☐ выкатить"
        )
    }
}
