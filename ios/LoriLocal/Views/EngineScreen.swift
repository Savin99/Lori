import SwiftUI

/// Выбор движка: радио-список, и конфиг только у выбранного.
struct EngineScreen: View {
    @ObservedObject var transcription: TranscriptionService
    @StateObject private var models = ModelInstallStore()
    @StateObject private var engines = EngineDirectory()

    @AppStorage(TranscriptionSettings.engineKey) private var engineRaw = TranscriptionEngineKind.gigaam.rawValue
    @AppStorage(TranscriptionSettings.gigaAMVariantKey) private var variantRaw = GigaAMVariant.rnnt.rawValue
    @State private var status: String?

    private var engine: TranscriptionEngineKind {
        TranscriptionEngineKind(rawValue: engineRaw) ?? .gigaam
    }

    private var variant: GigaAMVariant {
        GigaAMVariant(rawValue: variantRaw) ?? .rnnt
    }

    private var descriptor: EngineDescriptor { EngineCatalog.descriptor(for: engine) }

    /// Выбор режима пишется туда же, откуда читается чип панели: у движков это
    /// разные ключи, и знать о них должен один `TranscriptionSettings`.
    private func modeBinding(current: TranscriptionMode) -> Binding<String> {
        Binding(
            get: { current.id },
            set: { id in
                guard let mode = descriptor.modes.first(where: { $0.id == id }) else { return }
                TranscriptionSettings.setMode(mode, for: engine)
                engines.refresh()
            }
        )
    }

    var body: some View {
        List {
            EngineSections(directory: engines, selection: $engineRaw)

            Section("Настройки движка") {
                // Режим живёт здесь, а не в общей «Расшифровке»: он свойство
                // движка и запоминается у каждого свой.
                if let mode = TranscriptionSettings.mode(for: engine) {
                    Picker("Режим", selection: modeBinding(current: mode)) {
                        ForEach(descriptor.modes) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .accessibilityIdentifier("modePicker")

                    Text(mode.detail)
                        .font(.footnote)
                        .foregroundStyle(LoriPalette.muted)
                }

                LabeledContent("Состояние", value: status ?? "…")
                    .accessibilityIdentifier("engineStatus")

                switch engine {
                case .gigaam:
                    gigaAM
                case .whisper:
                    // Кнопки скачивания здесь нет и не будет: 632 МБ приложение
                    // само не тянет, поэтому единственное, что можно сказать
                    // человеку, — куда положить папку.
                    Text("Модель на 632 МБ кладётся руками: папка модели в «Файлы» → Lori → Models, а рядом с весами — tokenizer.json и tokenizer_config.json. Аудио остаётся на телефоне.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .apple:
                    Text("Системное распознавание iOS. Ключей не нужно, но пунктуации не будет, и язык берётся системный.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .openAI, .gemini, .elevenLabs:
                    NavigationLink {
                        ProviderScreen(kind: engine, transcription: transcription)
                    } label: {
                        LabeledContent("Провайдер", value: TranscriptionSettings.describedTarget(for: engine))
                    }
                    .accessibilityIdentifier("providerLink")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(LoriPalette.canvas)
        .navigationTitle("Движок")
        .task { await refresh() }
        .onChange(of: engineRaw) { _, _ in Task { await refresh() } }
        .onChange(of: variantRaw) { _, _ in Task { await refresh() } }
        .alert("Lori", isPresented: Binding(
            get: { models.lastError != nil },
            set: { if !$0 { models.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { models.lastError = nil }
        } message: {
            Text(models.lastError ?? "")
        }
    }

    @ViewBuilder
    private var gigaAM: some View {
        // Раньше здесь стоял второй `Picker` на то же значение, что и режим,
        // только под именем «Модель»: два контрола на одну настройку.
        LabeledContent("Модель", value: variant.title)

        if models.working == variant {
            ProgressView(value: models.fraction)
            if let text = models.status {
                LabeledContent("Загрузка", value: text)
            }
            Button("Отменить загрузку", role: .destructive) { models.cancel() }
        } else if models.isInstalled(variant) {
            Button("Удалить модель с телефона", role: .destructive) {
                models.remove(variant)
                Task { await refresh() }
            }
            .accessibilityIdentifier("removeModels")
        } else {
            Button("Скачать модель · \(variant.sizeText)") { models.install(variant) }
                .disabled(models.working != nil)
                .accessibilityIdentifier("downloadModels")
        }

        HStack {
            Text("Подробнее о движке")
                .font(LoriFont.body)
                .foregroundStyle(LoriPalette.ink)
            Spacer()
            HelpButton(
                title: "GigaAM на телефоне",
                text: """
                Модель считает целиком на этом iPhone: аудио никуда не уходит, ключи и интернет \
                не нужны.

                Файлы качаются с HuggingFace (istupakov/gigaam-v3-onnx) — открыто, без регистрации. \
                Размер и контрольная сумма каждого файла проверяются: не сошлось — установка \
                отменяется, а прежняя модель остаётся на месте.

                RNN-T — основной вариант: пунктуация и тайминги слов. CTC — одна модель вместо трёх, \
                считает быстрее.
                """
            )
        }
    }

    private func refresh() async {
        models.refresh()
        if let reason = await transcription.unavailability(of: engine) {
            status = reason.errorDescription
        } else {
            status = "Готов к работе"
        }
    }
}
