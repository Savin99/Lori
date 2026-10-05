import Combine
import Foundation

/// Заголовки и сниппеты для списка записей.
///
/// «Новая запись 48» ни о чём не говорит, а читать файл расшифровки на каждую
/// перерисовку строки нельзя. Поэтому значение считается один раз и запоминается,
/// а перечитывается, когда расшифровка перезаписана.
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

        /// Карточка по тексту файла — одним разбором, а не тремя.
        static func make(from markdown: String) -> Preview {
            let parts = TranscriptTitle.parts(of: TranscriptTitle.plain(from: markdown))
            return Preview(title: parts.title, snippet: parts.snippet, head: parts.head)
        }
    }

    @Published private(set) var previews: [String: Preview] = [:]
    private var loading = Set<String>()
    /// Номер последнего чтения по записи: ответ устаревшего чтения отбрасывается.
    private var generations: [String: Int] = [:]
    /// Счётчик чтений — общий и только растёт. Раньше номер считался по записи
    /// и после `invalidate`/`move` начинался заново с единицы: старое чтение,
    /// ещё шедшее для того же пути, совпадало номером с новым и затирало свежее
    /// превью устаревшим.
    private var lastGeneration = 0
    /// Чтение и разбор файла. Подменяется в тестах, чтобы задержать одно чтение
    /// и проверить, что его опоздавший ответ отбрасывается.
    private let reader: @Sendable (URL) async -> Preview

    init(reader: (@Sendable (URL) async -> Preview)? = nil) {
        self.reader = reader ?? { url in
            // Само чтение и разбор — вне главного потока: на длинных текстах
            // именно они задерживали скролл.
            await Task.detached(priority: .utility) {
                Preview.make(from: (try? WorkspaceStore.readTextFile(at: url)) ?? "")
            }.value
        }
    }
    /// Записи, у которых расшифровки не было, когда строка просила превью.
    ///
    /// Строка списка зовёт `load` один раз — в своём `.task`. Раньше запись без
    /// расшифровки там же и забывалась, и когда расшифровка дописывалась, карточка
    /// так и оставалась «Запись 21:46» до перезапуска. Теперь такие записи
    /// перечитываются сами, как только рабочая папка увидела новый файл.
    private var missing = Set<String>()
    private weak var workspace: WorkspaceStore?
    private var workspaceChanges: AnyCancellable?

    func preview(for relativePath: String) -> Preview? {
        previews[relativePath]
    }

    /// Ленивое чтение для строки списка: уже прочитанное не перечитывается.
    func load(_ entry: WorkspaceEntry, in workspace: WorkspaceStore) {
        watch(workspace)
        let path = entry.relativePath
        guard previews[path] == nil, !loading.contains(path) else { return }
        guard workspace.existingTranscript(for: entry) != nil else {
            missing.insert(path)
            return
        }
        read(path, in: workspace)
    }

    /// Расшифровку записи сохранили — после работы движка или правки текста.
    ///
    /// Прежнее превью остаётся на экране, пока новое не дочитано: раньше его
    /// сбрасывали заранее, и карточка мигала датой «Запись 21:46», пока файл
    /// читался заново. Звать с путём аудиозаписи, а не расшифровки.
    func transcriptSaved(_ relativePath: String, in workspace: WorkspaceStore) {
        watch(workspace)
        read(relativePath, in: workspace)
    }

    /// Запись переименовали: текст тот же, перечитывать нечего.
    func move(from old: String, to new: String) {
        guard old != new else { return }
        if let preview = previews.removeValue(forKey: old) { previews[new] = preview }
        if missing.remove(old) != nil { missing.insert(new) }
        // Чтение по старому пути, если оно шло, уже никому не нужно.
        generations[old] = nil
        loading.remove(old)
    }

    func invalidate(_ relativePath: String) {
        previews.removeValue(forKey: relativePath)
        missing.remove(relativePath)
        generations[relativePath] = nil
        loading.remove(relativePath)
    }

    func invalidateAll() {
        previews.removeAll()
        missing.removeAll()
        generations.removeAll()
        loading.removeAll()
    }

    // MARK: - Чтение

    private func read(_ path: String, in workspace: WorkspaceStore) {
        let transcript = RecordTitle.transcriptPath(forAudio: path)
        // Предел чтения в 1 МБ (`readableTextURL`) здесь не нужен: многочасовой
        // расшифровке тоже положен заголовок, а читается файл вне главного потока.
        guard let url = try? workspace.fileURL(for: transcript) else {
            // Расшифровки нет (или её удалили) — превью больше не о чем.
            previews.removeValue(forKey: path)
            loading.remove(path)
            missing.insert(path)
            return
        }
        missing.remove(path)
        loading.insert(path)
        lastGeneration += 1
        let generation = lastGeneration
        generations[path] = generation
        let reader = reader
        Task { [weak self] in
            let preview = await reader(url)
            guard let self, self.generations[path] == generation else { return }
            self.loading.remove(path)
            self.previews[path] = preview
        }
    }

    /// Новый снимок рабочей папки — повод проверить записи, у которых не было
    /// расшифровки: `saveTranscript` после работы движка заканчивается снимком.
    private func watch(_ workspace: WorkspaceStore) {
        guard self.workspace !== workspace else { return }
        self.workspace = workspace
        workspaceChanges = workspace.$audio
            .dropFirst()
            .sink { [weak self] _ in
                // Издатель срабатывает до присвоения; к следующему такту снимок уже на месте.
                Task { @MainActor [weak self] in self?.retryMissing() }
            }
    }

    private func retryMissing() {
        guard let workspace, !missing.isEmpty else { return }
        for path in Array(missing) where !loading.contains(path) {
            // `existingTranscript` смотрит только на имя файла — снимок рабочей
            // папки уже знает, появилась ли расшифровка, и диск трогать не нужно.
            let probe = WorkspaceEntry(relativePath: path, isDirectory: false, size: 0, modifiedAt: .distantPast)
            guard workspace.existingTranscript(for: probe) != nil else { continue }
            read(path, in: workspace)
        }
    }
}
