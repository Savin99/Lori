import CoreML
import Foundation

/// GigaAM v3 e2e RNN-T на устройстве.
///
/// Пунктуацию и заглавные буквы расставляет сама модель: её словарь содержит
/// знаки препинания и куски с заглавными буквами. Отдельного шага нормализации нет.
///
/// Модели в сборку не зашиты: энкодер весит около 240 МБ, его правильнее докачивать.
/// Пока файлов нет, движок честно сообщает, что не установлен.
struct GigaAMCoreMLTranscriber: LocalTranscribing {
    var name: String { "GigaAM v3, на устройстве" }

    func isAvailable() async -> Bool {
        GigaAMModelSet.locate() != nil
    }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        guard let models = GigaAMModelSet.locate() else {
            throw TranscriptionError.engineNotInstalled(name)
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let encoder = GigaAMEncoder(model: try await load(models.encoder, configuration: configuration))
        guard let window = encoder.window else { throw GigaAMEncoder.Failure.unknownWindow }

        let spectrogram = try LogMelSpectrogram()
        let samples = try AudioSamples.load(from: audioURL)
        guard !samples.isEmpty else { throw TranscriptionError.emptyResult }

        // Куски подбираются под окно энкодера, а не наоборот.
        let windowSeconds = Double(window) * Double(spectrogram.configuration.hopLength)
            / AudioSamples.sampleRate
        let chunker = AudioChunker(configuration: AudioChunker.Configuration(
            targetSeconds: max(5, windowSeconds - 5),
            searchSeconds: 4,
            windowSeconds: 0.02,
            minimumTailSeconds: 0.5
        ))
        let ranges = chunker.bounds(for: samples)

        let vocabulary = try SentencePieceVocabulary(contentsOf: models.vocabulary)
        let network = GigaAMCoreMLNetwork(
            prediction: try await load(models.prediction, configuration: configuration),
            joint: try await load(models.joint, configuration: configuration),
            blankIndex: vocabulary.blankIndex
        )
        let decoder = RNNTGreedyDecoder(network: network, vocabulary: vocabulary)

        let wordBuilder = TranscriptWordBuilder()
        let assembler = TranscriptAssembler()
        var words: [TranscriptWord] = []
        var coveredUntil: TimeInterval = 0

        for (index, range) in ranges.enumerated() {
            progress(index, ranges.count)
            let (features, frames) = spectrogram.features(from: Array(samples[range]))
            guard frames > 0 else { continue }
            let encoded = try encoder.encode(
                features: features,
                melCount: spectrogram.configuration.melCount,
                frames: frames
            )
            let output = try decoder.decode(
                encoded: encoded.encoded,
                frames: encoded.frames,
                dimension: encoded.dimension,
                encodedLength: encoded.length
            )
            let offset = Double(range.lowerBound) / AudioSamples.sampleRate
            guard !output.text.isEmpty else {
                coveredUntil = max(coveredUntil, Double(range.upperBound) / AudioSamples.sampleRate)
                continue
            }

            // Шаг кадра энкодера считается по факту, как в timestamps_utils:
            // длительность куска, поделённая на число кадров энкодера.
            let chunkSeconds = Double(range.count) / AudioSamples.sampleRate
            let frameDuration = chunkSeconds / Double(max(encoded.length, 1))
            let chunkWords = wordBuilder.words(
                tokens: output.tokens,
                tokenFrames: output.tokenFrames,
                vocabulary: vocabulary,
                frameDuration: frameDuration,
                offset: offset
            )
            assembler.merge(into: &words, words: chunkWords, coveredUntil: coveredUntil)
            coveredUntil = max(coveredUntil, Double(range.upperBound) / AudioSamples.sampleRate)
        }
        progress(ranges.count, ranges.count)

        let assembled = assembler.transcript(from: words)
        guard !assembled.text.isEmpty else { throw TranscriptionError.emptyResult }
        return assembled
    }

    /// `.mlpackage` перед запуском нужно скомпилировать; `.mlmodelc` уже готов.
    private func load(_ url: URL, configuration: MLModelConfiguration) async throws -> MLModel {
        if url.pathExtension == "mlmodelc" {
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        let compiled = try await MLModel.compileModel(at: url)
        return try MLModel(contentsOf: compiled, configuration: configuration)
    }
}
