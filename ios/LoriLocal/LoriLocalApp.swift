import SwiftUI

@main
struct LoriLocalApp: App {
    @StateObject private var workspace = WorkspaceStore()
    /// Обработка расшифровок нужна и карточке записи, и главному экрану,
    /// поэтому живёт на уровне приложения, как и рабочая папка.
    @StateObject private var digests = DigestService()

    init() {
        UserDefaults.standard.register(defaults: [
            "deepSeekModel": DeepSeekModel.fallback.rawValue,
            "autoProcessTranscripts": true,
            "loriMemory": true,
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspace)
                .environmentObject(digests)
                .task { workspace.start() }
        }
    }
}
