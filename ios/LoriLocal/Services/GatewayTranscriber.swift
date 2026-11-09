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
        let fingerprint = TranscriptCheckpoint.fingerprint(audio: audioURL, engine: "gemini-subscription",
            model: client.baseURL.absoluteString + "|" + audioURL.path, mode: options, partSeconds: target, vocabulary: vocabulary)
        var draft = TranscriptCheckpoint.load(fingerprint: fingerprint)
        if TranscriptionParts.retryPart != nil, draft.subscriptionParts == nil {
            throw TranscriptionError.api("Черновик частей недоступен или аудио изменилось. Запусти расшифровку заново.")
        }
        var saved = draft.subscriptionParts ?? []
        if saved.isEmpty {
            // Планируем границы без экспорта всей записи: временный AAC живёт только
            // во время своей отправки. План и номера переживают повтор/перезапуск.
            var start: TimeInterval = 0
            while start < duration - 0.1 {
                var length = min(target, duration - start)
                if start + length < duration - 0.1 {
                    length = splitter.alignedLength(in: audioURL, start: start, length: length, duration: duration)
                }
                saved.append(.init(start: start, end: start + length))
                if start + length >= duration - 0.1 { break }
                start += max(0.5, length - min(AudioSplitter.defaultOverlap, target / 2))
            }
        }
        var state = TranscriptionParts(parts: saved.map {
            .init(start: $0.start, end: $0.end, phase: $0.pieces != nil ? .complete : ($0.failure ?? .waiting))
        }, mode: TranscriptionSettings.subscriptionMode.rawValue)
        TranscriptionParts.report?(.plan(state))
        var warnings = [GatewaySettings.transcriptionNotice]
        if speakers { warnings.append("Метки говорящих действуют внутри одной части. S1 в разных частях может быть разными людьми.") }
        func assembled() -> Transcript {
            var segments: [TranscriptSegment] = []
            for item in saved {
                let produced = (item.pieces ?? []).map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, isApproximate: $0.isApproximate) }
                segments.append(contentsOf: produced.filter { !SegmentMerge.isDuplicate($0, in: segments) })
            }
            return Transcript(text: segments.map(\.text).joined(separator: " "), segments: segments, warnings: warnings)
        }
        for index in saved.indices {
            try Task.checkCancellation()
            guard saved[index].pieces == nil,
                  TranscriptionParts.retryPart == nil || TranscriptionParts.retryPart == index else { continue }
            state.parts[index].phase = .waiting
            TranscriptionParts.report?(.phase(index, .waiting))
            progress(state.completedCount, saved.count)
            let item = saved[index]
            do {
                let part = duration <= target
                    ? AudioSplitter.Part(url: audioURL, start: 0, length: duration, isOriginal: true)
                    : try await splitter.part(of: audioURL, from: item.start, length: item.end - item.start)
                defer { splitter.discard([part]) }
                let produced = try await ask(part, index: index, client: client, path: path, identity: identity, options: options,
                                             speakers: speakers, language: language, vocabulary: vocabulary)
                saved[index].pieces = produced.map { .init(start: $0.start, end: $0.end, text: $0.text, isApproximate: $0.isApproximate) }
                saved[index].failure = nil
                state.parts[index].phase = .complete
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let message = (error as? GatewayError)?.localizedDescription ?? "Не удалось подготовить или отправить аудио."
                let reset = ((error as? GatewayError)?.code == "quota" ? (error as? GatewayError)?.retryAfter : nil).flatMap { $0.isFinite && $0 > 0 ? Date().addingTimeInterval($0) : nil }
                state.parts[index].phase = .failed(reason: message, retryAt: reset)
                saved[index].failure = state.parts[index].phase
            }
            // Сначала диск, потом «готово»: уже оплаченный ответ не пропадает при обрыве.
            draft.subscriptionParts = saved
            draft.cursor = saved.filter { $0.pieces != nil }.map(\.end).max() ?? 0
            draft.pieces = saved.flatMap { $0.pieces ?? [] }
            draft.warnings = warnings
            TranscriptCheckpoint.save(draft)
            TranscriptionParts.report?(.phase(index, state.parts[index].phase))
            progress(state.completedCount, saved.count)
            partial(assembled())
        }
        guard state.failedIndices.isEmpty else { throw PartTranscriptionError(progress: state) }
        guard state.completedCount == saved.count else { throw TranscriptionError.api("Не все части готовы. Повтори оставшиеся части.") }
        let transcript = assembled()
        guard !transcript.segments.isEmpty else { throw TranscriptionError.emptyResult }
        TranscriptCheckpoint.drop(fingerprint: fingerprint)
        return transcript
    }

    private func ask(
        _ part: AudioSplitter.Part, index: Int, client: GatewayClient, path: String, identity: String, options: String,
        speakers: Bool, language: String, vocabulary: [String]
    ) async throws -> [TranscriptSegment] {
        let prepared = try CloudAudio.prepare(part.url)
        defer { prepared.discard() }
        let key = GatewayClient.audioKey(path: path, index: index, start: part.start, end: part.end, identity: identity, options: options)
        let report = TranscriptionParts.report
        let parent = BackgroundTranscriptionTransport.report
        let transfer: @Sendable (TransferPhase) -> Void = { phase in
            parent?(phase)
            switch phase {
            case let .sending(sent, expected): report?(.phase(index, .sending(sent: sent, expected: expected)))
            case .awaiting: report?(.phase(index, .waiting))
            case .answered: break
            }
        }
        // Опросы GET не трогают байты части. «Слушает» — только когда шлюз
        // подтвердил running: загруженная часть может ещё ждать очереди.
        let response = try await client.transcribe(audio: prepared, key: key, speakers: speakers, language: language, vocabulary: vocabulary,
            transfer: transfer, listening: { report?(.phase(index, .listening(since: .now))) })
        let segments = Self.segments(response, part: part, speakers: speakers)
        guard !segments.isEmpty else { throw GatewayError(code: "agent") }
        return segments
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
