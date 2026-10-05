import XCTest
@testable import LoriLocal

final class BundledAPIKeysTests: XCTestCase {
    func testBundledOpenAIKeyNeverGoesToPreviousProviderOrPlainHTTP() throws {
        for address in ["https://api.deepseek.com/v1", "http://api.openai.com/v1",
                        "https://api.openai.com.example.com/v1", "https://api.openai.com:8443/v1"] {
            XCTAssertFalse(BundledAPIKeys.allowsBundledKey(for: .openAI, at: try XCTUnwrap(URL(string: address))))
        }
        XCTAssertTrue(BundledAPIKeys.allowsBundledKey(for: .openAI,
            at: try XCTUnwrap(URL(string: "https://api.openai.com/v1"))))
        XCTAssertTrue(BundledAPIKeys.allowsBundledKey(for: .elevenLabs,
            at: try XCTUnwrap(URL(string: "https://api.elevenlabs.io/v1"))))
    }

    func testAccountsStaySeparateAndBlankValuesAreAbsent() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "elevenlabs-api-key": " fixture-eleven \n",
            "openai-api-key": "fixture-openai",
            "gemini-api-key": " \n"
        ], format: .binary, options: 0)
        XCTAssertEqual(BundledAPIKeys.key(for: .elevenLabs, in: data), "fixture-eleven")
        XCTAssertEqual(BundledAPIKeys.key(for: .openAI, in: data), "fixture-openai")
        XCTAssertNil(BundledAPIKeys.key(for: .gemini, in: data))
        // Отсутствующий ключ — тоже nil, а не чужое значение.
        let elevenOnly = try PropertyListSerialization.data(fromPropertyList: [
            "elevenlabs-api-key": "fixture-eleven"
        ], format: .binary, options: 0)
        XCTAssertNil(BundledAPIKeys.key(for: .openAI, in: elevenOnly))
        XCTAssertNil(BundledAPIKeys.key(for: .openAI, in: Data("broken".utf8)))
    }

    /// Имя аккаунта — это и аккаунт в Keychain, и ключ в `PrivateAPIKeys.plist`,
    /// который пишет `tools/embed-api-keys.py`. Совпавшие имена затёрли бы ключи
    /// друг друга, а переименование потеряло бы ключ, уже сохранённый на телефоне.
    func testKeychainAccountsAreDistinctAndKeepTheirNames() {
        XCTAssertEqual(
            Set(KeychainAccount.allCases.map(\.rawValue)).count,
            KeychainAccount.allCases.count,
            "аккаунты Keychain не должны совпадать"
        )
        XCTAssertEqual(KeychainAccount.openAI.rawValue, "openai-api-key")
        XCTAssertEqual(KeychainAccount.gemini.rawValue, "gemini-api-key")
        XCTAssertEqual(KeychainAccount.elevenLabs.rawValue, "elevenlabs-api-key")
    }

    func testSavedKeyWinsWithoutReadingBundle() {
        XCTAssertEqual(KeychainStore.resolve(saved: { "override" }, bundled: {
            XCTFail("Встроенный ключ не нужен при ручном ключе")
            return "bundled"
        }), "override")
    }

    func testFreshInstallAndResetUseBundledKey() {
        XCTAssertEqual(KeychainStore.resolve(saved: { nil }, bundled: { "bundled" }), "bundled")
        XCTAssertNil(KeychainStore.resolve(saved: { nil }, bundled: { nil }))
    }

    func testLockedKeychainDoesNotSwitchAccounts() {
        enum Locked: Error { case locked }
        XCTAssertThrowsError(try KeychainStore.resolve(saved: { throw Locked.locked }, bundled: {
            XCTFail("Ошибка Keychain не разрешает переключать ключ")
            return "bundled"
        }))
    }
}
