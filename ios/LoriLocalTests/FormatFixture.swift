import Foundation
import XCTest

/// Настоящее короткое аудио вместо произвольных байтов с расширением .m4a.
enum FormatFixture {
    static func url(_ name: String) throws -> URL {
        let parts = (name as NSString)
        return try XCTUnwrap(Bundle(for: ImportFormatTests.self).url(forResource: parts.deletingPathExtension, withExtension: parts.pathExtension), name)
    }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    static func original(named name: String) throws -> Data {
        let suffix = (name as NSString).pathExtension.lowercased()
        guard ["m4a", "mp3", "wav", "aac"].contains(suffix) else { return Data([1, 2, 3]) }
        return try data("reference.\(suffix)")
    }
}
