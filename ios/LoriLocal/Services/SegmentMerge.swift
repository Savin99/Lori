import Foundation

/// Склейка реплик из перекрывающихся кусков.
///
/// Куски заходят друг на друга на пару секунд, чтобы не потерять слово на стыке —
/// значит одна и та же реплика приходит дважды. Отбрасывать по фиксированному числу
/// символов нельзя: модель формулирует стык по-разному. Сравниваем по смыслу слов.
enum SegmentMerge {
    /// Насколько похожи два текста: доля общих слов (мера Жаккара).
    /// Пунктуация и регистр не учитываются — «Здесь мы.» и «здесь мы» это одно.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(RepetitionCheck.tokens(of: lhs))
        let right = Set(RepetitionCheck.tokens(of: rhs))
        guard !left.isEmpty, !right.isEmpty else { return left.isEmpty && right.isEmpty ? 1 : 0 }
        let common = left.intersection(right).count
        return Double(common) / Double(left.union(right).count)
    }

    /// Порог, после которого реплика считается той же самой.
    static let sameTextThreshold = 0.6
    /// Насколько далеко по времени искать дубликат: перекрытие плюс запас на
    /// разъезжающиеся таймкоды модели.
    static let window: TimeInterval = 6

    /// Добавляет новые реплики к уже собранным, отбрасывая дубли из перекрытия.
    static func merge(_ produced: [TranscriptSegment], into segments: inout [TranscriptSegment]) {
        for candidate in produced.sorted(by: { $0.start < $1.start }) {
            guard !isDuplicate(candidate, in: segments) else { continue }
            segments.append(candidate)
        }
    }

    static func isDuplicate(_ candidate: TranscriptSegment, in segments: [TranscriptSegment]) -> Bool {
        // Рядом по времени и похоже по словам — это тот же фрагмент речи.
        for existing in segments {
            let apart = min(
                abs(existing.start - candidate.start),
                abs(existing.end - candidate.end)
            )
            guard apart <= window || overlaps(existing, candidate) else { continue }
            if similarity(existing.text, candidate.text) >= sameTextThreshold { return true }
        }

        // Реплика целиком внутри уже расшифрованного времени и не приносит новых
        // слов — тоже дубль: так ловится случай, когда модель переформулировала стык.
        let length = max(0.01, candidate.end - candidate.start)
        let covered = TranscriptCoverage.merged(segments).reduce(0.0) { total, range in
            let from = max(range.lowerBound, candidate.start)
            let to = min(range.upperBound, candidate.end)
            return total + max(0, to - from)
        }
        guard covered / length >= 0.9 else { return false }
        let neighbours = segments
            .filter { overlaps($0, candidate) }
            .map(\.text)
            .joined(separator: " ")
        return similarity(neighbours, candidate.text) >= 0.4
    }

    private static func overlaps(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        lhs.start <= rhs.end && rhs.start <= lhs.end
    }
}
