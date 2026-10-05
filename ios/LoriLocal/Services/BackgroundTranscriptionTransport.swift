import CryptoKit
import Foundation
import UIKit

/// Система владеет передачей файла, процесс Lori — разбором ответа. Истечение
/// CPU-времени снимает только ожидание Swift: upload не отменяется и не оплачивается
/// заново после обычного возвращения. Ответ сохраняется до завершения всего задания.
final class BackgroundTranscriptionTransport: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundTranscriptionTransport()
    static let identifier = (Bundle.main.bundleIdentifier ?? "ru.ilyaqa.lori.local") + ".transcription-transfer"
    private let queue = DispatchQueue(label: "Lori.transcription-transfer")
    private var waiters: [String: [UUID: CheckedContinuation<(Data, URLResponse), Error>]] = [:]
    private var buffers: [Int: Data] = [:]
    private var cancelled: Set<UUID> = []
    private var transferring: Set<String> = []
    private var cancelledJobs: Set<String> = []
    private var downloadErrors: [Int: Error] = [:]
    private var completion: (() -> Void)?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 3 * 60 * 60
        config.timeoutIntervalForRequest = 180
        config.httpMaximumConnectionsPerHost = 3
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }()

    private struct Receipt: Codable {
        let status: Int
        let headers: [String: String]
        let url: URL
        let data: Data
        var result: (Data, URLResponse)? {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers).map { (data, $0) }
        }
    }

    /// Подставные сессии тестов и запросы вне задания идут прежним транспортом.
    static func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        guard let job = TranscriptionJob.current,
              session === CloudSession.shared || session === CloudSession.patient else {
            return try await session.data(for: request)
        }
        return try await shared.perform(request, job: job)
    }

    static func upload(for request: URLRequest, from data: Data, session: URLSession) async throws -> (Data, URLResponse) {
        guard TranscriptionJob.current != nil,
              session === CloudSession.shared || session === CloudSession.patient else {
            return try await session.upload(for: request, from: data)
        }
        var copy = request
        copy.httpBody = data
        return try await self.data(for: copy, session: session)
    }

    static func requestID(_ request: URLRequest, jobID: String) -> String {
        var hash = SHA256()
        hash.update(data: Data((request.httpMethod ?? "GET").utf8))
        hash.update(data: Data((request.url?.absoluteString ?? "").utf8))
        hash.update(data: request.httpBody ?? Data())
        return jobID + "_" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ id: String, _ ext: String) -> URL {
        TranscriptionJob.directory.appending(path: "Transfers/\(id).\(ext)")
    }

    private func perform(_ request: URLRequest, job: TranscriptionJob) async throws -> (Data, URLResponse) {
        let id = Self.requestID(request, jobID: job.id)
        let token = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if self.cancelledJobs.contains(job.id) || self.cancelled.remove(token) != nil { continuation.resume(throwing: CancellationError()); return }
                    if request.httpMethod != "GET", let data = try? Data(contentsOf: self.file(id, "json")),
                       let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                       let result = receipt.result {
                        continuation.resume(returning: result)
                        return
                    }
                    self.waiters[id, default: [:]][token] = continuation
                    guard self.transferring.insert(id).inserted else { return }
                    // Один запрос может быть уже в системной сессии после suspension/relaunch.
                    self.session.getAllTasks { tasks in
                        self.queue.async {
                            guard !self.cancelledJobs.contains(job.id), self.waiters[id]?.isEmpty == false else {
                                self.transferring.remove(id)
                                return
                            }
                            if tasks.contains(where: { $0.taskDescription == id && $0.state != .completed }) { return }
                            // Между getAllTasks и его callback мог прийти готовый ответ.
                            if request.httpMethod != "GET", let data = try? Data(contentsOf: self.file(id, "json")),
                               let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                               let result = receipt.result { self.resolve(id, .success(result)); return }
                            do {
                                try FileManager.default.createDirectory(at: self.file(id, "body").deletingLastPathComponent(), withIntermediateDirectories: true)
                                var outgoing = request
                                let task: URLSessionTask
                                if let body = request.httpBody {
                                    let path = self.file(id, "body")
                                    try body.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                                    outgoing.httpBody = nil
                                    task = self.session.uploadTask(with: outgoing, fromFile: path)
                                } else {
                                    task = self.session.downloadTask(with: outgoing)
                                }
                                task.taskDescription = id
                                task.resume()
                            } catch { self.resolve(id, .failure(error)) }
                        }
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                if let waiter = self.waiters[id]?.removeValue(forKey: token) {
                    waiter.resume(throwing: CancellationError())
                } else { self.cancelled.insert(token) }
            }
        }
    }

    private func resolve(_ id: String, _ result: Result<(Data, URLResponse), Error>) {
        transferring.remove(id)
        let pending = waiters.removeValue(forKey: id) ?? [:]
        for waiter in pending.values { waiter.resume(with: result) }
    }

    func cancel(jobID: String) {
        // Повреждённый ID не должен превращать очистку задания в удаление родителя.
        guard UUID(uuidString: jobID) != nil else { return }
        queue.async {
            self.cancelledJobs.insert(jobID)
            for id in Array(self.waiters.keys) where id.hasPrefix(jobID + "_") {
                self.resolve(id, .failure(CancellationError()))
            }
            self.session.getAllTasks { tasks in
                for task in tasks where task.taskDescription?.hasPrefix(jobID + "_") == true { task.cancel() }
            }
            let directory = self.file(jobID, "body").deletingLastPathComponent()
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent.hasPrefix(jobID + "_") { try? FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: TranscriptionJob.directory.appending(path: jobID))
        }
    }

    func reconnect(completion: @escaping () -> Void) {
        queue.async {
            self.completion = completion
            _ = self.session
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { self.buffers[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Временный файл исчезнет по выходу из delegate, поэтому читаем его здесь.
        let result = Result { try Data(contentsOf: location) }
        queue.async {
            switch result {
            case let .success(data): self.buffers[downloadTask.taskIdentifier] = data
            case let .failure(error): self.downloadErrors[downloadTask.taskIdentifier] = error
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            let body = self.buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
            guard let id = task.taskDescription else { return }
            defer { try? FileManager.default.removeItem(at: self.file(id, "body")) }
            let readError = self.downloadErrors.removeValue(forKey: task.taskIdentifier)
            if self.cancelledJobs.contains(String(id.split(separator: "_", maxSplits: 1)[0])) {
                self.resolve(id, .failure(CancellationError())); return
            }
            if let error = error ?? readError { self.resolve(id, .failure(error)); return }
            guard let response = task.response as? HTTPURLResponse, let url = response.url else {
                self.resolve(id, .failure(URLError(.badServerResponse))); return
            }
            do {
                // Не сохраняем auth/cookie-заголовки. Ответы нужны для продолжения,
                // а не для повторной аутентификации; ключи остаются в Keychain.
                let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                    let key = String(describing: pair.key)
                    if ["content-type", "x-goog-upload-url"].contains(key.lowercased()) {
                        result[key] = String(describing: pair.value)
                    }
                }
                let receipt = Receipt(status: response.statusCode, headers: headers, url: url, data: body)
                // Ошибку API нельзя кэшировать навсегда: исправленный ключ должен работать.
                if task.originalRequest?.httpMethod != "GET", (200..<300).contains(response.statusCode) {
                    try JSONEncoder().encode(receipt).write(to: self.file(id, "json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                self.resolve(id, .success((body, response)))
            } catch { self.resolve(id, .failure(error)) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        queue.async {
            let completion = self.completion
            self.completion = nil
            DispatchQueue.main.async { completion?() }
        }
    }
}

final class LoriBackgroundDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTranscriptionTransport.identifier else { completionHandler(); return }
        BackgroundTranscriptionTransport.shared.reconnect(completion: completionHandler)
    }
}
