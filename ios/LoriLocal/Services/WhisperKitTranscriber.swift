import Foundation
import WhisperKit

/// Папка с моделью Whisper на устройстве.
///
/// Веса в сборку не входят: turbo весит 632 МБ. Папку кладут руками в
/// `Lori/Models` через «Файлы» — той же дорогой, что и модели GigaAM.
/// Само приложение ничего не докачивает: WhisperKit умеет ходить на HuggingFace,
/// и эта дорога закрыта намеренно — расшифровка обязана работать без сети.
struct WhisperModelSet {
    let folder: URL

    /// Части модели в папке WhisperKit. Без любой из них движок не соберётся.
    static let parts = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
    /// Токенизатор WhisperKit ищет в том числе прямо в папке модели. Это и есть
    /// единственный способ обойтись без сети: иначе он идёт за ним на HuggingFace.
    /// Файлов нужно два: по `tokenizer.json` пакет решает, что токенизатор локальный,
    /// а класс токенизатора читает из `tokenizer_config.json` — без него разбор падает.
    /// В папке модели с HuggingFace их нет, они лежат в репозитории `openai/whisper-large-v3`.
    static let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]

    /// Первая папка со словом «whisper» в имени, где лежат все части модели.
    /// Имя не фиксировано: у HuggingFace оно вида `openai_whisper-large-v3-v20240930_turbo_632MB`,
    /// а переименовать папку владелец вправе.
    static func locate(fileManager: FileManager = .default) -> WhisperModelSet? {
        for location in locations(fileManager: fileManager) {
            let entries = (try? fileManager.contentsOfDirectory(
                at: location,
                includingPropertiesForKeys: nil
            )) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where entry.lastPathComponent.lowercased().contains("whisper") {
                let candidate = WhisperModelSet(folder: entry)
                if candidate.isComplete(fileManager: fileManager) { return candidate }
            }
        }
        return nil
    }

    /// Те же две папки, что у моделей GigaAM: скачанное приложением живёт в
    /// Application Support, а принесённое руками — в Documents, потому что
    /// только `Documents/Lori` видна через «Файлы».
    static func locations(fileManager: FileManager = .default) -> [URL] {
        [
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
        ]
        .compactMap { $0?.appending(path: "Lori/Models", directoryHint: .isDirectory) }
    }

    func isComplete(fileManager: FileManager = .default) -> Bool {
        Self.parts.allSatisfy { fileManager.fileExists(atPath: folder.appending(path: $0).path) }
    }

    /// Первый недостающий файл токенизатора — им и объясняется отказ.
    func missingTokenizerFile(fileManager: FileManager = .default) -> String? {
        Self.tokenizerFiles.first { !fileManager.fileExists(atPath: folder.appending(path: $0).path) }
    }
}

/// Whisper large-v3 turbo на устройстве через WhisperKit (Core ML).
///
/// Аудио остаётся на iPhone: сеть нужна только чтобы один раз добыть модель на Mac,
/// а само распознавание идёт офлайн. Знаки препинания и заглавные ставит сама модель.
struct WhisperKitTranscriber: Transcribing {
    /// Язык читается из настроек на каждом обращении — как вариант у GigaAM:
    /// иначе смена языка не подхватывалась бы без перезапуска. Пусто в настройках
    /// означает «определяй сам», и Whisper это умеет сам: у `DecodingOptions`
    /// за это отвечает `language: nil`, а не пустая строка.
    var language: String? {
        let code = TranscriptionSettings.language
        return code.isEmpty ? nil : code
    }

    var name: String { "Whisper large-v3 turbo, на этом iPhone" }

    func isAvailable() async -> Bool {
        WhisperModelSet.locate() != nil
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
        guard let models = WhisperModelSet.locate() else {
            throw TranscriptionError.whisperModelMissing
        }
        if let missing = models.missingTokenizerFile() {
            throw TranscriptionError.modelIncomplete(name, missing)
        }

        let samples = try AudioSamples.load(from: audioURL)
        guard !samples.isEmpty else { throw TranscriptionError.emptyResult }

        // Окно Whisper — 30 секунд. Кусок берём короче, чтобы он гарантированно
        // проходил одним окном, а нарезка и перекрытие — общие с GigaAM: без перекрытия
        // слово на стыке теряется целиком.
        let chunker = AudioChunker(configuration: AudioChunker.Configuration(
            targetSeconds: 28,
            searchSeconds: 2,
            windowSeconds: 0.02,
            minimumTailSeconds: 0.5
        ))
        let ranges = chunker.bounds(for: samples)
        let job = TranscriptionJob.current
        let checkpoint = LocalTranscriptCheckpoint.load(job: job, ranges: ranges)
        Diagnostics.log.notice(
            "Whisper turbo: кусков \(ranges.count), \(MemoryReport.text, privacy: .public)"
        )

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            // Служебные токены (<|ru|>, <|nospeech|>) в тексте расшифровки не нужны.
            skipSpecialTokens: true,
            // Слова со временем нужны сборщику реплик, и по ним же отбрасывается перекрытие.
            wordTimestamps: true
        )

        let assembler = TranscriptAssembler()

        // Модель — из общего кеша: 618 МБ весов грузятся один раз на пачку, а две
        // записи их делят, а не удваивают. Сам вызов модели кеш пропускает по одному:
        // одновременный `transcribe` на одном экземпляре WhisperKit нигде не обещан.
        // Куски двух записей от этого чередуются, и обе записи двигаются.
        let cache = EngineSessionCache.shared
        // На телефоне подготовка весов под Neural Engine занимает минуты, и до
        // первого куска экран иначе молчит.
        note("готовлю модель Whisper, это разово")
        let assembled = try await cache.withWhisperModel(models) { session in
            var words = checkpoint.words
            var coveredUntil = checkpoint.coveredUntil
            if !words.isEmpty { partial(assembler.transcript(from: words)) }

            for (index, range) in ranges.enumerated() {
                guard index >= checkpoint.next else { continue }
                progress(index, ranges.count)
                try Task.checkCancellation()
                // Кусок без звука модели не показываем вовсе. Whisper на тишине
                // выдаёт заученное из субтитров — «Продолжение следует...» — причём
                // уверенно: замер 31 августа 2026 дал `noSpeechProb` ровно 0 и
                // `avgLogprob` −0,08, так что штатное правило «не речь и модель не
                // уверена» здесь не срабатывает вовсе. Отличить тишину по самому
                // звуку и не спрашивать — единственный честный способ.
                guard !Self.isSilent(samples[range]) else {
                    coveredUntil = max(coveredUntil, Double(range.upperBound) / AudioSamples.sampleRate)
                    continue
                }
                let chunk = Array(samples[range])
                let spoken = try await cache.withWhisper(session) { pipe in
                    Self.spoken(in: try await pipe.transcribe(audioArray: chunk, decodeOptions: options))
                }
                let offset = Double(range.lowerBound) / AudioSamples.sampleRate
                let chunkWords = WhisperTranscript.words(from: spoken, offset: offset)
                assembler.merge(into: &words, words: chunkWords, coveredUntil: coveredUntil)
                coveredUntil = max(coveredUntil, Double(range.upperBound) / AudioSamples.sampleRate)
                // Готовый кусок сразу виден на экране записи: движок идёт кусками,
                // и ждать конца часовой записи, чтобы показать первую фразу, незачем.
                try LocalTranscriptCheckpoint(bounds: checkpoint.bounds, next: index + 1,
                    words: words, coveredUntil: coveredUntil).save(job: job)
                partial(assembler.transcript(from: words))
            }
            return assembler.transcript(from: words)
        }
        progress(ranges.count, ranges.count)

        guard !assembled.isEmpty else { throw TranscriptionError.emptyResult }
        return assembled
    }

    /// Тишина в куске: пик громкости ниже −60 dBFS (0.001). У шестнадцати бит
    /// младший разряд — это 3·10⁻⁵, то есть порог в тридцать раз выше шума
    /// оцифровки и во столько же раз ниже любой, даже шёпотной, речи. Проверяется
    /// **пик**, а не средняя громкость: одно слово в конце тихой минуты обязано
    /// спасти весь кусок.
    private static let silenceFloor: Float = 0.001

    private static func isSilent(_ samples: ArraySlice<Float>) -> Bool {
        samples.allSatisfy { abs($0) < silenceFloor }
    }

    /// Слова из ответа WhisperKit. Пословные времена считает отдельный проход
    /// по вниманию, и он может не дать результата — тогда словом становится целая
    /// реплика: текст важнее точности времени.
    private static func spoken(in results: [TranscriptionResult]) -> [WhisperWord] {
        results.flatMap { result in
            result.segments.flatMap { segment -> [WhisperWord] in
                guard let words = segment.words, !words.isEmpty else {
                    return [WhisperWord(
                        text: segment.text,
                        start: TimeInterval(segment.start),
                        end: TimeInterval(segment.end)
                    )]
                }
                return words.map {
                    WhisperWord(
                        text: $0.word,
                        start: TimeInterval($0.start),
                        end: TimeInterval($0.end)
                    )
                }
            }
        }
    }
}
