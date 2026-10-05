import XCTest

/// `XCTAssertThrowsError` не умеет `await`, а без него тест на отказ пришлось бы
/// писать через do/catch в каждом месте.
///
/// Общий помощник живёт своим файлом, а не внутри тестов одной функции: раньше
/// он лежал в `AssistantServiceTests` и при удалении чата «Спроси свой архив»
/// (5 октября 2026) исчез вместе с ним, уронив сборку тестов буфера обмена.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("ожидалась ошибка", file: file, line: line)
    } catch {
        handler(error)
    }
}
