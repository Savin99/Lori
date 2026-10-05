import BackgroundTasks
import XCTest
@testable import LoriLocal

/// Про фон: строка под полосой прогресса и перевод отказов системы.
///
/// Саму фоновую задачу здесь не проверить — `BGTaskScheduler` в симуляторе
/// недоступен по документации, и это ровно то, что проверяет
/// `testSimulatorFallsBackToForegroundOnly`: приложение обязано честно сказать,
/// что фона нет, а не молча обещать его.
@MainActor
final class TranscriptionRunwayTests: XCTestCase {
    func testSubtitleNamesTheRecordAndTheCounter() {
        XCTAssertEqual(
            TranscriptionRunway.subtitle(done: 1, total: 5, current: "Recordings/Совещание 27.08.m4a"),
            "2 из 5 · Совещание 27.08"
        )
        XCTAssertEqual(
            TranscriptionRunway.subtitle(done: 0, total: 1, current: "Recordings/Планёрка.m4a"),
            "Планёрка",
            "на одной записи счётчик «1 из 1» ничего не добавляет"
        )
        XCTAssertEqual(
            TranscriptionRunway.subtitle(done: 4, total: 3, current: nil),
            "3 из 3",
            "счётчик не имеет права перескочить итог"
        )
    }

    /// Идентификатор один и тот же в трёх местах, и форма у него базовая, без `.*`.
    ///
    /// Обе половины этого стоили живого прогона на телефоне. Форма с шаблоном в
    /// `Info.plist` ломает регистрацию целиком («is not advertised in the application's
    /// Info.plist»). А составная заявка `<база>.<uuid>` к базовой регистрации не
    /// привязывается — планировщик отвечает кодом 3 и «Unrecognized Identifier»,
    /// и полосы прогресса не появляется вовсе.
    func testTaskIdentifierIsTheBaseFormAndMatchesTheBundle() throws {
        let declared = try XCTUnwrap(
            Bundle(for: TranscriptionService.self)
                .object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        )
        XCTAssertTrue(
            declared.contains(TranscriptionRunway.taskIdentifier),
            "в Info.plist нет \(TranscriptionRunway.taskIdentifier): \(declared)"
        )
        XCTAssertFalse(
            TranscriptionRunway.taskIdentifier.hasSuffix(".*"),
            "форма с шаблоном в Info.plist ломает регистрацию целиком"
        )
        XCTAssertFalse(
            declared.contains { $0.hasSuffix(".*") },
            "ни одной записи с шаблоном в Info.plist быть не должно: \(declared)"
        )
        XCTAssertTrue(
            TranscriptionRunway.taskIdentifier.hasPrefix("ru.ilyaqa.lori.local"),
            "идентификатор обязан начинаться с идентификатора приложения"
        )
    }

    /// Регистрация обязана быть принята: иначе первая же пачка уронила бы приложение
    /// на `submit`, а не осталась бы без фона.
    func testHandlerRegistrationIsAccepted() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("фоновая задача есть с iOS 26") }
        XCTAssertTrue(
            TranscriptionRunway.isRegistered,
            "планировщик не принял \(TranscriptionRunway.taskIdentifier)"
        )
    }

    func testBackgroundModeIsDeclared() throws {
        let modes = try XCTUnwrap(
            Bundle(for: TranscriptionService.self)
                .object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        )
        XCTAssertTrue(modes.contains("processing"), "без режима «processing» заявку не примут: \(modes)")
    }

    /// Отказ системы должен читаться человеком, а не кодом ошибки.
    func testSchedulerRefusalsAreTranslated() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("коды планировщика есть с iOS 26") }
        func explain(_ code: BGTaskScheduler.Error.Code) -> String {
            TranscriptionRunway.explain(
                NSError(domain: BGTaskScheduler.errorDomain, code: code.rawValue)
            )
        }
        XCTAssertTrue(explain(.unavailable).contains("Обновление контента"), explain(.unavailable))
        // Симулятор и телефон отвечают одним кодом `notPermitted` — проверено живым
        // прогоном на обоих. Куда идти человеку, дописывает `remedy()` по факту.
        XCTAssertTrue(explain(.notPermitted).contains("запретила"), explain(.notPermitted))
        XCTAssertTrue(
            TranscriptionRunway.remedy().contains("симулятор"),
            "в симуляторе подсказка обязана говорить, что здесь это не проверяется"
        )
        XCTAssertTrue(explain(.immediateRunIneligible).contains("занят"), explain(.immediateRunIneligible))
        for code in [BGTaskScheduler.Error.Code.unavailable, .notPermitted, .tooManyPendingTaskRequests] {
            XCTAssertFalse(explain(code).contains("  "), "двойной пробел из многострочного литерала")
        }
    }

    /// В симуляторе фона нет, и приложение обязано сказать это словами.
    func testSimulatorFallsBackToForegroundOnly() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("проверка про симулятор")
        #else
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LoriRunway-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceStore(rootURL: root)
        workspace.start()
        try Data("не настоящее аудио".utf8).write(to: root.appending(path: "Запись.m4a"))
        try workspace.refresh()

        // Свой файл прерванных обязателен: тестовый хост живёт в контейнере
        // настоящего приложения, и запись из теста иначе попадёт в его список —
        // и приложение поставит фикстуру в очередь при следующем запуске. Такое
        // уже случилось в журнале.
        let store = FileManager.default.temporaryDirectory
            .appending(path: "LoriRunwayStore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }
        let service = TranscriptionService(engines: [.gigaam: InstantEngine()], interruptedStore: store)
        let runway = TranscriptionRunway(service: service)
        service.runway = runway

        service.enqueue(try workspace.entry(at: "Запись.m4a"), in: workspace, using: .gigaam)
        await service.waitForDrain()

        guard case let .foregroundOnly(reason) = runway.state else {
            return XCTFail("в симуляторе фоновой задачи не бывает, состояние: \(runway.state)")
        }
        XCTAssertFalse(reason.isEmpty)
        #endif
    }
}

private struct InstantEngine: Transcribing {
    let name = "Мгновенный"
    func isAvailable() async -> Bool { true }
    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        Transcript(text: "готово")
    }
}
