import Foundation
import WhisperKit

/// Папка с моделью Whisper на устройстве.
///
/// Веса в сборку не входят: turbo весит от 600 МБ. Папку кладут руками в
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

    /// Documents/Lori/Models видна через «Файлы», так что модель можно положить
    /// и удалить руками. Список заметок её не показывает: он читает только Workspace.
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
struct WhisperKitTranscriber: LocalTranscribing {
    /// Whisper многоязычный, поэтому язык — параметр, а не константа в коде.
    /// По умолчанию русский: на нём говорит владелец и весь остальной интерфейс.
    let language: String

    init(language: String = "ru") {
        self.language = language
    }

    var name: String { "Whisper large-v3 turbo, на устройстве" }

    func isAvailable() async -> Bool {
        WhisperModelSet.locate() != nil
    }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        guard let models = WhisperModelSet.locate() else {
            throw TranscriptionError.engineNotInstalled(name)
        }
        if let missing = models.missingTokenizerFile() {
            throw TranscriptionError.modelIncomplete(name, missing)
        }

        let samples = try AudioSamples.load(from: audioURL)
        guard !samples.isEmpty else { throw TranscriptionError.emptyResult }

        // `download: false` — единственная защита от похода в сеть: с моделью на месте
        // WhisperKit туда не пойдёт, а без неё честно упадёт, а не скачает 600 МБ по мобильной сети.
        let pipe = try await WhisperKit(WhisperKitConfig(
            modelFolder: models.folder.path,
            verbose: false,
            load: true,
            download: false
        ))

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
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            // Служебные токены (<|ru|>, <|nospeech|>) в тексте заметки не нужны.
            skipSpecialTokens: true,
            // Слова со временем нужны сборщику реплик, и по ним же отбрасывается перекрытие.
            wordTimestamps: true
        )

        let assembler = TranscriptAssembler()
        var words: [TranscriptWord] = []
        var coveredUntil: TimeInterval = 0

        for (index, range) in ranges.enumerated() {
            progress(index, ranges.count)
            let results = try await pipe.transcribe(
                audioArray: Array(samples[range]),
                decodeOptions: options
            )
            let offset = Double(range.lowerBound) / AudioSamples.sampleRate
            let chunkWords = WhisperTranscript.words(from: Self.spoken(in: results), offset: offset)
            assembler.merge(into: &words, words: chunkWords, coveredUntil: coveredUntil)
            coveredUntil = max(coveredUntil, Double(range.upperBound) / AudioSamples.sampleRate)
        }
        progress(ranges.count, ranges.count)

        let assembled = assembler.transcript(from: words)
        guard !assembled.isEmpty else { throw TranscriptionError.emptyResult }
        return assembled
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
