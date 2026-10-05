import Foundation

/// Заголовки и сниппеты для списка записей.
///
/// «Новая запись 48» ни о чём не говорит, а читать файл расшифровки на каждую
/// перерисовку строки нельзя. Поэтому значение считается один раз и запоминается,
/// а сбрасывается, когда расшифровка перезаписана.
@MainActor
final class TranscriptPreviews: ObservableObject {
    struct Preview: Equatable, Sendable {
        let title: String?
        /// Продолжение текста после того, что ушло в заголовок.
        let snippet: String?
        /// Текст с самого начала. Нужен, когда заголовок карточки взят не из
        /// расшифровки — у принесённого файла это его имя, у названной записи
        /// имя от человека, и обрезать текст «по заголовку» тогда бессмысленно:
        /// сниппет начинался бы с середины фразы.
        let head: String?
        /// Длина расшифровки в знаках. Нужна панели, чтобы сказать до отправки,
        /// сколько текста уйдёт ассистенту. Считается здесь, потому что файл
        /// на этом месте уже прочитан — ради одной цифры его не открывают заново.
        var characters: Int = 0
    }

    @Published private(set) var previews: [String: Preview] = [:]
    private var loading = Set<String>()

    func preview(for relativePath: String) -> Preview? {
        previews[relativePath]
    }

    func load(_ entry: WorkspaceEntry, in workspace: WorkspaceStore) {
        let path = entry.relativePath
        guard previews[path] == nil, !loading.contains(path) else { return }
        guard let transcript = workspace.existingTranscript(for: entry),
              let url = try? workspace.readableTextURL(at: transcript) else { return }
        loading.insert(path)
        Task { [weak self] in
            // `Task {}` наследует MainActor. Само чтение и разбор явно
            // выносим: на длинных текстах именно эта строка задерживала скролл.
            let preview = await Task.detached(priority: .utility) {
                let markdown = (try? WorkspaceStore.readTextFile(at: url)) ?? ""
                return Preview(
                    title: TranscriptTitle.title(from: markdown),
                    snippet: TranscriptTitle.snippet(from: markdown),
                    head: TranscriptTitle.head(from: markdown),
                    characters: markdown.count
                )
            }.value
            guard let self else { return }
            loading.remove(path)
            previews[path] = preview
        }
    }

    func invalidate(_ relativePath: String) {
        previews.removeValue(forKey: relativePath)
    }

    func invalidateAll() {
        previews.removeAll()
    }
}
