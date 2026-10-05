import Foundation

/// Журнал работы, который переживает перезапуск и лежит в рабочей папке.
///
/// Системный журнал устройства без пароля с Mac не забрать: `log collect`
/// требует root, а `sysdiagnose` — согласия на самом телефоне. Поэтому важное
/// приложение пишет себе само: файл рядом с записями видно и через «Файлы»,
/// и через инструменты разработчика, и его можно отдать целиком.
enum Journal {
    /// Больше мегабайта не храним: старая половина отбрасывается.
    static let limit = 1024 * 1024

    static var url: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appending(path: "Lori", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "journal.txt")
    }

    private static let lock = NSLock()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm:ss"
        return formatter
    }()

    /// Когда собран двоичный файл, который сейчас работает.
    ///
    /// **Не украшение.** Разбор поведения на устройстве уже один раз стоил
    /// целого круга: причину искали в коде, а на телефоне стояла позавчерашняя
    /// сборка, и понять это было неоткуда. Версия из `Info.plist` для этого
    /// бесполезна — она всегда «1.0 (1)». Дата правки исполняемого файла
    /// меняется с каждой сборкой сама, без правок в проекте.
    static var buildStamp: String {
        guard let executable = Bundle.main.executableURL,
              let built = try? executable
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        else { return "неизвестно" }
        return stamp.string(from: built)
    }

    /// Первая строка после запуска: по ней видно, что за сборка работает.
    static func noteLaunch() {
        append("запуск: сборка от \(buildStamp)")
    }

    static func append(_ line: String) {
        lock.withLock {
            let text = "\(stamp.string(from: Date())) \(line)\n"
            guard let data = text.data(using: .utf8) else { return }
            let file = url
            guard let handle = try? FileHandle(forWritingTo: file) else {
                try? data.write(to: file, options: .atomic)
                return
            }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
        trim()
    }

    /// Обрезает журнал по границе строки, чтобы файл не рос без конца.
    private static func trim() {
        let file = url
        guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int,
              size > limit,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let kept = text.suffix(limit / 2)
        let whole = kept.drop(while: { $0 != "\n" }).dropFirst()
        try? String(whole).write(to: file, atomically: true, encoding: .utf8)
    }

    static func clear() {
        lock.withLock { try? FileManager.default.removeItem(at: url) }
    }
}
