import AVFoundation
import XCTest
@testable import LoriLocal

/// Настоящий прогон Whisper через WhisperKit: сигнатуры пакета, папку модели,
/// токенизатор и разбор пословных времён заглушкой не проверить — только живой моделью.
///
/// Модель в репозиторий не входит (618 МБ). Без неё тесты пропускаются.
/// Положить её в контейнер приложения в симуляторе:
///
///     python3 design/whisper/fetch_model.py --out ~/Downloads/whisper-large-v3-turbo
///     ./design/whisper/seed-model.sh <udid>
@MainActor
final class WhisperKitIntegrationTests: XCTestCase {
    private func requireModel() throws {
        try XCTSkipUnless(
            WhisperModelSet.locate() != nil,
            "модель Whisper не установлена — прогони design/whisper/seed-model.sh"
        )
        UserDefaults.standard.set("ru", forKey: TranscriptionSettings.languageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.languageKey)
        super.tearDown()
    }

    private var workspace: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori/Workspace", directoryHint: .isDirectory)
    }

    /// Аудио в рабочей папке по имени. Файл кладёт хост: симулятор с микрофона не пишет.
    private func audio(named name: String) -> URL? {
        let url = workspace.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func seconds(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Отчёт печатается всегда: цифры этого прогона идут в CLAUDE.md, а придумывать
    /// их нельзя — только читать из живого замера.
    private func report(_ label: String, transcript: Transcript, audio: TimeInterval, work: TimeInterval) {
        let ratio = audio > 0 ? work / audio : 0
        print("""
        [\(label)] звук \(String(format: "%.0f", audio)) с · работа \(String(format: "%.1f", work)) с \
        · \(String(format: "%.2f", ratio)) с на секунду звука · знаков \(transcript.text.count) \
        · слов \(transcript.words.count) · реплик \(transcript.segments.count)
        """)
        print("[\(label)] текст: \(transcript.text.prefix(400))")
    }

    /// Короткая фраза: доказывает, что движок вообще работает — модель загрузилась,
    /// токенизатор нашёлся локально, текст пришёл русский и с временами слов.
    func testTranscribesShortRussianPhraseWithWordTimings() async throws {
        try requireModel()
        let audio = try XCTUnwrap(
            self.audio(named: "UI sample.m4a"),
            "нет «UI sample.m4a» — прогони design/qa/seed-audio.sh"
        )

        let started = Date()
        let transcript = try await WhisperKitTranscriber().transcribe(audioURL: audio)
        let work = Date().timeIntervalSince(started)

        report("Whisper короткая", transcript: transcript, audio: seconds(of: audio), work: work)
        XCTAssertFalse(transcript.text.isEmpty, "модель ничего не распознала")
        XCTAssertTrue(
            transcript.text.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil,
            "ожидался русский текст, получено: \(transcript.text)"
        )
        XCTAssertFalse(transcript.words.isEmpty, "у Whisper запрошены пословные времена")
        XCTAssertFalse(transcript.segments.isEmpty, "из времён собираются реплики")
        let last = try XCTUnwrap(transcript.words.last)
        XCTAssertGreaterThan(last.end, 0)
    }

    /// Whisper склонен выдумывать текст там, где речи нет: на тишине известны
    /// «Продолжение следует…» и подписи фансаберов. Тишина обязана давать пустоту,
    /// то есть честную ошибку `emptyResult`, а не выдуманную реплику в расшифровке.
    func testSilenceDoesNotBecomeInventedText() async throws {
        try requireModel()

        // Тридцать секунд нулей — ровно одно окно Whisper, худший случай:
        // декодеру нечего описывать, и он начинает сочинять.
        let silence = FileManager.default.temporaryDirectory
            .appending(path: "silence-\(UUID().uuidString).wav")
        try AudioChunker.write(
            samples: [Float](repeating: 0, count: Int(AudioSamples.sampleRate * 30))[...],
            sampleRate: AudioSamples.sampleRate,
            to: silence
        )
        defer { try? FileManager.default.removeItem(at: silence) }

        do {
            let transcript = try await WhisperKitTranscriber().transcribe(audioURL: silence)
            print("[Whisper тишина] знаков \(transcript.text.count): «\(transcript.text)»")
            XCTFail("на тишине пришёл текст «\(transcript.text)» — это выдумка, а не расшифровка")
        } catch TranscriptionError.emptyResult {
            print("[Whisper тишина] пусто — ошибка emptyResult, как и должно быть")
        }
    }

    /// Файл замера лежит рядом с рабочей папкой, а не внутри неё: интеграционный
    /// тест GigaAM берёт первое аудио из Workspace, и семь минут звука там
    /// растянули бы обычный прогон на минуты.
    private var benchmarkAudio: URL? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori/Замер.m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Замер, ради которого движок и добавлен: два движка на одном файле.
    /// Файл кладёт хост под именем «Замер.m4a» — без него тест пропускается,
    /// потому что в обычном прогоне семь минут звука никому не нужны.
    func testMeasuresBothEnginesOnTheSameRecording() async throws {
        try requireModel()
        let audio = try XCTSkipIfNil(benchmarkAudio, "нет «Documents/Lori/Замер.m4a»")
        try XCTSkipUnless(GigaAMModelSet.locate(.ctc) != nil, "нет модели GigaAM CTC для сравнения")
        let length = seconds(of: audio)

        let whisperStarted = Date()
        let whisper = try await WhisperKitTranscriber().transcribe(audioURL: audio)
        report("Whisper замер", transcript: whisper, audio: length, work: Date().timeIntervalSince(whisperStarted))

        UserDefaults.standard.set(GigaAMVariant.ctc.rawValue, forKey: TranscriptionSettings.gigaAMVariantKey)
        defer { UserDefaults.standard.removeObject(forKey: TranscriptionSettings.gigaAMVariantKey) }
        let gigaStarted = Date()
        let gigaam = try await GigaAMTranscriber().transcribe(audioURL: audio)
        report("GigaAM замер", transcript: gigaam, audio: length, work: Date().timeIntervalSince(gigaStarted))

        XCTAssertFalse(whisper.text.isEmpty)
        XCTAssertFalse(gigaam.text.isEmpty)
    }
}

/// `XCTSkipIfNil` в XCTest нет, а `XCTUnwrap` для «файла не положили» — это падение,
/// а не пропуск: обычному прогону файл замера не нужен.
private func XCTSkipIfNil<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw XCTSkip(message) }
    return value
}
