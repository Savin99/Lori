import XCTest
@testable import LoriLocal

/// Заголовок из первой фразы у диалога, который начинается короткими репликами.
///
/// Владелец, 6 октября 2026: карточка называлась «Что хотел? Не» — расшифровка
/// ElevenLabs начиналась так: «Что хотел? Не. Да. Сегодня справка. По чем? По
/// затратам на эксплуатацию…». Ранняя граница («Что хотел?» короче двенадцати
/// знаков) уступала следующей, и к заголовку приклеивалась реплика «Не».
///
/// Файлы здесь собраны тем же путём, что у движка ElevenLabs: слова с метками
/// говорящих → `ElevenLabsTranscriber.segmentsBySpeaker` → `Transcript.markdown`.
/// Рукописный образец однажды уже скрыл дефект — в нём не было строки режима
/// (раздел «Настоящий файл, а не рукописный образец» в `InterfaceModelTests`).
final class TranscriptTitleDialogTests: XCTestCase {
    /// Реплики двух голосов со временем каждого слова — как их отдаёт сервис.
    private func dialog(_ lines: [(speaker: String, text: String)]) -> String {
        var words: [(word: TranscriptWord, speaker: String?)] = []
        var time: TimeInterval = 0
        for line in lines {
            for token in line.text.split(separator: " ") {
                words.append((TranscriptWord(start: time, end: time + 0.3, text: String(token)), line.speaker))
                time += 0.4
            }
            time += 0.6
        }
        let segments = ElevenLabsTranscriber.segmentsBySpeaker(words, assembler: TranscriptAssembler())
        return Transcript(text: segments.map(\.text).joined(separator: "\n"), segments: segments)
            .markdown(title: "Recording-2026-10-05T09-12-40Z", engine: "ElevenLabs · scribe_v2", mode: "Дословно")
    }

    private let first = "speaker_0"
    private let second = "speaker_1"

    /// **Случай владельца.** Заголовок — первая содержательная фраза, а не
    /// «Что хотел? Не»; сниппет продолжает текст после неё.
    func testShortOpeningRepliesDoNotBecomeTheTitle() {
        let markdown = dialog([
            (first, "Что хотел?"),
            (second, "Не."),
            (first, "Да."),
            (second, "Сегодня справка."),
            (first, "По чем?"),
            (second, "По затратам на эксплуатацию здания."),
            (first, "Хорошо, присылай до пятницы."),
        ])
        XCTAssertTrue(markdown.contains("**["), "файл с таймкодами, как у ElevenLabs")
        XCTAssertTrue(markdown.contains("S1: Что хотел?") && markdown.contains("S2: Не."), markdown)

        let parts = TranscriptTitle.parts(of: TranscriptTitle.plain(from: markdown))

        XCTAssertEqual(parts.title, "По затратам на эксплуатацию здания")
        XCTAssertEqual(parts.snippet, "Хорошо, присылай до пятницы.", "сниппет — продолжение после заголовка")
        XCTAssertTrue(
            parts.head?.hasPrefix("Что хотел? Не. Да.") == true,
            "текст с начала — для чужого заголовка — по-прежнему с самого начала"
        )
    }

    /// Реплики из одних откликов не содержательны, даже когда слов в них три.
    func testFillerOnlyRepliesAreSkippedEvenWhenTheyHaveThreeWords() {
        let markdown = dialog([
            (first, "Да, да, да."),
            (second, "Ага, ну, хорошо."),
            (first, "Давайте обсудим график отпусков на лето."),
            (second, "Давайте."),
        ])

        XCTAssertEqual(TranscriptTitle.title(from: markdown), "Давайте обсудим график отпусков на лето")
        XCTAssertEqual(TranscriptTitle.snippet(from: markdown), "Давайте.")
    }

    /// Содержательная первая фраза по-прежнему побеждает: приветствие со смыслом —
    /// заголовок, отклики после него — нет.
    func testSubstantialFirstSentenceStillWins() {
        let markdown = dialog([
            (first, "Здравствуйте, давайте начнём встречу."),
            (second, "Да."),
            (first, "Хорошо."),
        ])

        XCTAssertEqual(TranscriptTitle.title(from: markdown), "Здравствуйте, давайте начнём встречу")
        XCTAssertEqual(TranscriptTitle.snippet(from: markdown), "Да. Хорошо.")
    }

    /// Правила первой фразы работают и после пропущенных реплик: дата «27.08» не
    /// граница, инициалы и «т.е.» — тоже, висящий предлог снимается.
    func testSentenceRulesHoldAfterSkippedReplies() {
        let date = dialog([
            (first, "Да."),
            (second, "Ага."),
            (first, "Совещание 27.08 по бюджету отдела."),
            (second, "Дальше детали."),
        ])
        XCTAssertEqual(TranscriptTitle.title(from: date), "Совещание 27.08 по бюджету отдела")
        XCTAssertEqual(TranscriptTitle.snippet(from: date), "Дальше детали.")

        let initials = dialog([
            (first, "Так."),
            (second, "Ну."),
            (first, "Встреча с А. С. Петровым по договору аренды."),
        ])
        XCTAssertEqual(TranscriptTitle.title(from: initials), "Встреча с А. С. Петровым по договору")

        let abbreviation = dialog([
            (first, "Да."),
            (second, "Мы решили, т.е. договорились, перенести релиз на май."),
        ])
        XCTAssertEqual(TranscriptTitle.title(from: abbreviation), "Мы решили, т.е. договорились, перенести")

        let preposition = dialog([
            (first, "Ага."),
            (second, "Обсуждали структуру базы знаний вместе с командой поддержки и продаж."),
        ])
        XCTAssertEqual(TranscriptTitle.title(from: preposition), "Обсуждали структуру базы знаний вместе")
    }

    /// Содержательной фразы среди первых реплик нет — правило прежнее, с начала
    /// текста: лучше такой заголовок, чем пустая карточка.
    func testWithoutSubstantialSentenceTheOldRuleApplies() {
        let markdown = dialog([
            (first, "Да."),
            (second, "Нет."),
            (first, "Что?"),
            (second, "Ну."),
        ])

        XCTAssertEqual(TranscriptTitle.title(from: markdown), "Да. Нет. Что")
    }

    /// Короткая, но содержательная первая фраза — заголовок целиком, без
    /// следующей реплики: раньше граница «не раньше двенадцати знаков» клеила их.
    func testShortSubstantialSentenceIsNotGluedToTheNextReply() {
        let markdown = dialog([
            (first, "Я за ним."),
            (second, "Не."),
            (first, "Подожду у входа, а потом вместе поднимемся."),
        ])

        XCTAssertEqual(TranscriptTitle.title(from: markdown), "Я за ним")
        XCTAssertEqual(TranscriptTitle.snippet(from: markdown), "Не. Подожду у входа, а потом вместе поднимемся.")
    }
}
