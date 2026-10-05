import Foundation
import Security

/// Ключи API, которые Lori хранит на телефоне. Каждый движок — свой аккаунт
/// в Keychain: ключ OpenAI и ключ Gemini не должны затирать друг друга.
///
/// Имя `assistant-api-key` не переиспользовать: так назывался аккаунт чата
/// «Спроси свой архив», удалённого 5 октября 2026. Его запись на телефонах
/// намеренно не стирается, и новый аккаунт с тем же именем молча получил бы
/// старый ключ.
enum KeychainAccount: String, CaseIterable, Sendable {
    case openAI = "openai-api-key"
    case gemini = "gemini-api-key"
    case elevenLabs = "elevenlabs-api-key"

    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .elevenLabs: "ElevenLabs"
        }
    }
}

enum KeychainStore {
    private static let service = Bundle.main.bundleIdentifier ?? "ru.ilyaqa.lori.local"

    static func save(_ key: String, for account: KeychainAccount) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainStoreError.emptyKey(account) }
        let data = Data(trimmed.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue,
        ]
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var create = query
            create[kSecValueData] = data
            create[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let createStatus = SecItemAdd(create as CFDictionary, nil)
            guard createStatus == errSecSuccess else { throw KeychainError(status: createStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func key(for account: KeychainAccount) throws -> String? {
        try resolve(saved: { try savedKey(for: account) }, bundled: { BundledAPIKeys.key(for: account) })
    }

    // Ошибку доступа к Keychain не скрываем подстановкой другого ключа:
    // например, заблокированный телефон не должен менять аккаунт оплаты.
    static func resolve(saved: () throws -> String?, bundled: () -> String?) rethrows -> String? {
        if let key = try saved(), !key.isEmpty { return key }
        return bundled()
    }

    private static func savedKey(for account: KeychainAccount) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status)
        }
        return key
    }

    /// Только факт наличия ключа: интерфейсу нужно показать статус,
    /// а сам ключ ему видеть незачем.
    static func hasKey(for account: KeychainAccount) -> Bool {
        ((try? key(for: account)) ?? nil)?.isEmpty == false
    }

    static func hasBundledKey(for account: KeychainAccount) -> Bool {
        BundledAPIKeys.key(for: account) != nil
    }

    static func usesBundledKey(for account: KeychainAccount) -> Bool {
        guard (try? savedKey(for: account)) == nil else { return false }
        return hasBundledKey(for: account)
    }

    static func statusDescription(for account: KeychainAccount) -> String {
        usesBundledKey(for: account) ? "Встроен в личную сборку" : "Ключ сохранён на этом iPhone"
    }

    static func delete(_ account: KeychainAccount) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

enum KeychainStoreError: LocalizedError {
    case emptyKey(KeychainAccount)

    var errorDescription: String? {
        switch self {
        case let .emptyKey(account): "Вставь непустой ключ \(account.title)."
        }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Не удалось сохранить ключ в Keychain (\(status))."
    }
}
