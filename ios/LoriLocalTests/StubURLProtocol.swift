import Foundation

/// Подставной транспорт для тестов облачных движков.
///
/// Сеть в тестах не участвует, ключи не нужны, а запросы записываются целиком:
/// проверять надо не только «движок вернул текст», но и что именно он отправил —
/// адрес, поля формы, словарь в подсказке.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()

        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(text.utf8))
        }
    }

    struct Recorded {
        let request: URLRequest
        let body: Data

        var bodyText: String { String(data: body, encoding: .utf8) ?? "" }

        /// Тело multipart несёт двоичное аудио, и целиком в строку оно не разбирается.
        /// Поиск идёт по байтам — иначе проверка полей формы всегда «не находила» их.
        func contains(_ text: String) -> Bool {
            body.range(of: Data(text.utf8)) != nil
        }

        /// Сколько раз подстрока встречается в теле. «Ровно один раз» ловит
        /// продублированные поля формы, которые простой `contains` пропускает.
        func occurrences(of text: String) -> Int {
            let pattern = Data(text.utf8)
            var count = 0
            var start = body.startIndex
            while start < body.endIndex, let range = body.range(of: pattern, in: start..<body.endIndex) {
                count += 1
                start = range.upperBound
            }
            return count
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest, Data) -> Reply)?
    nonisolated(unsafe) private static var log: [Recorded] = []

    /// Возвращает сессию, которая ходит только через этот протокол.
    static func session(_ handler: @escaping @Sendable (URLRequest, Data) -> Reply) -> URLSession {
        URLSession(configuration: configuration(handler))
    }

    /// Та же подстановка, но конфигурацией: установщику моделей нужна своя сессия
    /// с делегатом, и снаружи он принимает именно конфигурацию.
    static func configuration(_ handler: @escaping @Sendable (URLRequest, Data) -> Reply) -> URLSessionConfiguration {
        lock.withLock {
            Self.handler = handler
            log = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    static var requests: [Recorded] { lock.withLock { log } }

    static func reset() {
        lock.withLock {
            handler = nil
            log = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        let reply = Self.lock.withLock { () -> Reply in
            Self.log.append(Recorded(request: request, body: body))
            return Self.handler?(request, body) ?? Reply()
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://stub.invalid")!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Тело отдаётся частями: так проверяется, что делегат загрузки жив и получает
        // байты по мере поступления. Одним куском прогресса не увидеть.
        let chunk = max(1, reply.body.count / 4)
        var offset = 0
        while offset < reply.body.count {
            let end = min(offset + chunk, reply.body.count)
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
            offset = end
        }
        if reply.body.isEmpty { client?.urlProtocol(self, didLoad: Data()) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `URLSession` часто подменяет `httpBody` потоком, и без чтения потока
    /// тело запроса в тесте выглядело бы пустым.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
