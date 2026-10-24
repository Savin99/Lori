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

/// Ждёт условия с пределом времени. Для того, что приложение делает своим ходом —
/// задачей на главном акторе, тиком полосы раз в секунду, ответом с чужой очереди, — и
/// дождаться иначе, чем проверкой, нечем. Не дождался — тест падает, а не висит.
@MainActor
func eventually(
    _ what: String,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("не дождался: \(what)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
}
