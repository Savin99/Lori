import XCTest
@testable import LoriLocal

/// Слой «движок — модель — режим». Экраны читают только его, поэтому новый
/// движок не должен требовать правок в интерфейсе.
final class EngineCatalogTests: XCTestCase {
    private let keys = [
        TranscriptionSettings.engineKey,
        TranscriptionSettings.gigaAMVariantKey,
        TranscriptionSettings.geminiModeKey,
        TranscriptionSettings.openAIModelKey,
        TranscriptionSettings.elevenLabsModeKey,
        TranscriptionSettings.timecodesKey,
        TranscriptionSettings.speakerLabelsKey,
    ]

    override func setUpWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDownWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func testEnginesAreSplitByLocality() {
        XCTAssertEqual(EngineCatalog.onDevice().map(\.kind), [.gigaam, .whisper, .apple])
        XCTAssertEqual(EngineCatalog.cloud().map(\.kind), [.openAI, .gemini, .elevenLabs])
        XCTAssertEqual(EngineCatalog.descriptor(for: .gigaam).locality.symbol, "iphone")
    }

    /// Единственный движок, где оба переключателя «Расшифровки» настоящие:
    /// тайминги слов приходят нативно, говорящие — отдельным полем `diarize`,
    /// и одно другого не требует. У остальных хотя бы один из них с оговоркой.
    func testElevenLabsIsTheOnlyEngineWithBothTogglesActive() {
        let both = TranscriptionEngineKind.allCases.filter {
            let toggles = EngineToggles.current(for: $0)
            return toggles.timecodes == .active && toggles.speakers == .active
        }
        XCTAssertEqual(both, [.elevenLabs])
    }

    /// Режим у него отвечает за то, что словами не является, а не за таймкоды
    /// и говорящих: их включают тумблеры, и режим не имеет права их отменять.
    func testElevenLabsModesDoNotTouchTheToggles() {
        for mode in ElevenLabsMode.allCases {
            UserDefaults.standard.set(mode.rawValue, forKey: TranscriptionSettings.elevenLabsModeKey)
            XCTAssertEqual(EngineToggles.current(for: .elevenLabs).timecodes, .active, "режим \(mode.rawValue)")
            XCTAssertEqual(EngineToggles.current(for: .elevenLabs).speakers, .active, "режим \(mode.rawValue)")
        }
    }

    /// У движка Apple режимов нет — чип режима в панели должен исчезнуть.
    func testAppleHasNoModes() {
        XCTAssertTrue(EngineCatalog.descriptor(for: .apple).modes.isEmpty)
        XCTAssertNil(TranscriptionSettings.mode(for: .apple))
    }

    /// Режим у каждого движка свой и восстанавливается при возврате к нему.
    func testModeIsRememberedPerEngine() {
        let ctc = try! XCTUnwrap(EngineCatalog.descriptor(for: .gigaam).modes.first { $0.id == "ctc" })
        let smart = try! XCTUnwrap(EngineCatalog.descriptor(for: .gemini).modes.first { $0.id == "smart" })

        TranscriptionSettings.setMode(ctc, for: .gigaam)
        TranscriptionSettings.setMode(smart, for: .gemini)

        XCTAssertEqual(TranscriptionSettings.mode(for: .gigaam)?.id, "ctc")
        XCTAssertEqual(TranscriptionSettings.mode(for: .gemini)?.id, "smart")
        XCTAssertEqual(TranscriptionSettings.gigaAMVariant, .ctc, "режим — это тот же вариант модели")
        XCTAssertEqual(TranscriptionSettings.geminiMode, .smart)
    }

    /// Режим OpenAI — пресет над моделью: выбор режима выставляет модель.
    func testOpenAIModeSetsModel() {
        let speakers = try! XCTUnwrap(EngineCatalog.descriptor(for: .openAI).modes.first { $0.id == "speakers" })

        TranscriptionSettings.setMode(speakers, for: .openAI)

        XCTAssertEqual(TranscriptionSettings.openAIModel, "gpt-4o-transcribe-diarize")
        XCTAssertEqual(TranscriptionSettings.mode(for: .openAI)?.title, "Говорящие")
    }

    /// Модель, вписанная руками, режимом не притворяется.
    func testCustomModelIsNotAMode() {
        UserDefaults.standard.set("gpt-4o-mini-transcribe", forKey: TranscriptionSettings.openAIModelKey)

        XCTAssertNil(OpenAIMode.of("gpt-4o-mini-transcribe"))
        XCTAssertTrue(TranscriptionSettings.hasCustomModel(for: .openAI))
    }

    /// Режимов у Gemini три, и порядок один и тот же везде, где они видны.
    func testGeminiHasThreeModes() {
        XCTAssertEqual(EngineCatalog.descriptor(for: .gemini).modes.map(\.id), ["accuracy", "speakers", "smart"])
    }

    // MARK: - Матрица переключателей

    /// Переключатели честные: активны только там, где движок реально умеет.
    func testToggleMatrixPerEngine() {
        XCTAssertEqual(EngineToggles.current(for: .gigaam).timecodes, .active)
        XCTAssertNotEqual(EngineToggles.current(for: .gigaam).speakers, .active, "GigaAM говорящих не различает")

        XCTAssertNotEqual(EngineToggles.current(for: .apple).timecodes, .active)
        XCTAssertNotEqual(EngineToggles.current(for: .apple).speakers, .active)

        UserDefaults.standard.set("whisper-1", forKey: TranscriptionSettings.openAIModelKey)
        XCTAssertEqual(EngineToggles.current(for: .openAI).timecodes, .active)
        XCTAssertNotEqual(EngineToggles.current(for: .openAI).speakers, .active)

        UserDefaults.standard.set("gpt-4o-transcribe-diarize", forKey: TranscriptionSettings.openAIModelKey)
        XCTAssertEqual(EngineToggles.current(for: .openAI).timecodes, .active)
        guard case .fixedOn = EngineToggles.current(for: .openAI).speakers else {
            return XCTFail("diarize всегда различает говорящих")
        }

        UserDefaults.standard.set("gpt-transcribe", forKey: TranscriptionSettings.openAIModelKey)
        XCTAssertNotEqual(EngineToggles.current(for: .openAI).timecodes, .active)
        XCTAssertNotEqual(EngineToggles.current(for: .openAI).speakers, .active)
    }

    /// Тумблеры стали индикаторами режима: ни один из них больше не «активен»
    /// у Gemini, потому что решает режим. Это и есть лечение противоречия
    /// «Точность» + включённые таймкоды.
    func testGeminiTogglesOnlyReportWhatTheModeGives() {
        UserDefaults.standard.set(GeminiMode.speakers.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        XCTAssertEqual(
            EngineToggles.current(for: .gemini).timecodes,
            .fixedOn("Режим «Спикеры и таймкоды» включает и то и другое.")
        )
        XCTAssertEqual(
            EngineToggles.current(for: .gemini).speakers,
            .fixedOn("Режим «Спикеры и таймкоды» включает и то и другое.")
        )

        UserDefaults.standard.set(GeminiMode.accuracy.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        XCTAssertNotEqual(EngineToggles.current(for: .gemini).timecodes, .active)
        XCTAssertNotNil(EngineToggles.current(for: .gemini).timecodes.explanation, "причина объясняется")

        UserDefaults.standard.set(GeminiMode.smart.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        XCTAssertNotEqual(EngineToggles.current(for: .gemini).timecodes, .active)
        XCTAssertNotEqual(EngineToggles.current(for: .gemini).speakers, .active)
    }

    // MARK: - Готовность

    @MainActor
    func testCloudEngineWithoutKeyNeedsKey() {
        let directory = EngineDirectory(hasKey: { _ in false }, hasModel: { _ in true })

        XCTAssertEqual(directory.readiness(of: .gemini), .needsKey)
        XCTAssertEqual(directory.readiness(of: .gemini).badge, "Нет ключа")
        XCTAssertEqual(directory.readiness(of: .gigaam), .ready)
        XCTAssertNil(directory.readiness(of: .gigaam).badge, "у готового движка пометки нет")
    }

    @MainActor
    func testGigaAMWithoutWeightsNeedsDownload() {
        let directory = EngineDirectory(hasKey: { _ in true }, hasModel: { _ in false })

        XCTAssertEqual(directory.readiness(of: .gigaam), .needsDownload)
        XCTAssertEqual(directory.readiness(of: .gigaam).badge, "Скачать модель")
        XCTAssertEqual(directory.readiness(of: .apple), .ready, "системный движок готов всегда")
    }
}
