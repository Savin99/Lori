import Foundation

/// Словарь sentencepiece модели GigaAM.
///
/// У e2e-моделей в словаре есть знаки препинания и заглавные буквы, поэтому
/// пунктуацию расставляет сама модель: отдельный шаг нормализации не нужен.
/// Blank для CTC и RNN-T — индекс сразу за словарём, как в `gigaam/decoding.py`.
struct SentencePieceVocabulary: Equatable {
    enum Failure: LocalizedError {
        case empty

        var errorDescription: String? {
            switch self {
            case .empty: "Словарь модели пуст."
            }
        }
    }

    private static let wordStart = "\u{2581}"

    let pieces: [String]

    var count: Int { pieces.count }
    var blankIndex: Int { pieces.count }
    var classCount: Int { pieces.count + 1 }

    init(pieces: [String]) throws {
        guard !pieces.isEmpty else { throw Failure.empty }
        self.pieces = pieces
    }

    /// Словарь ONNX-экспорта: в строке «кусок пробел индекс», последняя строка — `<blk>`.
    ///
    /// Blank в проекте живёт за словарём (`blankIndex == pieces.count`), поэтому строка
    /// `<blk>` из файла отбрасывается, а не становится куском. `<unk>` остаётся на своём
    /// месте, но пустой строкой: служебному токену нечего делать в тексте расшифровки.
    init(tableAt url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [(piece: String, index: Int)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let raw = String(line)
            // Кусок может быть и пробелом, поэтому режем по последнему пробелу, а не по первому.
            guard let separator = raw.lastIndex(of: " "),
                  let index = Int(raw[raw.index(after: separator)...]) else { continue }
            entries.append((String(raw[raw.startIndex..<separator]), index))
        }
        guard !entries.isEmpty else { throw Failure.empty }
        entries.sort { $0.index < $1.index }

        var pieces = entries.map(\.piece)
        if pieces.last == "<blk>" { pieces.removeLast() }
        if let unknown = pieces.firstIndex(of: "<unk>") { pieces[unknown] = "" }
        try self.init(pieces: pieces)
    }

    /// Словарь лежит рядом с моделью: один кусок на строку.
    init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Файл обычно заканчивается переводом строки — последний пустой элемент не токен.
        if lines.last?.isEmpty == true { lines.removeLast() }
        try self.init(pieces: lines)
    }

    func detokenize(_ tokens: [Int]) -> String {
        tokens
            .filter { $0 >= 0 && $0 < pieces.count }
            .map { pieces[$0] }
            .joined()
            .replacingOccurrences(of: Self.wordStart, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
