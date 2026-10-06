import Foundation

/// Контроль полноты расшифровки.
///
/// Модель может молча пропустить участок записи — вернуть текст, который выглядит
/// правдоподобно, но начинается с середины. Единственный надёжный способ это
/// заметить — сравнить время, покрытое репликами, с длительностью аудио.
enum TranscriptCoverage {
    /// Реплики, слитые в непересекающиеся отрезки. Нужно и для подсчёта покрытия,
    /// и для поиска пропусков: у частей есть перекрытие, и отрезки дублируются.
    static func merged(_ segments: [TranscriptSegment]) -> [ClosedRange<TimeInterval>] {
        let ranges = segments
            .map { min($0.start, $0.end)...max($0.start, $0.end) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<TimeInterval>] = []
        for range in ranges {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    static func covered(_ segments: [TranscriptSegment]) -> TimeInterval {
        merged(segments).reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// Куски записи, для которых нет ни одной реплики. Мелкие паузы не считаются
    /// пропусками: `minimum` отсекает тишину между фразами.
    static func gaps(
        in segments: [TranscriptSegment],
        duration: TimeInterval,
        minimum: TimeInterval = 8
    ) -> [ClosedRange<TimeInterval>] {
        guard duration > 0 else { return [] }
        var result: [ClosedRange<TimeInterval>] = []
        var cursor: TimeInterval = 0
        for range in merged(segments) {
            if range.lowerBound - cursor >= minimum {
                result.append(cursor...range.lowerBound)
            }
            cursor = max(cursor, range.upperBound)
        }
        if duration - cursor >= minimum { result.append(cursor...duration) }
        return result
    }

    /// «1:40–3:05» — так пропуск читается в предупреждении к расшифровке.
    static func describe(_ range: ClosedRange<TimeInterval>) -> String {
        "\(TranscriptSegment.stamp(range.lowerBound))–\(TranscriptSegment.stamp(range.upperBound))"
    }

    /// Отрезок из плашки о пропуске — обратное к `describe`: «Пропуск 4:19–5:19:
    /// в ответе сервиса нет текста…» → 259…319. Плашки старых сборок («Похоже на
    /// пропуск 0:10–0:20: …», до 3 сентября 2026) лежат в файлах владельца так же.
    ///
    /// `nil` — это не плашка о пропуске. «Участок 0:00–5:00: модель зациклилась…»
    /// и прочие замечания про сорвавшийся ответ — о другом: там звук не спрашивают.
    static func gap(in warning: String) -> ClosedRange<TimeInterval>? {
        var text = Substring(warning.trimmingCharacters(in: .whitespaces))
        for prefix in ["Похоже на пропуск ", "Пропуск "] {
            guard text.lowercased().hasPrefix(prefix.lowercased()) else { continue }
            text = text.dropFirst(prefix.count)
            let token = text.prefix { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: ":.,;"))
            let bounds = token.split(whereSeparator: { $0 == "–" || $0 == "-" }).map(String.init)
            guard bounds.count == 2, let from = seconds(bounds[0]), let to = seconds(bounds[1]), to > from else {
                return nil
            }
            return from...to
        }
        return nil
    }

    /// «1:05:20» → 3920, «4:19» → 259. Только то, что пишет `TranscriptSegment.stamp`.
    static func seconds(_ stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts.compactMap { TimeInterval($0) }.reduce(0) { $0 * 60 + $1 }
    }

    /// Доля записи, покрытая репликами: 0…1.
    static func share(_ segments: [TranscriptSegment], duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, covered(segments) / duration)
    }
}


extension Array where Element: Hashable {
    /// Без повторов, с сохранением порядка: одно и то же предупреждение
    /// не должно попасть в расшифровку дважды.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
