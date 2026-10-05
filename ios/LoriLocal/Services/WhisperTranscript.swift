import Foundation

/// Слово так, как его отдаёт Whisper: с ведущим пробелом и временем от начала куска.
///
/// Отдельный тип нужен, чтобы разбор ответа проверялся тестами без самого пакета
/// WhisperKit: тестовая цель с ним не собирается.
struct WhisperWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

enum WhisperTranscript {
    /// Приводит слова куска к словам расшифровки: убирает пробел-разделитель,
    /// сдвигает время на начало куска и выбрасывает пустышки.
    ///
    /// Знаки препинания приезжают приклеенными к слову, и их надо сохранить:
    /// по ним `TranscriptAssembler` режет реплики.
    static func words(from raw: [WhisperWord], offset: TimeInterval = 0) -> [TranscriptWord] {
        var result: [TranscriptWord] = []
        for word in raw {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = max(0, word.start + offset)
            // Конец раньше начала приходит на стыке окон. Такое слово порвало бы
            // сборку реплик, поэтому длительность зажимается нулём, а слово остаётся.
            let end = max(start, word.end + offset)
            // Ведущий пробел у Whisper — это и есть признак начала слова, а кусок
            // без него продолжает предыдущий: «что» + «-то», «D» + «.0» + «.5».
            // Склеивать надо здесь, потому что `TranscriptAssembler` соединяет
            // слова пробелом и иначе в расшифровке стоит «что -то».
            let continuation = !(word.text.first?.isWhitespace ?? false)
            if continuation, let previous = result.popLast() {
                result.append(TranscriptWord(
                    start: previous.start,
                    end: max(previous.end, end),
                    text: previous.text + text
                ))
            } else {
                result.append(TranscriptWord(start: start, end: end, text: text))
            }
        }
        return result
    }
}
