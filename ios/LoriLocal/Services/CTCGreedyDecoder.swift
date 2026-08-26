import Foundation

/// Greedy-декодер CTC для GigaAM.
///
/// Повторяет `CTCGreedyDecoding.decode` из библиотеки GigaAM:
/// argmax по классам, выброс blank, склейка повторов сравнением с предыдущим кадром
/// (включая blank), обрезка по длине выхода энкодера. Blank — последний индекс,
/// число классов равно размеру словаря плюс один.
///
/// Словарь у e2e-моделей содержит знаки препинания и заглавные буквы, поэтому
/// пунктуацию расставляет сама модель и отдельный шаг нормализации не нужен.
struct CTCGreedyDecoder {
    enum Failure: LocalizedError {
        case classCountMismatch(expected: Int, got: Int)

        var errorDescription: String? {
            switch self {
            case let .classCountMismatch(expected, got):
                "Модель отдала \(got) классов, а словарь рассчитан на \(expected)."
            }
        }
    }

    let vocabulary: SentencePieceVocabulary

    var blankIndex: Int { vocabulary.blankIndex }
    var classCount: Int { vocabulary.classCount }

    init(vocabulary: SentencePieceVocabulary) {
        self.vocabulary = vocabulary
    }

    init(pieces: [String]) throws {
        vocabulary = try SentencePieceVocabulary(pieces: pieces)
    }

    init(vocabularyAt url: URL) throws {
        vocabulary = try SentencePieceVocabulary(contentsOf: url)
    }

    /// `logits` — плоская матрица `[frame][class]`. `encodedLength` ограничивает
    /// число значимых кадров, если энкодер вернул меньше, чем есть в буфере.
    func decode(logits: [Float], frames: Int, classes: Int, encodedLength: Int? = nil) throws -> String {
        guard classes == classCount else {
            throw Failure.classCountMismatch(expected: classCount, got: classes)
        }
        return detokenize(tokens(logits: logits, frames: frames, classes: classes, encodedLength: encodedLength))
    }

    /// Идентификаторы токенов без склейки в текст: нужны для отладки и для таймингов.
    func tokens(logits: [Float], frames: Int, classes: Int, encodedLength: Int? = nil) -> [Int] {
        let limit = min(max(encodedLength ?? frames, 0), frames)
        guard limit > 0, classes > 0 else { return [] }

        var result: [Int] = []
        var previous = -1
        for frame in 0..<limit {
            let offset = frame * classes
            var best = 0
            var bestValue = logits[offset]
            for candidate in 1..<classes {
                let value = logits[offset + candidate]
                if value > bestValue {
                    bestValue = value
                    best = candidate
                }
            }
            if best != blankIndex, best != previous {
                result.append(best)
            }
            previous = best
        }
        return result
    }

    func detokenize(_ tokens: [Int]) -> String {
        vocabulary.detokenize(tokens)
    }
}
