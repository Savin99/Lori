import XCTest
@testable import LoriLocal

final class NoteDigestTests: XCTestCase {
    private let sample = NoteDigest(
        title: "Планёрка по найму",
        theme: "Работа",
        summary: "Обсудили двух кандидатов и сроки.",
        highlights: ["Кандидат А сильнее в бэкенде", "Оффер готовим до пятницы"],
        decisions: ["Берём кандидата А"],
        tasks: ["Написать оффер"],
        tags: ["найм", "планёрка"]
    )

    func testMarkdownKeepsLinksAndSections() {
        let text = sample.markdown(
            audioPath: "Recordings/Rec-1.m4a",
            transcriptPath: "Transcripts/Rec-1.md",
            created: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(text.hasPrefix("---\nlori: digest\n"))
        XCTAssertTrue(text.contains("audio: Recordings/Rec-1.m4a"))
        XCTAssertTrue(text.contains("transcript: Transcripts/Rec-1.md"))
        XCTAssertTrue(text.contains("theme: Работа"))
        XCTAssertTrue(text.contains("tags: найм, планёрка"))
        XCTAssertTrue(text.contains("# Планёрка по найму"))
        XCTAssertTrue(text.contains("## Важное\n- Кандидат А сильнее в бэкенде"))
        XCTAssertTrue(text.contains("## Решения\n- Берём кандидата А"))
        // Задачи — с чекбоксом: их отмечают, а не просто читают.
        XCTAssertTrue(text.contains("## Задачи\n- [ ] Написать оффер"))
    }

    func testMarkdownSkipsEmptySections() {
        var digest = sample
        digest.decisions = []
        digest.tasks = []
        digest.tags = []
        let text = digest.markdown(audioPath: nil, transcriptPath: nil, created: .now)

        XCTAssertFalse(text.contains("## Решения"))
        XCTAssertFalse(text.contains("## Задачи"))
        XCTAssertFalse(text.contains("tags:"))
        XCTAssertFalse(text.contains("audio:"))
    }

    func testMetaRoundTrip() {
        let text = sample.markdown(
            audioPath: "Recordings/Rec-1.m4a",
            transcriptPath: "Transcripts/Rec-1.md",
            created: .now
        )
        let meta = NoteMeta.parse(text)

        XCTAssertTrue(meta.isDigest)
        XCTAssertEqual(meta.audio, "Recordings/Rec-1.m4a")
        XCTAssertEqual(meta.transcript, "Transcripts/Rec-1.md")
        XCTAssertEqual(meta.theme, "Работа")
        XCTAssertEqual(meta.tags, ["найм", "планёрка"])
    }

    func testMetaIgnoresPlainNote() {
        let meta = NoteMeta.parse("# Обычная заметка\n\nтекст")
        XCTAssertFalse(meta.isDigest)
        XCTAssertNil(meta.audio)
        XCTAssertEqual(NoteMeta.body(of: "# Обычная заметка\n\nтекст"), "# Обычная заметка\n\nтекст")
    }

    func testBodyDropsFrontMatter() {
        let text = sample.markdown(audioPath: nil, transcriptPath: nil, created: .now)
        let body = NoteMeta.body(of: text)

        XCTAssertTrue(body.hasPrefix("# Планёрка по найму"))
        XCTAssertFalse(body.contains("lori: digest"))
    }

    func testPayloadSurvivesFencesAndProse() throws {
        let answer = """
        Готово, вот результат:
        ```json
        {"title": "«Разбор недели».", "theme": "Работа/личное", "summary": "Итоги.",
         "highlights": ["- Пункт", "Пункт", ""], "tasks": ["[ ] Позвонить"], "tags": ["#Найм", "найм"]}
        ```
        Если нужно — поправлю.
        """
        let digest = try NoteDigestPayload.parse(answer).digest

        // Кавычки-ёлочки и точка в конце заголовка — мусор для имени файла.
        XCTAssertEqual(digest.title, "Разбор недели")
        // Слэш в теме сделал бы вложенную папку в обход проверки пути.
        XCTAssertEqual(digest.theme, "Работа личное")
        // Дубли и маркеры списка убираются, пустые пункты выбрасываются.
        XCTAssertEqual(digest.highlights, ["Пункт"])
        XCTAssertEqual(digest.tasks, ["Позвонить"])
        XCTAssertEqual(digest.tags, ["найм"])
        XCTAssertTrue(digest.decisions.isEmpty)
    }

    func testPayloadRejectsNonJSON() {
        XCTAssertThrowsError(try NoteDigestPayload.parse("Не могу выполнить запрос.")) { error in
            XCTAssertEqual(error as? DigestError, .notJSON)
        }
    }

    func testFilenameFallsBackWhenTitleIsUnusable() {
        var digest = sample
        digest.title = "///"
        XCTAssertEqual(digest.normalized().filename, "Без названия.md")
        XCTAssertEqual(sample.filename, "Планёрка по найму.md")
    }

    func testEmptyThemeFallsBack() {
        var digest = sample
        digest.theme = "   "
        XCTAssertEqual(digest.normalized().theme, "Заметки")
    }

    func testPlainTextDropsTitleAndTimestamps() {
        let markdown = """
        # Recording-1

        **[00:00–00:04]** Первая реплика.

        **[00:04–00:09]** Вторая реплика.
        """
        XCTAssertEqual(
            TranscriptReadability.plainText(fromMarkdown: markdown),
            "Первая реплика.\n\nВторая реплика."
        )
    }

    func testParagraphsBreakOnlyAtSentenceEnd() {
        let sentences = (1...9).map { "Предложение номер \($0) про важное дело." }
        let paragraphs = TranscriptReadability.paragraphs(from: sentences.joined(separator: " "))

        XCTAssertEqual(paragraphs.count, 3)
        for paragraph in paragraphs {
            XCTAssertTrue(paragraph.hasSuffix("."), "абзац оборвался посреди фразы: \(paragraph)")
        }
        // Слова не меняются — это та же расшифровка, только с абзацами.
        XCTAssertEqual(
            paragraphs.joined(separator: " "),
            sentences.joined(separator: " ")
        )
    }

    func testTextWithoutPunctuationStaysOneParagraph() {
        // Движок Apple не ставит знаков препинания — рвать такой текст наугад нельзя.
        let text = String(repeating: "слово ", count: 200).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(TranscriptReadability.paragraphs(from: text).count, 1)
    }

    func testAbbreviationDoesNotStartNewParagraph() {
        let text = "Сделали т. е. закрыли вопрос. Дальше пошли по плану."
        XCTAssertEqual(TranscriptReadability.paragraphs(from: text), [text])
    }
}
