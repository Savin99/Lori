import Foundation

enum AnnotationSource: String, CaseIterable, Identifiable {
    case local, gateway
    var id: String { rawValue }
    var title: String { self == .local ? "На телефоне (Qwen)" : "Подписка Gemini" }
}

enum GatewaySettings {
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
