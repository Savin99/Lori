import Foundation

/// Поиск зацикливания модели.
///
/// Модель может деградировать на середине куска и начать повторять одну фразу сотни
/// раз: в куске [4:58–9:58] после 8:48 пошло «здесь мы, здесь мы, здесь мы…», и
/// настоящая речь до конца куска потерялась. Такой ответ нельзя принимать как есть.
///
/// Всё считается по тексту, без обращения к сервису: детектор проверяется тестами.
enum RepetitionCheck {
    struct Report: Equatable {
        /// 0 — текст выглядит нормально, 1 — почти целиком повтор.
        let score: Double
        /// Что именно сработало: идёт в журнал и в предупреждение.
        let reason: String?
        /// Позиция в тексте, с которой начался повтор. nil — начала цикла нет.
        let loopStart: String.Index?

        var isSuspicious: Bool { score >= RepetitionCheck.threshold }

        static let clean = Report(score: 0, reason: nil, loopStart: nil)
    }

    /// Порог подозрения. Ниже — обычная речь с повторами («да, да, конечно»).
    static let threshold = 0.6
    /// Столько одинаковых слов подряд живая речь не даёт.
    static let maxRun = 5
    /// Больше этого числа символов в секунду человек не проговаривает даже скороговоркой.
    static let maxCharactersPerSecond: Double = 28

    static func inspect(text: String, duration: TimeInterval = 0) -> Report {
        let words = tokens(of: text)
        guard words.count >= 12 else { return .clean }

        var score = 0.0
        var reason: String?

        // 1. «X X X X…» — самый явный признак.
        let run = longestRun(words)
        if run.length > maxRun {
            score = max(score, min(1, Double(run.length) / Double(words.count) + 0.5))
            reason = "одно слово подряд \(run.length) раз"
        }

        // 2. Повтор n-грамм: «здесь мы, здесь мы» — это биграмма, повторённая сотни раз.
        for size in 2...4 where words.count >= size * 4 {
            let (share, sample) = dominantGram(words, size: size)
            if share > 0.35 {
                score = max(score, min(1, share + 0.3))
                reason = reason ?? "фраза «\(sample)» занимает \(Int(share * 100))% текста"
            }
        }

        // 3. Доля уникальных слов. У живой речи она высокая даже в монологе.
        let unique = Double(Set(words).count) / Double(words.count)
        if unique < 0.2 {
            score = max(score, 1 - unique)
            reason = reason ?? "уникальных слов всего \(Int(unique * 100))%"
        }

        // 4. Текста больше, чем можно было проговорить за это время.
        if duration > 5 {
            let perSecond = Double(text.count) / duration
            if perSecond > maxCharactersPerSecond {
                score = max(score, min(1, perSecond / maxCharactersPerSecond - 0.2))
                reason = reason ?? "текста \(Int(perSecond)) символов в секунду — столько не говорят"
            }
        }

        guard score >= threshold else { return .clean }
        return Report(score: min(1, score), reason: reason, loopStart: loopStart(in: text, words: words))
    }

    /// Текст до начала зацикливания. Настоящая речь до срыва обычно есть, и терять
    /// её нельзя: остаток участка потом переспрашивается по покрытию.
    static func truncated(_ text: String, duration: TimeInterval = 0) -> String {
        let report = inspect(text: text, duration: duration)
        guard report.isSuspicious, let start = report.loopStart else {
            return report.isSuspicious ? "" : text
        }
        let prefix = String(text[text.startIndex..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Если «нормальное начало» само состоит из двух-трёх слов повтора, спасать
        // там нечего: пустая строка честнее, чем «здесь мы, здесь мы».
        let unique = Set(tokens(of: prefix))
        guard unique.count > 3 else { return "" }
        return prefix
    }

    // MARK: - Внутреннее

    /// Слова без пунктуации и регистра: «Здесь мы,» и «здесь мы» — один повтор.
    static func tokens(of text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty }
    }

    static func longestRun(_ words: [String]) -> (word: String, length: Int) {
        var best = (word: "", length: 0)
        var current = (word: "", length: 0)
        for word in words {
            if word == current.word {
                current.length += 1
            } else {
                current = (word, 1)
            }
            if current.length > best.length { best = current }
        }
        return best
    }

    /// Самая частая n-грамма и её доля среди всех n-грамм текста.
    static func dominantGram(_ words: [String], size: Int) -> (share: Double, sample: String) {
        guard words.count >= size else { return (0, "") }
        var counts: [String: Int] = [:]
        for index in 0...(words.count - size) {
            let gram = words[index..<(index + size)].joined(separator: " ")
            counts[gram, default: 0] += 1
        }
        let total = words.count - size + 1
        guard let top = counts.max(by: { $0.value < $1.value }), total > 0 else { return (0, "") }
        return (Double(top.value) / Double(total), top.key)
    }

    /// Где начался цикл: ищем место, после которого текст состоит из повторов
    /// одной и той же короткой фразы.
    private static func loopStart(in text: String, words: [String]) -> String.Index? {
        let (share, sample) = dominantGram(words, size: 2)
        guard share > 0.2, !sample.isEmpty else { return nil }

        // Ищем третье вхождение доминирующей фразы: первые два могут быть обычной речью.
        let needle = sample.components(separatedBy: " ").first ?? sample
        var searchStart = text.startIndex
        var found = 0
        while let range = text.range(of: needle, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            found += 1
            if found >= 3 {
                // Отступаем к началу предложения, чтобы не рвать фразу посередине.
                let prefix = text[text.startIndex..<range.lowerBound]
                if let sentence = prefix.lastIndex(where: { ".!?…".contains($0) }) {
                    return text.index(after: sentence)
                }
                return range.lowerBound
            }
            searchStart = range.upperBound
        }
        return nil
    }
}
