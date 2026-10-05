import Foundation

/// Точный индекс следующей части и слова с настоящими временами. Незавершённый
/// кусок пересчитывается, уже законченные — нет. Снимок привязан к запуску и нарезке.
struct LocalTranscriptCheckpoint: Codable, Sendable {
    let bounds: [Int]
    var next: Int = 0
    var words: [TranscriptWord] = []
    var coveredUntil: TimeInterval = 0

    static func load(job: TranscriptionJob?, ranges: [Range<Int>]) -> Self {
        let bounds = ranges.flatMap { [$0.lowerBound, $0.upperBound] }
        if let job, let data = try? Data(contentsOf: job.directory.appending(path: "local.json")),
           let saved = try? JSONDecoder().decode(Self.self, from: data), saved.bounds == bounds {
            return saved
        }
        return Self(bounds: bounds)
    }

    func save(job: TranscriptionJob?) throws {
        guard let job else { return }
        try FileManager.default.createDirectory(at: job.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: job.directory.appending(path: "local.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
