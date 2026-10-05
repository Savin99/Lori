import Foundation

struct WorkspaceEntry: Identifiable, Hashable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let size: Int
    let modifiedAt: Date

    var id: String { relativePath }
    var name: String { URL(fileURLWithPath: relativePath).lastPathComponent }

    /// Заголовок для списка: расширение в имени заметки — шум.
    var displayName: String {
        isDirectory ? name : (name as NSString).deletingPathExtension
    }

    var isAudio: Bool {
        !isDirectory && WorkspaceEntry.audioExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff", "aif", "mp4", "mov"]
}

enum WorkspaceError: LocalizedError, Equatable, Sendable {
    case unsafePath
    case notText
    case tooLarge
    case notFound
    case importFailed
    case invalidName
    /// Имя занято другой записью или её расшифровкой.
    case nameTaken

    var errorDescription: String? {
        switch self {
        case .unsafePath: "Недопустимый путь: доступ разрешён только внутри рабочей папки Lori."
        case .notText: "Lori может открыть только UTF-8 текстовый файл."
        case .tooLarge: "Файл превышает лимит чтения 1 МБ."
        case .notFound: "Файл не найден."
        case .importFailed: "Не удалось добавить файл в рабочую папку Lori."
        case .invalidName: "Укажи корректное название без символов «/» и «\\»."
        case .nameTaken: "Запись с таким именем уже есть"
        }
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    nonisolated static let maxTextBytes = 1_000_000

    private struct Snapshot: Sendable {
        let entries: [WorkspaceEntry]
        let audio: [WorkspaceEntry]
        let fileTotal: Int
        let files: Set<String>
    }

    @Published private(set) var entries: [WorkspaceEntry] = []
    /// Все записи рабочей папки, новые сверху: главный экран — это их список.
    @Published private(set) var audio: [WorkspaceEntry] = []
    @Published private(set) var fileTotal = 0
    @Published private(set) var rootPath = ""
    @Published var lastError: String?

    private let root: URL
    private let fileManager: FileManager
    /// Снимок файлов нужен не только списку. Без него каждая карточка при
    /// любом обновлении прогресса делала `fileExists` для своей расшифровки.
    private var knownFiles = Set<String>()
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            root = rootURL.standardizedFileURL
        } else {
            let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            root = documents.appending(path: "Lori/Workspace", directoryHint: .isDirectory)
        }
        rootPath = root.path
    }

    func start() {
        do {
            try ensureRoot()
            removeStaleImportLeftovers()
            requestRefresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() throws {
        refreshTask?.cancel()
        refreshGeneration += 1
        apply(try Self.makeSnapshot(root: root, fileManager: fileManager))
    }

    /// Обход всей рабочей папки не должен задерживать первый кадр и нажатия.
    /// Публикация остаётся на главном акторе, сам файловый обход идёт фоном.
    func requestRefresh() {
        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        let root = root
        refreshTask = Task { [weak self] in
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try Self.makeSnapshot(root: root, fileManager: .default)
                }.value
                guard !Task.isCancelled, let self, self.refreshGeneration == generation else { return }
                self.apply(snapshot)
                self.refreshTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.refreshGeneration == generation else { return }
                self.lastError = error.localizedDescription
                self.refreshTask = nil
            }
        }
    }

    /// Все аудиофайлы рабочей папки, новые сверху. Обход рекурсивный: записи с
    /// диктофона лежат в `Recordings`, принесённые файлы — в `Imported`,
    /// и человеку это различие в списке не нужно.
    func audioEntries() throws -> [WorkspaceEntry] {
        try ensureRoot()
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard let walker = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [WorkspaceEntry] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { continue }
            let relativePath = String(path.dropFirst(root.path.count + 1))
            // Корзина и сами расшифровки в списке записей не нужны.
            guard !relativePath.hasPrefix(".LoriTrash/"), !relativePath.hasPrefix("Transcripts/") else { continue }
            let entry = WorkspaceEntry(
                relativePath: relativePath,
                isDirectory: false,
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
            guard entry.isAudio else { continue }
            result.append(entry)
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Содержимое одной запрошенной папки, без обхода вложенных.
    /// Все пути остаются относительными корня рабочей папки Lori.
    func entries(at relativePath: String = "") throws -> [WorkspaceEntry] {
        try ensureRoot()
        let directory = try safeURL(for: relativePath)
        guard fileManager.fileExists(atPath: directory.path) else { throw WorkspaceError.notFound }
        try rejectSymbolicLinks(for: relativePath)
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard directoryValues.isDirectory == true else { throw WorkspaceError.notText }

        let values: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(values),
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: values)
            guard values.isSymbolicLink != true else { return nil }
            let name = url.lastPathComponent
            guard name != ".LoriTrash" else { return nil }
            return WorkspaceEntry(
                relativePath: relativePath.isEmpty ? name : "\(relativePath)/\(name)",
                isDirectory: values.isDirectory ?? false,
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Абсолютный URL внутри песочницы: движку расшифровки нужен файл, а не текст.
    /// Проверки пути и симлинков те же, что у чтения.
    func fileURL(for relativePath: String) throws -> URL {
        let target = try safeURL(for: relativePath)
        guard fileManager.fileExists(atPath: target.path) else { throw WorkspaceError.notFound }
        try rejectSymbolicLinks(for: relativePath)
        return target
    }

    func readText(at relativePath: String) throws -> String {
        try Self.readTextFile(at: readableTextURL(at: relativePath))
    }

    /// Проверяет путь на главном акторе, после чего сам файл можно читать в
    /// `Task.detached`: URL уже ограничен рабочей папкой и не является ссылкой.
    func readableTextURL(at relativePath: String) throws -> URL {
        let target = try safeURL(for: relativePath)
        guard fileManager.fileExists(atPath: target.path) else { throw WorkspaceError.notFound }
        try rejectSymbolicLinks(for: relativePath)
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw WorkspaceError.notText }
        guard (values.fileSize ?? 0) <= Self.maxTextBytes else { throw WorkspaceError.tooLarge }
        return target
    }

    nonisolated static func readTextFile(at target: URL) throws -> String {
        guard let text = try? String(contentsOf: target, encoding: .utf8) else { throw WorkspaceError.notText }
        return text
    }

    func writeText(_ text: String, at relativePath: String) throws {
        let target = try safeURL(for: relativePath)
        try rejectSymbolicLinks(for: relativePath)
        try ensureRoot()
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target, options: .atomic)
        try refresh()
    }

    func moveToTrash(_ relativePath: String) throws {
        let source = try safeURL(for: relativePath)
        guard fileManager.fileExists(atPath: source.path) else { throw WorkspaceError.notFound }
        try rejectSymbolicLinks(for: relativePath)
        let trash = root.appending(path: ".LoriTrash", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString)-\(source.lastPathComponent)"
        try fileManager.moveItem(at: source, to: trash.appending(path: name))
        try refresh()
    }

    func rename(_ relativePath: String, to destinationPath: String) throws {
        let source = try safeURL(for: relativePath)
        let destination = try safeURL(for: destinationPath)
        guard fileManager.fileExists(atPath: source.path) else { throw WorkspaceError.notFound }
        try rejectSymbolicLinks(for: relativePath)
        try rejectSymbolicLinks(for: destinationPath)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            guard isSameFile(source, destination) else { throw WorkspaceError.nameTaken }
            // Тот же файл под другим регистром букв (файловая система регистр не
            // различает): прямой перенос она считает занятым местом, поэтому —
            // через временное имя рядом.
            let detour = source.deletingLastPathComponent().appending(path: ".lori-rename-\(UUID().uuidString)")
            try fileManager.moveItem(at: source, to: detour)
            do {
                try fileManager.moveItem(at: detour, to: destination)
            } catch {
                try? fileManager.moveItem(at: detour, to: source)
                throw error
            }
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
        try refresh()
    }

    /// Один и тот же файл: так выглядит смена регистра букв там, где файловая
    /// система регистр не различает (симулятор на Mac).
    private func isSameFile(_ first: URL, _ second: URL) -> Bool {
        guard let one = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let other = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return one.isEqual(other)
    }

    /// Имя свободно — или занято тем же самым файлом.
    private func ensureFree(_ destinationPath: String, for sourcePath: String?) throws {
        let destination = try safeURL(for: destinationPath)
        guard fileManager.fileExists(atPath: destination.path) else { return }
        if let sourcePath, let source = try? safeURL(for: sourcePath), isSameFile(source, destination) { return }
        throw WorkspaceError.nameTaken
    }

    /// Переименование внутри той же папки. Расширение файла сохраняется, если пользователь его не указал.
    @discardableResult
    func renameItem(at relativePath: String, toName newName: String) throws -> String {
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              !cleanName.contains("/"),
              !cleanName.contains("\\"),
              !cleanName.hasPrefix("."),
              cleanName != "..",
              cleanName != ".LoriTrash" else {
            throw WorkspaceError.invalidName
        }
        var parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let oldName = parts.popLast() else { throw WorkspaceError.unsafePath }
        let parent = parts.joined(separator: "/")

        let source = try safeURL(for: relativePath)
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let oldExtension = (oldName as NSString).pathExtension
        var finalName = cleanName
        // Сравнивается окончание, а не `pathExtension`: у «Совещание 27.08»
        // «расширение» — «08», и запись теряла «.m4a» и пропадала из списка.
        if !isDirectory, !oldExtension.isEmpty, !cleanName.lowercased().hasSuffix(".\(oldExtension.lowercased())") {
            finalName = "\(cleanName).\(oldExtension)"
        }

        let destination = parent.isEmpty ? finalName : "\(parent)/\(finalName)"
        guard destination != relativePath else { return relativePath }
        try rename(relativePath, to: destination)
        return destination
    }

    /// Copies a user-selected document into the sandboxed workspace. The picker grants
    /// temporary access only to this exact URL; no directory-wide access is requested.
    /// Возвращает путь копии внутри рабочей папки: чат показывает вложение карточкой,
    /// и для этого ему нужен путь, а не только факт успеха.
    ///
    /// Правила импорта общие с `importFileAsync`: формат проверяется до копирования,
    /// имя не должно делить расшифровку с уже лежащей записью, копия кладётся целиком или
    /// не кладётся вовсе, а дата изменения ставится на момент импорта.
    @discardableResult
    func importFile(
        from externalURL: URL,
        into relativeDirectory: String = "Imported",
        modifiedAt: Date = .now
    ) throws -> String {
        let (destinationDirectory, name) = try prepareImport(from: externalURL, into: relativeDirectory)
        let didAccess = externalURL.startAccessingSecurityScopedResource()
        defer { if didAccess { externalURL.stopAccessingSecurityScopedResource() } }

        let taken = Self.occupiedBaseNames(in: root)
        let destination = reserveImportDestination(in: destinationDirectory, preferredName: name, taken: taken)
        defer { releaseImportReservation(destination) }
        try Self.copyAtomically(from: externalURL, to: destination, modifiedAt: modifiedAt)
        try refresh()
        return importedPath(destination, in: relativeDirectory)
    }

    /// Большая запись копируется не на главном потоке. Иначе после нажатия
    /// «Расшифровать» интерфейс замирал на всё время копирования из staging.
    ///
    /// Что делает импорт, и почему:
    /// - **Формат проверяется до копирования.** `.ogg`, `.opus`, `.flac` раньше доезжали до
    ///   `Imported/`, но в список записей не попадали (`WorkspaceEntry.audioExtensions`) и
    ///   падали с «Расшифровать можно только аудиофайл»; человек не находил запись.
    /// - **Имя уникально по базе, а не по полному имени.** Расшифровка лежит в
    ///   `Transcripts/<база>.md`, и `Совещание.m4a` рядом с `Совещание.mp3` — или такая же
    ///   база в `Recordings/` и `Imported/` — делили бы один файл текста: вторая расшифровка
    ///   затирала бы первую. Занятыми считаются база любого аудио в любой папке и база любой
    ///   расшифровки (текст мог пережить удалённое аудио). Имя при этом остаётся таким, как
    ///   дали, пока не занято; занято — получает номер: «Совещание 2.mp3».
    /// - **Дата изменения — момент импорта.** Список «новые сверху» сортируется по ней, а
    ///   копия сохраняет дату оригинала: запись месячной давности ушла бы в середину списка,
    ///   и человек, только что добавивший пять файлов, не находил бы их наверху. Своей
    ///   «даты записи» у приложения нет — везде (группы по дням, подпись карточки, экспорт,
    ///   оглавление ассистента) читается именно `modifiedAt`, так что у принесённой записи
    ///   это день её принесения.
    /// - **Копия целиком или никак.** Файл копируется под скрытым именем и только потом
    ///   переименовывается: оборванная посреди копия не должна лежать под настоящим именем и
    ///   выглядеть записью.
    @discardableResult
    func importFileAsync(
        from externalURL: URL,
        into relativeDirectory: String = "Imported",
        modifiedAt: Date = .now
    ) async throws -> String {
        let (destinationDirectory, name) = try prepareImport(from: externalURL, into: relativeDirectory)

        // Обход всей папки — не на главном акторе. Выбор имени после него — синхронный и
        // на главном акторе, поэтому два импорта разом не выберут одно имя: второй увидит
        // бронь первого.
        let root = root
        let taken = await Task.detached(priority: .userInitiated) {
            Self.occupiedBaseNames(in: root)
        }.value
        let destination = reserveImportDestination(in: destinationDirectory, preferredName: name, taken: taken)
        defer { releaseImportReservation(destination) }
        let didAccess = externalURL.startAccessingSecurityScopedResource()

        try await Task.detached(priority: .userInitiated) {
            defer { if didAccess { externalURL.stopAccessingSecurityScopedResource() } }
            try Self.copyAtomically(from: externalURL, to: destination, modifiedAt: modifiedAt)
        }.value

        requestRefresh()
        return importedPath(destination, in: relativeDirectory)
    }

    /// Откат импорта: убирает файл, который `importFileAsync` только что создал.
    ///
    /// Не «Удалить запись» (та уходит в корзину): здесь файл — наша свежая копия, а
    /// оригинал по-прежнему лежит в промежуточной папке, так что терять нечего. Нужен,
    /// когда за импортом не удалось поставить запись в очередь: оставить её в списке
    /// «Без расшифровки» значило бы вернуть человеку работу, которую он уже отдал.
    func discardImportedFile(at relativePath: String) {
        guard let url = try? fileURL(for: relativePath) else { return }
        try? fileManager.removeItem(at: url)
        requestRefresh()
    }

    // MARK: - Импорт: подготовка, имена, копирование

    /// Проверки, общие для обоих вариантов импорта. Возвращает папку назначения и имя файла.
    private func prepareImport(from externalURL: URL, into relativeDirectory: String) throws -> (URL, String) {
        try ensureRoot()
        let name = externalURL.lastPathComponent
        guard !name.isEmpty, !name.contains("/") else { throw WorkspaceError.importFailed }
        guard ImportInbox.isSupported(fileName: name) else { throw ImportError.unsupportedFormat(fileName: name) }
        let destinationDirectory = try safeURL(for: relativeDirectory)
        try rejectSymbolicLinks(for: relativeDirectory)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        return (destinationDirectory, name)
    }

    private func importedPath(_ destination: URL, in relativeDirectory: String) -> String {
        let filename = destination.lastPathComponent
        return relativeDirectory.isEmpty ? filename : "\(relativeDirectory)/\(filename)"
    }

    /// Базы имён, уже занятые в рабочей папке: любого аудио (в любой папке, при любом
    /// расширении) и любой расшифровки. Корзина (`.LoriTrash`) и скрытое не в счёт — их не
    /// видно ни в списке, ни в поиске расшифровки.
    nonisolated static func occupiedBaseNames(in root: URL) -> Set<String> {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var taken = Set<String>()
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { continue }
            let relative = path.dropFirst(root.path.count + 1)
            let suffix = url.pathExtension.lowercased()
            if relative.hasPrefix("Transcripts/") {
                if suffix == "md" { taken.insert(baseKey(url.deletingPathExtension().lastPathComponent)) }
            } else if WorkspaceEntry.audioExtensions.contains(suffix) {
                taken.insert(baseKey(url.deletingPathExtension().lastPathComponent))
            }
        }
        return taken
    }

    /// Ключ для сравнения баз. Файловая система iOS не различает регистр и форму
    /// юникода («й» одним знаком и «и» с краткой), так что «Совещание» и «СОВЕЩАНИЕ» —
    /// одно и то же имя, и сравнивать их надо как одно.
    nonisolated static func baseKey(_ base: String) -> String {
        base.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Базы, под которые копия уже выбрана, но файла ещё нет. Без этого два импорта,
    /// идущих одновременно, выбрали бы одно имя: файла ещё нет ни у одного.
    private var reservedImportBases: Set<String> = []

    /// Выбирает имя и тут же бронирует его до конца копирования. Всё синхронно на главном
    /// акторе — именно это и делает выбор безопасным.
    private func reserveImportDestination(in directory: URL, preferredName: String, taken: Set<String>) -> URL {
        let preferred = directory.appending(path: preferredName)
        let base = preferred.deletingPathExtension().lastPathComponent
        let suffix = preferred.pathExtension
        var index = 1
        while true {
            let candidate = index == 1 ? base : "\(base) \(index)"
            let key = Self.baseKey(candidate)
            if !taken.contains(key), !reservedImportBases.contains(key), !isTakenOnDisk(candidate, in: directory) {
                reservedImportBases.insert(key)
                return directory.appending(path: suffix.isEmpty ? candidate : "\(candidate).\(suffix)")
            }
            index += 1
        }
    }

    private func releaseImportReservation(_ destination: URL) {
        reservedImportBases.remove(Self.baseKey(destination.deletingPathExtension().lastPathComponent))
    }

    /// Свежая проверка прямо на диске: обход мог начаться раньше, чем закончился
    /// предыдущий импорт этой же пачки, и не видеть его файл, а бронь к этому времени уже снята.
    private func isTakenOnDisk(_ base: String, in directory: URL) -> Bool {
        let transcript = root.appending(path: "Transcripts").appending(path: "\(base).md")
        if fileManager.fileExists(atPath: transcript.path) { return true }
        return WorkspaceEntry.audioExtensions.contains { suffix in
            fileManager.fileExists(atPath: directory.appending(path: "\(base).\(suffix)").path)
        }
    }

    /// Копирует целиком или не копирует вовсе и ставит дату изменения.
    ///
    /// Под скрытым именем (`.lori-import-<uuid>.partial`): точка прячет файл от списка
    /// записей и «Файлов», а переименование в той же папке происходит разом. Упади процесс
    /// посреди копии — под настоящим именем не останется обрубка, который выглядел бы
    /// записью и расшифровывался в мусор; остаток подберёт `removeStaleImportLeftovers`.
    nonisolated private static func copyAtomically(from source: URL, to destination: URL, modifiedAt: Date) throws {
        let manager = FileManager.default
        let partial = destination.deletingLastPathComponent()
            .appending(path: "\(importLeftoverPrefix)\(UUID().uuidString)\(importLeftoverSuffix)")
        do {
            try manager.copyItem(at: source, to: partial)
            try manager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: partial.path)
            try manager.moveItem(at: partial, to: destination)
        } catch {
            try? manager.removeItem(at: partial)
            throw error
        }
    }

    nonisolated private static let importLeftoverPrefix = ".lori-import-"
    nonisolated private static let importLeftoverSuffix = ".partial"

    /// Недокопированное с прошлого запуска. Зовётся только при старте, когда ни один
    /// импорт ещё идти не может, — чужую копию «в процессе» отсюда не удалить.
    private func removeStaleImportLeftovers() {
        let directory = root.appending(path: "Imported", directoryHint: .isDirectory)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(Self.importLeftoverPrefix) && name.hasSuffix(Self.importLeftoverSuffix) {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
    }

    func makeRecordingURL() throws -> URL {
        try ensureRoot()
        let recordings = root.appending(path: "Recordings", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: recordings, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        return recordings.appending(path: "Recording-\(stamp).m4a")
    }

    /// Расшифровка на запись одна: перерасшифровка другим движком заменяет текст,
    /// а не оставляет рядом «имя 2.md» — иначе после трёх попыток в папке каша.
    @discardableResult
    func saveTranscript(_ transcript: Transcript, for audioURL: URL, engine: String? = nil, mode: String? = nil) throws -> String {
        let base = audioURL.deletingPathExtension().lastPathComponent
        let directory = try safeURL(for: "Transcripts")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let relativePath = "Transcripts/\(base).md"
        // Выключенные «Таймкоды реплик» убирают время и из файла — иначе тумблер
        // работал бы только у облачных движков, а у GigaAM время приходит всегда.
        try writeText(
            transcript.markdown(title: base, engine: engine, mode: mode, stamps: TranscriptionSettings.timecodes),
            at: relativePath
        )
        return relativePath
    }

    /// Сборка Markdown и атомарная запись длинной расшифровки не задерживают
    /// финальное обновление интерфейса после работы движка.
    @discardableResult
    func saveTranscriptAsync(
        _ transcript: Transcript,
        for audioURL: URL,
        engine: String? = nil,
        mode: String? = nil
    ) async throws -> String {
        let base = audioURL.deletingPathExtension().lastPathComponent
        let relativePath = "Transcripts/\(base).md"
        let target = try safeURL(for: relativePath)
        try rejectSymbolicLinks(for: relativePath)
        let markdown = transcript.markdown(
            title: base,
            engine: engine,
            mode: mode,
            stamps: TranscriptionSettings.timecodes
        )
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(markdown.utf8).write(to: target, options: .atomic)
        }.value
        // Состояние карточки меняется сразу; полный индекс догоняет фоном.
        knownFiles.insert(relativePath)
        requestRefresh()
        return relativePath
    }

    /// Запись о конкретном файле: нужна интерфейсу, когда путь известен, а списка ещё нет.
    func entry(at relativePath: String) throws -> WorkspaceEntry {
        let url = try fileURL(for: relativePath)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return WorkspaceEntry(
            relativePath: relativePath,
            isDirectory: values.isDirectory ?? false,
            size: values.fileSize ?? 0,
            modifiedAt: values.contentModificationDate ?? .now
        )
    }

    /// Переименовать запись вместе с её расшифровкой.
    ///
    /// `newName` — заголовок так, как его набрал человек; имя файла выводится
    /// из него (`RecordTitle.fileBaseName`): «/» и «:» становятся «-», длина
    /// укладывается в предел файловой системы, расширение записи сохраняется.
    /// Сам заголовок хранит `SummaryStore.setManual` — ровно таким, как набран.
    ///
    /// Расшифровка ищется по имени аудиофайла (`Transcripts/<имя>.md`), поэтому
    /// переименование только аудио оставляло текст сиротой: на экране он
    /// пропадал, и запись приходилось прогонять заново. Здесь оба файла едут
    /// вместе, а если текст переименовать не удалось — возвращается и аудио,
    /// чтобы не остаться в разъехавшемся состоянии. Занятое имя — ошибка
    /// `nameTaken` до того, как сдвинулся хоть один файл.
    ///
    /// Возвращает новый путь записи; тот же путь — имя файла не поменялось.
    @discardableResult
    func renameRecording(at relativePath: String, toName newName: String) throws -> String {
        var parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let oldName = parts.popLast() else { throw WorkspaceError.unsafePath }
        let parent = parts.joined(separator: "/")
        let suffix = (oldName as NSString).pathExtension
        guard let base = RecordTitle.fileBaseName(for: newName, extension: suffix) else {
            throw WorkspaceError.invalidName
        }
        let fileName = suffix.isEmpty ? base : "\(base).\(suffix)"
        let destination = parent.isEmpty ? fileName : "\(parent)/\(fileName)"
        guard destination != relativePath else { return relativePath }

        // Расшифровку проверяем на диске, а не по снимку папки: снимок мог не
        // успеть за только что сохранённым текстом.
        let transcriptPath = RecordTitle.transcriptPath(forAudio: relativePath)
        let transcript = (try? fileURL(for: transcriptPath)) != nil ? transcriptPath : nil
        let transcriptDestination = RecordTitle.transcriptPath(forAudio: destination)

        // Имя занято — другой записью, её расшифровкой или осиротевшим текстом:
        // переименование в него слило бы две записи в одну. Запись с тем же
        // именем в соседней папке тоже в счёт: расшифровка у них была бы общей.
        try ensureFree(destination, for: relativePath)
        try ensureFree(transcriptDestination, for: transcript)
        let namesake = audio.contains { other in
            other.relativePath != relativePath && (other.name as NSString).deletingPathExtension == base
        }
        guard !namesake else { throw WorkspaceError.nameTaken }

        try rename(relativePath, to: destination)
        guard let transcript, transcript != transcriptDestination else { return destination }
        do {
            try rename(transcript, to: transcriptDestination)
        } catch {
            try? rename(destination, to: relativePath)
            throw error
        }
        return destination
    }

    /// Уже готовая расшифровка для аудиофайла, если она есть.
    func existingTranscript(for entry: WorkspaceEntry) -> String? {
        let base = (entry.name as NSString).deletingPathExtension
        let relativePath = "Transcripts/\(base).md"
        return knownFiles.contains(relativePath) ? relativePath : nil
    }

    private func apply(_ snapshot: Snapshot) {
        knownFiles = snapshot.files
        entries = snapshot.entries
        audio = snapshot.audio
        fileTotal = snapshot.fileTotal
    }

    /// Один обход вместо прежних трёх: корень, аудио и количество файлов
    /// раньше независимо перечитывали одну и ту же папку.
    nonisolated private static func makeSnapshot(root: URL, fileManager: FileManager) throws -> Snapshot {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let topKeys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ]
        let topURLs = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(topKeys),
            options: [.skipsHiddenFiles]
        )
        let entries = try topURLs.compactMap { url -> WorkspaceEntry? in
            let values = try url.resourceValues(forKeys: topKeys)
            guard values.isSymbolicLink != true, url.lastPathComponent != ".LoriTrash" else { return nil }
            return WorkspaceEntry(
                relativePath: url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard let walker = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return Snapshot(entries: entries, audio: [], fileTotal: 0, files: [])
        }

        var audio: [WorkspaceEntry] = []
        var files = Set<String>()
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { continue }
            let relativePath = String(path.dropFirst(root.path.count + 1))
            files.insert(relativePath)
            guard !relativePath.hasPrefix("Transcripts/") else { continue }
            let entry = WorkspaceEntry(
                relativePath: relativePath,
                isDirectory: false,
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
            if entry.isAudio { audio.append(entry) }
        }
        audio.sort { $0.modifiedAt > $1.modifiedAt }
        return Snapshot(entries: entries, audio: audio, fileTotal: files.count, files: files)
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func safeURL(for relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return root }
        guard !trimmed.hasPrefix("/"), !trimmed.contains("\\"), !trimmed.contains("\0") else {
            throw WorkspaceError.unsafePath
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(".."), !parts.contains(".") else { throw WorkspaceError.unsafePath }
        let target = parts.reduce(root) { $0.appending(path: $1) }.standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else { throw WorkspaceError.unsafePath }
        return target
    }

    private func rejectSymbolicLinks(for relativePath: String) throws {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var cursor = root
        for part in parts {
            cursor.append(path: part)
            if fileManager.fileExists(atPath: cursor.path) {
                let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw WorkspaceError.unsafePath }
            }
        }
    }

    private func uniqueDestination(in directory: URL, preferredName: String) -> URL {
        let preferred = directory.appending(path: preferredName)
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }
        let base = preferred.deletingPathExtension().lastPathComponent
        let extensionPart = preferred.pathExtension
        var index = 2
        while true {
            let candidateName = extensionPart.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(extensionPart)"
            let candidate = directory.appending(path: candidateName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
