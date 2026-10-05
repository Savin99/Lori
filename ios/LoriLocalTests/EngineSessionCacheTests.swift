import XCTest
@testable import LoriLocal

/// Общая модель на пачку записей.
///
/// Настоящие веса в репозиторий не входят, поэтому счётчик пользователей и выгрузка
/// проверяются на живой модели GigaAM, если она установлена, и пропускаются, если нет —
/// как и остальные интеграционные тесты. Подделать `WhisperKit` или `ORTSession`
/// нечем: смысл кеша ровно в том, что он держит настоящие веса.
final class EngineSessionCacheTests: XCTestCase {
    func testIdleCacheHoldsNothing() async {
        let cache = EngineSessionCache()
        await cache.dropIdle()
        let inventory = await cache.inventory()
        XCTAssertEqual(inventory.loaded, 0)
        XCTAssertEqual(inventory.users, 0)
    }

    /// Две записи подряд берут одну и ту же загруженную модель, и после последней
    /// она уходит: 618 МБ Whisper в покое стоят дороже повторной загрузки.
    func testTwoRecordsShareOneLoadedModel() async throws {
        let variant = GigaAMVariant.ctc
        try XCTSkipUnless(
            GigaAMModelSet.locate(variant) != nil,
            "модель \(variant.title) не установлена — прогони design/gigaam/seed-models.sh"
        )
        let models = try XCTUnwrap(GigaAMModelSet.locate(variant))
        let cache = EngineSessionCache()

        let first = try await cache.leaseGigaAM(models)
        let second = try await cache.leaseGigaAM(models)
        XCTAssertTrue(first === second, "вторая запись обязана получить те же веса, а не свою копию")
        var inventory = await cache.inventory()
        XCTAssertEqual(inventory.loaded, 1)
        XCTAssertEqual(inventory.users, 2)

        // Пока хоть кто-то пользуется, выгружать нельзя.
        await cache.releaseGigaAM(variant)
        await cache.dropIdle()
        inventory = await cache.inventory()
        XCTAssertEqual(inventory.loaded, 1, "одна запись ещё считает")

        await cache.releaseGigaAM(variant)
        await cache.dropIdle()
        inventory = await cache.inventory()
        XCTAssertEqual(inventory.loaded, 0)
        XCTAssertEqual(inventory.users, 0)
    }

    /// Неудачная загрузка не имеет права оставить счётчик поднятым: модель, которой
    /// нет, навсегда осталась бы «занятой», и выгрузить её было бы нечем.
    func testFailedLoadDoesNotLeakAUser() async {
        let cache = EngineSessionCache()
        let missing = GigaAMModelSet(
            variant: .ctc,
            directory: FileManager.default.temporaryDirectory
                .appending(path: "нет-такой-папки-\(UUID().uuidString)", directoryHint: .isDirectory)
        )
        do {
            _ = try await cache.leaseGigaAM(missing)
            XCTFail("папки нет — загрузка обязана упасть")
        } catch {
            let inventory = await cache.inventory()
            XCTAssertEqual(inventory.users, 0, "счётчик обязан вернуться назад")
            XCTAssertEqual(inventory.loaded, 0)
        }
    }
}
