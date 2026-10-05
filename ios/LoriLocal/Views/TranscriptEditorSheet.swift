import SwiftUI

/// Правка расшифровки руками: текст лежит обычным файлом, и человек вправе его
/// поправить, не выходя из приложения.
struct TranscriptEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    let path: String
    let title: String

    @State private var text = ""
    @State private var loaded = ""
    @State private var error: String?
    @State private var share: SharePayload?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $text)
                    .font(LoriFont.body)
                    .foregroundStyle(LoriPalette.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .accessibilityIdentifier("transcriptEditor")
            }
            .background(LoriPalette.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") {
                        save()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { shareFile() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Поделиться")
                }
            }
            .task {
                guard let url = try? workspace.readableTextURL(at: path) else { return }
                let value = await Task.detached(priority: .userInitiated) {
                    (try? WorkspaceStore.readTextFile(at: url)) ?? ""
                }.value
                text = value
                loaded = value
            }
            .sheet(item: $share) { payload in
                ShareSheet(payload: payload)
            }
            .alert("Lori", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
        // Снаружи стека — по той же причине, что и в настройках: внутри плашку
        // перекрывает навигационная панель.
        .recordingBanner { dismiss() }
    }

    /// Экран правит сам файл расшифровки — значит и наружу уходит он же, файлом
    /// `.md`, а не строкой в теле сообщения. Выбора формата здесь нет намеренно:
    /// PDF собирают с экрана записи, где есть шапка, время и имена говорящих.
    private func shareFile() {
        let name = "\(TranscriptExport.safeName(title)).\(TranscriptExportFormat.markdown.fileExtension)"
        do {
            share = SharePayload(
                url: try TranscriptExportFile.write(Data(text.utf8), name: name),
                subject: title
            )
        } catch {
            self.error = "Не удалось собрать файл: \(error.localizedDescription)"
        }
    }

    /// Пустой текст не сохраняется: это почти всегда промах по клавиатуре,
    /// а не желание стереть расшифровку.
    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != loaded.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return }
        do {
            try workspace.writeText(text, at: path)
            loaded = text
        } catch {
            self.error = error.localizedDescription
        }
    }
}
