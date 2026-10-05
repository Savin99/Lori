import XCTest
@testable import LoriLocal

/// Проверочный движок для снимков: включается только в Lori QA и только по
/// аргументу запуска, а считает как настоящий — долями, с отменой и ошибкой.
final class QAStubEngineTests: XCTestCase {
    /// Личное приложение не включает заглушку ни с каким аргументом.
    func testPersonalAppNeverGetsTheStub() {
        XCTAssertFalse(QAStubEngine.isAllowed(bundleID: "ru.ilyaqa.lori.local", arguments: ["--ui-stub-engine"]))
        XCTAssertFalse(QAStubEngine.isAllowed(bundleID: nil, arguments: ["--ui-stub-engine"]))
        XCTAssertFalse(QAStubEngine.isAllowed(bundleID: "ru.ilyaqa.lori.local.qa.extra", arguments: ["--ui-stub-engine"]))
    }

    /// Lori QA без аргумента считает настоящими движками.
    func testQAAppNeedsTheArgument() {
        XCTAssertFalse(QAStubEngine.isAllowed(bundleID: "ru.ilyaqa.lori.local.qa", arguments: []))
        XCTAssertFalse(QAStubEngine.isAllowed(bundleID: "ru.ilyaqa.lori.local.qa", arguments: ["--recovery-probe"]))
        XCTAssertTrue(QAStubEngine.isAllowed(bundleID: "ru.ilyaqa.lori.local.qa", arguments: ["-x", "--ui-stub-engine"]))
    }

    /// Хост юнит-тестов — Lori QA, но без аргумента: в тестах заглушка выключена.
    func testUnitTestHostIsNotStubbed() {
        XCTAssertFalse(QAStubEngine.enabled)
    }

    func testSecondsComeFromTheArgument() {
        XCTAssertEqual(QAStubEngine.seconds(in: ["--ui-stub-seconds", "8"]), 8)
        XCTAssertEqual(QAStubEngine.seconds(in: ["--ui-stub-seconds"]), QAStubEngine.defaultSeconds)
        XCTAssertEqual(QAStubEngine.seconds(in: ["--ui-stub-seconds", "-3"]), QAStubEngine.defaultSeconds)
        XCTAssertEqual(QAStubEngine.seconds(in: ["--ui-stub-seconds", "9999"]), 600, "потолок — десять минут")
    }

    /// Заглушка стоит за каждым движком: облачный без ключа не остановит пачку.
    func testStubStandsBehindEveryEngine() async {
        let engines = QAStubEngine.engines(seconds: 1)
        XCTAssertEqual(Set(engines.keys), Set(TranscriptionEngineKind.allCases))
        for engine in engines.values {
            let available = await engine.isAvailable()
            XCTAssertTrue(available)
        }
    }

    /// Расшифровка правдоподобная: реплики двух говорящих с диапазонами времени —
    /// экран записи и экспорт видят то же, что после настоящего движка.
    func testTranscriptHasTimecodesAndSpeakers() async throws {
        let stub = QAStubTranscriber(seconds: 0.05, steps: 4)
        let shares = Shares()
        let transcript = try await stub.transcribe(
            audioURL: URL(fileURLWithPath: "/tmp/Совещание.m4a"),
            progress: { done, total in shares.add(TranscriptionService.fraction(done: done, total: total)) },
            partial: { _ in },
            note: { _ in }
        )
        let document = TranscriptDocument.parse(transcript.markdown(title: "Совещание", engine: stub.name))
        XCTAssertTrue(document.hasTimecodes)
        XCTAssertEqual(Set(document.lines.compactMap(\.speaker)), ["S1", "S2"])
        XCTAssertEqual(document.engineStayedOnDevice, true, "звук никуда не уходит — и подпись это говорит")
        XCTAssertEqual(shares.values.compactMap { $0 }.last, 1, "сотню ставит только конец работы")
        XCTAssertEqual(shares.values.first ?? nil, 0, "начинаем с нуля, а не с первого куска")
    }

    /// Разные записи — разные разговоры: иначе в списке все заголовки одинаковы.
    func testDifferentNamesGetDifferentConversations() {
        let names = ["Совещание по бюджету", "Интервью Маши", "Звонок поставщику", "Разбор отзывов", "Планёрка"]
        let titles = Set(names.map { TranscriptTitle.title(from: QAStubTranscriber.transcript(for: $0).markdown(title: $0)) })
        XCTAssertGreaterThan(titles.count, 2)
        XCTAssertEqual(
            QAStubTranscriber.stableIndex(of: "Интервью Маши", count: 5),
            QAStubTranscriber.stableIndex(of: "Интервью Маши", count: 5),
            "номер не зависит от запуска"
        )
    }

    /// «fail» в имени — ошибка движка, а не обрыв связи: на карточке «Повторить».
    func testFailNameFails() async {
        let stub = QAStubTranscriber(seconds: 0.05, steps: 6)
        do {
            _ = try await stub.transcribe(audioURL: URL(fileURLWithPath: "/tmp/Звонок (fail).m4a"))
            XCTFail("файл с «fail» в имени обязан упасть")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .api("Нет связи с сервисом. Проверь интернет и нажми «Повторить»."))
        } catch {
            XCTFail("ошибка не та: \(error)")
        }
    }

    /// «Остановить» снимает заглушку так же, как настоящий движок.
    func testCancellationStopsTheStub() async {
        let stub = QAStubTranscriber(seconds: 30)
        let task = Task { try await stub.transcribe(audioURL: URL(fileURLWithPath: "/tmp/Длинная.m4a")) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        switch result {
        case .success: XCTFail("отменённая заглушка не должна дойти до конца")
        case let .failure(error): XCTAssertTrue(error is CancellationError, "ожидалась отмена, пришло \(error)")
        }
    }
}

/// Доли прогресса из колбэка — под замком: колбэк `@Sendable`.
private final class Shares: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double?] = []

    func add(_ value: Double?) { lock.withLock { stored.append(value) } }
    var values: [Double?] { lock.withLock { stored } }
}
