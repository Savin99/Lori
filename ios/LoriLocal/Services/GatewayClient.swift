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

struct RecordingSummary: Codable, Equatable, Sendable {
    var brief: String
    var highlights: [String]
    var decisions: [String]
    var tasks: [String]
    var openQuestions: [String]

    var sections: [(title: String, items: [String])] {
        [("Главное", highlights), ("Решения", decisions), ("Задачи", tasks), ("Открытые вопросы", openQuestions)]
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
    enum Kind: String, Sendable { case annotate, report }
    let baseURL: URL
    let token: String
    let session: URLSession
    var pollInterval: TimeInterval = 2
    var annotateTimeout: TimeInterval = 300
    var reportTimeout: TimeInterval = 600

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    static func configured() throws -> GatewayClient {
        guard let url = GatewaySettings.baseURL, let token = try KeychainStore.key(for: .gateway), !token.isEmpty else {
            throw GatewayError(code: "configuration")
        }
        return GatewayClient(baseURL: url, token: token)
    }

    static func key(kind: Kind, path: String, transcript: String) -> String {
        // Разделители исключают совпадение разных пар «вид + путь».
        let value = kind.rawValue + "\n" + path + "\n" + SummaryStore.fingerprint(of: transcript)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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
        }
    }

    private func perform(_ kind: Kind, path: String, transcript: String, title: String?, language: String?) async throws -> Job {
        let started = Date()
        let limit = kind == .annotate ? annotateTimeout : reportTimeout
        let body = try JSONEncoder().encode(Payload(kind: kind.rawValue, key: Self.key(kind: kind, path: path, transcript: transcript), transcript: transcript, title: title, language: language))
        Diagnostics.note("шлюз: \(kind.rawValue), \(transcript.count) знаков, \(body.count) байт")
        var id: String?
        do {
            let accepted: Job = try await request("v1/jobs", method: "POST", body: body, timeout: min(60, limit))
            guard let acceptedID = accepted.id, !acceptedID.isEmpty,
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
                case "queued", "running": try await Task.sleep(for: .seconds(min(pollInterval, remaining)))
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
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = max(0.01, timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw GatewayError(code: "network")
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
