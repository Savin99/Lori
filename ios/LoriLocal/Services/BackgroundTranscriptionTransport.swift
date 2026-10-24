import CryptoKit
import Foundation
import UIKit

/// Где сейчас запрос облачного задания — по счёту самой системной передачи.
///
/// Нужна двум читателям. Фоновой задаче: запрос одним куском (ElevenLabs отправляет
/// запись целиком) иначе не даёт никакой доли — ноль стоит всю загрузку и всё ожидание
/// ответа, а планировщик снимает задачу, которая стоит на месте (`BGTask.h`: «Tasks that
/// appear stalled may be forcibly expired by the scheduler»; статья Apple «Performing
/// long-running tasks on iOS and iPadOS»: «the system prioritizes the termination of
/// tasks that reflect minimal or no progress»). Экрану — чтобы честно сказать «отправляю
/// 45%», а потом «жду ответ сервиса», а не показывать минуты пустой полосы.
enum TransferPhase: Equatable, Sendable {
    /// Тело уходит: сколько байт отправила система и сколько всего. `expected` −1 —
    /// объём системе неизвестен.
    case sending(sent: Int64, expected: Int64)
    /// Тело целиком ушло (или его нет вовсе, как у GET) — ждём ответ сервиса.
    case awaiting
    /// Ответ пришёл или запрос кончился ошибкой: дальше работа самого процесса.
    case answered

    /// Доля отправленного тела, от 0 до 1. **Не доля расшифровки**: запись, ушедшая
    /// целиком, ещё не расшифрована, поэтому на карточке эта доля подписана «Отправляю».
    var sentShare: Double? {
        guard case let .sending(sent, expected) = self, expected > 0 else { return nil }
        return min(1, max(0, Double(sent) / Double(expected)))
    }

    var isSending: Bool {
        if case .sending = self { return true }
        return false
    }

    /// Из счётчиков системы (`didSendBodyData`, `countOfBytesSent`). Неизвестный объём
    /// (`NSURLSessionTransferSizeUnknown`, −1) — это ещё отправка, а не «готово»: у
    /// загрузки из файла его не бывает (документация `didSendBodyData`: объём берётся из
    /// длины файла), но гадать на нём нельзя.
    static func from(sent: Int64, expected: Int64) -> TransferPhase {
        guard expected > 0 else { return .sending(sent: max(0, sent), expected: -1) }
        guard sent < expected else { return .awaiting }
        return .sending(sent: max(0, sent), expected: expected)
    }

    /// Словами — для журнала.
    var journalWord: String {
        switch self {
        case .sending: "отправка \(Int(((sentShare ?? 0) * 100).rounded(.down)))%"
        case .awaiting: "ждёт ответ сервиса"
        case .answered: "ответ получен"
        }
    }
}

/// Система владеет передачей файла, процесс Lori — разбором ответа. Истечение
/// CPU-времени снимает только ожидание Swift: upload не отменяется и не оплачивается
/// заново после обычного возвращения. Ответ сохраняется до завершения всего задания.
///
/// С 24 октября 2026 истечение фонового времени запрос, уже отданный системе, не снимает
/// вовсе: Swift-задача записи ждёт дальше (`TranscriptionService.interruptEverything`
/// оставляет такую запись), а когда ответ приходит, система будит приложение
/// (`sessionSendsLaunchEvents`) и запись доделывается — см. `LoriBackgroundDelegate`.
final class BackgroundTranscriptionTransport: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundTranscriptionTransport()
    static let identifier = (Bundle.main.bundleIdentifier ?? "ru.ilyaqa.lori.local") + ".transcription-transfer"

    /// Куда докладывать фазу запроса. Ставит `TranscriptionService` вокруг вызова движка:
    /// все облачные запросы задания и так идут через этот транспорт, поэтому доля загрузки
    /// доходит до записи, не меняя ни одного движка.
    @TaskLocal static var report: (@Sendable (TransferPhase) -> Void)?

    /// Режим пробуждения после того, как процесс убили: доделать задание можно только
    /// тем, на что ответ уже пришёл (расписка) или уже идёт (запрос у системы). Новую
    /// отправку в этом режиме не начинаем: окно пробуждения — секунды, запрос, начатый из
    /// фона, система откладывает («the task doesn't begin until the delay expires»,
    /// «Downloading files in the background»), а человек ничего нового не просил.
    @TaskLocal static var answersOnly = false

    private let queue = DispatchQueue(label: "Lori.transcription-transfer")
    private var waiters: [String: [UUID: CheckedContinuation<(Data, URLResponse), Error>]] = [:]
    private var buffers: [Int: Data] = [:]
    private var cancelled: Set<UUID> = []
    private var transferring: Set<String> = []
    private var cancelledJobs: Set<String> = []
    private var downloadErrors: [Int: Error] = [:]
    private var completions: [@Sendable () -> Void] = []
    /// Кому докладывать о запросе и что ему сказано последним: делегат зовётся на каждые
    /// несколько килобайт, а экрану и полосе хватает целых процентов.
    private var reporters: [String: @Sendable (TransferPhase) -> Void] = [:]
    private var lastMark: [String: Int] = [:]
    /// Запросы, отданные системе и ещё не закончившиеся. По ним решается, можно ли
    /// оставить запись ждать, когда фоновое время кончилось.
    private var inSystem: Set<String> = []
    /// Задания, по которым в режиме `answersOnly` понадобилась новая отправка.
    private var deferredJobs: Set<String> = []
    /// Сколько новых передач отдано системе за жизнь процесса — для тестов и журнала.
    private var launched = 0

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

    private static var transfers: URL { TranscriptionJob.directory.appending(path: "Transfers", directoryHint: .isDirectory) }

    private static func file(_ id: String, _ ext: String) -> URL {
        transfers.appending(path: "\(id).\(ext)")
    }

    private static func receipt(_ id: String) -> (Data, URLResponse)? {
        guard let data = try? Data(contentsOf: file(id, "json")),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return nil }
        return receipt.result
    }

    /// Ответ сервиса распиской: запрос, на который он пришёл, заново не уходит.
    ///
    /// Заголовки — только безобидные: auth и cookie не сохраняем. Ответы нужны для
    /// продолжения, а не для повторной аутентификации; ключи остаются в Keychain.
    /// Отдельной функцией, чтобы тест клал расписку ровно того же вида, что и делегат.
    static func saveReceipt(status: Int, headers: [String: String], url: URL, body: Data, for id: String) throws {
        try FileManager.default.createDirectory(at: transfers, withIntermediateDirectories: true)
        let receipt = Receipt(status: status, headers: headers, url: url, data: body)
        try JSONEncoder().encode(receipt).write(to: file(id, "json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func perform(_ request: URLRequest, job: TranscriptionJob) async throws -> (Data, URLResponse) {
        let id = Self.requestID(request, jobID: job.id)
        let token = UUID()
        // Значения задачи читаются здесь, в самой Swift-задаче: дальше работа идёт на
        // очереди транспорта и в колбэках сессии, куда task-local не доезжают.
        let report = Self.report
        let answersOnly = Self.answersOnly
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if self.cancelledJobs.contains(job.id) || self.cancelled.remove(token) != nil { continuation.resume(throwing: CancellationError()); return }
                    if request.httpMethod != "GET", let result = Self.receipt(id) {
                        continuation.resume(returning: result)
                        return
                    }
                    self.waiters[id, default: [:]][token] = continuation
                    if let report { self.reporters[id] = report }
                    guard self.transferring.insert(id).inserted else { return }
                    // Один запрос может быть уже в системной сессии после suspension/relaunch.
                    self.session.getAllTasks { tasks in
                        self.queue.async {
                            guard !self.cancelledJobs.contains(job.id), self.waiters[id]?.isEmpty == false else {
                                self.transferring.remove(id)
                                return
                            }
                            if let live = tasks.first(where: { $0.taskDescription == id && $0.state != .completed }) {
                                self.inSystem.insert(id)
                                self.publish(id, TransferPhase.from(sent: live.countOfBytesSent, expected: live.countOfBytesExpectedToSend))
                                Journal.append("передача: запрос задания уже у системы — жду его ответ, новый не отправляю")
                                return
                            }
                            // Между getAllTasks и его callback мог прийти готовый ответ.
                            if request.httpMethod != "GET", let result = Self.receipt(id) { self.resolve(id, .success(result)); return }
                            if answersOnly {
                                // Отказ — отменой, а не ошибкой: ни один движок не должен счесть это
                                // сбоем сервиса. Отметка по заданию нужна сервису, чтобы не сохранить
                                // то, что движок соберёт без этого ответа (Gemini умеет продолжать
                                // после неудачного переспроса).
                                self.deferredJobs.insert(job.id)
                                Journal.append("передача: в фоне новую отправку не начинаю — задание продолжится, когда Lori откроют")
                                self.resolve(id, .failure(CancellationError()))
                                return
                            }
                            do {
                                try FileManager.default.createDirectory(at: Self.transfers, withIntermediateDirectories: true)
                                var outgoing = request
                                let task: URLSessionTask
                                let phase: TransferPhase
                                if let body = request.httpBody {
                                    let path = Self.file(id, "body")
                                    try body.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                                    outgoing.httpBody = nil
                                    task = self.session.uploadTask(with: outgoing, fromFile: path)
                                    phase = .sending(sent: 0, expected: Int64(body.count))
                                } else {
                                    task = self.session.downloadTask(with: outgoing)
                                    phase = .awaiting
                                }
                                task.taskDescription = id
                                task.resume()
                                self.inSystem.insert(id)
                                self.launched += 1
                                self.publish(id, phase)
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

    /// Докладывает фазу тому, кто ждёт этот запрос, — только когда есть что сказать:
    /// новый целый процент или новая фаза.
    private func publish(_ id: String, _ phase: TransferPhase) {
        guard let report = reporters[id] else { return }
        let mark: Int
        switch phase {
        case .sending: mark = Int(((phase.sentShare ?? 0) * 100).rounded(.down))
        case .awaiting: mark = 1000
        case .answered: mark = 2000
        }
        guard lastMark[id] != mark else { return }
        lastMark[id] = mark
        report(phase)
    }

    private func resolve(_ id: String, _ result: Result<(Data, URLResponse), Error>) {
        transferring.remove(id)
        reporters[id] = nil
        lastMark[id] = nil
        let pending = waiters.removeValue(forKey: id) ?? [:]
        for waiter in pending.values { waiter.resume(with: result) }
    }

    func cancel(jobID: String) {
        // Повреждённый ID не должен превращать очистку задания в удаление родителя.
        guard UUID(uuidString: jobID) != nil else { return }
        queue.async {
            self.cancelledJobs.insert(jobID)
            self.deferredJobs.remove(jobID)
            self.inSystem = self.inSystem.filter { !$0.hasPrefix(jobID + "_") }
            for id in Array(self.waiters.keys) where id.hasPrefix(jobID + "_") {
                self.resolve(id, .failure(CancellationError()))
            }
            self.session.getAllTasks { tasks in
                for task in tasks where task.taskDescription?.hasPrefix(jobID + "_") == true { task.cancel() }
            }
            let directory = Self.transfers
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent.hasPrefix(jobID + "_") { try? FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: TranscriptionJob.directory.appending(path: jobID))
        }
    }

    // MARK: - Что видно снаружи

    /// Лежит ли сейчас у системы запрос этого задания: тело уходит или ответ ещё не пришёл.
    ///
    /// Зовётся с главного актора. `sync` здесь безопасен: очередь транспорта главный поток
    /// никогда не ждёт — туда она только отправляет (`DispatchQueue.main.async`).
    func holdsTransfer(forJob jobID: String) -> Bool {
        queue.sync { inSystem.contains { $0.hasPrefix(jobID + "_") } }
    }

    /// Пришёл ли по заданию хоть один ответ, лежащий распиской.
    func hasAnswer(forJob jobID: String) -> Bool {
        guard UUID(uuidString: jobID) != nil else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.transfers.path)) ?? []
        return names.contains { $0.hasPrefix(jobID + "_") && $0.hasSuffix(".json") }
    }

    /// Отказывался ли транспорт начинать новую отправку по заданию в режиме `answersOnly`.
    /// Отметка снимается: следующий прогон задания — уже другой.
    func takeDeferral(forJob jobID: String) -> Bool {
        queue.sync { deferredJobs.remove(jobID) != nil }
    }

    var launchedTransfers: Int { queue.sync { launched } }

    /// Пересоздать сессию после пробуждения системой и узнать, когда все её события
    /// доставлены (`urlSessionDidFinishEvents`). `completion` зовётся на главной очереди.
    func reconnect(completion: @escaping @Sendable () -> Void) {
        queue.async {
            self.completions.append(completion)
            _ = self.session
        }
    }

    // MARK: - Делегат сессии

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        queue.async {
            guard let id = task.taskDescription else { return }
            self.publish(id, TransferPhase.from(sent: totalBytesSent, expected: totalBytesExpectedToSend))
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
            self.inSystem.remove(id)
            defer { try? FileManager.default.removeItem(at: Self.file(id, "body")) }
            let readError = self.downloadErrors.removeValue(forKey: task.taskIdentifier)
            let status = (task.response as? HTTPURLResponse)?.statusCode
            // Строка на каждый запрос с телом (опросы GET не пишем — их у Gemini десятки):
            // «ждут 0» значит, что ответ пришёл, когда Swift-кода, ждущего его, в процессе
            // уже не было, — процесс убили и подняли заново ради этого события.
            if task.originalRequest?.httpMethod != "GET" {
                let failure = (error ?? readError).map { error -> String in
                    let raw = error as NSError
                    return ", сбой \(raw.domain) \(raw.code)"
                } ?? ""
                Journal.append(
                    "передача: запрос кончился — \(status.map { "ответ \($0)" } ?? "без ответа"), "
                    + "\(body.count / 1024) КБ, ждут \(self.waiters[id]?.count ?? 0)\(failure)"
                )
            }
            self.publish(id, .answered)
            if self.cancelledJobs.contains(String(id.split(separator: "_", maxSplits: 1)[0])) {
                self.resolve(id, .failure(CancellationError())); return
            }
            if let error = error ?? readError { self.resolve(id, .failure(error)); return }
            guard let response = task.response as? HTTPURLResponse, let url = response.url else {
                self.resolve(id, .failure(URLError(.badServerResponse))); return
            }
            do {
                let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                    let key = String(describing: pair.key)
                    if ["content-type", "x-goog-upload-url"].contains(key.lowercased()) {
                        result[key] = String(describing: pair.value)
                    }
                }
                // Ошибку API нельзя кэшировать навсегда: исправленный ключ должен работать.
                if task.originalRequest?.httpMethod != "GET", (200..<300).contains(response.statusCode) {
                    try Self.saveReceipt(status: response.statusCode, headers: headers, url: url, body: body, for: id)
                }
                self.resolve(id, .success((body, response)))
            } catch { self.resolve(id, .failure(error)) }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        queue.async {
            let completions = self.completions
            self.completions = []
            Journal.append("передача: система доставила все события фоновой сессии")
            DispatchQueue.main.async { completions.forEach { $0() } }
        }
    }
}

/// Система будит приложение событиями фоновой передачи: ответ сервиса пришёл, пока
/// процесс спал, или процесс уже убит и поднят заново ради этого события.
///
/// Раньше здесь только пересоздавалась сессия, а системный `completionHandler` звался, как
/// только события доставлены, — то есть раньше, чем запись разобрана и сохранена. После
/// него система вправе снова усыпить процесс («Calling this completion handler lets the
/// system know that your app’s user interface is updated»), и ответ лежал распиской до
/// возвращения человека. Теперь разбор и сохранение ведёт `TranscriptionRunway` под своим
/// окном `beginBackgroundTask`, и системе отвечают, когда всё на диске или окно кончилось.
final class LoriBackgroundDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTranscriptionTransport.identifier else { completionHandler(); return }
        guard let runway = TranscriptionRunway.current else {
            Journal.append("фон: система разбудила приложение событиями передачи, а вести их некому — отдаю системе как есть")
            // Обработчик UIKit зовётся только на главной очереди (туда его и вернёт
            // `reconnect`), поэтому перевозка через `nonisolated(unsafe)` безопасна.
            nonisolated(unsafe) let handler = completionHandler
            BackgroundTranscriptionTransport.shared.reconnect { handler() }
            return
        }
        runway.systemWokeForTransfers(completion: completionHandler)
    }
}
