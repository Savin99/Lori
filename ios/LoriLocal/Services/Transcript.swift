import Foundation

/// Слово со временем. Границы считаются как в `gigaam/timestamps_utils.py`:
/// начало — кадр первого токена слова, конец — кадр последнего плюс один.
struct TranscriptWord: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Реплика: несколько слов между знаком конца предложения или паузой.
struct TranscriptSegment: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    /// «12:03» или «1:05:20» для записей длиннее часа.
    static func stamp(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Результат расшифровки: текст, реплики и слова со временем.
struct Transcript: Equatable {
    let text: String
    let segments: [TranscriptSegment]
    let words: [TranscriptWord]

    init(text: String, segments: [TranscriptSegment] = [], words: [TranscriptWord] = []) {
        self.text = text
        self.segments = segments
        self.words = words
    }

    var isEmpty: Bool { text.isEmpty }

    /// Markdown для файла расшифровки. Без реплик — просто текст,
    /// чтобы результат движка без времени не выглядел ущербным.
    func markdown(title: String) -> String {
        guard !segments.isEmpty else { return "# \(title)\n\n\(text)\n" }
        let body = segments
            .map { segment in
                let from = TranscriptSegment.stamp(segment.start)
                let to = TranscriptSegment.stamp(segment.end)
                return "**[\(from)–\(to)]** \(segment.text)"
            }
            .joined(separator: "\n\n")
        return "# \(title)\n\n\(body)\n"
    }
}

/// Собирает слова из токенов RNN-T.
///
/// Повторяет `frames_to_words` из библиотеки: кусок, начинающийся с `▁`,
/// открывает новое слово, маркер отбрасывается.
struct TranscriptWordBuilder {
    private static let wordStart: Character = "\u{2581}"

    func words(
        tokens: [Int],
        tokenFrames: [Int],
        vocabulary: SentencePieceVocabulary,
        frameDuration: TimeInterval,
        offset: TimeInterval = 0
    ) -> [TranscriptWord] {
        guard tokens.count == tokenFrames.count, !tokens.isEmpty else { return [] }

        var result: [TranscriptWord] = []
        var characters = ""
        var frames: [Int] = []

        func commit() {
            defer {
                characters = ""
                frames = []
            }
            let text = characters.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let first = frames.first, let last = frames.last else { return }
            result.append(TranscriptWord(
                start: offset + Double(first) * frameDuration,
                end: offset + Double(last + 1) * frameDuration,
                text: text
            ))
        }

        for (token, frame) in zip(tokens, tokenFrames) {
            guard token >= 0, token < vocabulary.count else { continue }
            var piece = vocabulary.pieces[token]
            if piece.first == Self.wordStart {
                commit()
                piece.removeFirst()
            } else if piece == " " {
                commit()
                continue
            }
            characters += piece
            frames.append(frame)
        }
        commit()
        return result
    }
}

/// Склеивает слова из кусков в реплики и текст.
struct TranscriptAssembler {
    /// Пауза, после которой начинается новая реплика.
    var pauseSeconds: TimeInterval = 0.8
    var sentenceEndings: Set<Character> = [".", "!", "?", "…"]

    func segments(from words: [TranscriptWord]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var current: [TranscriptWord] = []

        func flush() {
            defer { current = [] }
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            guard !text.isEmpty else { return }
            result.append(TranscriptSegment(start: first.start, end: last.end, text: text))
        }

        for word in words {
            if let previous = current.last, word.start - previous.end >= pauseSeconds {
                flush()
            }
            current.append(word)
            if let last = word.text.last, sentenceEndings.contains(last) {
                flush()
            }
        }
        flush()
        return result
    }

    func transcript(from words: [TranscriptWord]) -> Transcript {
        let segments = segments(from: words)
        let text = segments.isEmpty
            ? words.map(\.text).joined(separator: " ")
            : segments.map(\.text).joined(separator: " ")
        return Transcript(text: text, segments: segments, words: words)
    }

    /// Отбрасывает слова из перекрытия: этот участок звука уже расшифрован
    /// предыдущим куском, и без отбрасывания слова дублируются.
    func merge(
        into accumulated: inout [TranscriptWord],
        words: [TranscriptWord],
        coveredUntil: TimeInterval
    ) {
        accumulated.append(contentsOf: words.filter { $0.start >= coveredUntil })
    }
}
