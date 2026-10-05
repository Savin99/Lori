import SwiftUI

/// Настройки: четыре строки, а не один бесконечный скролл.
///
/// Раньше на одном экране лежали конфиги всех четырёх движков сразу, и текста было
/// больше, чем контролов. Теперь корень показывает только текущие значения, а
/// подробности живут в своих экранах.
struct SettingsRoot: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var topics: TopicStore

    @AppStorage(TranscriptionSettings.engineKey) private var engineRaw = TranscriptionEngineKind.gigaam.rawValue
    @AppStorage(TranscriptionSettings.languageKey) private var language = TranscriptionSettings.defaultLanguage
    @AppStorage(TranscriptionSettings.timecodesKey) private var timecodes = true
    @AppStorage(TranscriptionSettings.speakerLabelsKey) private var speakerLabels = false
    @AppStorage(TranscriptionSettings.vocabularyKey) private var vocabulary = ""
    // Сводка «Расшифровки» зависит от модели OpenAI и режима Gemini: подписка
    // на их ключи обновляет строку после правок на дочерних экранах.
    @AppStorage(TranscriptionSettings.openAIModelKey) private var openAIModelRaw = ""
    @AppStorage(TranscriptionSettings.geminiModeKey) private var geminiModeRaw = ""
    // Строка «Ассистент» показывает модель: подписка на ключ обновляет её
    // после выбора на дочернем экране.
    @AppStorage(AssistantSettings.modelKey) private var assistantModelRaw = ""
    @State private var assistantHasKey = false

    private var engine: TranscriptionEngineKind {
        TranscriptionEngineKind(rawValue: engineRaw) ?? .gigaam
    }

    @EnvironmentObject private var summaryModels: SummaryModelStore

    /// Что показать в строке «Заголовки»: скачана модель или нет.
    private var summaryValue: String {
        let ready = SummaryVariant.allCases.filter(summaryModels.isInstalled)
        guard let best = ready.first else { return "выключены" }
        return best.title.lowercased()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        EngineScreen(transcription: transcription)
                    } label: {
                        row("Движок", symbol: "cpu", value: engineValue)
                    }
                    .accessibilityIdentifier("settingsEngine")

                    NavigationLink {
                        TranscriptionScreen(transcription: transcription)
                    } label: {
                        row("Расшифровка", symbol: "doc.text", value: transcriptionValue)
                    }
                    .accessibilityIdentifier("settingsTranscription")

                    NavigationLink {
                        SummaryScreen(models: summaryModels)
                    } label: {
                        row("Заголовки", symbol: "text.quote", value: summaryValue)
                    }
                    .accessibilityIdentifier("settingsSummary")

                    NavigationLink {
                        AssistantProviderScreen()
                    } label: {
                        // Без ключа ассистент не работает вовсе, и строка это
                        // показывает цветом, а не только словами.
                        row(
                            "Ассистент",
                            symbol: "sparkles",
                            value: assistantValue,
                            warning: !assistantHasKey
                        )
                    }
                    .accessibilityIdentifier("settingsAssistant")

                    NavigationLink {
                        VocabularyScreen()
                    } label: {
                        row("Словарь", symbol: "book", value: LoriFormat.plural(
                            TranscriptionSettings.terms(from: vocabulary).count,
                            one: "слово", few: "слова", many: "слов"
                        ))
                    }
                    .accessibilityIdentifier("settingsVocabulary")

                    NavigationLink {
                        StorageScreen(topics: topics)
                    } label: {
                        row("Хранилище", symbol: "folder", value: LoriFormat.plural(
                            workspace.fileTotal,
                            one: "файл", few: "файла", many: "файлов"
                        ))
                    }
                    .accessibilityIdentifier("settingsStorage")
                }
            }
            .scrollContentBackground(.hidden)
            .background(LoriPalette.canvas)
            .navigationTitle("Настройки")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
            .onAppear { assistantHasKey = AssistantSettings.hasKey }
            .onChange(of: assistantModelRaw) { assistantHasKey = AssistantSettings.hasKey }
        }
        // Плашка записи — снаружи `NavigationStack`: внутри её накрывает большой
        // заголовок, и нажатие достаётся заголовку, а не плашке.
        .recordingBanner { dismiss() }
    }

    /// Ассистент без ключа не работает вовсе — об этом честнее сказать в строке,
    /// а не за два экрана отсюда. Сам ключ спрашивается у Keychain на появлении
    /// экрана, а не в теле View: обращение к Keychain на каждую перерисовку —
    /// синхронный системный вызов на главном потоке.
    private var assistantValue: String {
        assistantHasKey ? AssistantSettings.model : "ключа нет"
    }

    private var engineValue: String {
        engine == .gigaam ? "GigaAM v3" : engine.title
    }

    private var transcriptionValue: String {
        var parts: [String] = []
        switch language {
        case "": parts.append("язык сам")
        case "en": parts.append("английский")
        default: parts.append("русский")
        }
        // Сводка не обещает того, чего выбранный режим не даёт: «говорящие»
        // у Apple выглядели бы работающей настройкой, а она там мертва.
        let toggles = EngineToggles.current(for: engine)
        switch toggles.timecodes {
        case .active: if timecodes { parts.append("таймкоды") }
        case .fixedOn: parts.append("таймкоды")
        case .unavailable: break
        }
        switch toggles.speakers {
        case .active: if speakerLabels { parts.append("говорящие") }
        case .fixedOn: parts.append("говорящие")
        case .unavailable: break
        }
        // Числа «сколько сразу» здесь нет сознательно: строка и так упирается в
        // многоточие, а вытеснять ею «таймкоды» и «говорящих» — менять важное на
        // второстепенное. Оно живёт на самом экране «Расшифровка».
        return parts.joined(separator: ", ")
    }

    private func row(_ title: String, symbol: String, value: String, warning: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(LoriFont.meta.weight(.medium))
                .foregroundStyle(LoriPalette.lime)
                .frame(width: 24)
            Text(title)
                .font(LoriFont.body)
                .foregroundStyle(LoriPalette.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(LoriFont.meta)
                .foregroundStyle(warning ? LoriPalette.warn : LoriPalette.muted)
                .lineLimit(1)
        }
    }
}

/// Длинные пояснения не должны занимать экран: они прячутся за «?».
struct HelpButton: View {
    let title: String
    let text: String

    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(LoriPalette.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Подробнее: \(title)")
        .sheet(isPresented: $shown) {
            NavigationStack {
                ScrollView {
                    Text(text)
                        .font(LoriFont.body)
                        .foregroundStyle(LoriPalette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .background(LoriPalette.canvas)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("Готово") { shown = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
