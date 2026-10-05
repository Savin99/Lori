import CryptoKit
import Foundation
import os

enum ModelInstallError: LocalizedError, Equatable {
    case size(String)
    case checksum(String)
    case http(String, Int)

    var errorDescription: String? {
        switch self {
        case let .size(name):
            "Файл модели скачался не полностью: \(name). Установка отменена."
        case let .checksum(name):
            "Контрольная сумма файла не совпала: \(name). Установка отменена."
        case let .http(name, status):
            "Не удалось скачать \(name): сервер ответил \(status)."
        }
    }
}

/// Скачивание моделей. Отдельный `Sendable`-тип, а не метод у объекта интерфейса:
/// считать SHA-256 от 225 МБ на главном акторе — это заморозить приложение.
struct ModelDownloadWorker: Sendable {
    /// Куда складываются модели: `Application Support/Lori/Models`, ровно там,
    /// где их ищет `GigaAMModelSet.locate()`.
    let root: URL
    let configuration: URLSessionConfiguration

    init(root: URL? = nil, configuration: URLSessionConfiguration? = nil) {
        self.root = root ?? Self.defaultRoot
        self.configuration = configuration ?? Self.defaultConfiguration
    }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori/Models", directoryHint: .isDirectory)
    }

    /// Таймаут ресурса большой: 225 МБ на медленной сети качаются минутами,
    /// и обрывать это по стандартной минуте нельзя.
    static var defaultConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3_600
        configuration.waitsForConnectivity = true
        return configuration
    }

    /// Ставит вариант модели целиком. `progress` получает долю скачанных байтов
    /// и номер файла: у одного энкодера вес больше, чем у всего остального.
    func install(
        _ variant: GigaAMVariant,
        progress: @escaping @Sendable (Int, Int, Double) -> Void = { _, _, _ in }
    ) async throws {
        try await install(
            files: variant.files,
            from: GigaAMVariant.source,
            into: variant.directory,
            progress: progress
        )
    }

    /// Та же установка, но список файлов передан явно: так она проверяется тестами
    /// на файлах в байтах, а не на настоящих 225 МБ.
    func install(
        files: [GigaAMFile],
        from source: URL,
        into directory: String,
        progress: @escaping @Sendable (Int, Int, Double) -> Void = { _, _, _ in }
    ) async throws {
        let fileManager = FileManager.default
        let staging = root
            .deletingLastPathComponent()
            .appending(path: "Models.incoming-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        // Оборвалось на середине — в папке моделей ничего не меняется: половина модели
        // хуже, чем её отсутствие, движок бы всё равно не поднялся.
        defer { try? fileManager.removeItem(at: staging) }

        let downloader = FileDownloader(configuration: configuration)
        defer { downloader.finish() }

        let total = Double(max(1, files.reduce(0) { $0 + $1.bytes }))
        var done = 0

        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let already = done
            let destination = staging.appending(path: file.name)
            try await downloader.download(from: source.appending(path: file.name), to: destination) { written, _ in
                progress(index, files.count, min(1, (Double(already) + Double(written)) / total))
            }

            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size == file.bytes else {
                // В журнал — настоящие числа: по одному сообщению в интерфейсе
                // не понять, оборвалась сеть или сменился файл в репозитории.
                Diagnostics.log.error("модель \(file.name, privacy: .public): ждали \(file.bytes) байт, получили \(size)")
                throw ModelInstallError.size(file.name)
            }
            if let expected = file.sha256, try Self.sha256(of: destination) != expected.lowercased() {
                throw ModelInstallError.checksum(file.name)
            }

            done += size
            progress(index + 1, files.count, min(1, Double(done) / total))
        }

        // Папка варианта подменяется целиком: полусобранной модели существовать нельзя.
        let target = root.appending(path: directory, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.moveItem(at: staging, to: target)
    }

    func remove(_ variant: GigaAMVariant) throws {
        let target = root.appending(path: variant.directory, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Загрузка файла с прогрессом по байтам.
///
/// Написана на делегате уровня сессии, а не на `session.download(from:delegate:)`:
/// у асинхронной формы колбэки прогресса не приходят вовсе — проверено и на подставном
/// транспорте, и на настоящем HTTP. Ровно из-за этого на телефоне модель качалась,
/// а полоса стояла на нуле.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession!
    private var continuation: CheckedContinuation<Void, Error>?
    private var progress: (@Sendable (Int64, Int64) -> Void)?
    private var destination: URL?
    private var moveError: Error?

    init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Сессию нужно закрыть: с делегатом она держит на него сильную ссылку,
    /// и без `invalidate` загрузчик не освобождается никогда.
    func finish() {
        session.finishTasksAndInvalidate()
    }

    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let task = session.downloadTask(with: url)
        lock.withLock {
            self.continuation = nil
            self.progress = progress
            self.destination = destination
            self.moveError = nil
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            // «Отменить загрузку» должно действительно останавливать передачу,
            // а не только убирать полосу с экрана.
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let report = lock.withLock { progress }
        report?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    /// Временный файл удаляется сразу после выхода из этого метода, поэтому
    /// переносить его нужно здесь же, а не в продолжении.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destination = lock.withLock({ self.destination }) else { return }
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let name = task.originalRequest?.url?.lastPathComponent ?? "файл"
        var failure: Error? = error ?? lock.withLock { moveError }
        if failure == nil, let http = task.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            Diagnostics.log.error("загрузка \(name, privacy: .public): HTTP \(http.statusCode)")
            failure = ModelInstallError.http(name, http.statusCode)
        }
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}

/// Состояние установки для интерфейса.
@MainActor
final class ModelInstallStore: ObservableObject {
    @Published private(set) var installed: Set<GigaAMVariant> = []
    @Published private(set) var working: GigaAMVariant?
    /// Доля скачанного, от 0 до 1.
    @Published private(set) var fraction: Double = 0
    @Published private(set) var status: String?
    @Published var lastError: String?

    private let worker: ModelDownloadWorker
    private var task: Task<Void, Never>?

    init(worker: ModelDownloadWorker = ModelDownloadWorker()) {
        self.worker = worker
        refresh()
    }

    func refresh() {
        installed = Set(GigaAMVariant.allCases.filter { GigaAMModelSet.locate($0) != nil })
    }

    func isInstalled(_ variant: GigaAMVariant) -> Bool { installed.contains(variant) }

    func install(_ variant: GigaAMVariant) {
        guard working == nil else { return }
        working = variant
        fraction = 0
        status = "Соединяюсь…"
        task = Task { [worker] in
            do {
                try await worker.install(variant) { _, _, share in
                    Task { @MainActor [weak self] in
                        self?.fraction = share
                        // Мегабайты, а не только проценты: на 226 МБ человек хочет
                        // видеть, что дело движется, даже когда процент ещё не сменился.
                        let done = Double(variant.totalBytes) * share / 1024 / 1024
                        self?.status = String(format: "Скачано %.0f из %@ · %d%%", done, variant.sizeText, Int(share * 100))
                    }
                }
                status = "Модель установлена"
            } catch is CancellationError {
                status = nil
            } catch {
                lastError = error.localizedDescription
                status = nil
            }
            working = nil
            refresh()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        working = nil
        status = nil
    }

    /// Освободить место: каждый вариант — больше 200 МБ.
    func remove(_ variant: GigaAMVariant) {
        do {
            try worker.remove(variant)
            status = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}
