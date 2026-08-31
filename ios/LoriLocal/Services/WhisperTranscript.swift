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
        raw.compactMap { word in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = max(0, word.start + offset)
            // Конец раньше начала приходит на стыке окон. Такое слово порвало бы
            // сборку реплик, поэтому длительность зажимается нулём, а слово остаётся.
            return TranscriptWord(start: start, end: max(start, word.end + offset), text: text)
        }
    }
}
