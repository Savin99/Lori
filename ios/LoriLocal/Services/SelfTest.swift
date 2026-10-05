import Foundation

/// Самопроверка движка прямо на устройстве.
///
/// Нужна потому, что расшифровку на телефоне иначе нечем запустить без живого нажатия:
/// симулятор врёт (в нём нет ни Core ML-провайдера, ни лимита памяти), а падение на
/// устройстве не оставляет крэш-отчёта. Включается только переменной окружения —
/// обычный запуск с домашнего экрана её не касается:
///
///     xcrun devicectl device process launch --device <udid> \
///       --environment '{"LORI_SELFTEST":"1"}' ru.ilyaqa.lori.local
///
/// Отчёт пишется по шагам в `Documents/Lori/selftest.txt` и сбрасывается на диск после
/// каждой строки: если приложение убьют на середине, в файле останется последний
/// дошедший шаг — именно это и нужно знать.
enum SelfTest {
    static var isRequested: Bool {
        // Аргумент, а не только переменная окружения: `devicectl` умеет передавать
        // приложению аргументы запуска, а окружение — не во всех версиях.
        ProcessInfo.processInfo.arguments.contains("--selftest")
            || ProcessInfo.processInfo.environment["LORI_SELFTEST"] != nil
    }

    /// Рабочая папка живёт на главном акторе, поэтому пути берутся там,
    /// а сама расшифровка идёт уже вне него — она долгая.
    @MainActor
    static func run(in workspace: WorkspaceStore) async {
        let report = Report()
        report.write("самопроверка началась, \(MemoryReport.text)")

        let engine = TranscriptionSettings.engine
        report.write("движок из настроек: \(engine.rawValue), вариант GigaAM: \(TranscriptionSettings.gigaAMVariant.rawValue)")

        guard let entry = pickAudio(in: workspace) else {
            report.write("в рабочей папке нет аудио — расшифровывать нечего")
            return
        }
        report.write("файл: \(entry.relativePath), \(entry.size) байт")

        guard let url = try? workspace.fileURL(for: entry.relativePath) else {
            report.write("файл не читается")
            return
        }

        let engines: [TranscriptionEngineKind: any Transcribing] = [
            .gigaam: GigaAMTranscriber(),
            .apple: AppleSpeechTranscriber(),
            .openAI: OpenAITranscriber(),
            .gemini: GeminiTranscriber(),
        ]
        let chosen = engines[engine] ?? GigaAMTranscriber()
        report.write("движок: \(chosen.name)")
        guard await chosen.isAvailable() else {
            report.write("движок недоступен: нет модели или ключа")
            return
        }

        let started = Date()
        do {
            let transcript = try await chosen.transcribe(audioURL: url) { done, total in
                report.write("кусок \(min(done + 1, total)) из \(total), \(MemoryReport.text)")
            }
            let seconds = Date().timeIntervalSince(started)
            report.write(String(format: "готово за %.1f с, символов %d, слов с таймингами %d",
                                seconds, transcript.text.count, transcript.words.count))
            report.write("начало текста: \(transcript.text.prefix(160))")
            report.write("память после: \(MemoryReport.text)")
        } catch {
            report.write("ошибка: \(error.localizedDescription)")
            report.write("память на момент ошибки: \(MemoryReport.text)")
        }
    }

    /// Берётся самая свежая запись: её же человек и пробовал расшифровать.
    @MainActor
    private static func pickAudio(in workspace: WorkspaceStore) -> WorkspaceEntry? {
        (try? workspace.audioEntries())?.first
    }

    /// Отчёт с немедленным сбросом на диск: если процесс убьют, файл должен
    /// содержать всё, что успело произойти.
    private final class Report: @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var lines: [String] = []

        init() {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let directory = documents.appending(path: "Lori", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appending(path: "selftest.txt")
        }

        func write(_ line: String) {
            Diagnostics.log.notice("самопроверка: \(line, privacy: .public)")
            lock.withLock {
                lines.append(line)
                try? Data(lines.joined(separator: "\n").appending("\n").utf8)
                    .write(to: url, options: .atomic)
            }
        }
    }
}
