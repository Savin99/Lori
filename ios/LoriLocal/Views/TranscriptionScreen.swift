import SwiftUI

/// Что просить у модели: язык и автозапуск, плюс честная сводка того, что даёт
/// выбранный режим.
///
/// Таймкоды и говорящие здесь больше не переключатели, а индикаторы. Пара
/// «режим плюс независимые тумблеры» позволяла собрать состояние, которого у
/// сервиса не бывает: режим «Точность» с подписью «без таймкодов» — и рядом
/// включённый тумблер «Таймкоды реплик». Решает режим, и он живёт в настройках
/// своего движка.
struct TranscriptionScreen: View {
    @ObservedObject var transcription: TranscriptionService

    @AppStorage(TranscriptionSettings.engineKey) private var engineRaw = TranscriptionEngineKind.gigaam.rawValue
    @AppStorage(TranscriptionSettings.languageKey) private var language = TranscriptionSettings.defaultLanguage
    @AppStorage(TranscriptionSettings.timecodesKey) private var timecodes = true
    @AppStorage(TranscriptionSettings.speakerLabelsKey) private var speakerLabels = false
    @AppStorage(TranscriptionSettings.autoTranscribeKey) private var autoTranscribe = true
    @AppStorage(TranscriptionSettings.concurrencyKey) private var concurrency =
        TranscriptionSettings.defaultConcurrency
    // Матрица возможностей зависит от модели OpenAI и режима Gemini: подписка
    // на их ключи перерисовывает тумблеры, когда настройки меняются на других экранах.
    @AppStorage(TranscriptionSettings.openAIModelKey) private var openAIModelRaw = ""
    @AppStorage(TranscriptionSettings.geminiModeKey) private var geminiModeRaw = ""

    private var engine: TranscriptionEngineKind {
        TranscriptionEngineKind(rawValue: engineRaw) ?? .gigaam
    }

    private var toggles: EngineToggles { EngineToggles.current(for: engine) }

    var body: some View {
        List {
            Section {
                Picker("Язык записи", selection: $language) {
                    Text("Русский").tag("ru")
                    Text("Английский").tag("en")
                    Text("Определять сам").tag("")
                }
                .accessibilityIdentifier("languagePicker")

                capabilityToggle("Таймкоды реплик", support: toggles.timecodes, value: $timecodes)
                    .accessibilityIdentifier("timecodesToggle")
                capabilityToggle("Разделять говорящих", support: toggles.speakers, value: $speakerLabels)
                    .accessibilityIdentifier("speakersToggle")

                if let mode = TranscriptionSettings.mode(for: engine) {
                    LabeledContent("Режим движка", value: mode.title)
                        .accessibilityIdentifier("modeSummary")
                }
                Toggle("Расшифровывать запись сразу", isOn: $autoTranscribe)

                Picker("Сразу записей", selection: $concurrency) {
                    ForEach(Array(TranscriptionSettings.concurrencyRange), id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .accessibilityIdentifier("concurrencyPicker")
            } footer: {
                HStack(alignment: .top, spacing: 8) {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HelpButton(title: "Что умеет движок", text: help)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(LoriPalette.canvas)
        .navigationTitle("Расшифровка")
    }

    /// Тумблер, который не притворяется: где возможности нет — выключен и
    /// объясняет это в футере, где она всегда включена — включён без выбора.
    private func capabilityToggle(_ title: String, support: ToggleSupport, value: Binding<Bool>) -> some View {
        let shown: Binding<Bool>
        switch support {
        case .active: shown = value
        case .fixedOn: shown = .constant(true)
        case .unavailable: shown = .constant(false)
        }
        return Toggle(title, isOn: shown).disabled(support != .active)
    }

    /// Пояснения к недоступным тумблерам для текущего движка, плюс предел Gemini.
    private var footnote: String {
        var lines: [String] = []
        for support in [toggles.timecodes, toggles.speakers] {
            if let reason = support.explanation, !lines.contains(reason) { lines.append(reason) }
        }
        if engine == .gemini, TranscriptionSettings.geminiWantsWordTimestamps || TranscriptionSettings.geminiWantsDiarization {
            lines.append("С таймкодами или говорящими Gemini берёт до 30 минут одним запросом.")
        }
        if lines.isEmpty { lines.append("У движков разные возможности.") }
        lines.append(concurrencyNote)
        return lines.joined(separator: " ")
    }

    /// Про число одновременных записей говорим по выбранному движку, а не вообще:
    /// у Whisper веса вчетверо тяжелее, и цена второй записи там совсем другая.
    private var concurrencyNote: String {
        guard concurrency > 1 else {
            return "Записи идут по одной, остальные ждут в очереди."
        }
        let count = LoriFormat.plural(concurrency, one: "запись", few: "записи", many: "записей")
        switch engine {
        case .apple, .openAI, .gemini, .elevenLabs:
            // У Apple своих весов мы не грузим вовсе (распознаёт системная служба),
            // у облачных работа в сети — обещать «общую модель» тут было бы неправдой.
            return "\(count) считаются одновременно; остальные ждут в очереди."
        case .whisper:
            return "\(count) считаются одновременно на общих весах модели — она загружается один раз на всю очередь. У Whisper модель самая тяжёлая, и если памяти не хватит, вторая запись подождёт со строкой «Жду память», а не уронит приложение."
        case .gigaam:
            return "\(count) считаются одновременно на общих весах модели — она загружается один раз на всю очередь."
        }
    }

    private var help: String {
        """
        GigaAM на телефоне: всегда считает таймкоды слов, язык — русский, говорящих не различает. \
        Тумблер «Таймкоды реплик» решает, писать ли время в файл расшифровки.

        Движок Apple: только текст, без таймкодов и говорящих, язык системный.

        OpenAI: язык уходит полем запроса, «Определять сам» — значит поле не отправляется. \
        Таймкоды дают модели whisper, говорящих — модели с «diarize».

        Gemini: всё решает режим в «Настройки → Движок». «Точность» — дословный текст без времени; \
        «Спикеры и таймкоды» — то же плюс поля timestamp_granularities и diarization_mode \
        (предел одного запроса падает с часа до 30 минут); «Причёсанный текст» несовместим ни \
        с тем, ни с другим. Если сервис поле не принял, Lori просит то же самое текстом.

        ElevenLabs Scribe: единственный движок, где оба тумблера работают и независимо — \
        тайминги слов приходят нативно, говорящие включаются отдельным полем. Запись уходит \
        одним запросом целиком, поэтому резать её не нужно и метки говорящих не разъезжаются.

        Выключенные «Таймкоды реплик» убирают время и из файла расшифровки — \
        перемотка тапом по реплике тогда не работает.

        «Расшифровывать запись сразу»: включено — Lori берётся за запись, как только остановишь \
        диктофон. Принесённый файл это не касается: он сначала показывается в панели с движком \
        и оценкой времени, и уходит в работу по нажатию.

        «Сразу записей» — сколько **разных** записей считать в один момент; по умолчанию \
        одна, остальные ждут в очереди. Разрезать между движками одну запись смысла нет: \
        локальные делят один процессор, и сумма времени от этого не уменьшается. Если \
        поднять до двух, веса модели у записей общие, поэтому расход памяти не удваивается; \
        если её всё-таки не хватит, вторая запись подождёт со строкой «Жду память».

        Работа продолжается, когда уходишь из приложения или запираешь телефон: прогресс \
        видно в Dynamic Island и на экране блокировки. Нужна iOS 26 — на более старых \
        расшифровка идёт, только пока приложение открыто. Если систему перестанет \
        устраивать нагрузка, она заберёт процесс: такие записи помечаются «Прервано» и \
        считаются заново при следующем открытии.
        """
    }
}
