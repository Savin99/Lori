import XCTest
@testable import LoriLocal

@MainActor
final class DeviceSummaryIntegrationTests: XCTestCase {
    func testInstalledModelGeneratesDescriptionAndPreservesManualTitle() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("MLX generation is verified on the physical iPhone")
        #else
        let url = FileManager.default.temporaryDirectory.appending(path: "summary-device-\(UUID().uuidString).json")
        let store = SummaryStore(url: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: store.pendingQueueURL)
        }
        let runner = SummaryRunner(models: SummaryModelStore(), store: store)
        try XCTSkipUnless(runner.choose() != nil, "No installed summary model or insufficient memory")
        store.setManual(title: "Контрольное интервью", for: "synthetic.m4a")
        runner.summarize(path: "synthetic.m4a", text: "На встрече обсудили подготовку выставки. Анна отвечает за фотографии, а Павел готовит подписи к экспонатам. Монтаж начнётся в понедельник утром. Все материалы нужно проверить до пятницы. Следующую встречу назначили на среду, чтобы согласовать оставшиеся вопросы.")
        runner.summarize(path: "automatic.m4a", text: "Обсудили переезд офиса в новое помещение. Коробки и мебель перевезут в субботу. В пятницу сотрудники должны подписать свои вещи и отключить компьютеры. За доступ в новое здание отвечает администратор. В понедельник все начинают работу по новому адресу.")
        let deadline = Date().addingTimeInterval(120)
        while runner.pendingCount > 0 && runner.failure == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        runner.applicationWillResignActive()
        XCTAssertNil(runner.failure)
        XCTAssertEqual(runner.pendingCount, 0, runner.waitingReason ?? "Timed out")
        let reloaded = SummaryStore(url: url)
        XCTAssertEqual(reloaded.title(for: "synthetic.m4a"), "Контрольное интервью")
        XCTAssertFalse((reloaded.detail(for: "synthetic.m4a") ?? "").isEmpty)
        let title = try XCTUnwrap(reloaded.title(for: "automatic.m4a"))
        XCTAssertFalse(title.isEmpty)
        XCTAssertFalse(Summarizer.looksLikeTemplate(title))
        XCTAssertLessThanOrEqual(title.count, Summarizer.titleLimit + 1)
        XCTAssertFalse((reloaded.detail(for: "automatic.m4a") ?? "").isEmpty)
        print("Synthetic recording received an on-device title: \(title)")
        #endif
    }
}
