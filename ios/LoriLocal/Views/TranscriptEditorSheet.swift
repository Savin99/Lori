import SwiftUI

/// Правка расшифровки руками: текст лежит обычным файлом, и человек вправе его
/// поправить, не выходя из приложения.
struct TranscriptEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    let path: String
    /// Заголовок записи (`RecordTitle`): им же называется файл, если поделиться.
    let title: String

    @State private var text = ""
    @State private var loaded = ""
    @State private var error: String?
    @State private var share: SharePayload?
    @State private var confirmDiscard = false

    /// Есть несохранённая правка.
    private var isDirty: Bool { text != loaded }

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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отменить") {
                        if isDirty { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        if save() { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { shareFile() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Поделиться")
                    .accessibilityHint("Файлом Markdown, как он есть сейчас")
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
            .confirmationDialog("Выйти без сохранения?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Не сохранять", role: .destructive) { dismiss() }
                Button("Продолжить правку", role: .cancel) {}
            } message: {
                Text("Правки в тексте пропадут.")
            }
            .alert("Не удалось сохранить", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
        // Смахнуть лист с несохранённой правкой — значит молча её потерять:
        // сохраняет только «Готово». Пока правка есть, выйти можно кнопками.
        .interactiveDismissDisabled(isDirty)
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
    ///
    /// - Returns: можно ли закрывать лист. Раньше лист закрывался и при ошибке
    ///   записи — алерт уезжал вместе с ним, и правка пропадала молча.
    private func save() -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != loaded.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return true }
        do {
            try workspace.writeText(text, at: path)
            loaded = text
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
