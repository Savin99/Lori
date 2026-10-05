import XCTest
@testable import LoriLocal

/// Настройки читаются из `UserDefaults.standard`, поэтому тест сам их и убирает:
/// иначе выбранный движок протёк бы в следующий тест.
final class TranscriptionSettingsTests: XCTestCase {
    private let keys = [
        TranscriptionSettings.engineKey,
        TranscriptionSettings.openAIBaseURLKey,
        TranscriptionSettings.openAIModelKey,
        TranscriptionSettings.geminiModelKey,
        TranscriptionSettings.geminiBaseURLKey,
        TranscriptionSettings.geminiModeKey,
        TranscriptionSettings.vocabularyKey,
        TranscriptionSettings.gigaAMVariantKey,
        TranscriptionSettings.timecodesKey,
        TranscriptionSettings.speakerLabelsKey,
        TranscriptionSettings.geminiPartKey,
        TranscriptionSettings.elevenLabsModeKey,
        TranscriptionSettings.elevenLabsModelKey,
        TranscriptionSettings.elevenLabsBaseURLKey,
    ]

    override func setUp() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func testEngineDefaultsToLocalGigaAM() {
        XCTAssertEqual(TranscriptionSettings.engine, .gigaam)
        UserDefaults.standard.set("gemini", forKey: TranscriptionSettings.engineKey)
        XCTAssertEqual(TranscriptionSettings.engine, .gemini)
        UserDefaults.standard.set("мусор", forKey: TranscriptionSettings.engineKey)
        XCTAssertEqual(TranscriptionSettings.engine, .gigaam, "неизвестное значение не должно ломать выбор")
    }

    func testOnlyCloudEnginesLeaveTheDevice() {
        XCTAssertFalse(TranscriptionEngineKind.gigaam.leavesDevice)
        XCTAssertFalse(TranscriptionEngineKind.apple.leavesDevice)
        XCTAssertTrue(TranscriptionEngineKind.openAI.leavesDevice)
        XCTAssertTrue(TranscriptionEngineKind.gemini.leavesDevice)
        XCTAssertTrue(TranscriptionEngineKind.elevenLabs.leavesDevice)
        XCTAssertNil(TranscriptionEngineKind.gigaam.keychainAccount)
        XCTAssertEqual(TranscriptionEngineKind.openAI.keychainAccount, .openAI)
        // Свой аккаунт, а не переиспользованный ключ: движки выбираются
        // независимо, и один ключ не имеет права затирать другой.
        XCTAssertEqual(TranscriptionEngineKind.elevenLabs.keychainAccount, .elevenLabs)
    }

    /// Настройки нового движка: модель, режим и адрес по умолчанию, и ни одна
    /// из них не ломается на мусоре в хранилище.
    func testElevenLabsDefaultsAndMode() {
        XCTAssertEqual(TranscriptionSettings.elevenLabsModel, "scribe_v2")
        XCTAssertEqual(TranscriptionSettings.elevenLabsMode, .verbatim)
        XCTAssertEqual(
            TranscriptionSettings.elevenLabsTranscriptionsURL.absoluteString,
            "https://api.elevenlabs.io/v1/speech-to-text"
        )
        XCTAssertEqual(TranscriptionSettings.describedTarget(for: .elevenLabs), "api.elevenlabs.io · scribe_v2")

        UserDefaults.standard.set("мусор", forKey: TranscriptionSettings.elevenLabsModeKey)
        XCTAssertEqual(TranscriptionSettings.elevenLabsMode, .verbatim, "неизвестный режим не должен ломать выбор")

        let clean = ElevenLabsMode.clean
        TranscriptionSettings.setMode(
            TranscriptionMode(id: clean.rawValue, title: clean.title, detail: clean.detail),
            for: .elevenLabs
        )
        XCTAssertEqual(TranscriptionSettings.elevenLabsMode, .clean)
        XCTAssertEqual(TranscriptionSettings.mode(for: .elevenLabs)?.id, clean.rawValue)
    }

    func testGigaAMVariantDefaultsToRNNT() {
        XCTAssertEqual(TranscriptionSettings.gigaAMVariant, .rnnt)
        UserDefaults.standard.set("ctc", forKey: TranscriptionSettings.gigaAMVariantKey)
        XCTAssertEqual(TranscriptionSettings.gigaAMVariant, .ctc)
        UserDefaults.standard.set("мусор", forKey: TranscriptionSettings.gigaAMVariantKey)
        XCTAssertEqual(TranscriptionSettings.gigaAMVariant, .rnnt, "неизвестный вариант не должен ломать выбор")
    }

    /// В шапке главного экрана и в настройках видно не «GigaAM», а какой именно вариант.
    func testDescribedTargetNamesTheVariant() {
        UserDefaults.standard.set("ctc", forKey: TranscriptionSettings.gigaAMVariantKey)
        XCTAssertEqual(TranscriptionSettings.describedTarget(for: .gigaam), GigaAMVariant.ctc.title)
        XCTAssertEqual(TranscriptionSettings.describedTarget(for: .apple), TranscriptionEngineKind.apple.title)
    }

    // MARK: - Режим Gemini и переключатели

    /// Режим прошёл круг: «Спикеры и таймкоды» были режимом, стали парой
    /// тумблеров и снова стали режимом. Обе прошлые формы обязаны привестись
    /// к нынешней — человек не должен замечать этих метаний.
    func testLegacyTimecodesModeBecomesSpeakersMode() {
        UserDefaults.standard.set("timecodes", forKey: TranscriptionSettings.geminiModeKey)

        TranscriptionSettings.migrateLegacyGeminiMode()

        XCTAssertEqual(TranscriptionSettings.geminiMode, .speakers)
    }

    /// Регрессия: «Точность» с включёнными старыми тумблерами раньше считалась
    /// прошлой формой режима «Спикеры и таймкоды» и приводилась к нему. Отличить
    /// её от осознанно выбранной «Точности» нечем, а вызов идёт на каждом
    /// запуске — владелец выбирал «Точность» на главной и после выхода из
    /// приложения получал обратно «Спикеры». Выбор человека сильнее.
    func testAccuracyStaysAccuracyWhateverTheOldTogglesSay() {
        UserDefaults.standard.set(GeminiMode.accuracy.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        UserDefaults.standard.set(true, forKey: TranscriptionSettings.timecodesKey)
        UserDefaults.standard.set(true, forKey: TranscriptionSettings.speakerLabelsKey)

        TranscriptionSettings.migrateLegacyGeminiMode()

        XCTAssertEqual(TranscriptionSettings.geminiMode, .accuracy)
    }

    /// Сохранённые «правильные» режимы миграция не трогает — включать людям
    /// говорящих без спроса нельзя.
    func testMigrationLeavesModernModesAlone() {
        UserDefaults.standard.set(GeminiMode.smart.rawValue, forKey: TranscriptionSettings.geminiModeKey)

        TranscriptionSettings.migrateLegacyGeminiMode()

        XCTAssertEqual(TranscriptionSettings.geminiMode, .smart)
        XCTAssertNil(UserDefaults.standard.object(forKey: TranscriptionSettings.speakerLabelsKey))
    }

    /// Выбранный на главной режим переживает перезапуск приложения. Миграция
    /// зовётся при каждом запуске, поэтому проверяется именно повтор вызова:
    /// один прогон её ничего не доказывает.
    func testChosenModeSurvivesRepeatedLaunches() throws {
        UserDefaults.standard.set(true, forKey: TranscriptionSettings.timecodesKey)
        UserDefaults.standard.set(true, forKey: TranscriptionSettings.speakerLabelsKey)

        for mode in GeminiMode.ordered {
            let chosen = try XCTUnwrap(
                EngineCatalog.descriptor(for: .gemini).modes.first { $0.id == mode.rawValue }
            )
            TranscriptionSettings.setMode(chosen, for: .gemini)

            TranscriptionSettings.migrateLegacyGeminiMode()
            TranscriptionSettings.migrateLegacyGeminiMode()

            XCTAssertEqual(TranscriptionSettings.geminiMode, mode, "режим «\(mode.title)» не дожил до второго запуска")
        }
    }

    /// Сырое значение может прийти в обход миграции — аргументом запуска.
    /// Читается оно так же, как мигрировало бы.
    func testRawLegacyValueReadsAsSpeakersMode() {
        UserDefaults.standard.set("timecodes", forKey: TranscriptionSettings.geminiModeKey)

        XCTAssertEqual(TranscriptionSettings.geminiMode, .speakers)
    }

    /// Прежние тумблеры на запрос не влияют вовсе: решает режим.
    func testTogglesDoNotReachTheRequestAnyMore() {
        UserDefaults.standard.set(GeminiMode.smart.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        UserDefaults.standard.set(true, forKey: TranscriptionSettings.timecodesKey)
        UserDefaults.standard.set(true, forKey: TranscriptionSettings.speakerLabelsKey)

        XCTAssertFalse(TranscriptionSettings.geminiWantsWordTimestamps)
        XCTAssertFalse(TranscriptionSettings.geminiWantsDiarization)
        XCTAssertEqual(TranscriptionSettings.geminiMaxSeconds, 60 * 60)
    }

    /// Предел одного запроса следует за режимом: таймкоды и говорящие режут
    /// час до получаса (документация Google).
    func testSpeakersModeHalvesTheRequestLimit() {
        UserDefaults.standard.set(GeminiMode.accuracy.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        XCTAssertEqual(TranscriptionSettings.geminiMaxSeconds, 60 * 60)

        UserDefaults.standard.set(GeminiMode.speakers.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        XCTAssertEqual(TranscriptionSettings.geminiMaxSeconds, 30 * 60)

        UserDefaults.standard.set(GeminiMode.smart.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        XCTAssertEqual(TranscriptionSettings.geminiMaxSeconds, 60 * 60)
    }

    // MARK: - Длина части

    func testPartDefaultsToTenMinutes() {
        XCTAssertEqual(TranscriptionSettings.geminiPartMinutes, TranscriptionSettings.defaultGeminiPart)
        XCTAssertEqual(TranscriptionSettings.geminiPartSeconds, 10 * 60)
    }

    func testPartOutsideTheRangeFallsBackToDefault() {
        UserDefaults.standard.set(600, forKey: TranscriptionSettings.geminiPartKey)
        XCTAssertEqual(TranscriptionSettings.geminiPartMinutes, TranscriptionSettings.defaultGeminiPart)

        UserDefaults.standard.set(1, forKey: TranscriptionSettings.geminiPartKey)
        XCTAssertEqual(TranscriptionSettings.geminiPartMinutes, TranscriptionSettings.defaultGeminiPart)
    }

    /// Больше, чем сервис берёт за раз, не отправляется никогда: там начинается
    /// его собственная нарезка, и она уже не про читаемость.
    func testPartIsCappedByTheServiceLimit() {
        UserDefaults.standard.set(60, forKey: TranscriptionSettings.geminiPartKey)
        UserDefaults.standard.set(GeminiMode.accuracy.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        XCTAssertEqual(TranscriptionSettings.geminiPartSeconds, 60 * 60)

        UserDefaults.standard.set(GeminiMode.speakers.rawValue, forKey: TranscriptionSettings.geminiModeKey)
        XCTAssertEqual(TranscriptionSettings.geminiPartSeconds, 30 * 60, "с таймкодами предел сервиса вдвое ниже")
    }

    // MARK: - Зеркало словаря

    /// Словарь пропадал целиком: настройки не доживают до диска, если процесс
    /// убить. Зеркало в рабочей папке переживает и это, и переустановку.
    func testLostVocabularyIsRestoredFromTheMirror() {
        TranscriptionSettings.mirrorVocabulary("MCP\nДуматель 2.0")
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.vocabularyKey)

        TranscriptionSettings.restoreVocabularyIfLost()

        XCTAssertEqual(TranscriptionSettings.vocabulary, ["MCP", "Думатель 2.0"])
        try? FileManager.default.removeItem(at: TranscriptionSettings.vocabularyMirror)
    }

    /// Обратное направление опаснее: вернуть слова человеку, который их удалил,
    /// значит спорить с ним. Что в настройках — то и правда.
    func testExistingVocabularyIsNeverOverwrittenByTheMirror() {
        TranscriptionSettings.mirrorVocabulary("Старое")
        UserDefaults.standard.set("Новое", forKey: TranscriptionSettings.vocabularyKey)

        TranscriptionSettings.restoreVocabularyIfLost()

        XCTAssertEqual(TranscriptionSettings.vocabulary, ["Новое"])
        try? FileManager.default.removeItem(at: TranscriptionSettings.vocabularyMirror)
    }

    func testEmptyMirrorRestoresNothing() {
        TranscriptionSettings.mirrorVocabulary("   ")
        UserDefaults.standard.removeObject(forKey: TranscriptionSettings.vocabularyKey)

        TranscriptionSettings.restoreVocabularyIfLost()

        XCTAssertEqual(TranscriptionSettings.vocabulary, [])
        try? FileManager.default.removeItem(at: TranscriptionSettings.vocabularyMirror)
    }

    func testModelNamesFallBackToDefaults() {
        XCTAssertEqual(TranscriptionSettings.openAIModel, TranscriptionSettings.defaultOpenAIModel)
        XCTAssertEqual(TranscriptionSettings.geminiModel, TranscriptionSettings.defaultGeminiModel)

        UserDefaults.standard.set("   ", forKey: TranscriptionSettings.openAIModelKey)
        XCTAssertEqual(TranscriptionSettings.openAIModel, TranscriptionSettings.defaultOpenAIModel, "пробелы — это не имя модели")

        UserDefaults.standard.set("gpt-4o-transcribe", forKey: TranscriptionSettings.openAIModelKey)
        XCTAssertEqual(TranscriptionSettings.openAIModel, "gpt-4o-transcribe")
    }

    func testBaseURLAcceptsOnlyHTTPAddresses() {
        XCTAssertNil(TranscriptionSettings.url(from: ""))
        XCTAssertNil(TranscriptionSettings.url(from: "  "))
        XCTAssertNil(TranscriptionSettings.url(from: "ftp://example.com"))
        XCTAssertNil(TranscriptionSettings.url(from: "просто текст"))
        XCTAssertEqual(TranscriptionSettings.url(from: "http://192.168.1.10:1234/v1/")?.absoluteString, "http://192.168.1.10:1234/v1")

        UserDefaults.standard.set("мусор", forKey: TranscriptionSettings.openAIBaseURLKey)
        XCTAssertEqual(TranscriptionSettings.openAIBaseURL.absoluteString, TranscriptionSettings.defaultOpenAIBaseURL)

        UserDefaults.standard.set("https://api.groq.com/openai/v1", forKey: TranscriptionSettings.openAIBaseURLKey)
        XCTAssertEqual(
            TranscriptionSettings.openAITranscriptionsURL.absoluteString,
            "https://api.groq.com/openai/v1/audio/transcriptions"
        )
    }

    /// Гео-блок Google лечится только своим адресом, поэтому он обязан быть настройкой.
    func testGeminiHostIsConfigurable() {
        XCTAssertEqual(TranscriptionSettings.geminiHost.absoluteString, TranscriptionSettings.defaultGeminiHost)
        XCTAssertFalse(TranscriptionSettings.geminiUsesCustomHost)

        UserDefaults.standard.set("https://lori.example.net/gemini/", forKey: TranscriptionSettings.geminiBaseURLKey)
        XCTAssertTrue(TranscriptionSettings.geminiUsesCustomHost)
        XCTAssertEqual(
            TranscriptionSettings.geminiInteractionsURL.absoluteString,
            "https://lori.example.net/gemini/v1beta/interactions"
        )
        XCTAssertEqual(
            TranscriptionSettings.geminiModelsURL.absoluteString,
            "https://lori.example.net/gemini/v1beta/models"
        )
        XCTAssertTrue(TranscriptionSettings.describedTarget(for: .gemini).contains("lori.example.net"))
    }

    /// Адрес загрузки сервис возвращает на своём хосте: через прокси по нему идти
    /// бессмысленно, он снова упрётся в тот же блок.
    func testUploadAddressIsRoutedThroughTheCustomHost() {
        let google = "https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=42"
        XCTAssertEqual(GeminiTranscriber.routed(google)?.absoluteString, google, "без своего адреса ничего не меняем")

        UserDefaults.standard.set("https://lori.example.net", forKey: TranscriptionSettings.geminiBaseURLKey)
        XCTAssertEqual(
            GeminiTranscriber.routed(google)?.absoluteString,
            "https://lori.example.net/upload/v1beta/files?upload_id=42"
        )
    }

    /// Человек читает «User location is not supported» и думает, что дело в ключе.
    func testRegionBlockIsExplainedInRussian() {
        let google = APICheck.explain("User location is not supported for the API use.")
        XCTAssertTrue(google.contains("региона"), google)
        XCTAssertTrue(google.contains("User location is not supported"), "текст сервиса нужно сохранить")

        let openAI = APICheck.explain("Country, region, or territory not supported")
        XCTAssertTrue(openAI.contains("региона"), openAI)

        XCTAssertEqual(APICheck.explain("Incorrect API key provided"), "Incorrect API key provided")

        // Дорожки пробелов от склейки строк человек уже видел на телефоне —
        // проверяем, что сообщение выглядит как текст, а не как исходник.
        for text in [google, openAI] {
            XCTAssertFalse(text.contains("  "), "в сообщении лишние пробелы: \(text)")
            XCTAssertFalse(text.contains("\n"), "сообщение должно быть одной строкой: \(text)")
        }
    }

    func testVocabularyIsParsedFromLinesAndCommas() {
        UserDefaults.standard.set("Кайрос\nИнтегра-4D, ЛОС\nкайрос;  \n", forKey: TranscriptionSettings.vocabularyKey)
        XCTAssertEqual(TranscriptionSettings.vocabulary, ["Кайрос", "Интегра-4D", "ЛОС"], "повторы отбрасываются без учёта регистра")
        XCTAssertEqual(TranscriptionSettings.vocabularyHint, "Кайрос, Интегра-4D, ЛОС")
    }

    func testVocabularyIsCutAtTheLimit() {
        let long = (1...300).map { "Термин\($0)" }.joined(separator: "\n")
        UserDefaults.standard.set(long, forKey: TranscriptionSettings.vocabularyKey)
        let terms = TranscriptionSettings.vocabulary
        XCTAssertFalse(terms.isEmpty)
        XCTAssertLessThan(terms.count, 300, "длинный словарь вытеснил бы саму расшифровку")
        XCTAssertLessThanOrEqual(TranscriptionSettings.vocabularyHint.count, TranscriptionSettings.vocabularyLimit)
    }

    func testEmptyVocabularyGivesNoHint() {
        XCTAssertTrue(TranscriptionSettings.vocabulary.isEmpty)
        XCTAssertTrue(TranscriptionSettings.vocabularyHint.isEmpty)
    }
}
