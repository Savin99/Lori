import Foundation

/// Предсказательная сеть и joint RNN-T. За протоколом — три модели Core ML,
/// в тестах — заглушка, поэтому цикл декодирования проверяется без модели.
protocol RNNTNetwork {
    /// Состояние LSTM предсказательной сети.
    associatedtype State

    /// Без предыдущего токена возвращает начальный выход и начальное состояние.
    func predict(previousToken: Int?, state: State?) throws -> (embedding: [Float], state: State)

    /// Логиты по всем классам для пары «кадр энкодера + выход предиктора».
    func joint(encoderFrame: [Float], embedding: [Float]) throws -> [Float]
}

/// Greedy-декодер RNN-T для GigaAM.
///
/// Повторяет `RNNTGreedyDecoding.decode` из библиотеки GigaAM для батча из одного элемента.
/// Главное, что легко переврать: **на blank ни последний токен, ни состояние LSTM
/// не обновляются** — в референсе обновление живёт внутри ветки эмиссии.
struct RNNTGreedyDecoder<Network: RNNTNetwork> {
    struct Output: Equatable {
        let text: String
        let tokens: [Int]
        /// Индексы кадров энкодера, на которых выпущены токены.
        let tokenFrames: [Int]
    }

    enum Failure: LocalizedError {
        case classCountMismatch(expected: Int, got: Int)
        case dimensionMismatch

        var errorDescription: String? {
            switch self {
            case let .classCountMismatch(expected, got):
                "Модель отдала \(got) классов, а словарь рассчитан на \(expected)."
            case .dimensionMismatch:
                "Размер выхода энкодера не делится на число кадров."
            }
        }
    }

    let network: Network
    let vocabulary: SentencePieceVocabulary
    /// Столько токенов максимум выпускается на один кадр энкодера. В библиотеке 10.
    let maxSymbolsPerStep: Int

    init(network: Network, vocabulary: SentencePieceVocabulary, maxSymbolsPerStep: Int = 10) {
        self.network = network
        self.vocabulary = vocabulary
        self.maxSymbolsPerStep = maxSymbolsPerStep
    }

    /// `encoded` — плоская матрица `[frame][dimension]`.
    func decode(
        encoded: [Float],
        frames: Int,
        dimension: Int,
        encodedLength: Int? = nil
    ) throws -> Output {
        guard frames * dimension == encoded.count else { throw Failure.dimensionMismatch }
        let limit = min(max(encodedLength ?? frames, 0), frames)

        var tokens: [Int] = []
        var tokenFrames: [Int] = []
        var lastToken: Int?
        var state: Network.State?

        for frame in 0..<limit {
            let start = frame * dimension
            let encoderFrame = Array(encoded[start..<(start + dimension)])

            for _ in 0..<maxSymbolsPerStep {
                let prediction = try network.predict(previousToken: lastToken, state: state)
                let logits = try network.joint(encoderFrame: encoderFrame, embedding: prediction.embedding)
                guard logits.count == vocabulary.classCount else {
                    throw Failure.classCountMismatch(expected: vocabulary.classCount, got: logits.count)
                }

                let token = argmax(logits)
                if token == vocabulary.blankIndex { break }

                tokens.append(token)
                tokenFrames.append(frame)
                lastToken = token
                state = prediction.state
            }
        }

        return Output(text: vocabulary.detokenize(tokens), tokens: tokens, tokenFrames: tokenFrames)
    }

    private func argmax(_ values: [Float]) -> Int {
        var best = 0
        var bestValue = values[0]
        for index in 1..<values.count where values[index] > bestValue {
            bestValue = values[index]
            best = index
        }
        return best
    }
}
