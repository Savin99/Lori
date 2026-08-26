import Foundation

/// Персистентная история диалогов.
///
/// Файл лежит в Application Support, а не в `Documents`: у приложения включён
/// `UIFileSharingEnabled`, и служебный JSON не должен появляться в «Файлах»
/// рядом с заметками пользователя.
struct ConversationArchive {
    static let maxConversations = 50

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = support
                .appending(path: "Lori", directoryHint: .isDirectory)
                .appending(path: "chat-history.json")
        }
    }

    /// Битый или отсутствующий файл истории не должен ломать запуск приложения.
    func load() -> [SavedConversation] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([SavedConversation].self, from: data) else { return [] }
        return stored.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ conversations: [SavedConversation]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Array(conversations.prefix(Self.maxConversations)))
        try data.write(to: fileURL, options: .atomic)
    }
}
