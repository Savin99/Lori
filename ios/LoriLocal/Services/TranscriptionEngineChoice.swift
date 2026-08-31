import Foundation

/// Чем расшифровывать запись.
///
/// Выбор владельца, а не догадка приложения: GigaAM и Whisper на одном и том же
/// файле дают заметно разный текст, и сравнить их можно только переключившись руками.
/// Автоматический режим — прежнее поведение: первый движок, чьи модели лежат на устройстве.
enum TranscriptionEngineChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case gigaAM
    case whisper
    case apple

    static let storageKey = "transcriptionEngine"
    static let fallback = TranscriptionEngineChoice.automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Автоматически"
        case .gigaAM: "GigaAM v3"
        case .whisper: "Whisper large-v3 turbo"
        case .apple: "Движок Apple"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Первый движок, чьи модели есть на iPhone"
        case .gigaAM: "Русская речь, знаки препинания и заглавные ставит сам"
        case .whisper: "Многоязычный, со знаками препинания"
        case .apple: "Есть всегда, но текст без знаков препинания"
        }
    }

    init(storedValue: String) {
        self = TranscriptionEngineChoice(rawValue: storedValue) ?? .fallback
    }

    /// Что читает `TranscriptionService`, когда его не подменили в тестах.
    static func stored(in defaults: UserDefaults = .standard) -> TranscriptionEngineChoice {
        TranscriptionEngineChoice(storedValue: defaults.string(forKey: storageKey) ?? "")
    }
}
