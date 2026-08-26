import XCTest
@testable import LoriLocal

final class ConversationArchiveTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appending(path: "LoriArchiveTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "chat-history.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testRoundTripKeepsNewestConversationFirst() throws {
        let archive = ConversationArchive(fileURL: fileURL)
        let older = SavedConversation(
            bubbles: [ChatBubble(role: .user, text: "старый")],
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = SavedConversation(
            bubbles: [ChatBubble(role: .user, text: "новый")],
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        try archive.save([older, newer])

        XCTAssertEqual(archive.load().map(\.title), ["новый", "старый"])
    }

    func testBrokenFileDoesNotBreakStartup() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("не json".utf8).write(to: fileURL)

        XCTAssertEqual(ConversationArchive(fileURL: fileURL).load().count, 0)
    }

    func testKeepsAtMostMaxConversations() throws {
        let archive = ConversationArchive(fileURL: fileURL)
        let conversations = (0..<(ConversationArchive.maxConversations + 10)).map { index in
            SavedConversation(
                bubbles: [ChatBubble(role: .user, text: "диалог \(index)")],
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        try archive.save(conversations)

        XCTAssertEqual(archive.load().count, ConversationArchive.maxConversations)
    }
}
