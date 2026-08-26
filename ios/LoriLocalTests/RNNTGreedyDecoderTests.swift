import XCTest
@testable import LoriLocal

/// Заглушка сети: выдаёт заранее расписанные классы и запоминает,
/// с каким состоянием и токеном её позвали.
private final class ScriptedNetwork: RNNTNetwork {
    /// Состояние — номер обновления, чтобы было видно, переносится ли он между шагами.
    typealias State = Int

    /// plan[кадр] — последовательность классов, выдаваемых на этом кадре.
    private let plan: [[Int]]
    private var callsPerFrame: [Int: Int] = [:]
    private(set) var predictCalls: [(previousToken: Int?, state: Int?)] = []
    private var stateCounter = 0
    let classCount: Int

    init(plan: [[Int]], classCount: Int) {
        self.plan = plan
        self.classCount = classCount
    }

    func predict(previousToken: Int?, state: Int?) throws -> (embedding: [Float], state: Int) {
        predictCalls.append((previousToken, state))
        stateCounter += 1
        return ([Float(previousToken ?? -1)], stateCounter)
    }

    /// Номер кадра закодирован в самом кадре энкодера, поэтому подпись протокола чистая.
    func joint(encoderFrame: [Float], embedding: [Float]) throws -> [Float] {
        let frame = Int(encoderFrame[0])
        let step = callsPerFrame[frame, default: 0]
        callsPerFrame[frame] = step + 1

        let winner = frame < plan.count && step < plan[frame].count
            ? plan[frame][step]
            : classCount - 1 // blank
        var logits = [Float](repeating: -10, count: classCount)
        logits[winner] = 5
        return logits
    }
}

final class RNNTGreedyDecoderTests: XCTestCase {
    /// blank получает индекс 3.
    private let pieces = ["\u{2581}привет", "\u{2581}мир", "."]

    private func makeDecoder(
        plan: [[Int]],
        maxSymbolsPerStep: Int = 10
    ) throws -> (RNNTGreedyDecoder<ScriptedNetwork>, ScriptedNetwork) {
        let vocabulary = try SentencePieceVocabulary(pieces: pieces)
        let network = ScriptedNetwork(plan: plan, classCount: vocabulary.classCount)
        return (
            RNNTGreedyDecoder(network: network, vocabulary: vocabulary, maxSymbolsPerStep: maxSymbolsPerStep),
            network
        )
    }

    /// Кадр энкодера несёт свой номер — так заглушка понимает, где она.
    private func encoded(frames: Int) -> [Float] {
        (0..<frames).map(Float.init)
    }

    func testEmitsSeveralTokensOnOneFrame() throws {
        // кадр 0: привет, мир, blank; кадр 1: blank; кадр 2: точка
        let (decoder, _) = try makeDecoder(plan: [[0, 1, 3], [3], [2]])

        let output = try decoder.decode(encoded: encoded(frames: 3), frames: 3, dimension: 1)

        XCTAssertEqual(output.tokens, [0, 1, 2])
        XCTAssertEqual(output.tokenFrames, [0, 0, 2], "второй токен выпущен на том же кадре")
        XCTAssertEqual(output.text, "привет мир.")
    }

    func testBlankDoesNotUpdateStateOrLastToken() throws {
        // кадр 0: привет, blank; кадр 1: мир
        let (decoder, network) = try makeDecoder(plan: [[0, 3], [1]])

        _ = try decoder.decode(encoded: encoded(frames: 2), frames: 2, dimension: 1)

        // 0: старт без токена → «привет»; 1: blank, ничего не меняет;
        // 2: новый кадр, вход тот же, что был до blank; 3: закрывающий blank после «мир».
        XCTAssertEqual(network.predictCalls.count, 4)
        XCTAssertNil(network.predictCalls[0].previousToken)
        XCTAssertNil(network.predictCalls[0].state)
        XCTAssertEqual(network.predictCalls[1].previousToken, 0)
        XCTAssertEqual(network.predictCalls[1].state, 1)
        XCTAssertEqual(
            network.predictCalls[2].previousToken, 0,
            "после blank последний токен остаётся прежним"
        )
        XCTAssertEqual(
            network.predictCalls[2].state, 1,
            "после blank состояние LSTM не обновляется"
        )
        XCTAssertEqual(network.predictCalls[3].previousToken, 1, "после эмиссии токен обновился")
        XCTAssertEqual(network.predictCalls[3].state, 3, "и состояние тоже")
    }

    func testMaxSymbolsPerStepStopsRunawayFrame() throws {
        // кадр всё время выдаёт непустой токен — ограничитель обязан прервать
        let (decoder, _) = try makeDecoder(plan: [Array(repeating: 0, count: 50)], maxSymbolsPerStep: 4)

        let output = try decoder.decode(encoded: encoded(frames: 1), frames: 1, dimension: 1)

        XCTAssertEqual(output.tokens.count, 4)
    }

    func testEncodedLengthCutsTail() throws {
        let (decoder, _) = try makeDecoder(plan: [[0], [1], [2]])

        let output = try decoder.decode(
            encoded: encoded(frames: 3), frames: 3, dimension: 1, encodedLength: 2
        )

        XCTAssertEqual(output.tokens, [0, 1])
    }

    func testAllBlankGivesEmptyText() throws {
        let (decoder, _) = try makeDecoder(plan: [[3], [3]])

        let output = try decoder.decode(encoded: encoded(frames: 2), frames: 2, dimension: 1)

        XCTAssertEqual(output.text, "")
        XCTAssertTrue(output.tokens.isEmpty)
    }

    func testRejectsBrokenShape() throws {
        let (decoder, _) = try makeDecoder(plan: [[0]])

        XCTAssertThrowsError(try decoder.decode(encoded: [0, 1, 2], frames: 2, dimension: 2))
    }
}
