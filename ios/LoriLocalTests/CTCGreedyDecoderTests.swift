import XCTest
@testable import LoriLocal

/// Поведение сверено с `CTCGreedyDecoding.decode` из библиотеки GigaAM.
final class CTCGreedyDecoderTests: XCTestCase {
    /// blank получает индекс 4 — последний, как в библиотеке.
    private let vocabulary = ["\u{2581}привет", "\u{2581}мир", ".", "ик"]

    private func decoder() throws -> CTCGreedyDecoder {
        try CTCGreedyDecoder(pieces: vocabulary)
    }

    /// Строит логиты, где в каждом кадре побеждает заданный класс.
    private func logits(_ argmaxPerFrame: [Int], classes: Int) -> [Float] {
        var values = [Float](repeating: -10, count: argmaxPerFrame.count * classes)
        for (frame, winner) in argmaxPerFrame.enumerated() {
            values[frame * classes + winner] = 5
        }
        return values
    }

    func testBlankIsLastIndex() throws {
        let decoder = try decoder()
        XCTAssertEqual(decoder.blankIndex, 4)
        XCTAssertEqual(decoder.classCount, 5)
    }

    func testCollapsesRepeatsAndDropsBlanks() throws {
        let decoder = try decoder()
        // привет привет blank привет мир blank .
        let frames = [0, 0, 4, 0, 1, 4, 2]
        let text = try decoder.decode(
            logits: logits(frames, classes: 5), frames: frames.count, classes: 5
        )
        XCTAssertEqual(text, "привет привет мир.")
    }

    func testRepeatSeparatedByBlankIsKept() throws {
        let decoder = try decoder()
        let tokens = decoder.tokens(logits: logits([0, 4, 0], classes: 5), frames: 3, classes: 5)
        XCTAssertEqual(tokens, [0, 0], "blank между одинаковыми токенами разделяет их")
    }

    func testAdjacentRepeatIsCollapsed() throws {
        let decoder = try decoder()
        let tokens = decoder.tokens(logits: logits([0, 0, 0], classes: 5), frames: 3, classes: 5)
        XCTAssertEqual(tokens, [0])
    }

    func testEncodedLengthCutsTail() throws {
        let decoder = try decoder()
        let frames = [0, 1, 2]
        let text = try decoder.decode(
            logits: logits(frames, classes: 5), frames: 3, classes: 5, encodedLength: 1
        )
        XCTAssertEqual(text, "привет", "кадры за пределами длины энкодера не читаются")
    }

    func testAllBlankGivesEmptyString() throws {
        let decoder = try decoder()
        let text = try decoder.decode(logits: logits([4, 4, 4], classes: 5), frames: 3, classes: 5)
        XCTAssertEqual(text, "")
    }

    func testDetokenizationGluesPiecesAndPunctuation() throws {
        let decoder = try decoder()
        XCTAssertEqual(decoder.detokenize([0, 3, 2]), "приветик.")
        XCTAssertEqual(decoder.detokenize([]), "")
    }

    func testRejectsWrongClassCount() throws {
        let decoder = try decoder()
        XCTAssertThrowsError(try decoder.decode(logits: [0, 0, 0], frames: 1, classes: 3))
    }

    func testRejectsEmptyVocabulary() {
        XCTAssertThrowsError(try CTCGreedyDecoder(pieces: []))
    }

    func testLoadsVocabularyFromFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "vocab-\(UUID().uuidString).txt")
        try "\u{2581}да\nнет\n.\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try CTCGreedyDecoder(vocabularyAt: url)

        XCTAssertEqual(decoder.vocabulary.count, 3, "завершающий перевод строки не токен")
        XCTAssertEqual(decoder.blankIndex, 3)
        XCTAssertEqual(decoder.detokenize([0, 1, 2]), "данет.")
    }
}
