import Foundation

/// Общая модель по подписке не даёт нативных таймингов: временем всегда остаются
/// границы отправленной части. S1 имеет смысл только внутри одного запроса.
struct GatewayTranscriber: Transcribing {
    let clientProvider: @Sendable () throws -> GatewayClient
    let splitter = AudioSplitter()
    let partLimit: TimeInterval?

    init(
        partLimit: TimeInterval? = nil,
        clientProvider: @escaping @Sendable () throws -> GatewayClient = { try GatewayClient.configured(session: CloudSession.shared) }
    ) {
        self.partLimit = partLimit
        self.clientProvider = clientProvider
    }

    var name: String { "Gemini (подписка), через Mac mini в Google" }

    func isAvailable() async -> Bool { (try? clientProvider()) != nil }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, partial: { _ in })
    }

    func transcribe(
        audioURL: URL,
        progress: @Sendable (Int, Int) -> Void,
        partial: @Sendable (Transcript) -> Void
    ) async throws -> Transcript {
        let client = try clientProvider()
        let duration = try await splitter.duration(of: audioURL)
        guard duration.isFinite, duration > 0 else { throw TranscriptionError.emptyResult }
        let target = partLimit ?? TranscriptionSettings.subscriptionPartSeconds
        let speakers = TranscriptionSettings.subscriptionMode == .speakers
        let language = TranscriptionSettings.language
        let vocabulary = TranscriptionSettings.vocabulary
        // Временные имена частей меняются после обрыва; ключ привязан к оригиналу.
        let path = audioURL.path
        let attributes = try audioURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "\(attributes.fileSize ?? 0)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let options = try JSONEncoder().encode([speakers ? "1" : "0", language] + vocabulary).base64EncodedString()
        var segments: [TranscriptSegment] = []
        var warnings = [GatewaySettings.transcriptionNotice]
        if speakers {
            warnings.append("Метки говорящих действуют внутри одной части. S1 в разных частях может быть разными людьми.")
        }
        var cutter = splitter.cutter(audioURL, duration: duration, partSeconds: target, alignToSilence: true)
        var done = 0
        // Короткую запись CloudAudio отправит как есть — без лишнего экспорта в AAC.
        if duration <= target {
            progress(0, 1)
            let part = AudioSplitter.Part(url: audioURL, start: 0, length: duration, isOriginal: true)
            segments = try await ask(part, index: 0, client: client, path: path, identity: identity, options: options,
                                     speakers: speakers, language: language, vocabulary: vocabulary)
            progress(1, 1)
        } else {
            while let part = try await cutter.next() {
                defer { splitter.discard([part]) }
                try Task.checkCancellation()
                progress(done, max(cutter.expectedCount, done + 1))
                let produced = try await ask(part, index: done, client: client, path: path, identity: identity, options: options,
                                             speakers: speakers, language: language, vocabulary: vocabulary)
                // Не сравниваем реплики одной части между собой: все они имеют
                // одинаковые границы, но похожие фразы внутри — настоящие повторы.
                let fresh = produced.filter { !SegmentMerge.isDuplicate($0, in: segments) }
                segments.append(contentsOf: fresh)
                done += 1
                partial(Transcript(text: segments.map(\.text).joined(separator: " "), segments: segments, warnings: warnings))
            }
            progress(done, done)
        }
        guard !segments.isEmpty else { throw TranscriptionError.emptyResult }
        return Transcript(text: segments.map(\.text).joined(separator: " "), segments: segments, warnings: warnings)
    }

    private func ask(
        _ part: AudioSplitter.Part, index: Int, client: GatewayClient, path: String, identity: String, options: String,
        speakers: Bool, language: String, vocabulary: [String]
    ) async throws -> [TranscriptSegment] {
        do {
            let prepared = try CloudAudio.prepare(part.url)
            defer { prepared.discard() }
            let key = GatewayClient.audioKey(path: path, index: index, start: part.start, end: part.end, identity: identity, options: options)
            let response = try await client.transcribe(audio: prepared, key: key, speakers: speakers, language: language, vocabulary: vocabulary)
            let segments = Self.segments(response, part: part, speakers: speakers)
            guard !segments.isEmpty else { throw GatewayError(code: "agent") }
            return segments
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let message = (error as? GatewayError)?.localizedDescription ?? "Не удалось подготовить или отправить аудио."
            throw TranscriptionError.api("Участок \(TranscriptCoverage.describe(part.start...part.end)): \(message)")
        }
    }

    static func segments(_ response: [GatewayClient.Segment], part: AudioSplitter.Part, speakers: Bool) -> [TranscriptSegment] {
        response.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let label = speakers ? segment.speaker.flatMap { value in
                value.range(of: #"^S[1-9][0-9]{0,2}$"#, options: .regularExpression) != nil ? value : nil
            } : nil
            return TranscriptSegment(start: part.start, end: part.end,
                                     text: label.map { "\($0): \(text)" } ?? text, isApproximate: true)
        }
    }
}
