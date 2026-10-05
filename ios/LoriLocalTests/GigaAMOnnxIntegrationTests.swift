import AVFoundation
import XCTest
@testable import LoriLocal

/// Настоящий прогон GigaAM через ONNX Runtime: имена входов и выходов, типы длин,
/// порядок осей и разбор словаря нельзя проверить заглушкой — только живой моделью.
///
/// Модель в репозиторий не входит (225 МБ на вариант). Без неё тест пропускается.
/// Положить её в контейнер приложения в симуляторе:
///
///     ./design/gigaam/seed-models.sh <udid> <папка со скачанными моделями>
@MainActor
final class GigaAMOnnxIntegrationTests: XCTestCase {
    /// Русская речь для проверки: симулятор с микрофона не пишет, поэтому фраза
    /// синтезируется на хосте (`design/qa/seed-audio.sh`) либо берётся из рабочей папки.
    private func sampleAudio() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let workspace = documents.appending(path: "Lori/Workspace", directoryHint: .isDirectory)
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: nil
        )) ?? []
        let audio = candidates.first { WorkspaceEntry.audioExtensions.contains($0.pathExtension.lowercased()) }
        return try XCTUnwrap(audio, "в рабочей папке нет аудио — прогони design/qa/seed-audio.sh")
    }

    private func transcribe(_ variant: GigaAMVariant) async throws -> Transcript {
        try XCTSkipUnless(
            GigaAMModelSet.locate(variant) != nil,
            "модель \(variant.title) не установлена — прогони design/gigaam/seed-models.sh"
        )
        UserDefaults.standard.set(variant.rawValue, forKey: TranscriptionSettings.gigaAMVariantKey)
        defer { UserDefaults.standard.removeObject(forKey: TranscriptionSettings.gigaAMVariantKey) }

        let audio = try sampleAudio()
        return try await GigaAMTranscriber().transcribe(audioURL: audio)
    }

    func testRNNTProducesRussianTextWithWordTimings() async throws {
        let transcript = try await transcribe(.rnnt)

        XCTAssertFalse(transcript.text.isEmpty, "модель ничего не распознала")
        XCTAssertTrue(
            transcript.text.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil,
            "ожидался русский текст, получено: \(transcript.text)"
        )
        XCTAssertFalse(transcript.words.isEmpty, "у RNN-T должны быть тайминги слов")
        XCTAssertFalse(transcript.segments.isEmpty, "из таймингов собираются реплики")
        let last = try XCTUnwrap(transcript.words.last)
        XCTAssertGreaterThan(last.end, 0)
        print("RNN-T: \(transcript.text)")
        print("RNN-T память после прогона: \(MemoryReport.text)")
    }

    func testCTCProducesRussianTextWithWordTimings() async throws {
        let transcript = try await transcribe(.ctc)

        XCTAssertFalse(transcript.text.isEmpty, "модель ничего не распознала")
        XCTAssertTrue(
            transcript.text.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil,
            "ожидался русский текст, получено: \(transcript.text)"
        )
        XCTAssertFalse(transcript.words.isEmpty, "кадры CTC тоже дают тайминги слов")
        print("CTC: \(transcript.text)")
        print("CTC память после прогона: \(MemoryReport.text)")
    }
}
