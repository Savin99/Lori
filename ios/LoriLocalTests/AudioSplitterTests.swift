import AVFoundation
import XCTest
@testable import LoriLocal

/// Нарезка отвечает за главное требование: в сервис должна уйти вся запись,
/// без дырок между частями и без потерянного хвоста.
final class AudioSplitterTests: XCTestCase {
    private var audio: URL!
    private let duration: Double = 30

    override func setUpWithError() throws {
        audio = FileManager.default.temporaryDirectory.appending(path: "split-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: duration, at: audio)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: audio)
    }

    func testPartsCoverTheWholeRecording() async throws {
        let splitter = AudioSplitter()
        let parts = try await splitter.split(audio, partSeconds: 10)
        defer { splitter.discard(parts) }

        XCTAssertGreaterThan(parts.count, 1, "получасовую запись одним куском отправлять нельзя")
        XCTAssertEqual(parts.first?.start ?? -1, 0, accuracy: 0.01, "первая часть обязана начинаться с нуля")
        XCTAssertEqual(parts.last?.end ?? 0, duration, accuracy: 0.5, "хвост записи теряться не должен")

        // Дырок между частями быть не может: следующая начинается раньше, чем кончилась предыдущая.
        for (previous, next) in zip(parts, parts.dropFirst()) {
            XCTAssertLessThan(next.start, previous.end, "между частями пропал участок записи")
            XCTAssertEqual(previous.end - next.start, AudioSplitter.defaultOverlap, accuracy: 0.3)
        }

        // Каждая часть — настоящий файл нужной длины, а не пустышка.
        for part in parts {
            let exported = try await AVURLAsset(url: part.url).load(.duration).seconds
            XCTAssertEqual(exported, part.length, accuracy: 0.5, "экспорт части не совпал с её длиной")
        }
    }

    func testShortRecordingGoesWholeAndIsNotDeleted() async throws {
        let splitter = AudioSplitter()
        let parts = try await splitter.split(audio, partSeconds: 60)

        XCTAssertEqual(parts.count, 1)
        XCTAssertTrue(parts[0].isOriginal, "исходный файл удалять нельзя")
        XCTAssertEqual(parts[0].length, duration, accuracy: 0.5)

        splitter.discard(parts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "исходник пережил уборку")
    }

    /// Кусок по месту пропуска: им приложение переспрашивает сервис.
    func testGapPieceIsCutExactlyAndClamped() async throws {
        let splitter = AudioSplitter()
        let piece = try await splitter.part(of: audio, from: 20, length: 100)
        defer { splitter.discard([piece]) }

        XCTAssertEqual(piece.start, 20, accuracy: 0.01)
        XCTAssertEqual(piece.length, 10, accuracy: 0.5, "длина обрезается по концу записи")
        let exported = try await AVURLAsset(url: piece.url).load(.duration).seconds
        XCTAssertEqual(exported, 10, accuracy: 0.5)
    }

    // MARK: - Границы по паузам

    /// Разрез уезжает на паузу, а не падает по таймеру на середину слова.
    func testBoundaryMovesToThePause() async throws {
        let spoken = FileManager.default.temporaryDirectory.appending(path: "pause-\(UUID().uuidString).wav")
        // Пауза стоит не там, куда метит таймер: до цели ещё три секунды речи.
        try AudioFixture.wav(seconds: 60, silenceAt: 16...17, at: spoken)
        defer { try? FileManager.default.removeItem(at: spoken) }

        let splitter = AudioSplitter()
        let parts = try await splitter.split(spoken, partSeconds: 20, alignToSilence: true)
        defer { splitter.discard(parts) }

        let cut = try XCTUnwrap(parts.first?.end)
        XCTAssertGreaterThanOrEqual(cut, 16, "разрез сел раньше паузы, посреди речи")
        XCTAssertLessThanOrEqual(cut, 17.5, "разрез проехал паузу и снова попал в речь")
    }

    /// Вперёд граница не тянется, даже если пауза именно там: часть длиннее
    /// запрошенной у облачного движка упирается в предел одного запроса.
    func testBoundaryNeverGrowsPastTheRequestedLength() async throws {
        let spoken = FileManager.default.temporaryDirectory.appending(path: "ahead-\(UUID().uuidString).wav")
        // Единственная пауза — сразу после цели.
        try AudioFixture.wav(seconds: 60, silenceAt: 21...23, at: spoken)
        defer { try? FileManager.default.removeItem(at: spoken) }

        let splitter = AudioSplitter()
        let parts = try await splitter.split(spoken, partSeconds: 20, alignToSilence: true)
        defer { splitter.discard(parts) }

        let cut = try XCTUnwrap(parts.first?.end)
        XCTAssertLessThanOrEqual(cut, 20, "часть выросла за запрошенную длину")
    }

    /// Сдвиг ограничен окном поиска: граница не может уехать в другой конец записи.
    func testBoundaryStaysNearTheTarget() async throws {
        let spoken = FileManager.default.temporaryDirectory.appending(path: "far-\(UUID().uuidString).wav")
        // Единственная пауза далеко от цели — тянуться к ней нельзя.
        try AudioFixture.wav(seconds: 60, silenceAt: 2...4, at: spoken)
        defer { try? FileManager.default.removeItem(at: spoken) }

        let splitter = AudioSplitter()
        let parts = try await splitter.split(spoken, partSeconds: 20, alignToSilence: true)
        defer { splitter.discard(parts) }

        let cut = try XCTUnwrap(parts.first?.end)
        XCTAssertEqual(cut, 20, accuracy: 20 / 4, "граница ушла дальше окна поиска")
    }

    /// Главное требование нарезки не отменяется поиском пауз.
    func testSilenceAlignedPartsStillCoverTheWholeRecording() async throws {
        let spoken = FileManager.default.temporaryDirectory.appending(path: "cover-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 60, silenceAt: 16...17, at: spoken)
        defer { try? FileManager.default.removeItem(at: spoken) }

        let splitter = AudioSplitter()
        let parts = try await splitter.split(spoken, partSeconds: 20, alignToSilence: true)
        defer { splitter.discard(parts) }

        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.first?.start ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(parts.last?.end ?? 0, 60, accuracy: 0.5, "хвост записи теряться не должен")
        for (previous, next) in zip(parts, parts.dropFirst()) {
            XCTAssertLessThan(next.start, previous.end, "между частями пропал участок записи")
        }
    }

    // MARK: - Нарезка по одной части

    /// Ленивая нарезка обязана давать ровно то же покрытие, что и разом: на
    /// живом прогоне нарезка вперёд съела 38% фонового окна, но терять из-за
    /// экономии кусок записи нельзя.
    func testCutterCoversTheWholeRecording() async throws {
        let splitter = AudioSplitter()
        var cutter = splitter.cutter(audio, duration: duration, partSeconds: 10)
        var parts: [AudioSplitter.Part] = []
        while let part = try await cutter.next() { parts.append(part) }
        defer { splitter.discard(parts) }

        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.first?.start ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(parts.last?.end ?? 0, duration, accuracy: 0.5, "хвост записи теряться не должен")
        for (previous, next) in zip(parts, parts.dropFirst()) {
            XCTAssertLessThan(next.start, previous.end, "между частями пропал участок записи")
        }
    }

    /// После обрыва работа продолжается с отметки, а не с нуля: в этом весь
    /// смысл черновика готовых частей.
    func testCutterResumesFromTheCursor() async throws {
        let splitter = AudioSplitter()
        var cutter = splitter.cutter(audio, duration: duration, partSeconds: 10, from: 18)
        var parts: [AudioSplitter.Part] = []
        while let part = try await cutter.next() { parts.append(part) }
        defer { splitter.discard(parts) }

        XCTAssertEqual(parts.first?.start ?? -1, 18, accuracy: 0.01, "продолжили не с той секунды")
        XCTAssertEqual(parts.last?.end ?? 0, duration, accuracy: 0.5)
    }

    /// Оценка числа частей нужна полосе прогресса. Занижать её нельзя: полоса
    /// упёрлась бы в сотню раньше конца — ровно тот огрех, что уже чинили.
    func testExpectedCountIsNotBelowTheRealOne() async throws {
        let splitter = AudioSplitter()
        var cutter = splitter.cutter(audio, duration: duration, partSeconds: 10)
        let expected = cutter.expectedCount
        var actual = 0
        var parts: [AudioSplitter.Part] = []
        while let part = try await cutter.next() {
            parts.append(part)
            actual += 1
        }
        defer { splitter.discard(parts) }

        XCTAssertGreaterThanOrEqual(expected, actual, "частей оказалось больше, чем обещала оценка")
    }

    func testOverlapCannotEatTheWholeStep() async throws {
        let splitter = AudioSplitter()
        // Перекрытие больше шага остановило бы нарезку на первой части.
        let parts = try await splitter.split(audio, partSeconds: 10, overlapSeconds: 30)
        defer { splitter.discard(parts) }

        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.last?.end ?? 0, duration, accuracy: 0.5)
    }
}
