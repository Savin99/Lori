import Foundation

/// Условия фиксируются по нажатию, а не при освобождении очереди и не на последнем
/// ответе API. Ключей здесь нет. TaskLocal не меняет глобальные настройки соседней записи.
struct TranscriptionJob: Codable, Sendable, Equatable {
    let id: String
    let kind: TranscriptionEngineKind
    let values: [String: String]
    let created: Date

    init(id: String, kind: TranscriptionEngineKind, values: [String: String], created: Date) {
        self.id = id
        self.kind = kind
        self.values = values
        self.created = created
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let id = try box.decode(String.self, forKey: .id)
        guard UUID(uuidString: id) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: box, debugDescription: "Invalid job UUID")
        }
        self.init(id: id, kind: try box.decode(TranscriptionEngineKind.self, forKey: .kind),
                  values: try box.decode([String: String].self, forKey: .values),
                  created: try box.decode(Date.self, forKey: .created))
    }

    @TaskLocal static var current: TranscriptionJob?

    static func capture(kind: TranscriptionEngineKind) -> Self {
        let keys = [
            TranscriptionSettings.engineKey, TranscriptionSettings.openAIBaseURLKey,
            TranscriptionSettings.openAIModelKey, TranscriptionSettings.geminiModelKey,
            TranscriptionSettings.geminiBaseURLKey, TranscriptionSettings.geminiModeKey,
            TranscriptionSettings.elevenLabsBaseURLKey, TranscriptionSettings.elevenLabsModelKey,
            TranscriptionSettings.elevenLabsModeKey, TranscriptionSettings.gigaAMVariantKey,
            TranscriptionSettings.vocabularyKey, TranscriptionSettings.languageKey,
            TranscriptionSettings.speakerLabelsKey, TranscriptionSettings.timecodesKey,
            TranscriptionSettings.geminiPartKey,
        ]
        var values: [String: String] = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { values[key] = String(describing: value) }
        }
        values[TranscriptionSettings.engineKey] = kind.rawValue
        return Self(id: UUID().uuidString, kind: kind, values: values, created: .now)
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori/Jobs", directoryHint: .isDirectory)
    }

    var directory: URL { Self.directory.appending(path: id, directoryHint: .isDirectory) }
}
