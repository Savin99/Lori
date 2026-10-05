import XCTest
@testable import LoriLocal

final class BundledAPIKeysTests: XCTestCase {
    func testBundledOpenAIKeyNeverGoesToPreviousProviderOrPlainHTTP() throws {
        for address in ["https://api.deepseek.com/v1", "http://api.openai.com/v1",
                        "https://api.openai.com.example.com/v1", "https://api.openai.com:8443/v1"] {
            XCTAssertFalse(BundledAPIKeys.allowsBundledKey(for: .assistant, at: try XCTUnwrap(URL(string: address))))
        }
        XCTAssertTrue(BundledAPIKeys.allowsBundledKey(for: .assistant,
            at: try XCTUnwrap(URL(string: "https://api.openai.com/v1"))))
        XCTAssertTrue(BundledAPIKeys.allowsBundledKey(for: .elevenLabs,
            at: try XCTUnwrap(URL(string: "https://api.elevenlabs.io/v1"))))
    }

    func testAccountsStaySeparateAndBlankValuesAreAbsent() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "elevenlabs-api-key": " fixture-eleven \n",
            "assistant-api-key": "fixture-chat",
            "openai-api-key": " \n"
        ], format: .binary, options: 0)
        XCTAssertEqual(BundledAPIKeys.key(for: .elevenLabs, in: data), "fixture-eleven")
        XCTAssertEqual(BundledAPIKeys.key(for: .assistant, in: data), "fixture-chat")
        XCTAssertNil(BundledAPIKeys.key(for: .openAI, in: data))
        XCTAssertNil(BundledAPIKeys.key(for: .gemini, in: data))
        XCTAssertNil(BundledAPIKeys.key(for: .assistant, in: Data("broken".utf8)))
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
