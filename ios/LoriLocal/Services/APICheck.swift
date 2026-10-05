import Foundation
import os

/// Журнал приложения. На телефоне ошибку API иначе не разобрать: в интерфейсе
/// одна строка, а знать нужно и адрес, и код состояния.
/// Сессия для облачных движков.
///
/// У `URLSession.shared` минута на запрос и семь дней на ресурс: на медленном канале
/// это значит «висит непонятно сколько». Здесь ожидание конечное и осмысленное,
/// а `waitsForConnectivity` не даёт свалиться в ошибку из-за секундного провала связи.
enum CloudSession {
    nonisolated(unsafe) static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    /// Сессия для движка, который отправляет запись **целиком одним запросом**
    /// (ElevenLabs Scribe). Здесь `timeoutIntervalForResource` — не деталь
    /// настройки, а условие работы: это потолок на всю задачу, и его нельзя
    /// поднять из `URLRequest`. Полтора часа звука на медленном канале в
    /// десять минут не укладываются, и запрос обрывался бы сам.
    nonisolated(unsafe) static let patient: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3 * 60 * 60
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()
}

enum Diagnostics {
    /// Уровень записи — `notice` и выше: `info` живёт только в памяти и после
    /// вылета приложения его уже не прочитать, а нужен он ровно тогда.
    static let log = Logger(subsystem: "ru.ilyaqa.lori.local", category: "lori")

    /// То же, что `log.notice`, но ещё и в файл: системный журнал с устройства
    /// без пароля не забрать, а разбираться приходится по факту.
    static func note(_ line: String) {
        log.notice("\(line, privacy: .public)")
        Journal.append(line)
    }

    static func fault(_ line: String) {
        log.error("\(line, privacy: .public)")
        Journal.append("ОШИБКА \(line)")
    }
}

/// Разбор неудачного HTTP-ответа. У OpenAI и у Google совпадает форма ошибки
/// (`{"error": {"message": …}}`), у ElevenLabs своя (`{"detail": …}`), а вот код
/// состояния одинаково бесполезен: «ключ не тот», «модели нет» и «файл слишком
/// большой» приходят одним 400. Человеку нужен текст сервиса, поэтому он и
/// попадает в ошибку.
enum APICheck {
    static func ensureSuccess(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let address = http.url?.absoluteString ?? "—"
        Diagnostics.fault("\(address) ответил \(http.statusCode)")
        if let payload = try? JSONDecoder().decode(Envelope.self, from: data), !payload.error.message.isEmpty {
            Diagnostics.fault("текст ошибки: \(payload.error.message)")
            throw TranscriptionError.api(explain(payload.error.message))
        }
        if let message = detail(in: data), !message.isEmpty {
            Diagnostics.fault("текст ошибки: \(message)")
            throw TranscriptionError.api(explain(message))
        }
        let text = String(data: data.prefix(400), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw TranscriptionError.api(text.isEmpty ? "Сервис ответил \(http.statusCode)." : text)
    }

    /// Некоторые ответы сервисов бесполезны без пояснения: человек читает
    /// «User location is not supported» и не понимает, что ключ тут не при чём.
    static func explain(_ message: String) -> String {
        // Тексты — одной строкой: склейка многострочных литералов уже один раз
        // протащила в интерфейс дорожку пробелов, и человек увидел её на телефоне.
        if message.localizedCaseInsensitiveContains("user location is not supported") {
            return "Google не принимает запросы из твоего региона — дело не в ключе. "
                + "Ответ сервиса: «\(message)» "
                + "Выход: указать в настройках Gemini адрес своего прокси в поддерживаемом регионе "
                + "или выбрать другой движок."
        }
        if message.localizedCaseInsensitiveContains("country, region, or territory not supported")
            || message.localizedCaseInsensitiveContains("unsupported_country") {
            return "Сервис не принимает запросы из твоего региона — дело не в ключе. "
                + "Ответ сервиса: «\(message)» "
                + "Выход: указать свой адрес API в настройках или выбрать другой движок."
        }
        return message
    }

    /// Ошибка ElevenLabs. Форм три, и все три встречаются: объект
    /// (`{"detail": {"status": "invalid_api_key", "message": "…"}}`), строка и
    /// список проверок полей (`{"detail": [{"msg": "…"}]}`). Без этого разбора
    /// человек получал в ошибке сырой JSON — то есть текст, который сервис ему
    /// как раз и написал, только нечитаемым.
    static func detail(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = root["detail"] else { return nil }
        if let text = detail as? String { return text }
        if let object = detail as? [String: Any] {
            return (object["message"] as? String) ?? (object["status"] as? String)
        }
        if let list = detail as? [[String: Any]] {
            let messages = list.compactMap { $0["msg"] as? String }
            return messages.isEmpty ? nil : messages.joined(separator: "; ")
        }
        return nil
    }

    private struct Envelope: Decodable {
        let error: Payload

        struct Payload: Decodable {
            let message: String
        }
    }
}
