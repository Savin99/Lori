import SwiftUI
import UIKit

/// Настройки ассистента: ключ, адрес совместимого сервиса и модель.
///
/// Отдельно от экранов расшифровки, потому что это другой сервис и другой ключ.
/// Форма та же, что у `ProviderScreen`: ключ в Keychain, адрес — обычное поле,
/// модель — выбор из списка, который отдал сам сервис.
struct AssistantProviderScreen: View {
    @AppStorage(AssistantSettings.baseURLKey) private var baseURL = ""
    @AppStorage(AssistantSettings.modelKey) private var model = ""

    @State private var key = ""
    @State private var hasKey = false
    @State private var options: [RemoteModel] = []
    @State private var loading = false
    @State private var checking = false
    @State private var result: String?
    @State private var note: String?

    var body: some View {
        List {
            Section("Модель") {
                Picker("Модель", selection: $model) {
                    ForEach(listed, id: \.id) { option in
                        modelRow(option).tag(option.id)
                    }
                }
                .accessibilityIdentifier("assistantModelPicker")

                Button(loading ? "Обновляю список…" : "Обновить список моделей") { loadModels() }
                    .disabled(loading || !hasKey)

                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Ключ") {
                SecureField("Ключ API", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("assistantKeyField")

                Button("Сохранить в Keychain") { save() }

                // Один и тот же ключ на расшифровку и на вопросы — обычный
                // случай, и перепечатывать его вручную незачем.
                if KeychainStore.hasKey(for: .openAI) {
                    Button("Взять ключ OpenAI-расшифровки") { borrowOpenAIKey() }
                }

                if hasKey {
                    LabeledContent("Статус", value: KeychainStore.statusDescription(for: .assistant))
                    Button(checking ? "Проверяю…" : "Проверить ключ") { validate() }
                        .disabled(checking)
                    if !KeychainStore.usesBundledKey(for: .assistant) {
                        Button(KeychainStore.hasBundledKey(for: .assistant) ? "Вернуть встроенный ключ" : "Удалить ключ", role: .destructive) { remove() }
                    }
                }
            }

            Section("Адрес") {
                TextField("Адрес API", text: $baseURL, prompt: Text(AssistantSettings.defaultBaseURL))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("assistantBaseURLField")

                // Подсказка, а не переключатель: адрес всегда виден целиком
                // в поле выше, и кнопка только вписывает в него готовую строку.
                ForEach(AssistantSettings.presets) { preset in
                    Button("Подставить адрес \(preset.title)") { baseURL = preset.baseURL }
                }

                LabeledContent("Запросы идут в", value: AssistantSettings.describedTarget)
                HStack {
                    Text("Что уходит наружу")
                        .font(LoriFont.body)
                        .foregroundStyle(LoriPalette.ink)
                    Spacer()
                    HelpButton(title: "Ассистент", text: Self.help)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(LoriPalette.canvas)
        .navigationTitle("Ассистент")
        .task { load() }
        .onChange(of: baseURL) { _, _ in
            hasKey = AssistantSettings.hasKey
        }
        .alert("Lori", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("Скопировать") {
                UIPasteboard.general.string = result
                result = nil
            }
            Button("OK", role: .cancel) { result = nil }
        } message: {
            Text(result ?? "")
        }
    }

    /// Выбранная модель обязана быть в списке, иначе `Picker` показывает пустоту.
    private var listed: [RemoteModel] {
        guard !model.isEmpty, !options.contains(where: { $0.id == model }) else { return options }
        return options + [RemoteModel(id: model, title: model, detail: "выбрано раньше")]
    }

    @ViewBuilder
    private func modelRow(_ option: RemoteModel) -> some View {
        if let detail = option.detail {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                Text(detail)
                    .font(LoriFont.small)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(option.title)
        }
    }

    static let help = """
    Вопрос уходит выбранному сервису вместе с текстом тех расшифровок, по которым \
    вы спрашиваете, — и только когда нажата кнопка «Спросить». Аудиозаписи не \
    уходят никогда, названия файлов и остальное содержимое рабочей папки тоже.

    Какие именно куски отправятся, приложение выбирает у себя на телефоне: \
    по совпадению слов вопроса со словами расшифровки. Если весь выбор помещается \
    в бюджет запроса, уходит он целиком; если нет, экран «Спроси» говорит, сколько \
    кусков осталось за бортом.

    Подойдёт любой сервис с интерфейсом OpenAI — сама OpenAI, DeepSeek, Groq или \
    свой сервер в домашней сети. Ключ хранится в Keychain этого iPhone и к движку \
    расшифровки отношения не имеет: их можно держать у разных провайдеров.
    """

    private func load() {
        hasKey = AssistantSettings.hasKey
        options = ModelCatalog.chatSuggestions
        if model.isEmpty { model = AssistantSettings.defaultModel }
        if hasKey { loadModels() }
    }

    private func loadModels() {
        Task {
            guard let stored = ((try? KeychainStore.key(for: .assistant)) ?? nil), !stored.isEmpty else { return }
            loading = true
            defer { loading = false }
            do {
                let list = try await ModelCatalog().chat(key: stored)
                if !list.isEmpty { options = list }
                note = nil
            } catch {
                // Список моделей — удобство, а не условие работы: спросить можно
                // и на модели из подсказок.
                note = "Список моделей получить не удалось: \(error.localizedDescription) Ключ при этом может работать."
            }
        }
    }

    private func save() {
        do {
            try KeychainStore.save(key, for: .assistant)
            key = ""
            hasKey = true
            result = "Ключ сохранён в Keychain этого iPhone."
            loadModels()
        } catch {
            result = error.localizedDescription
        }
    }

    /// Ключ переносится между аккаунтами внутри Keychain: показывать его на
    /// экране незачем, да и нельзя.
    private func borrowOpenAIKey() {
        do {
            guard let stored = try KeychainStore.key(for: .openAI), !stored.isEmpty else {
                result = "Ключ OpenAI не сохранён: Настройки → Движок → OpenAI."
                return
            }
            try KeychainStore.save(stored, for: .assistant)
            hasKey = true
            result = "Ассистент теперь пользуется ключом OpenAI."
            loadModels()
        } catch {
            result = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try KeychainStore.delete(.assistant)
            hasKey = KeychainStore.hasKey(for: .assistant)
            result = hasKey ? "Используется встроенный ключ." : "Ключ удалён."
        } catch {
            result = error.localizedDescription
        }
    }

    /// Проверка ключа — запрос списка моделей: он самый дешёвый и отвечает
    /// ровно на вопрос «ключ рабочий».
    private func validate() {
        Task {
            checking = true
            defer { checking = false }
            do {
                guard let stored = try KeychainStore.key(for: .assistant), !stored.isEmpty else {
                    throw TranscriptionError.missingKey(.assistant)
                }
                _ = try await ModelCatalog().chat(key: stored)
                result = "Сервис принял ключ: \(AssistantSettings.describedTarget)."
            } catch {
                result = "Проверка ключа: \(error.localizedDescription)"
            }
        }
    }
}
