import Foundation
import UIKit

/// Только DEBUG: воспроизводимый device-прогон без личных записей и API.
/// Обычный запуск не использует тестовую папку и не меняет настройки пользователя.
@MainActor
enum RecoveryProbe {
    nonisolated static func allowsDiagnostics(in bundleID: String?) -> Bool {
        bundleID == "ru.ilyaqa.lori.local.qa"
    }

    static var enabled: Bool {
        #if DEBUG
        allowsDiagnostics(in: Bundle.main.bundleIdentifier)
            && ProcessInfo.processInfo.arguments.contains("--recovery-probe")
        #else
        false
        #endif
    }
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori/RecoveryProbe")
    }
    static var queue: URL { root.appending(path: "queue.json") }
    static var summaries: URL { root.appending(path: "summaries.json") }
    private static var started = false
    private static var events: [String] = []

    static func note(_ event: String) {
        guard enabled else { return }
        events.append("\(Date().timeIntervalSince1970): \(event)")
        try? Data(events.joined(separator: "\n").utf8).write(to: root.appending(path: "events.txt"), options: .atomic)
    }

    static func run(workspace: WorkspaceStore, service: TranscriptionService, summaries: SummaryStore, runner: SummaryRunner, runway: TranscriptionRunway) async {
        guard enabled, !started else { return }
        started = true
        note("probe started")
        guard let entry = try? workspace.entry(at: "input.wav") else { note("BLOCKED: missing synthetic input.wav"); return }
        summaries.setManual(title: "Контрольное интервью", for: entry.relativePath)
        if workspace.existingTranscript(for: entry) == nil, service.isIdle {
            service.enqueue(entry, in: workspace, using: .gigaam)
        }
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            let transcript = workspace.existingTranscript(for: entry)
            let jobs = InterruptedRecords.jobs(from: queue)
            let checkpoints = jobs.values.filter { FileManager.default.fileExists(atPath: $0.directory.appending(path: "local.json").path) }.count
            let status: [String: String] = [
                "appState": String(UIApplication.shared.applicationState.rawValue),
                "transcriptSaved": String(transcript != nil),
                "manualTitlePreserved": String(summaries.title(for: entry.relativePath) == "Контрольное интервью"),
                "descriptionSaved": String(summaries.detail(for: entry.relativePath) != nil),
                "interrupted": String(service.interrupted.count),
                "checkpoints": String(checkpoints),
                "pendingSummaries": String(runner.pendingCount),
                "summaryRunning": runner.running ?? "",
                "waitingReason": runner.waitingReason ?? "",
                "availableMB": String(MemoryReport.availableBytes / 1024 / 1024),
                "progress": service.progressText(for: entry.relativePath) ?? "",
                "fraction": service.progressFraction(for: entry.relativePath).map(String.init(describing:)) ?? "",
                "error": service.error(for: entry.relativePath) ?? runner.failure ?? "",
                "runway": String(describing: runway.state),
            ]
            if let data = try? JSONEncoder().encode(status) {
                try? data.write(to: root.appending(path: "status.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            if transcript != nil, summaries.detail(for: entry.relativePath) != nil { note("PASS: transcript + description + manual title"); return }
            if service.error(for: entry.relativePath) != nil { note("FAIL: transcription error"); return }
            try? await Task.sleep(for: .seconds(1))
        }
        note("TIMEOUT")
    }
}
