import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import LoriLocal

/// Несколько аудио в буфере: считаются по типам без чтения, забираются все, по очереди,
/// со своими именами — и пять вставленных за одну секунду не сливаются в один.
final class ClipboardBatchTests: XCTestCase {
    private let manager = FileManager.default
    private var pasteboard: UIPasteboard!
    private var outside: URL!

    override func setUpWithError() throws {
        try? manager.removeItem(at: ImportInbox.staging)
        pasteboard = UIPasteboard(name: UIPasteboard.Name("ru.ilyaqa.lori.tests.batch.\(UUID().uuidString)"), create: true)
        outside = manager.temporaryDirectory.appending(path: "LoriClipboardTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UIPasteboard.remove(withName: pasteboard.name)
        try? manager.removeItem(at: outside)
        try? manager.removeItem(at: ImportInbox.staging)
    }

    private let mp3 = "public.mp3"
    private let m4a = "com.apple.m4a-audio"
    private let wav = "com.microsoft.waveform-audio"

    /// Готовые данные в элементах — так кладёт мессенджер.
    private func putData(_ items: [(type: String, bytes: [UInt8])]) {
        pasteboard.setItems(items.map { [$0.type: Data($0.bytes)] }, options: [:])
    }

    private func outsideFile(_ name: String, bytes: [UInt8]) throws -> URL {
        let url = outside.appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - Подсчёт без чтения

    func testInventoryCountsAudioItemsByTypeOnly() {
        putData([(mp3, [1]), (m4a, [2]), (wav, [3]), (mp3, [4]), (m4a, [5])])

        let inventory = ClipboardAudio.inventory(in: pasteboard)

        XCTAssertEqual(inventory.audio, 5)
        XCTAssertEqual(inventory.fileReferences, 0)
        XCTAssertFalse(inventory.isEmpty)
        XCTAssertEqual(inventory.hint, "В буфере 5 аудио")
    }

    /// Главное: считать можно, **не читая** — ни один поставщик не запрошен. Чтение
    /// показало бы системную плашку о вставке, а человек ещё ничего не нажимал.
    ///
    /// Нюанс симулятора: `setItemProviders` на именованном буфере вычитывает обещания сама
    /// система, сразу после записи и не на нашем потоке (на телефоне, между приложениями,
    /// они ленивые). Поэтому тест сначала дожидается, пока система закончит, и считает не
    /// «ноль чтений», а «ни одного **нового** чтения после подсчёта».
    func testCountingNeverAsksAProviderForItsData() async throws {
        final class Reads: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func note() { lock.withLock { count += 1 } }
            var value: Int { lock.withLock { count } }
        }
        let reads = Reads()
        let source = outside!
        let providers = (1...3).map { number -> NSItemProvider in
            let provider = NSItemProvider()
            provider.suggestedName = "Запись \(number)"
            provider.registerFileRepresentation(forTypeIdentifier: m4a, fileOptions: [], visibility: .all) { completion in
                reads.note()
                let file = source.appending(path: "\(UUID().uuidString).m4a")
                try? Data([UInt8(number)]).write(to: file)
                completion(file, false, nil)
                return nil
            }
            return provider
        }
        pasteboard.setItemProviders(providers, localOnly: true, expirationDate: nil)
        let deadline = Date().addingTimeInterval(3)
        while reads.value < providers.count, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let before = reads.value

        let inventory = ClipboardAudio.inventory(in: pasteboard)
        _ = ClipboardAudio.content(in: pasteboard)

        XCTAssertEqual(inventory.audio, 3, "обещания файлов видны по типам")
        XCTAssertEqual(reads.value, before, "подсчёт не прочитал ни одного поставщика")
    }

    func testHintWording() {
        XCTAssertNil(ClipboardAudio.Inventory(audio: 0, fileReferences: 3).hint, "ссылки подсказкой не предлагаются")
        XCTAssertEqual(ClipboardAudio.Inventory(audio: 1).hint, "В буфере есть аудио", "как было для одного")
        XCTAssertEqual(ClipboardAudio.Inventory(audio: 2).hint, "В буфере 2 аудио")
        XCTAssertEqual(ClipboardAudio.Inventory(audio: 5).hint, "В буфере 5 аудио")
        XCTAssertEqual(ClipboardAudio.Inventory(audio: 21).hint, "В буфере 21 аудио", "слово не склоняется")
    }

    func testInventoryOfAnEmptyBufferIsEmpty() {
        let inventory = ClipboardAudio.inventory(in: pasteboard)

        XCTAssertTrue(inventory.isEmpty)
        XCTAssertNil(inventory.hint)
    }

    func testInventoryIgnoresNonAudioItemsAndCountsFileReferencesApart() {
        pasteboard.setItems([
            [UTType.plainText.identifier: "просто текст"],
            [mp3: Data([1])],
            [UTType.fileURL.identifier: URL(fileURLWithPath: "/tmp/Совещание.m4a")],
        ], options: [:])

        let inventory = ClipboardAudio.inventory(in: pasteboard)

        XCTAssertEqual(inventory.audio, 1)
        XCTAssertEqual(inventory.fileReferences, 1)
        XCTAssertEqual(inventory.hint, "В буфере есть аудио")
    }

    /// Аудио во втором элементе тоже видно: раньше смотрели только на первый.
    func testAudioInALaterItemIsSeen() {
        pasteboard.setItems([
            [UTType.plainText.identifier: "заголовок"],
            [mp3: Data([1])],
        ], options: [:])

        XCTAssertEqual(ClipboardAudio.content(in: pasteboard), .audio)
        XCTAssertEqual(ClipboardAudio.inventory(in: pasteboard).audio, 1)
    }

    // MARK: - Все элементы

    func testTakeAllTakesEveryItemInBufferOrder() async throws {
        putData([(mp3, [1]), (m4a, [2]), (wav, [3]), (mp3, [4]), (m4a, [5])])

        let urls = try await ClipboardAudio.takeAll(from: pasteboard)

        XCTAssertEqual(urls.count, 5)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, [[1], [2], [3], [4], [5]].map { Data($0) }, "порядок буфера")
        XCTAssertEqual(urls.map(\.pathExtension), ["mp3", "m4a", "wav", "mp3", "m4a"])
        XCTAssertTrue(urls.allSatisfy(ImportInbox.isStaged), "всё ложится в ту же промежуточную папку")
    }

    /// Раньше имя было «Вставленное <секунды>»: пять файлов за одну секунду получали одно
    /// имя и сливались в один — а панель ещё и склеивала их по адресу.
    func testFilesPastedInTheSameSecondKeepDistinctNames() async throws {
        putData([(mp3, [1]), (mp3, [2]), (mp3, [3]), (mp3, [4]), (mp3, [5])])

        let urls = try await ClipboardAudio.takeAll(from: pasteboard)

        XCTAssertEqual(Set(urls.map(\.lastPathComponent)).count, 5, "пять разных имён")
        XCTAssertEqual(
            urls.map(\.lastPathComponent),
            ["Вставленное.mp3", "Вставленное 2.mp3", "Вставленное 3.mp3", "Вставленное 4.mp3", "Вставленное 5.mp3"]
        )
        XCTAssertEqual(ImportInbox.waiting().count, 5, "и все пять лежат, ни один не затёрт")
    }

    /// Вставили, не успели отправить, вставили снова — вторая пачка не затирает первую.
    func testSecondPasteDoesNotOverwriteTheFirst() async throws {
        putData([(mp3, [1])])
        let first = try await ClipboardAudio.takeAll(from: pasteboard)
        putData([(mp3, [2])])

        let second = try await ClipboardAudio.takeAll(from: pasteboard)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first[0]), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second[0]), Data([2]))
    }

    func testPlainItemsAndAudioTogetherOnlyAudioIsTaken() async throws {
        pasteboard.setItems([
            [UTType.plainText.identifier: "просто текст"],
            [mp3: Data([1])],
            [UTType.png.identifier: Data([9, 9])],
            [m4a: Data([2])],
        ], options: [:])

        let result = try await ClipboardAudio.takeBatch(from: pasteboard)

        XCTAssertEqual(result.urls.count, 2)
        XCTAssertTrue(result.skipped.isEmpty, "не аудио — не отказ, а «не наше»")
    }

    func testTakeAllFromAnEmptyBufferFailsAsBefore() async {
        await assertThrowsAsync(try await ClipboardAudio.takeAll(from: pasteboard)) { error in
            XCTAssertEqual(error as? ClipboardAudioError, .notAudio([]))
        }
    }

    func testTakeAllWithoutAnyAudioNamesWhatWasThere() async {
        pasteboard.string = "просто текст"

        await assertThrowsAsync(try await ClipboardAudio.takeAll(from: pasteboard)) { error in
            guard case let .notAudio(types)? = error as? ClipboardAudioError else {
                return XCTFail("ожидалась ошибка «нет аудио», а пришло \(error)")
            }
            XCTAssertFalse(types.isEmpty, "типы видны в тексте ошибки")
        }
    }

    /// Прежний вызов остаётся: берёт первое и **не трогает остальные** — они не копируются
    /// и не остаются лежать в промежуточной папке.
    func testTakeStillReturnsOnlyTheFirstFile() async throws {
        putData([(mp3, [1]), (m4a, [2]), (wav, [3])])

        let url = try await ClipboardAudio.take(from: pasteboard)

        XCTAssertEqual(try Data(contentsOf: url), Data([1]))
        XCTAssertEqual(ImportInbox.waiting().count, 1, "остальные элементы не скопированы")
    }

    // MARK: - Форматы

    /// Одно неподдерживаемое не отменяет остальных — и не пропадает молча.
    func testUnsupportedItemIsSkippedWithAReasonAndTheRestAreTaken() async throws {
        putData([(mp3, [1]), ("org.xiph.ogg-audio", [2]), (m4a, [3])])

        let result = try await ClipboardAudio.takeBatch(from: pasteboard)

        XCTAssertEqual(result.urls.count, 2)
        XCTAssertEqual(try result.urls.map { try Data(contentsOf: $0) }, [Data([1]), Data([3])])
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.skipped[0].index, 1)
        let refusal = result.skipped[0].error as? ImportError
        XCTAssertEqual(refusal, .unsupportedFormat(fileName: "Вставленное.ogg"))
        XCTAssertTrue(result.messages[0].contains(".ogg"), result.messages[0])
        XCTAssertEqual(ImportInbox.waiting().count, 2, "негодное в папку не попало")
        let all = try await ClipboardAudio.takeAll(from: pasteboard)
        XCTAssertEqual(all.count, 2, "takeAll при частичном успехе не бросает")
    }

    func testOnlyUnsupportedItemsFailWithTheFormatMessage() async {
        putData([("org.xiph.ogg-audio", [1]), ("org.xiph.flac", [2])])

        await assertThrowsAsync(try await ClipboardAudio.takeAll(from: pasteboard)) { error in
            XCTAssertEqual(error as? ImportError, .unsupportedFormat(fileName: "Вставленное.ogg"))
        }
        XCTAssertEqual(ImportInbox.waiting(), [], "ничего не осталось лежать")
    }

    // MARK: - Обещания файлов и ссылки

    /// Так кладёт «Файлы»: тип объявлен, а файл отдаёт поставщик. Каждый забирается в
    /// порядке буфера и прямо в колбэке — позже временной копии уже не будет.
    func testFilesFromProvidersAreTakenInBufferOrder() async throws {
        let source = outside!
        let providers = ["Лекция 1", "Лекция 2", "Лекция 3"].enumerated().map { index, title -> NSItemProvider in
            let provider = NSItemProvider()
            provider.suggestedName = title
            provider.registerFileRepresentation(forTypeIdentifier: m4a, fileOptions: [], visibility: .all) { completion in
                let file = source.appending(path: "\(UUID().uuidString).m4a")
                do {
                    try Data([UInt8(index + 1)]).write(to: file)
                    completion(file, false, nil)
                } catch {
                    completion(nil, false, error)
                }
                return nil
            }
            return provider
        }
        pasteboard.setItemProviders(providers, localOnly: true, expirationDate: nil)

        let urls = try await ClipboardAudio.takeAll(from: pasteboard)

        XCTAssertEqual(urls.map(\.lastPathComponent), ["Лекция 1.m4a", "Лекция 2.m4a", "Лекция 3.m4a"])
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, [Data([1]), Data([2]), Data([3])])
    }

    /// Имена берутся у источника, а не придумываются: человек узнаёт свои записи.
    func testPastedFilesKeepTheNamesTheSourceGave() async throws {
        let source = outside!
        let providers = ["Совещание 27.08", "Планёрка", "Совещание 27.08"].enumerated().map { index, title -> NSItemProvider in
            let provider = NSItemProvider()
            provider.suggestedName = title
            provider.registerFileRepresentation(forTypeIdentifier: mp3, fileOptions: [], visibility: .all) { completion in
                let file = source.appending(path: "\(UUID().uuidString).mp3")
                try? Data([UInt8(index)]).write(to: file)
                completion(file, false, nil)
                return nil
            }
            return provider
        }
        pasteboard.setItemProviders(providers, localOnly: true, expirationDate: nil)

        let urls = try await ClipboardAudio.takeAll(from: pasteboard)

        XCTAssertEqual(
            urls.map(\.lastPathComponent),
            ["Совещание 27.08.mp3", "Планёрка.mp3", "Совещание 27.08 2.mp3"],
            "повтор одного имени получает номер, а не затирает"
        )
    }

    /// Одна нечитаемая запись из двух не отменяет вторую — и не пропадает молча.
    func testAnUnreadableItemIsSkippedNotFatal() async throws {
        let missing = outside.appending(path: "Пропала.m4a")
        let good = try outsideFile("Целая.m4a", bytes: [7])
        pasteboard.setItems([missing, good].map { [UTType.fileURL.identifier: $0] }, options: [:])

        let result = try await ClipboardAudio.takeBatch(from: pasteboard)

        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["Целая.m4a"])
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.skipped[0].index, 0)
        XCTAssertFalse(result.messages[0].isEmpty, "причина — текстом для человека")
        let all = try await ClipboardAudio.takeAll(from: pasteboard)
        XCTAssertEqual(all.count, 1, "takeAll при частичном успехе не бросает")
    }

    /// Все нечитаемы — это ошибка, а не пустой список.
    func testWhenNothingIsReadableTakeAllThrows() async throws {
        let missing = outside.appending(path: "Пропала.m4a")
        pasteboard.setItems([[UTType.fileURL.identifier: missing]], options: [:])

        await assertThrowsAsync(try await ClipboardAudio.takeAll(from: pasteboard))
        XCTAssertEqual(ImportInbox.waiting(), [])
    }

    func testFileReferencesAreCopiedWithTheirOwnNames() async throws {
        let first = try outsideFile("Первая.m4a", bytes: [1])
        let second = try outsideFile("Вторая.mp3", bytes: [2])
        let third = try outsideFile("Третья.WAV", bytes: [3])
        pasteboard.setItems(
            [first, second, third].map { [UTType.fileURL.identifier: $0] },
            options: [:]
        )

        let urls = try await ClipboardAudio.takeAll(from: pasteboard)

        XCTAssertEqual(urls.map(\.lastPathComponent), ["Первая.m4a", "Вторая.mp3", "Третья.WAV"])
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, [Data([1]), Data([2]), Data([3])])
        for original in [first, second, third] {
            XCTAssertTrue(manager.fileExists(atPath: original.path), "чужие файлы остаются у владельца")
        }
    }

    func testFileReferenceToANonAudioFileIsLeftAlone() async throws {
        let note = try outsideFile("Заметка.pdf", bytes: [9])
        let audio = try outsideFile("Запись.m4a", bytes: [1])
        pasteboard.setItems([note, audio].map { [UTType.fileURL.identifier: $0] }, options: [:])

        let result = try await ClipboardAudio.takeBatch(from: pasteboard)

        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["Запись.m4a"])
        XCTAssertTrue(result.skipped.isEmpty, "pdf — не звук и не отказ")
    }

    func testFileReferenceToAnUnsupportedAudioFormatIsRefusedWithAReason() async throws {
        let ogg = try outsideFile("Голосовое.ogg", bytes: [1])
        let good = try outsideFile("Запись.m4a", bytes: [2])
        pasteboard.setItems([ogg, good].map { [UTType.fileURL.identifier: $0] }, options: [:])

        let result = try await ClipboardAudio.takeBatch(from: pasteboard)

        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["Запись.m4a"])
        XCTAssertEqual(result.skipped.first?.error as? ImportError, .unsupportedFormat(fileName: "Голосовое.ogg"))
    }

    // MARK: - Имя файла

    func testStagedNameRules() {
        func name(_ suggested: String?, _ source: String?, _ type: String?) -> String {
            ClipboardAudio.stagedName(suggestedName: suggested, sourceName: source, typeExtension: type)
        }
        XCTAssertEqual(name("Совещание", nil, "m4a"), "Совещание.m4a")
        XCTAssertEqual(name("Совещание.m4a", nil, "mp3"), "Совещание.m4a", "своё звуковое расширение главнее")
        XCTAssertEqual(name("Отчёт 27.08", nil, "m4a"), "Отчёт 27.08.m4a", "«.08» не расширение")
        XCTAssertEqual(name(nil, "Лекция.wav", "m4a"), "Лекция.wav", "имя временного файла, когда своего нет")
        XCTAssertEqual(name("Лекция", "temp.wav", "m4a"), "Лекция.wav", "расширение — у настоящего файла")
        XCTAssertEqual(name(nil, nil, "mp3"), "Вставленное.mp3")
        XCTAssertEqual(name(nil, nil, nil), "Вставленное.m4a", "как было, когда тип ничего не сказал")
        XCTAssertEqual(name("", "", "m4a"), "Вставленное.m4a")
        XCTAssertEqual(name(nil, "6F9619FF-8B86-D011-B42D-00C04FC964FF.m4a", "m4a"), "Вставленное.m4a", "набор знаков — не имя")
        XCTAssertEqual(name("а/б", nil, "m4a"), "а-б.m4a", "«/» не должен стать папкой")
        XCTAssertEqual(name(".скрытая", nil, "m4a"), "скрытая.m4a")
    }
}

/// `XCTAssertThrowsError` для асинхронных выражений. Свой, и приватный в файле: общий
/// `XCTAssertThrowsErrorAsync` живёт в чужом файле тестов, и опираться на него значило бы
/// ломаться вместе с ним.
private func assertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("ожидалась ошибка", file: file, line: line)
    } catch {
        handler(error)
    }
}
