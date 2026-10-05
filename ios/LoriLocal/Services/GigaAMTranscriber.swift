import Foundation

/// GigaAM v3 на самом телефоне, через ONNX Runtime.
///
/// Core ML-экспорта GigaAM никто не публикует, а int8-ONNX лежит на HuggingFace открыто,
/// поэтому модель качается одной кнопкой и никаких адресов вписывать не нужно.
/// Пунктуацию и заглавные буквы расставляет сама модель: в словаре e2e-вариантов есть
/// знаки препинания и куски с заглавными буквами.
struct GigaAMTranscriber: Transcribing {
    /// Вариант читается из настроек на каждом обращении: человек может переключить
    /// RNN-T на CTC, не перезапуская приложение.
    var variant: GigaAMVariant { TranscriptionSettings.gigaAMVariant }

    var name: String { "\(variant.title), на этом iPhone" }

    func isAvailable() async -> Bool {
        GigaAMModelSet.locate(variant) != nil
    }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, partial: { _ in }, note: { _ in })
    }

    func transcribe(
        audioURL: URL,
        progress: @Sendable (Int, Int) -> Void,
        partial: @Sendable (Transcript) -> Void
    ) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, partial: partial, note: { _ in })
    }

    func transcribe(
        audioURL: URL,
        progress: @Sendable (Int, Int) -> Void,
        partial: @Sendable (Transcript) -> Void,
        note: @Sendable (String) -> Void
    ) async throws -> Transcript {
        let variant = variant
        guard let models = GigaAMModelSet.locate(variant) else {
            throw TranscriptionError.modelsMissing
        }

        let samples = try AudioSamples.load(from: audioURL)
        guard !samples.isEmpty else { throw TranscriptionError.emptyResult }

        // Окно в 12 секунд — не требование графа (входы динамические), а память:
        // внимание в Conformer глобальное, стоимость растёт квадратично по длине,
        // и на телефоне с 225-мегабайтными весами это разница между работой и
        // вылетом по памяти.
        let chunker = AudioChunker(configuration: AudioChunker.Configuration(
            targetSeconds: 12,
            searchSeconds: 4,
            windowSeconds: 0.02,
            minimumTailSeconds: 0.5
        ))
        let ranges = chunker.bounds(for: samples)
        let job = TranscriptionJob.current
        let checkpoint = LocalTranscriptCheckpoint.load(job: job, ranges: ranges)
        Diagnostics.log.notice(
            "GigaAM \(variant.rawValue, privacy: .public): кусков \(ranges.count), \(MemoryReport.text, privacy: .public)"
        )

        // Модель берётся из общего кеша: на пачке записей она грузится один раз, и две
        // записи делят одни веса вместо того, чтобы держать по своей копии. Счёт через
        // модель кеш сериализует — куски двух записей идут по очереди, чередуясь.
        let cache = EngineSessionCache.shared
        note("готовлю модель GigaAM, это разово")
        let wordBuilder = TranscriptWordBuilder()
        let assembler = TranscriptAssembler()

        let transcript = try await cache.withGigaAM(models) { session in
            let vocabulary = session.vocabulary
            let melCount = session.spectrogram.configuration.melCount
            var words = checkpoint.words
            var coveredUntil = checkpoint.coveredUntil
            if !words.isEmpty { partial(assembler.transcript(from: words)) }

            for (index, range) in ranges.enumerated() {
                guard index >= checkpoint.next else { continue }
                progress(index, ranges.count)
                try Task.checkCancellation()
                Diagnostics.log.notice(
                    "GigaAM \(variant.rawValue, privacy: .public): кусок \(index + 1) из \(ranges.count), \(MemoryReport.text, privacy: .public)"
                )
                let chunk = Array(samples[range])
                // Пустой ответ модели — это тишина в куске, а не сбой: идём дальше.
                guard let output = try await cache.compute(gigaam: session, { model in
                    let (features, frames) = model.spectrogram.features(from: chunk)
                    guard frames > 0 else { return nil as ChunkOutput? }
                    switch model.graph {
                    case let .rnnt(encoder, network):
                        let encoded = try encoder.encode(
                            features: features,
                            melCount: melCount,
                            frames: frames
                        )
                        let decoded = try RNNTGreedyDecoder(
                            network: network,
                            vocabulary: model.vocabulary
                        ).decode(
                            encoded: encoded.encoded,
                            frames: encoded.frames,
                            dimension: encoded.dimension,
                            encodedLength: encoded.length
                        )
                        return ChunkOutput(
                            tokens: decoded.tokens,
                            tokenFrames: decoded.tokenFrames,
                            encodedLength: encoded.length
                        )
                    case let .ctc(model2):
                        let logits = try model2.logProbabilities(
                            features: features,
                            melCount: melCount,
                            frames: frames,
                            classes: model.vocabulary.classCount
                        )
                        let decoded = CTCGreedyDecoder(vocabulary: model.vocabulary).tokensWithFrames(
                            logits: logits.logits,
                            frames: logits.frames,
                            classes: model.vocabulary.classCount
                        )
                        return ChunkOutput(
                            tokens: decoded.tokens,
                            tokenFrames: decoded.frames,
                            encodedLength: logits.frames
                        )
                    }
                }) else { continue }

                append(
                    tokens: output.tokens,
                    tokenFrames: output.tokenFrames,
                    range: range,
                    encodedLength: output.encodedLength,
                    vocabulary: vocabulary,
                    wordBuilder: wordBuilder,
                    assembler: assembler,
                    words: &words,
                    coveredUntil: &coveredUntil
                )
                // Кусок готов — показываем текст сразу, не дожидаясь конца.
                try LocalTranscriptCheckpoint(bounds: checkpoint.bounds, next: index + 1,
                    words: words, coveredUntil: coveredUntil).save(job: job)
                partial(assembler.transcript(from: words))
            }
            return assembler.transcript(from: words)
        }
        progress(ranges.count, ranges.count)

        let assembled = transcript
        Diagnostics.log.notice(
            "GigaAM: готово, символов \(assembled.text.count), \(MemoryReport.text, privacy: .public)"
        )
        guard !assembled.text.isEmpty else { throw TranscriptionError.emptyResult }
        return assembled
    }

    /// Что вернул один кусок: токены, кадры и длина, по которой считается шаг времени.
    /// Обе ветки графа отдают одно и то же, и наружу из шлюза кеша уходит именно это —
    /// значения, а не сессии: сессии обязаны остаться внутри.
    private struct ChunkOutput: Sendable {
        let tokens: [Int]
        let tokenFrames: [Int]
        let encodedLength: Int
    }

    /// Общая для обоих вариантов часть: из токенов и кадров собираются слова со временем.
    ///
    /// Шаг кадра считается по факту — длительность куска, поделённая на число кадров
    /// энкодера, — как в `gigaam/timestamps_utils.py`. Дубли из перекрытия кусков
    /// отбрасываются по времени, а не сравнением строк.
    private func append(
        tokens: [Int],
        tokenFrames: [Int],
        range: Range<Int>,
        encodedLength: Int,
        vocabulary: SentencePieceVocabulary,
        wordBuilder: TranscriptWordBuilder,
        assembler: TranscriptAssembler,
        words: inout [TranscriptWord],
        coveredUntil: inout TimeInterval
    ) {
        let end = Double(range.upperBound) / AudioSamples.sampleRate
        guard !tokens.isEmpty else {
            coveredUntil = max(coveredUntil, end)
            return
        }
        let offset = Double(range.lowerBound) / AudioSamples.sampleRate
        let chunkSeconds = Double(range.count) / AudioSamples.sampleRate
        let frameDuration = chunkSeconds / Double(max(encodedLength, 1))
        let chunkWords = wordBuilder.words(
            tokens: tokens,
            tokenFrames: tokenFrames,
            vocabulary: vocabulary,
            frameDuration: frameDuration,
            offset: offset
        )
        assembler.merge(into: &words, words: chunkWords, coveredUntil: coveredUntil)
        coveredUntil = max(coveredUntil, end)
    }
}
