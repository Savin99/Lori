import SwiftUI

/// Один экран на все облачные сервисы: ключ, адрес, модель, проверка.
/// Конфиги OpenAI, Gemini и ElevenLabs почти совпадают, и трёх похожих экранов
/// быть не должно.
struct ProviderScreen: View {
    let kind: TranscriptionEngineKind
    @ObservedObject var transcription: TranscriptionService

    @AppStorage(TranscriptionSettings.openAIBaseURLKey) private var openAIBaseURL = ""
    @AppStorage(TranscriptionSettings.openAIModelKey) private var openAIModel = ""
    @AppStorage(TranscriptionSettings.geminiBaseURLKey) private var geminiBaseURL = ""
    @AppStorage(TranscriptionSettings.geminiModelKey) private var geminiModel = ""
    @AppStorage(TranscriptionSettings.geminiModeKey) private var geminiMode = GeminiMode.accuracy.rawValue
    @AppStorage(TranscriptionSettings.geminiPartKey) private var geminiPart = TranscriptionSettings.defaultGeminiPart
    @AppStorage(TranscriptionSettings.elevenLabsBaseURLKey) private var elevenLabsBaseURL = ""
    @AppStorage(TranscriptionSettings.elevenLabsModelKey) private var elevenLabsModel = ""

    @State private var key = ""
    @State private var hasKey = false
    @State private var options: [RemoteModel] = []
    @State private var loading = false
    @State private var checking = false
    @State private var result: String?
    @State private var note: String?

    /// У движка без ключа этого экрана не бывает вовсе (`EngineScreen` его не
    /// открывает), поэтому откат к `.openAI` — формальность для компилятора.
    private var account: KeychainAccount { kind.keychainAccount ?? .openAI }

    private var model: Binding<String> {
        switch kind {
        case .openAI: $openAIModel
        case .elevenLabs: $elevenLabsModel
        default: $geminiModel
        }
    }

    private var baseURL: Binding<String> {
        switch kind {
        case .openAI: $openAIBaseURL
        case .elevenLabs: $elevenLabsBaseURL
        default: $geminiBaseURL
        }
    }

    private var defaultBaseURL: String {
        switch kind {
        case .openAI: TranscriptionSettings.defaultOpenAIBaseURL
        case .elevenLabs: TranscriptionSettings.defaultElevenLabsBaseURL
        default: TranscriptionSettings.defaultGeminiHost
        }
    }

    /// Отдаёт ли сервис список моделей распознавания. У ElevenLabs — нет:
    /// `GET /v1/models` там про синтез речи. Кнопка «Обновить список» в таком
    /// случае не показывается: нажатие, которое заведомо ничего не даст, хуже
    /// отсутствия кнопки.
    private var hasModelList: Bool { kind != .elevenLabs }

    private var title: String {
        switch kind {
        case .openAI: "OpenAI"
        case .elevenLabs: "ElevenLabs"
        default: "Google Gemini"
        }
    }

    var body: some View {
        List {
            // Режим выбирается на экране движка — там же, где движок и
            // выбран. Третья вёрстка того же выбора здесь только расходилась
            // с остальными: порядок режимов был свой, названия свои.

            Section("Модель") {
                Picker("Модель", selection: model) {
                    ForEach(listed, id: \.id) { option in
                        modelRow(option).tag(option.id)
                    }
                }
                .accessibilityIdentifier("modelPicker")

                if hasModelList {
                    Button(loading ? "Обновляю список…" : "Обновить список моделей") { loadModels() }
                        .disabled(loading || !hasKey)
                } else {
                    Text("Список моделей распознавания сервис не отдаёт — здесь то, что есть в его документации.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if kind == .gemini {
                Section {
                    Picker("Длина части", selection: $geminiPart) {
                        ForEach(TranscriptionSettings.geminiPartOptions, id: \.self) { minutes in
                            Text("\(minutes) мин").tag(minutes)
                        }
                    }
                    .accessibilityIdentifier("geminiPartPicker")
                } header: {
                    Text("Как запись уходит в сервис")
                } footer: {
                    Text(
                        "Каким куском запись отправляется на расшифровку. В режиме «Точность» сервис "
                        + "времени не возвращает вовсе, и отметка времени в расшифровке — это начало "
                        + "части: короче части — чаще отметки и меньше потеря, если модель собьётся. "
                        + "Длиннее — меньше стыков, а на стыке можно потерять слово. "
                        + "Больше предела сервиса не отправляется в любом случае."
                    )
                    .font(.footnote)
                }
            }

            Section("Ключ") {
                SecureField("Ключ API", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("providerKeyField")

                Button("Сохранить в Keychain") { save() }

                if hasKey {
                    LabeledContent("Статус", value: KeychainStore.statusDescription(for: account))
                    Button(checking ? "Проверяю…" : "Проверить ключ") { validate() }
                        .disabled(checking)
                    if !KeychainStore.usesBundledKey(for: account) {
                        Button(KeychainStore.hasBundledKey(for: account) ? "Вернуть встроенный ключ" : "Удалить ключ", role: .destructive) { remove() }
                    }
                }
            }

            Section("Адрес") {
                TextField("Адрес API", text: baseURL, prompt: Text(defaultBaseURL))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("providerBaseURLField")
                LabeledContent("Запросы идут в", value: TranscriptionSettings.describedTarget(for: kind))
                HStack {
                    Text("Когда это нужно")
                        .font(LoriFont.body)
                        .foregroundStyle(LoriPalette.ink)
                    Spacer()
                    HelpButton(title: "Адрес API", text: help)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(LoriPalette.canvas)
        .navigationTitle(title)
        .task { await load() }
        .onChange(of: baseURL.wrappedValue) { _, _ in
            hasKey = KeychainStore.hasKey(for: account)
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
        let current = model.wrappedValue
        guard !current.isEmpty, !options.contains(where: { $0.id == current }) else { return options }
        return options + [RemoteModel(id: current, title: current, detail: "выбрано раньше")]
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

    private var help: String {
        switch kind {
        case .gemini:
            """
            Google отвечает «User location is not supported for the API use» из части регионов — \
            это про место запроса, а не про ключ. Тогда сюда вписывается адрес своего прокси в \
            поддерживаемом регионе; ссылку на загрузку крупных файлов Lori тоже поведёт через него.

            Запись уходит одним запросом целиком: сервис берёт до часа аудио, а с таймкодами \
            слов или разделением говорящих — до 30 минут. Своей нарезки на куски у приложения \
            больше нет: именно на стыках модель и срывалась в повтор одной фразы.

            Настройки уходят внутри «generation_config.transcription_config», как описано в \
            документации: словарь — до ста терминов, говорящих модель различает до восьми, \
            тайминги приходят нативно, для каждого слова. Режим «Причёсанный текст» сам убирает \
            слова-паразиты, но с таймкодами и говорящими несовместим.

            Если сервис не принимает какое-то поле запроса, Lori убирает именно его и повторяет \
            попытку, а словарь и просьбы про таймкоды в этом случае уходят в текст запроса.
            """
        case .elevenLabs:
            """
            Запись уходит одним запросом целиком: сервис берёт до 5 ГБ и до 10 часов, а резать \
            её нельзя — говорящих он нумерует внутри запроса, и на стыке частей «S1» стал бы другим \
            человеком. Поэтому и полоса здесь показывает только начало и конец: делить нечего.

            Таймкоды и говорящих включают переключатели на экране «Расшифровка» — это единственный \
            движок, где работают оба и независимо друг от друга. Режим на экране движка решает \
            другое: писать ли в текст пометки нереплик (смех, аплодисменты) и причёсывать ли речь.

            Словарь уходит штатным полем «keyterms» — тем самым, что сервис для этого и сделал. \
            Но оно платное: словарь добавляет 20% к стоимости расшифровки. Не нужен — очисти \
            «Словарь» в настройках, и поле не отправится вовсе.

            Адрес меняют только ради прокси: по умолчанию запросы идут прямо в ElevenLabs.
            """
        default:
            """
            Адрес нужен только для совместимого сервиса: Groq, свой whisper-сервер в домашней сети \
            или прокси в другом регионе. По умолчанию запросы идут в OpenAI.

            Тайминги слов даёт whisper. Модели с «diarize» дают реплики с говорящими, но словарь \
            им передавать нельзя — сервис отвечает «Prompt is not supported for diarization models», \
            и Lori в таком случае словарь не отправляет.
            """
        }
    }

    private func load() async {
        hasKey = KeychainStore.hasKey(for: account)
        switch kind {
        case .openAI:
            options = ModelCatalog.openAISuggestions
            if model.wrappedValue.isEmpty { model.wrappedValue = TranscriptionSettings.openAIModel }
        case .elevenLabs:
            options = ModelCatalog.elevenLabsSuggestions
            if model.wrappedValue.isEmpty { model.wrappedValue = TranscriptionSettings.elevenLabsModel }
        default:
            options = ModelCatalog.geminiSuggestions
            if model.wrappedValue.isEmpty { model.wrappedValue = TranscriptionSettings.geminiModel }
        }
        if hasKey, hasModelList { loadModels() }
    }

    private func loadModels() {
        guard hasModelList else { return }
        Task {
            guard let stored = ((try? KeychainStore.key(for: account)) ?? nil), !stored.isEmpty else { return }
            loading = true
            defer { loading = false }
            do {
                let catalog = ModelCatalog()
                let list = kind == .openAI
                    ? try await catalog.openAI(key: stored)
                    : try await catalog.gemini(key: stored)
                if !list.isEmpty { options = list }
                note = nil
            } catch {
                // Список моделей — удобство, а не условие работы: расшифровка может
                // идти и на модели из подсказок.
                note = "Список моделей получить не удалось: \(error.localizedDescription) Ключ при этом может работать."
            }
        }
    }

    private func save() {
        do {
            try KeychainStore.save(key, for: account)
            key = ""
            hasKey = true
            result = "Ключ сохранён в Keychain этого iPhone."
            loadModels()
        } catch {
            result = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try KeychainStore.delete(account)
            hasKey = KeychainStore.hasKey(for: account)
            result = hasKey ? "Используется встроенный ключ." : "Ключ удалён."
        } catch {
            result = error.localizedDescription
        }
    }

    private func validate() {
        Task {
            checking = true
            defer { checking = false }
            do {
                let target: String
                switch kind {
                case .openAI: target = try await OpenAITranscriber().validate()
                case .elevenLabs: target = try await ElevenLabsTranscriber().validate()
                default: target = try await GeminiTranscriber().validate()
                }
                result = "Сервис принял ключ: \(target)."
            } catch {
                result = "Проверка ключа: \(error.localizedDescription)"
            }
        }
    }
}
