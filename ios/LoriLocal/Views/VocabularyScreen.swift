import SwiftUI

/// Словарь: список слов, а не сырой текст в общем скролле.
struct VocabularyScreen: View {
    @AppStorage(TranscriptionSettings.vocabularyKey) private var vocabulary = ""
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var terms: [String] { TranscriptionSettings.terms(from: vocabulary) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField("Новое слово или имя", text: $draft)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { add() }
                        .accessibilityIdentifier("vocabularyField")
                    Button("Добавить") { add() }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                HStack(alignment: .top, spacing: 8) {
                    Text("Учитывается слов: \(terms.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("vocabularyCount")
                    HelpButton(
                        title: "Словарь",
                        text: """
                        Имена, названия и термины, которые модель обычно перевирает: MCP, Думатель, \
                        оргструктура, крон-задачи.

                        OpenAI получает их штатным полем подсказки, Gemini — в тексте запроса. \
                        Локальные движки (GigaAM, Apple) словарь не умеют и его игнорируют. \
                        Модели с разделением говорящих у OpenAI подсказку не принимают вовсе.

                        Список ограничен по длине: у моделей подсказка живёт в том же лимите, что и \
                        текст расшифровки, и слишком длинный словарь вытесняет сам результат.
                        """
                    )
                }
            }

            if !terms.isEmpty {
                Section("Слова") {
                    ForEach(terms, id: \.self) { term in
                        Text(term)
                            .font(LoriFont.body)
                            .foregroundStyle(LoriPalette.ink)
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(LoriPalette.canvas)
        .navigationTitle("Словарь")
        .toolbar { EditButton() }
    }

    private func add() {
        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var list = terms
        guard !list.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else {
            draft = ""
            return
        }
        list.append(clean)
        save(list)
        draft = ""
        focused = true
    }

    private func delete(_ offsets: IndexSet) {
        var list = terms
        list.remove(atOffsets: offsets)
        save(list)
    }

    /// Словарь пишется сразу в двух местах: в настройки и в файл рабочей папки.
    /// Настройки не доживают до диска, если процесс убить, — а набранные руками
    /// слова человек по памяти не восстановит.
    private func save(_ list: [String]) {
        let text = list.joined(separator: "\n")
        vocabulary = text
        TranscriptionSettings.mirrorVocabulary(text)
    }
}
