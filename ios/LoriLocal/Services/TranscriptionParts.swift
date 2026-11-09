import Foundation

/// Настоящее состояние каждой части. Единственная дробь — байты отправки;
/// ожидание модели измеряется временем, а не выдуманным процентом.
struct TranscriptionParts: Codable, Equatable, Sendable {
    enum Phase: Codable, Equatable, Sendable {
        case waiting
        case sending(sent: Int64, expected: Int64)
        case listening(since: Date)
        case complete
        case failed(reason: String, retryAt: Date?)

        var uploadShare: Double? {
            guard case let .sending(sent, expected) = self, expected > 0 else { return nil }
            return max(0, min(1, Double(sent) / Double(expected)))
        }
    }
    struct Part: Codable, Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        var phase: Phase = .waiting
    }
    enum Event: Sendable {
        case plan(TranscriptionParts)
        case phase(Int, Phase)
    }
    @TaskLocal static var report: (@Sendable (Event) -> Void)?
    @TaskLocal static var retryPart: Int?
    var parts: [Part]
    var engine: TranscriptionEngineKind = .geminiSubscription
    var mode: String?

    var failedIndices: [Int] { parts.indices.filter { if case .failed = parts[$0].phase { true } else { false } } }
    var completedCount: Int { parts.filter { $0.phase == .complete }.count }
    var activeIndex: Int? {
        parts.indices.first { if case .listening = parts[$0].phase { true } else { false } }
        ?? parts.indices.first { if case .sending = parts[$0].phase { true } else { false } }
        ?? parts.indices.first { parts[$0].phase == .waiting }
    }
    var unfinishedAudio: TimeInterval {
        parts.filter { $0.phase != .complete }.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }
    mutating func apply(_ event: Event) {
        switch event {
        case let .plan(plan): self = plan
        case let .phase(index, phase):
            guard parts.indices.contains(index) else { return }
            // Поздний тик URLSession не возвращает готовую часть к отправке.
            guard parts[index].phase != .complete else { return }
            if case .failed = parts[index].phase, case .waiting = phase { parts[index].phase = phase; return }
            if case .failed = parts[index].phase { return }
            if case .listening = parts[index].phase, case .sending = phase { return }
            if case let .listening(since) = parts[index].phase, case .listening = phase {
                parts[index].phase = .listening(since: since)
            } else { parts[index].phase = phase }
        }
    }
    func title(now: Date = .now) -> String {
        if let index = activeIndex {
            switch parts[index].phase {
            case .listening: return "Слушает часть \(index + 1) из \(parts.count)"
            case .sending: return "Отправляю часть \(index + 1) из \(parts.count)"
            default: return "Ждёт часть \(index + 1) из \(parts.count)"
            }
        }
        if failedIndices.count == 1 { return "Готово, кроме части \(failedIndices[0] + 1)" }
        if !failedIndices.isEmpty { return "Не готовы части " + failedIndices.map { String($0 + 1) }.joined(separator: ", ") }
        return "Все части готовы"
    }
    func detail(now: Date = .now) -> String? {
        if let index = activeIndex {
            switch parts[index].phase {
            case let .listening(since): return LoriFormat.duration(now.timeIntervalSince(since))
            case .sending: return parts[index].phase.uploadShare.map { "Отправлено \(Int(($0 * 100).rounded(.down)))%" }
            default: return nil
            }
        }
        return failedIndices.map { failureDetail($0) }.joined(separator: "\n").nilIfEmpty
    }
    func failureDetail(_ index: Int) -> String {
        guard parts.indices.contains(index), case let .failed(reason, retryAt) = parts[index].phase else { return "" }
        let reset = retryAt.map { " · повтор в " + $0.formatted(.dateTime.hour().minute().locale(LoriFormat.locale)) } ?? ""
        return "\(TranscriptCoverage.describe(parts[index].start...parts[index].end)) не расшифровано · \(reason)\(reset)"
    }
}

struct PartTranscriptionError: Error, LocalizedError, Sendable {
    let progress: TranscriptionParts
    var errorDescription: String? {
        guard let index = progress.failedIndices.first else { return "Не удалось расшифровать часть." }
        let part = progress.parts[index]
        let reason: String
        if case let .failed(message, _) = part.phase { reason = message } else { reason = "Сбой части." }
        return "Участок \(TranscriptCoverage.describe(part.start...part.end)): \(reason)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
