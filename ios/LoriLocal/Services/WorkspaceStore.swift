import Foundation

struct WorkspaceEntry: Identifiable, Hashable {
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

enum WorkspaceError: LocalizedError, Equatable {
    case unsafePath
    case notText
    case tooLarge
    case notFound
    case mutationsDisabled
    case importFailed
    case invalidFolderName
    case invalidName

    var errorDescription: String? {
        switch self {
        case .unsafePath: "Недопустимый путь: доступ разрешён только внутри рабочей папки Lori."
        case .notText: "Lori может открыть только UTF-8 текстовый файл."
        case .tooLarge: "Файл превышает лимит чтения 1 МБ."
        case .notFound: "Файл не найден."
        case .mutationsDisabled: "Изменение файлов ИИ отключено в настройках."
        case .importFailed: "Не удалось добавить файл в рабочую папку Lori."
        case .invalidFolderName: "Укажи корректное название папки."
        case .invalidName: "Укажи корректное название без символов «/» и «\\»."
        }
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    static let maxTextBytes = 1_000_000
    /// Папки, которые создаёт само приложение: в списке заметок они не должны стоять первыми.
    static let generatedFolders: Set<String> = ["Recordings", "Transcripts"]

    @Published private(set) var entries: [WorkspaceEntry] = []
    @Published private(set) var noteTotal = 0
    @Published private(set) var rootPath = ""
    @Published var lastError: String?

    private let root: URL
    private let fileManager: FileManager

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
            try refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() throws {
        entries = try entries(at: "")
        noteTotal = noteCount()
    }

    /// Lists only the exact subfolder requested by the user or the assistant.
    /// Every returned path stays relative to the Lori workspace root.
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
        let target = try safeURL(for: relativePath)
        guard fileManager.fileExists(atPath: target.path) else { throw WorkspaceError.notFound }
        try rejectSymbolicLinks(for: relativePath)
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw WorkspaceError.notText }
        guard (values.fileSize ?? 0) <= Self.maxTextBytes else { throw WorkspaceError.tooLarge }
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
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
        try refresh()
    }

    /// Создаёт заметку. Имя берётся из первой непустой строки текста, иначе из даты.
    @discardableResult
    func createNote(in relativeDirectory: String = "", content: String = "") throws -> String {
        try ensureRoot()
        let directory = try safeURL(for: relativeDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = uniqueDestination(in: directory, preferredName: noteFilename(for: content)).lastPathComponent
        let relativePath = relativeDirectory.isEmpty ? filename : "\(relativeDirectory)/\(filename)"
        try writeText(content, at: relativePath)
        return relativePath
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
        if !isDirectory, !oldExtension.isEmpty, (cleanName as NSString).pathExtension.isEmpty {
            finalName = "\(cleanName).\(oldExtension)"
        }

        let destination = parent.isEmpty ? finalName : "\(parent)/\(finalName)"
        guard destination != relativePath else { return relativePath }
        try rename(relativePath, to: destination)
        return destination
    }

    @discardableResult
    func createFolder(named name: String, in relativeDirectory: String = "") throws -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              !cleanName.contains("/"),
              !cleanName.contains("\\"),
              cleanName != ".",
              cleanName != ".." else {
            throw WorkspaceError.invalidFolderName
        }
        let relativePath = relativeDirectory.isEmpty ? cleanName : "\(relativeDirectory)/\(cleanName)"
        let destination = try safeURL(for: relativePath)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        try refresh()
        return relativePath
    }

    /// Copies a user-selected document into the sandboxed workspace. The picker grants
    /// temporary access only to this exact URL; no directory-wide access is requested.
    /// Возвращает путь копии внутри рабочей папки: чат показывает вложение карточкой,
    /// и для этого ему нужен путь, а не только факт успеха.
    @discardableResult
    func importFile(from externalURL: URL, into relativeDirectory: String = "Inbox") throws -> String {
        try ensureRoot()
        let didAccess = externalURL.startAccessingSecurityScopedResource()
        defer { if didAccess { externalURL.stopAccessingSecurityScopedResource() } }

        let destinationDirectory = try safeURL(for: relativeDirectory)
        try rejectSymbolicLinks(for: relativeDirectory)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let name = externalURL.lastPathComponent
        guard !name.isEmpty, !name.contains("/") else { throw WorkspaceError.importFailed }
        let destination = uniqueDestination(in: destinationDirectory, preferredName: name)
        try fileManager.copyItem(at: externalURL, to: destination)
        try refresh()
        let filename = destination.lastPathComponent
        return relativeDirectory.isEmpty ? filename : "\(relativeDirectory)/\(filename)"
    }

    func makeRecordingURL() throws -> URL {
        try ensureRoot()
        let recordings = root.appending(path: "Recordings", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: recordings, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        return recordings.appending(path: "Recording-\(stamp).m4a")
    }

    @discardableResult
    func saveTranscript(_ transcript: Transcript, for audioURL: URL) throws -> String {
        let base = audioURL.deletingPathExtension().lastPathComponent
        let directory = try safeURL(for: "Transcripts")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = uniqueDestination(in: directory, preferredName: "\(base).md").lastPathComponent
        let relativePath = "Transcripts/\(name)"
        try writeText(transcript.markdown(title: base), at: relativePath)
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

    /// Уже готовая расшифровка для аудиофайла, если она есть.
    func existingTranscript(for entry: WorkspaceEntry) -> String? {
        let base = (entry.name as NSString).deletingPathExtension
        let relativePath = "Transcripts/\(base).md"
        guard let url = try? safeURL(for: relativePath),
              fileManager.fileExists(atPath: url.path) else { return nil }
        return relativePath
    }

    func executeTool(named name: String, arguments: String, allowMutations: Bool) -> String {
        do {
            let payload = try parseArguments(arguments)
            switch name {
            case "list_files":
                let requestedPath = payload["path"] as? String ?? ""
                let listed = try entries(at: requestedPath)
                let lines = listed.map { entry -> String in
                    "\(entry.isDirectory ? "[папка]" : "[файл]") \(entry.relativePath) \(entry.isDirectory ? "" : "(\(entry.size) байт)")"
                }
                return lines.isEmpty ? "Папка пуста." : lines.joined(separator: "\n")
            case "read_text_file":
                guard let path = payload["path"] as? String else { throw WorkspaceError.unsafePath }
                return try readText(at: path)
            case "write_text_file":
                guard allowMutations else { throw WorkspaceError.mutationsDisabled }
                guard let path = payload["path"] as? String, let content = payload["content"] as? String else { throw WorkspaceError.unsafePath }
                try writeText(content, at: path)
                return "Файл записан: \(path)"
            case "rename_file":
                guard allowMutations else { throw WorkspaceError.mutationsDisabled }
                guard let path = payload["path"] as? String, let destination = payload["destination"] as? String else { throw WorkspaceError.unsafePath }
                try rename(path, to: destination)
                return "Файл перемещён: \(destination)"
            case "move_to_trash":
                guard allowMutations else { throw WorkspaceError.mutationsDisabled }
                guard let path = payload["path"] as? String else { throw WorkspaceError.unsafePath }
                try moveToTrash(path)
                return "Файл перемещён в локальную корзину: \(path)"
            default:
                return "Инструмент недоступен: \(name)"
            }
        } catch {
            return "Ошибка инструмента: \(error.localizedDescription)"
        }
    }

    /// Сколько файлов лежит в рабочей папке, включая вложенные. Скрытое и корзина не считаются.
    /// Считается только при refresh: обход файловой системы в теле View дал бы работу на каждый кадр.
    private func noteCount() -> Int {
        guard let walker = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var count = 0
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        }
        return count
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

    private func parseArguments(_ arguments: String) throws -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkspaceError.unsafePath
        }
        return object
    }

    private func noteFilename(for content: String) -> String {
        let firstLine = content
            .split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        var title = firstLine
            .replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\r\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while title.hasPrefix(".") { title.removeFirst() }
        title = String(title.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            return "Заметка \(formatter.string(from: .now)).md"
        }
        return "\(title).md"
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
