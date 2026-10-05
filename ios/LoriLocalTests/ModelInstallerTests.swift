import CryptoKit
import XCTest
@testable import LoriLocal

/// Прогресс приходит из фонового потока, поэтому копится под замком:
/// обычная локальная переменная тут не собирается в Swift 6.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var shares: [Double] { lock.withLock { storage } }

    func add(_ share: Double) {
        lock.withLock { storage.append(share) }
    }
}

/// Установка моделей: скачивание по встроенному списку файлов, проверка размера
/// и SHA-256 и правило «или всё, или ничего» — половина модели хуже, чем её отсутствие.
final class ModelInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "LoriModels-\(UUID().uuidString)/Models", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        StubURLProtocol.reset()
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func configuration(_ files: [String: String]) -> URLSessionConfiguration {
        StubURLProtocol.configuration { request, _ in
            let name = request.url?.lastPathComponent ?? ""
            guard let content = files[name] else {
                return StubURLProtocol.Reply(status: 404, body: Data("нет файла".utf8))
            }
            return StubURLProtocol.Reply(status: 200, body: Data(content.utf8))
        }
    }

    private let source = URL(string: "https://huggingface.co/istupakov/gigaam-v3-onnx/resolve/main")!

    func testInstallsEveryFileOfTheVariant() async throws {
        let files = ["model.onnx": "как будто модель", "vocab.txt": "▁а 0\n<blk> 1\n"]
        let worker = ModelDownloadWorker(root: root, configuration: configuration(files))
        let entries = [
            GigaAMFile(name: "model.onnx", bytes: files["model.onnx"]!.utf8.count, sha256: sha256(files["model.onnx"]!)),
            GigaAMFile(name: "vocab.txt", bytes: files["vocab.txt"]!.utf8.count, sha256: nil),
        ]
        let log = ProgressLog()

        try await worker.install(files: entries, from: source, into: "GigaAM-тест") { _, _, share in
            log.add(share)
        }

        let directory = root.appending(path: "GigaAM-тест")
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "model.onnx"), encoding: .utf8), files["model.onnx"])
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "vocab.txt"), encoding: .utf8), files["vocab.txt"])
        XCTAssertEqual(log.shares.last, 1, "к концу установки прогресс должен дойти до единицы")
    }

    func testChecksumMismatchLeavesNothingInstalled() async throws {
        let worker = ModelDownloadWorker(root: root, configuration: configuration(["model.onnx": "настоящее содержимое"]))
        let entries = [
            GigaAMFile(name: "model.onnx", bytes: "настоящее содержимое".utf8.count, sha256: sha256("другое содержимое")),
        ]

        do {
            try await worker.install(files: entries, from: source, into: "GigaAM-тест")
            XCTFail("подменённый файл устанавливать нельзя")
        } catch {
            XCTAssertEqual(error as? ModelInstallError, .checksum("model.onnx"))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appending(path: "GigaAM-тест").path),
            "после сбоя в папке моделей не должно остаться ничего"
        )
    }

    func testTruncatedDownloadIsRejected() async throws {
        let worker = ModelDownloadWorker(root: root, configuration: configuration(["model.onnx": "коротко"]))
        let entries = [GigaAMFile(name: "model.onnx", bytes: 999_999, sha256: nil)]

        do {
            try await worker.install(files: entries, from: source, into: "GigaAM-тест")
            XCTFail("недокачанный файл устанавливать нельзя")
        } catch {
            XCTAssertEqual(error as? ModelInstallError, .size("model.onnx"))
        }
    }

    func testServerErrorIsReportedWithFileName() async throws {
        let worker = ModelDownloadWorker(root: root, configuration: configuration([:]))
        let entries = [GigaAMFile(name: "model.onnx", bytes: 10, sha256: nil)]

        do {
            try await worker.install(files: entries, from: source, into: "GigaAM-тест")
            XCTFail("404 — это ошибка установки")
        } catch {
            XCTAssertEqual(error as? ModelInstallError, .http("model.onnx", 404))
        }
    }

    func testSecondInstallReplacesTheWholeDirectory() async throws {
        let entries = [GigaAMFile(name: "model.onnx", bytes: "первая".utf8.count, sha256: nil)]
        let first = ModelDownloadWorker(root: root, configuration: configuration(["model.onnx": "первая"]))
        try await first.install(files: entries, from: source, into: "GigaAM-тест")
        // Мусор от прошлой версии не должен пережить переустановку.
        try Data("лишний".utf8).write(to: root.appending(path: "GigaAM-тест/старый.onnx"))

        let second = ModelDownloadWorker(root: root, configuration: configuration(["model.onnx": "вторая"]))
        try await second.install(
            files: [GigaAMFile(name: "model.onnx", bytes: "вторая".utf8.count, sha256: nil)],
            from: source,
            into: "GigaAM-тест"
        )

        let directory = root.appending(path: "GigaAM-тест")
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "model.onnx"), encoding: .utf8), "вторая")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "старый.onnx").path))
    }
}

/// Прогресс по байтам проверяется на настоящем HTTP: подставной `URLProtocol` колбэков
/// загрузки не порождает вовсе, и именно поэтому дырка доехала до телефона — там
/// модель качалась, а полоса стояла на нуле.
///
/// Перед прогоном на хосте:
///   python3 -c "import os; open('probe.bin','wb').write(os.urandom(8*1024*1024))"
///   python3 -m http.server 8321 --bind 127.0.0.1
/// Без сервера тест пропускается.
final class ModelDownloadProgressTests: XCTestCase {
    private let probe = URL(string: "http://127.0.0.1:8321")!
    private let bytes = 8 * 1024 * 1024

    func testProgressArrivesWhileFileIsDownloading() async throws {
        let up = await serverIsUp()
        try XCTSkipUnless(up, "локальный сервер на 8321 не запущен")

        let root = FileManager.default.temporaryDirectory
            .appending(path: "LoriProgress-\(UUID().uuidString)/Models", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let worker = ModelDownloadWorker(root: root)
        let log = ProgressLog()

        try await worker.install(
            files: [GigaAMFile(name: "probe.bin", bytes: bytes, sha256: nil)],
            from: probe,
            into: "проба"
        ) { _, _, share in log.add(share) }

        // Один вызов — это итоговый, после проверки файла. Всё, что сверх, приходит
        // от делегата: задача держит его слабой ссылкой, и без явного удержания
        // ARC освобождал делегата сразу после вызова.
        XCTAssertGreaterThan(
            log.shares.count,
            1,
            "прогресс по байтам не приходит — делегат загрузки не дожил до конца запроса"
        )
        XCTAssertEqual(log.shares.last, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appending(path: "проба/probe.bin").path),
            "файл должен доехать целиком"
        )
    }

    private func serverIsUp() async -> Bool {
        var request = URLRequest(url: probe.appending(path: "probe.bin"))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}

/// Каталог моделей: адрес, состав вариантов и поиск установленного на диске.
final class GigaAMCatalogTests: XCTestCase {
    func testVariantsPointAtTheOpenRepository() {
        XCTAssertEqual(
            GigaAMVariant.source.absoluteString,
            "https://huggingface.co/istupakov/gigaam-v3-onnx/resolve/main"
        )
        for variant in GigaAMVariant.allCases {
            XCTAssertFalse(variant.files.isEmpty)
            XCTAssertGreaterThan(variant.totalBytes, 100_000_000, "int8-модель GigaAM меньше 100 МБ не бывает")
            let vocabulary = variant.files.filter { $0.name.hasSuffix("vocab.txt") }
            XCTAssertEqual(vocabulary.count, 1, "словарь должен быть ровно один: \(variant.rawValue)")
            let heavy = variant.files.filter { $0.bytes > 1_000_000 }
            XCTAssertTrue(heavy.allSatisfy { $0.sha256 != nil }, "большие файлы обязаны иметь контрольную сумму")
        }
        XCTAssertEqual(GigaAMVariant.rnnt.files.count, 4, "энкодер, декодер, joint и словарь")
        XCTAssertEqual(GigaAMVariant.ctc.files.count, 2, "модель и словарь")
    }

    func testLocateNeedsEveryFileOfTheVariant() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LoriLocate-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: GigaAMVariant.ctc.directory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertNil(GigaAMModelSet.locate(.ctc, roots: [root]), "пустая папка — это не установленная модель")

        try Data("модель".utf8).write(to: directory.appending(path: "v3_e2e_ctc.int8.onnx"))
        XCTAssertNil(GigaAMModelSet.locate(.ctc, roots: [root]), "без словаря модель не запустится")

        try Data("словарь".utf8).write(to: directory.appending(path: "v3_e2e_ctc_vocab.txt"))
        let found = GigaAMModelSet.locate(.ctc, roots: [root])
        XCTAssertEqual(found?.directory, directory)
        XCTAssertEqual(found?.vocabulary.lastPathComponent, "v3_e2e_ctc_vocab.txt")
    }
}
