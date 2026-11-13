import CryptoKit
import Foundation

struct GatewayError: Error, LocalizedError, Decodable, Sendable, Equatable {
    let code: String
    var retryAfter: Double? = nil

    // Текст сервера намеренно не выводится и не журналируется: он может
    // содержать фрагмент входных данных или ответ модели.
    var errorDescription: String? {
        switch code {
        case "auth": "Проверь токен шлюза. На Mac mini может потребоваться вход в Antigravity."
        case "quota": "Квота подписки закончилась." + (retryAfter.map { " Повтори примерно через \(Int(ceil($0 / 60))) мин." } ?? " Попробуй позже.")
        case "rate": "Слишком много запросов. Подожди минуту и повтори."
        case "queue": "Шлюз занят. Заявка подождёт следующего прохода."
        case "timeout": "Шлюз не успел ответить. Попробуй ещё раз."
        case "agent": "Gemini не смог выполнить задачу. Попробуй ещё раз."
        case "invalid": "Шлюз не принял данные задачи."
        case "size": "Расшифровка слишком большая для шлюза."
        case "missing": "Задача на шлюзе уже недоступна. Попробуй ещё раз."
        case "configuration": "Подписка Gemini не настроена: укажи адрес и токен в настройках."
        case "network": "Не удалось связаться с Mac mini. Проверь подключение и адрес шлюза."
        case "cancelled": "Задача отменена."
        default: "Не удалось прочитать ответ шлюза. Попробуй ещё раз."
        }
    }
}

/// Строки старых итогов читаем наряду с новой формой шлюза.
struct SummaryTask: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    var text: String
    var owner: String?
    var due: String?

    init(text: String, owner: String? = nil, due: String? = nil) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.owner = owner.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.due = due.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    init(stringLiteral value: String) { self.init(text: value) }
    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) { self.init(text: text); return }
        let box = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try box.decode(String.self, forKey: .text), owner: try box.decodeIfPresent(String.self, forKey: .owner), due: try box.decodeIfPresent(String.self, forKey: .due))
    }
    var attribution: String? {
        let fields = [owner, due].compactMap { $0 }
        return fields.isEmpty ? nil : "— " + fields.joined(separator: ", ")
    }
    var displayText: String { [text, attribution].compactMap { $0 }.joined(separator: " ") }
}

struct RecordingSummary: Codable, Equatable, Sendable {
    var brief: String
    var highlights: [String]
    var decisions: [String]
    var tasks: [SummaryTask]
    var openQuestions: [String]

    var sections: [(title: String, items: [String])] {
        [("Главное", highlights), ("Решения", decisions), ("Задачи", tasks.map(\.displayText)), ("Открытые вопросы", openQuestions)]
            .map { ($0.0, $0.1.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) }
            .filter { !$0.1.isEmpty }
    }

    var markdown: String {
        var parts = ["## Итог"]
        if !brief.isEmpty { parts.append(brief) }
        for section in sections {
            parts.append("### \(section.title)\n\n" + section.items.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

struct GatewayAnnotation: Codable, Sendable {
    let title: String
    let description: String
    let summary: RecordingSummary
}

struct GatewayUsage: Decodable, Sendable {
    struct Group: Decodable, Sendable {
        let name: String
        let buckets: [Bucket]
    }
    struct Bucket: Decodable, Sendable {
        let id: String
        let window: String
        let remainingFraction: Double?
        let resetTime: String?
    }
    let groups: [Group]
    let cachedAt: String?
    let stale: Bool?

    var status: String {
        let group = groups.first { $0.name.localizedCaseInsensitiveContains("gemini") } ?? groups.first
        let quotas = (group?.buckets ?? []).compactMap { bucket -> String? in
            guard let fraction = bucket.remainingFraction else { return nil }
            let window = bucket.window.lowercased()
            let label: String
            if window.contains("week") || window.contains("7d") { label = "неделя" }
            else if window.contains("5") || window.contains("five") { label = "5 часов" }
            else { label = bucket.window }
            return "\(label) \(Int((max(0, min(1, fraction)) * 100).rounded()))%"
        }
        var result = "Подключение работает" + (quotas.isEmpty ? "" : " · " + quotas.joined(separator: ", "))
        if stale == true {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let cachedAt, let date = formatter.date(from: cachedAt) ?? ISO8601DateFormatter().date(from: cachedAt) {
                result += " · по данным на " + date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "ru_RU")))
            } else { result += " · сохранённые данные" }
        }
        return result
    }
}

struct GatewayClient: Sendable {
    enum Kind: String, Sendable { case annotate, report, transcribe }
    let baseURL: URL
    let token: String
    let session: URLSession
    var pollInterval: TimeInterval = 2
    var annotateTimeout: TimeInterval = 300
    var reportTimeout: TimeInterval = 600
    var transcribeTimeout: TimeInterval = 600

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    static func configured(session: URLSession = .shared) throws -> GatewayClient {
        guard let url = GatewaySettings.baseURL, let token = try KeychainStore.key(for: .gateway), !token.isEmpty else {
            throw GatewayError(code: "configuration")
        }
        return GatewayClient(baseURL: url, token: token, session: session)
    }

    static func key(kind: Kind, path: String, transcript: String) -> String {
        // Разделители исключают совпадение разных пар «вид + путь».
        let value = kind.rawValue + "\n" + path + "\n" + SummaryStore.fingerprint(of: transcript)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Ресурсный таймаут URLSession нельзя поднять одним URLRequest.
    static let conversionSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    /// В обе стороны поток с диска: видео может весить десятки мегабайт.
    func convert(file source: URL) async throws -> URL {
        var request = URLRequest(url: baseURL.appending(path: "v1/convert"))
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let safeName = ImportInbox.cleanFileName(source.lastPathComponent)
        let encoded = safeName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "audio"
        request.setValue(encoded, forHTTPHeaderField: "X-Lori-Filename")
        request.setValue(String(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), forHTTPHeaderField: "Content-Length")
        request.httpBodyStream = InputStream(url: source)
        let downloaded: URL
        let response: URLResponse
        do { (downloaded, response) = try await session.download(for: request, delegate: FileBody(source: source)) }
        catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw ImportError.gatewayFailed(reason: (error as? URLError)?.code == .timedOut
                ? "шлюз не ответил за 15 минут. Попробуй снова."
                : "не удалось связаться с Mac mini. Проверь подключение и адрес шлюза.")
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard let http = response as? HTTPURLResponse else { throw ImportError.gatewayFailed(reason: "непонятный ответ шлюза.") }
        guard http.statusCode == 200 else {
            let size = (try? downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let envelope = size < 65536 ? (try? JSONDecoder().decode(Envelope.self, from: Data(contentsOf: downloaded))) : nil
            let message: String
            switch envelope?.error.code {
            case "audio", "type": message = "файл повреждён или не содержит читаемой звуковой дорожки."
            case "unavailable": message = "на Mac mini недоступен ffmpeg."
            case "size": message = "файл превышает предел загрузки шлюза (95 МБ)."
            case "timeout": message = "Mac mini не успел перевести запись. Попробуй снова."
            default: message = (envelope?.error ?? GatewayError(code: http.statusCode == 401 ? "auth" : "response")).localizedDescription
            }
            throw ImportError.gatewayFailed(reason: message)
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "lori-convert-\(UUID().uuidString).m4a")
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }

    private final class FileBody: NSObject, URLSessionTaskDelegate, Sendable {
        let source: URL
        init(source: URL) { self.source = source }
        func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
            completionHandler(InputStream(url: source))
        }
    }

    func checkConnection() async throws -> GatewayUsage {
        struct Health: Decodable { let ok: Bool }
        let health: Health = try await request("v1/health")
        guard health.ok else { throw GatewayError(code: "agent") }
        return try await request("v1/usage")
    }

    func annotate(path: String, transcript: String, title: String? = nil, language: String? = nil) async throws -> GatewayAnnotation {
        let job = try await perform(.annotate, path: path, transcript: transcript, title: title, language: language)
        guard let result = job.result, let title = result.title, let description = result.description,
              let summary = result.summary else { throw GatewayError(code: "response") }
        return GatewayAnnotation(title: title, description: description, summary: summary)
    }

    func report(path: String, transcript: String, title: String? = nil, language: String? = nil) async throws -> String {
        let job = try await perform(.report, path: path, transcript: transcript, title: title, language: language)
        guard let markdown = job.result?.markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatewayError(code: "response")
        }
        return markdown
    }

    struct Segment: Decodable, Sendable {
        let speaker: String?
        // Поле start — оценка модели. Разбираем только текст и говорящего,
        // чтобы оценка никогда не превратилась в таймкод речи.
        let text: String
    }

    static func audioKey(path: String, index: Int, start: TimeInterval, end: TimeInterval, identity: String = "", options: String = "") -> String {
        // Точные двоичные границы не зависят от локали и не округляются до секунд.
        let fields = ["transcribe", path, String(index), String(start.bitPattern), String(end.bitPattern), identity, options]
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func transcribe(audio: CloudAudio.Prepared, key: String, speakers: Bool, language: String, vocabulary: [String], transfer: (@Sendable (TransferPhase) -> Void)? = nil, listening: @Sendable () -> Void = {}) async throws -> [Segment] {
        var url = URLComponents(url: baseURL.appending(path: "v1/jobs"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "kind", value: "transcribe")]
        var submission = URLRequest(url: url.url!)
        submission.httpMethod = "POST"
        submission.timeoutInterval = max(0.01, min(60, transcribeTimeout))
        submission.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        submission.setValue(audio.mime, forHTTPHeaderField: "Content-Type")
        submission.setValue(key, forHTTPHeaderField: "X-Lori-Key")
        submission.setValue(speakers ? "1" : "0", forHTTPHeaderField: "X-Lori-Speakers")
        submission.setValue(language, forHTTPHeaderField: "X-Lori-Language")
        let encoded = vocabulary.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .init(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
        submission.setValue(encoded, forHTTPHeaderField: "X-Lori-Vocabulary")
        submission.httpBody = try Data(contentsOf: audio.url)
        Diagnostics.note("шлюз: transcribe, \(submission.httpBody?.count ?? 0) байт")
        let job = try await run(.transcribe, limit: transcribeTimeout, submission: submission, submissionReport: transfer, listening: listening)
        guard let segments = job.result?.segments, !segments.isEmpty else { throw GatewayError(code: "response") }
        return segments
    }

    private struct Envelope: Decodable { let error: GatewayError }

    private struct Payload: Encodable {
        let kind: String
        let key: String
        let transcript: String
        let title: String?
        let language: String?
    }
    private struct Job: Decodable {
        var id: String?
        let state: String
        var result: Result?
        var error: GatewayError?
        struct Result: Decodable {
            var title: String?
            var description: String?
            var summary: RecordingSummary?
            var markdown: String?
            var segments: [Segment]?
        }
    }

    private func perform(_ kind: Kind, path: String, transcript: String, title: String?, language: String?) async throws -> Job {
        let limit = kind == .annotate ? annotateTimeout : reportTimeout
        let body = try JSONEncoder().encode(Payload(kind: kind.rawValue, key: Self.key(kind: kind, path: path, transcript: transcript), transcript: transcript, title: title, language: language))
        Diagnostics.note("шлюз: \(kind.rawValue), \(transcript.count) знаков, \(body.count) байт")
        return try await run(kind, limit: limit, submission: makeRequest("v1/jobs", method: "POST", body: body, timeout: min(60, limit)))
    }

    private func run(_ kind: Kind, limit: TimeInterval, submission: URLRequest, submissionReport: (@Sendable (TransferPhase) -> Void)? = nil, listening: @Sendable () -> Void = {}) async throws -> Job {
        let started = Date()
        var id: String?
        do {
            let submitted: Job = try await BackgroundTranscriptionTransport.$report.withValue(submissionReport ?? BackgroundTranscriptionTransport.report) {
                try await send(submission)
            }
            guard let acceptedID = submitted.id, !acceptedID.isEmpty,
                  acceptedID.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_" )).inverted) == nil else {
                throw GatewayError(code: "response")
            }
            id = acceptedID
            while true {
                try Task.checkCancellation()
                let remaining = limit - Date().timeIntervalSince(started)
                guard remaining > 0 else { throw GatewayError(code: "timeout") }
                let job: Job = try await request("v1/jobs/\(acceptedID)", timeout: min(60, remaining))
                switch job.state {
                case "done":
                    Diagnostics.note("шлюз: \(kind.rawValue) done, \(Int(Date().timeIntervalSince(started))) с")
                    return job
                case "failed": throw job.error ?? GatewayError(code: "agent")
                case "cancelled": throw GatewayError(code: "cancelled")
                case "running":
                    listening()
                    try await Task.sleep(for: .seconds(min(pollInterval, remaining)))
                case "queued": try await Task.sleep(for: .seconds(min(pollInterval, remaining)))
                default: throw GatewayError(code: "response")
                }
            }
        } catch {
            // Отмена родительской Task не должна отменить DELETE раньше отправки.
            if let id, Task.isCancelled || (error as? GatewayError)?.code == "timeout" {
                await Task.detached { try? await self.cancel(id: id) }.value
            }
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let failure = (error as? GatewayError) ?? GatewayError(code: "network")
            Diagnostics.fault("шлюз: \(kind.rawValue), код \(failure.code), \(Int(Date().timeIntervalSince(started))) с")
            throw failure
        }
    }

    func cancel(id: String) async throws {
        let _: Job = try await request("v1/jobs/\(id)", method: "DELETE", timeout: 10)
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 60) async throws -> T {
        try await send(makeRequest(path, method: method, body: body, timeout: timeout))
    }

    private func makeRequest(_ path: String, method: String, body: Data?, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = max(0.01, timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await BackgroundTranscriptionTransport.data(for: request, session: session) }
        catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw GatewayError(code: (error as? URLError)?.code == .timedOut ? "timeout" : "network")
        }
        guard let http = response as? HTTPURLResponse else { throw GatewayError(code: "response") }
        guard (200..<300).contains(http.statusCode) else {
            throw (try? JSONDecoder().decode(Envelope.self, from: data).error)
                ?? GatewayError(code: http.statusCode == 401 || http.statusCode == 403 ? "auth" : "response")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GatewayError(code: "response") }
    }
}
