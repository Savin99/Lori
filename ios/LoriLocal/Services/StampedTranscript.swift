import Foundation

/// Разбор расшифровки, в которой время стоит прямо в тексте — «[1:23] реплика».
///
/// Это страховка, а не главный путь: обычно таймкоды приходят нативно через
/// `timestamp_granularities` внутри `transcription_config`. Но если сервис
/// отверг штатное поле или модель вовсе не из линейки расшифровки, время
/// просится словами в запросе и разбирается из текста ответа. Это грубее
/// нативных таймингов, но лучше, чем минуты речи одним куском без времени.
enum StampedTranscript {
    /// Есть ли в тексте похожие на время метки — иначе разбирать нечего.
    static func looksStamped(_ text: String) -> Bool {
        segments(from: text, offset: 0, end: .greatestFiniteMagnitude).count > 1
    }

    static func segments(from text: String, offset: TimeInterval, end: TimeInterval) -> [TranscriptSegment] {
        var found: [(start: TimeInterval, text: String)] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let stamp = leadingStamp(trimmed) else {
                // Продолжение реплики без метки прилипает к предыдущей.
                if var last = found.popLast() {
                    last.text += " " + trimmed
                    found.append(last)
                }
                continue
            }
            guard !stamp.text.isEmpty else { continue }
            found.append((stamp.start, stamp.text))
        }

        return found.enumerated().map { index, item in
            let next = index + 1 < found.count ? found[index + 1].start : nil
            return TranscriptSegment(
                start: offset + item.start,
                end: min(offset + (next ?? item.start + 5), end),
                text: item.text
            )
        }
    }

    /// Время в начале строки: «[1:23]», «(01:23)», «1:23:45 —», «00:12».
    static func leadingStamp(_ line: String) -> (start: TimeInterval, text: String)? {
        let pattern = "^[\\[\\(<]?\\s*(\\d{1,2}):([0-5]\\d)(?::([0-5]\\d))?\\s*[\\]\\)>]?\\s*[—–\\-:]?\\s*"
        guard let match = line.range(of: pattern, options: .regularExpression) else { return nil }
        let head = String(line[match])
        let numbers = head.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
            .compactMap(Double.init)
        guard numbers.count >= 2 else { return nil }
        let seconds = numbers.count >= 3
            ? numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
            : numbers[0] * 60 + numbers[1]
        let rest = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (seconds, rest)
    }
}
