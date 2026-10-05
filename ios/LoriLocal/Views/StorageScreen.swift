import SwiftUI
import UIKit

/// Хранилище: где лежат файлы, сколько их, куда отправлять и как открыть.
struct StorageScreen: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @ObservedObject var topics: TopicStore
    @Environment(\.openURL) private var openURL

    @AppStorage(ObsidianExport.vaultKey) private var vault = ""
    @State private var showJournal = false
    @State private var shownPath: String?

    var body: some View {
        List {
            Section("Рабочая папка") {
                LabeledContent("Файлов", value: String(workspace.fileTotal))
                // Сырой путь к контейнеру — не то, что человек читает каждый
                // день: он нужен раз в жизни, когда файлы забирают с Mac.
                // Долгое нажатие показывает его и кладёт в буфер.
                Button("Открыть в Файлах") { openFiles() }
                    .accessibilityIdentifier("openInFiles")
                    .contextMenu {
                        Button("Скопировать путь", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = workspace.rootPath
                            shownPath = workspace.rootPath
                        }
                    }
                if let shownPath {
                    Text(shownPath)
                        .font(.footnote)
                        .foregroundStyle(LoriPalette.muted)
                        .textSelection(.enabled)
                }
            }

            Section("Журнал работы") {
                Button("Показать журнал") { showJournal = true }
                    .accessibilityIdentifier("showJournal")
                Button("Очистить журнал") { Journal.clear() }
                Text("Приложение записывает, что уходит в сервис расшифровки и что приходит обратно: поля запроса, размер ответа, сколько разобрано слов, попытки и срывы. По этому файлу видно причину, когда расшифровка пришла пустой или оборванной.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Obsidian") {
                TextField("Название хранилища", text: $vault)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("obsidianVaultField")
                Text("Свайп по карточке → Obsidian создаёт заметку в этом хранилище. Название видно в самом Obsidian, в списке хранилищ.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !topics.topics.isEmpty {
                Section("Темы") {
                    ForEach(topics.topics, id: \.self) { topic in
                        LabeledContent(topic, value: String(topics.count(of: topic)))
                    }
                    .onDelete { offsets in
                        for index in offsets { topics.remove(topics.topics[index]) }
                    }
                    Text("Темы живут в метаданных, а не папками: переименование темы не ломает пути к расшифровкам.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(LoriPalette.canvas)
        .navigationTitle("Хранилище")
        .toolbar { EditButton() }
        .sheet(isPresented: $showJournal) { JournalSheet() }
    }

    /// «Файлы» открываются по своей схеме на папке приложения.
    private func openFiles() {
        let path = workspace.rootPath
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "shareddocuments://\(encoded)") else { return }
        openURL(url)
    }
}
