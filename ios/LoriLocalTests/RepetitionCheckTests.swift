import XCTest
@testable import LoriLocal

/// Зацикливание модели: в куске [4:58–9:58] после 8:48 пошло «здесь мы, здесь мы,
/// здесь мы…» сотни раз, и настоящая речь до конца куска потерялась. Такой ответ
/// не должен попадать в расшифровку.
final class RepetitionCheckTests: XCTestCase {
    private let normal = """
    Значит, по корпусу Славы: сначала гоним вертикальный срез, смотрим recall на десяти \
    документах, и только потом полный инжест. По метаданным нужна марка, позиция и вид \
    документа, иначе гибридный поиск даёт мусор на однотипных чертежах. И надо решить, \
    что делать с Excel — там таблицы, которые ломают разбиение на абзацы.
    """

    func testNormalSpeechIsNotSuspicious() {
        let report = RepetitionCheck.inspect(text: normal, duration: 60)

        XCTAssertFalse(report.isSuspicious, "score=\(report.score) reason=\(report.reason ?? "—")")
        XCTAssertEqual(RepetitionCheck.truncated(normal, duration: 60), normal, "нормальный текст не режем")
    }

    /// Живая речь с повторами («да, да, конечно») подозрительной быть не должна.
    func testHumanRepetitionIsAllowed() {
        let text = "Да, да, конечно. Я говорю: надо, надо это сделать, потому что иначе будет плохо всем нам."

        XCTAssertFalse(RepetitionCheck.inspect(text: text, duration: 20).isSuspicious)
    }

    func testRepeatedPhraseIsDetected() {
        let loop = "Мы обсудили сроки поставки. " + String(repeating: "здесь мы, ", count: 120)

        let report = RepetitionCheck.inspect(text: loop, duration: 300)

        XCTAssertTrue(report.isSuspicious)
        XCTAssertGreaterThan(report.score, 0.6)
        XCTAssertNotNil(report.reason)
    }

    func testSingleWordRunIsDetected() {
        let loop = "Начали разбирать оргструктуру " + String(repeating: "так ", count: 40)

        XCTAssertTrue(RepetitionCheck.inspect(text: loop, duration: 120).isSuspicious)
        XCTAssertGreaterThan(RepetitionCheck.longestRun(RepetitionCheck.tokens(of: loop)).length, RepetitionCheck.maxRun)
    }

    /// Текста больше, чем можно проговорить за это время, — тоже признак срыва.
    func testImpossibleSpeechRateIsDetected() {
        let text = String(repeating: "слово раз два три четыре пять шесть семь восемь ", count: 40)

        XCTAssertTrue(RepetitionCheck.inspect(text: text, duration: 10).isSuspicious)
    }

    /// Главное: нормальное начало сохраняется, а повтор отрезается.
    func testTruncationKeepsRealSpeech() {
        let good = "Мы обсудили сроки поставки и смету. Дальше нужно согласовать схему обвязки."
        let loop = good + " " + String(repeating: "здесь мы, ", count: 150)

        let kept = RepetitionCheck.truncated(loop, duration: 300)

        XCTAssertTrue(kept.contains("сроки поставки"), kept)
        XCTAssertLessThan(kept.count, loop.count / 2, "повтор должен быть отрезан")
        XCTAssertLessThanOrEqual(
            RepetitionCheck.inspect(text: kept, duration: 300).score,
            RepetitionCheck.threshold,
            "то, что осталось, уже не должно выглядеть циклом"
        )
    }

    func testShortAnswersAreLeftAlone() {
        XCTAssertFalse(RepetitionCheck.inspect(text: "Да.", duration: 2).isSuspicious)
        XCTAssertFalse(RepetitionCheck.inspect(text: "", duration: 0).isSuspicious)
    }
}

/// Склейка перекрытий: одна и та же реплика приходит из двух кусков, и отбрасывать
/// её надо по сходству слов, а не по числу символов.
final class SegmentMergeTests: XCTestCase {
    private func segment(_ from: TimeInterval, _ to: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: from, end: to, text: text)
    }

    func testSimilarityIgnoresPunctuationAndCase() {
        XCTAssertEqual(SegmentMerge.similarity("Здесь мы, конечно.", "здесь мы конечно"), 1)
        XCTAssertLessThan(SegmentMerge.similarity("Про метаданные", "Про сроки поставки"), 0.3)
    }

    func testDuplicateFromOverlapIsDropped() {
        var segments = [segment(0, 10, "Сначала гоним вертикальный срез")]

        SegmentMerge.merge([
            segment(9.5, 12, "Сначала гоним вертикальный срез."),
            segment(12, 20, "Потом полный инжест"),
        ], into: &segments)

        XCTAssertEqual(segments.count, 2, "дубль со стыка должен уйти: \(segments.map(\.text))")
        XCTAssertEqual(segments.last?.text, "Потом полный инжест")
    }

    /// Переформулированный стык — тоже дубль: слова те же.
    func testReworderedOverlapIsDropped() {
        var segments = [segment(0, 10, "Нужна марка, позиция и вид документа")]

        SegmentMerge.merge([segment(8, 11, "нужна марка позиция и вид документа")], into: &segments)

        XCTAssertEqual(segments.count, 1)
    }

    func testDifferentSpeechAtTheSameTimeIsKept() {
        var segments = [segment(0, 10, "Про метаданные и марку")]

        SegmentMerge.merge([segment(9, 18, "Отдельно решаем, что делать с Excel")], into: &segments)

        XCTAssertEqual(segments.count, 2, "разная речь на стыке теряться не должна")
    }

    /// Переспрошенный пропуск приходит после более поздних кусков — и должен встать
    /// на место, а не быть выброшенным как «уже покрытое время».
    func testGapFillArrivingLateIsKept() {
        var segments = [segment(100, 200, "Поздняя часть записи")]

        SegmentMerge.merge([segment(0, 90, "Начало записи, которое переспросили")], into: &segments)

        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments.contains { $0.start == 0 })
    }
}
