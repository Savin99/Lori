import Foundation

enum AnnotationSource: String, CaseIterable, Identifiable {
    case local, gateway
    var id: String { rawValue }
    var title: String { self == .local ? "На телефоне (Qwen)" : "Подписка Gemini" }
}

enum GatewaySettings {
    static let transcriptionNotice = "Общая модель Gemini по подписке слушает запись: может пересказывать и пропускать речь, точных таймкодов нет. Аудио уходит на Mac mini и оттуда в Google."
    static let baseURLKey = "gatewayBaseURL"
    static let sourceKey = "annotationSource"
    static let autoSummaryKey = "gatewayAutoSummary"

    static func validatedURL(_ value: String) -> URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    static var baseURL: URL? {
        // Пустой или неправильный ручной адрес — «не настроено», а не откат.
        if let job = TranscriptionJob.current, job.kind == .geminiSubscription || job.kind == .elevenLabs {
            return job.values[baseURLKey].flatMap(validatedURL)
        }
        if let value = UserDefaults.standard.string(forKey: baseURLKey) { return validatedURL(value) }
        return BundledAPIKeys.gatewayURL
    }
    static var isConfigured: Bool { baseURL != nil && KeychainStore.hasKey(for: .gateway) }
    static var source: AnnotationSource { resolveSource(defaults: .standard, configured: isConfigured) }

    static func resolveSource(defaults: UserDefaults, configured: Bool) -> AnnotationSource {
        if let value = defaults.string(forKey: sourceKey), let source = AnnotationSource(rawValue: value) { return source }
        guard configured else { return .local }
        // Выбранную по умолчанию подписку тоже помним: пропавший токен или
        // неверный адрес не должны молча запустить Qwen вместо шлюза.
        defaults.set(AnnotationSource.gateway.rawValue, forKey: sourceKey)
        return .gateway
    }
    static var autoSummary: Bool {
        (UserDefaults.standard.object(forKey: autoSummaryKey) as? Bool) ?? isConfigured
    }
}

/// Диаризация относится к присланной части, а не ко всей записи.
enum SubscriptionMode: String, CaseIterable, Sendable {
    case verbatim, speakers
    var title: String { self == .verbatim ? "Дословно" : "С говорящими" }
    var detail: String {
        self == .verbatim
            ? "Просим дословный текст. Время — только границы отправленной части."
            : "Говорящие различаются внутри каждой части; S1 в разных частях может быть разными людьми. Время — только границы части."
    }
}
