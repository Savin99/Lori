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
