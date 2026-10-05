import XCTest
@testable import LoriLocal

/// Проверка движка один раз на всю пачку, а не пять одинаковых ошибок по записям.
@MainActor
final class QueuePreflightTests: XCTestCase {
    private var fixture: QueueFixture!

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.concurrencyKey)
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.engineKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.concurrencyKey)
    }

    private func makeService(
        _ engines: [TranscriptionEngineKind: Bool]
    ) throws -> TranscriptionService {
        fixture = try QueueFixture()
        return TranscriptionService(
            engines: engines.mapValues { QueueEngine(gate: QueueGate(blocking: false), available: $0) },
            interruptedStore: fixture.store,
            availableMemory: { 0 }
        )
    }

    func testReadyEngineHasNoProblem() async throws {
        let service = try makeService([.gigaam: true, .gemini: true])

        let local = await service.preflightProblem(for: .gigaam)
        let cloud = await service.preflightProblem(for: .gemini)

        XCTAssertNil(local)
        XCTAssertNil(cloud)
    }

    /// Текст тот же, что стоит на карточке записи при сбое на старте, — не второй вариант.
    func testMissingEnginePartsAreNamedInPlainRussian() async throws {
        let service = try makeService([
            .gigaam: false, .whisper: false, .apple: false, .openAI: false, .gemini: false, .elevenLabs: false,
        ])

        let expected: [(TranscriptionEngineKind, TranscriptionError)] = [
            (.gigaam, .modelsMissing),
            (.whisper, .whisperModelMissing),
            (.apple, .assetsUnavailable),
            (.openAI, .missingKey(.openAI)),
            (.gemini, .missingKey(.gemini)),
            (.elevenLabs, .missingKey(.elevenLabs)),
        ]
        for (kind, error) in expected {
            let problem = await service.preflightProblem(for: kind)
            XCTAssertEqual(problem, error.errorDescription, "\(kind.rawValue)")
            XCTAssertFalse(problem?.isEmpty ?? true)
        }
    }

    /// Без явного движка спрашивается тот, что выбран в настройках.
    func testDefaultsToTheEngineChosenInSettings() async throws {
        let service = try makeService([.gigaam: true, .gemini: false])

        UserDefaults.standard.set(TranscriptionEngineKind.gigaam.rawValue, forKey: TranscriptionSettings.engineKey)
        let local = await service.preflightProblem()
        XCTAssertNil(local)

        UserDefaults.standard.set(TranscriptionEngineKind.gemini.rawValue, forKey: TranscriptionSettings.engineKey)
        let cloud = await service.preflightProblem()
        XCTAssertEqual(cloud, TranscriptionError.missingKey(.gemini).errorDescription)
    }

    /// Вопрос ничего не запускает и ничего не меняет: ни очереди, ни ошибок.
    func testPreflightTouchesNothing() async throws {
        let service = try makeService([.gemini: false])

        _ = await service.preflightProblem(for: .gemini)

        XCTAssertTrue(service.isIdle)
        XCTAssertTrue(service.failed.isEmpty)
        XCTAssertNil(service.lastError, "общая строка ошибки — для действий, а не для вопросов")
        XCTAssertEqual(service.batchTotal, 0)
    }
}
