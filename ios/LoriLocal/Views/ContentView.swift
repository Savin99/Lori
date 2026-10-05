import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Палитра и шрифты внутренние, а не приватные: их используют все экраны.
enum LoriPalette {
    /// Цвета заданы парой «светлый — тёмный»: тёмная тема не должна быть
    /// кремовой наизнанку, у неё свои плотности. Раньше палитра была жёстко
    /// светлой, а весь интерфейс держался на `preferredColorScheme(.light)`.
    private static func pair(
        light: (Double, Double, Double, Double),
        dark: (Double, Double, Double, Double)
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0, green: value.1, blue: value.2, alpha: value.3)
        })
    }

    static let canvas = pair(light: (0.961, 0.957, 0.914, 1), dark: (0.071, 0.071, 0.067, 1))
    static let card = pair(light: (1, 1, 1, 0.86), dark: (1, 1, 1, 0.06))
    static let ink = pair(light: (0.12, 0.12, 0.11, 1), dark: (0.957, 0.953, 0.925, 1))
    /// Цвет текста на заливке `ink` и `lime`: в тёмной теме сама заливка светлая,
    /// и белые надписи на ней исчезали.
    static let onInk = pair(light: (1, 1, 1, 1), dark: (0.071, 0.071, 0.067, 1))
    static let muted = pair(light: (0.44, 0.44, 0.41, 1), dark: (0.64, 0.64, 0.61, 1))
    static let line = pair(light: (0, 0, 0, 0.12), dark: (1, 1, 1, 0.14))
    static let bubble = pair(light: (0.917, 0.914, 0.878, 1), dark: (1, 1, 1, 0.10))
    static let lime = pair(light: (0.36, 0.47, 0.0, 1), dark: (0.66, 0.78, 0.29, 1))
    static let limeSoft = pair(light: (0.89, 0.92, 0.73, 1), dark: (0.24, 0.29, 0.11, 1))
    /// Состояния в карточке: идёт работа, ждёт очереди, сорвалось.
    /// Работа идёт: тот же оливковый, только приглушённый. Синий рядом с
    /// оливковым читался как второй акцент — и получалось два «главных» цвета
    /// на экране: зелёная галочка движка и синяя галочка режима.
    static let info = pair(light: (0.42, 0.52, 0.16, 1), dark: (0.60, 0.72, 0.30, 1))
    /// Второй говорящий и прочее, что надо просто отличить от первого.
    /// Не акцент: приглушённый тёплый, а не спорящий с оливковым синий.
    static let accentAlt = pair(light: (0.45, 0.36, 0.24, 1), dark: (0.78, 0.66, 0.48, 1))
    /// Цвет чужого бренда — единственное место, где он оправдан. Пара нужна и
    /// ему: в тёмной теме глухой фиолетовый сливался с фоном.
    static let obsidian = pair(light: (0.42, 0.29, 0.62, 1), dark: (0.66, 0.55, 0.86, 1))
    static let warn = pair(light: (0.62, 0.44, 0.05, 1), dark: (0.91, 0.73, 0.35, 1))
    static let danger = pair(light: (0.66, 0.16, 0.13, 1), dark: (0.94, 0.48, 0.44, 1))
}

/// Шрифты приложения. Всё через семантические стили и `relativeTo`,
/// иначе интерфейс не реагирует на системный размер текста.
enum LoriFont {
    static let display = Font.custom("Georgia", size: 30, relativeTo: .largeTitle)
    static let displaySmall = Font.custom("Georgia", size: 27, relativeTo: .title2)
    static let section = Font.system(.subheadline, weight: .medium)
    static let cardTitle = Font.system(.headline)
    static let meta = Font.system(.subheadline)
    static let body = Font.system(.body)
    static let bubble = Font.system(.body)
    static let small = Font.system(.footnote)
    /// Иконки и стрелки внутри чипов: мельче подписи, но всё ещё масштабируемый.
    static let tiny = Font.system(.caption2)
    static let control = Font.system(.body, weight: .semibold)
}

/// Главный экран: список расшифровок.
///
/// Карточка отвечает на вопрос «что это за запись» без открытия: заголовок из первых
/// слов расшифровки, две строки текста, длительность и состояние. Название движка
/// сюда не выведено — это настройка, а не свойство записи.
struct ContentView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @StateObject private var recorder = AudioCaptureStore()
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var runway: TranscriptionRunway
    @StateObject private var search = TranscriptSearchStore()
    @StateObject private var topics = TopicStore()
    @StateObject private var durations = RecordingDurations()
    @StateObject private var previews = TranscriptPreviews()

    @State private var showSettings = false
    @State private var opened: WorkspaceEntry?
    @State private var showFileImporter = false
    @State private var query = ""
    @State private var isSearching = false
    @State private var startError: String?
    @State private var topicFilter: String?
    @State private var topicTarget: WorkspaceEntry?
    @State private var renameTarget: WorkspaceEntry?
    @State private var renameDraft = ""
    @State private var newTopicName = ""
    @State private var showNewTopic = false
    @State private var share: SharePayload?
    /// Запись, для которой спрашивают формат экспорта.
    @State private var shareTarget: WorkspaceEntry?
    @State private var showAsk = false
    /// Запись из ссылки в ответе открывается после того, как лист «Спросить»
    /// закрылся: два листа подряд в одном такте SwiftUI просто теряет.
    @State private var pendingOpen: WorkspaceEntry?
    /// Секунда из ссылки в ответе: запись открывается сразу на ней.
    @State private var pendingSeek: TimeInterval?
    /// Вопрос, с которым открывают тред. Пустой — просто вернуться к разговору.
    @State private var askedQuestion = ""
    /// Секунда, на которую откроется запись из ссылки.
    @State private var openedSeek: TimeInterval?
    @FocusState private var searchFocused: Bool

    @AppStorage(TranscriptionSettings.autoTranscribeKey) private var autoTranscribe = true
    @AppStorage(TranscriptionSettings.engineKey) private var engineRaw = TranscriptionEngineKind.gigaam.rawValue
    @StateObject private var engines = EngineDirectory()
    @EnvironmentObject private var summaries: SummaryStore
    @EnvironmentObject private var summaryModels: SummaryModelStore
    @EnvironmentObject private var summaryRunner: SummaryRunner
    @State private var showEnginePicker = false
    @StateObject private var composer = ComposerModel()
    @StateObject private var assistant = AssistantThreadStore()
    @StateObject private var speakers = SpeakerNames()
    @StateObject private var speed = TranscriptionSpeed()
    @State private var importingAttached = false
    /// Строка «Спрошу по 5 расшифровкам · 92 тыс. знаков». Считается при входе
    /// в вопрос и при смене охвата, а не на каждое нажатие клавиши.
    @State private var contextSummary: String?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LoriPalette.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                if isSearching {
                    searchResults
                } else {
                    recordings
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composerBar }
            .onChange(of: transcription.lastMeasure) { _, measure in
                guard let measure else { return }
                speed.record(
                    audio: measure.audio,
                    spent: measure.spent,
                    engine: measure.engine,
                    mode: measure.mode
                )
            }
        }
        .tint(LoriPalette.lime)
        .sheet(isPresented: $showSettings) {
            SettingsRoot(transcription: transcription, topics: topics)
        }
        .sheet(item: $opened) { entry in
            TranscriptScreen(
                entry: entry,
                transcription: transcription,
                topics: topics,
                previews: previews,
                isRecording: recorder.isCapturing,
                startAt: openedSeek
            )
        }
        .sheet(isPresented: $showAsk, onDismiss: openPending) {
            AssistantThreadScreen(
                store: assistant,
                scopes: askScopes,
                initialScopeID: composer.scopeID,
                initialQuestion: askedQuestion,
                title: title(for:),
                detail: { summaries.detail(for: $0.relativePath) },
                topic: { topics.topic(for: $0.relativePath) },
                onOpen: { citation in
                    pendingOpen = try? workspace.entry(at: citation.path)
                    pendingSeek = citation.start
                }
            )
        }
        .sheet(item: $topicTarget) { entry in
            TopicSheet(
                topics: topics,
                title: title(for: entry),
                path: entry.relativePath,
                suggestion: suggestion(for: entry)
            )
        }
        .sheet(item: $share) { payload in
            ShareSheet(payload: payload)
        }
        .confirmationDialog(
            "Поделиться расшифровкой",
            isPresented: isPresented($shareTarget),
            titleVisibility: .visible,
            presenting: shareTarget
        ) { entry in
            ForEach(TranscriptExportFormat.allCases) { format in
                Button(format.title) { export(entry, as: format) }
            }
        } message: { _ in
            Text("PDF удобно читать и отправлять, Markdown — работать с текстом дальше.")
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff],
            allowsMultipleSelection: true,
            onCompletion: attachFiles
        )
        .alert("Переименовать", isPresented: isPresented($renameTarget)) {
            TextField("Название", text: $renameDraft)
            Button("Отмена", role: .cancel) { renameTarget = nil }
            Button("Готово") { commitRename() }
        }
        .alert("Новая тема", isPresented: $showNewTopic) {
            TextField("Название темы", text: $newTopicName)
            Button("Отмена", role: .cancel) { newTopicName = "" }
            Button("Добавить") {
                if let added = topics.add(newTopicName) { topicFilter = added }
                newTopicName = ""
            }
        }
        .alert("Lori", isPresented: Binding(
            get: { activeError != nil },
            set: { if !$0 { clearErrors() } }
        )) {
            Button("Скопировать") {
                UIPasteboard.general.string = activeError
                clearErrors()
            }
            Button("OK", role: .cancel) { clearErrors() }
        } message: {
            Text(activeError ?? "")
        }
        // Только снаружи всех `.sheet`: объект окружения достаётся лишь тому,
        // что лежит внутри обёртки, иначе плашка записи в листе роняет приложение.
        .environmentObject(recorder)
        .environmentObject(assistant)
        .environmentObject(speakers)
        .environmentObject(speed)
    }

    // MARK: - Шапка

    /// Шапка без названия экрана. «Расшифровки» — единственное, что здесь могло
    /// быть написано, и это ровно то, на что человек и так смотрит: список
    /// расшифровок занимает весь экран. Освободившуюся строку заняли темы.
    private var header: some View {
        Group {
            if isSearching {
                TranscriptSearchBar(query: $query, focus: $searchFocused) {
                    isSearching = false
                    query = ""
                    search.clear()
                    searchFocused = false
                }
                .onChange(of: query) { _, value in search.apply(value) }
                .padding(.horizontal, 20)
            } else {
                HStack(spacing: 8) {
                    topicMenu

                    Spacer(minLength: 0)

                    CircleIconButton(symbol: "magnifyingglass", label: "Искать по расшифровкам") {
                        isSearching = true
                        searchFocused = true
                        search.reindex(workspace)
                    }
                    // Вход в разговор — всегда, а не только когда он уже есть.
                    // Иначе попасть к ассистенту можно было единственным путём:
                    // набрать вопрос в панели, — а если поле чем-то занято, то
                    // и вовсе никак.
                    CircleIconButton(
                        symbol: "sparkles",
                        label: assistant.hasThread ? "Вернуться к разговору" : "Спросить по расшифровкам"
                    ) {
                        askedQuestion = ""
                        showAsk = true
                    }
                    CircleIconButton(symbol: "gearshape", label: "Настройки") { showSettings = true }
                }
                .padding(.trailing, 14)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// Темы больше не занимают шапку и не требуют горизонтального свайпа:
    /// одна иконка открывает нативный список, а галочка сохраняет контекст выбора.
    private var topicMenu: some View {
        Menu {
            Button { topicFilter = nil } label: {
                if topicFilter == nil {
                    Label("Все записи", systemImage: "checkmark")
                } else {
                    Text("Все записи")
                }
            }

            ForEach(topics.topics, id: \.self) { topic in
                Button { topicFilter = topic } label: {
                    if topicFilter == topic {
                        Label(topic, systemImage: "checkmark")
                    } else {
                        Text(topic)
                    }
                }
            }

            Divider()

            Button { showNewTopic = true } label: {
                Label("Новая тема", systemImage: "plus")
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(LoriFont.control)
                .foregroundStyle(topicFilter == nil ? LoriPalette.ink : LoriPalette.lime)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Фильтр по теме")
        .accessibilityValue(topicFilter ?? "Все записи")
        .accessibilityIdentifier("topicMenu")
        .padding(.leading, 14)
    }

    // MARK: - Список записей

    private var recordings: some View {
        List {
            if visible.isEmpty {
                empty
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { entry in
                        RecordingCard(
                            entry: entry,
                            title: title(for: entry),
                            snippet: snippet(for: entry),
                            stamp: stamp(for: entry),
                            status: status(for: entry),
                            topic: topics.topic(for: entry.relativePath),
                            needsTopic: needsTopic(entry)
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .onTapGesture { opened = entry }
                        .onLongPressGesture { topicTarget = entry }
                        .task {
                            previews.load(entry, in: workspace)
                            if let url = try? workspace.fileURL(for: entry.relativePath) {
                                durations.load(entry.relativePath, url: url)
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button { topicTarget = entry } label: {
                                Label("Тема", systemImage: "tag")
                            }
                            .tint(LoriPalette.lime)

                            Button {
                                renameDraft = entry.displayName
                                renameTarget = entry
                            } label: {
                                Label("Переименовать", systemImage: "pencil")
                            }
                            .tint(LoriPalette.muted)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { delete(entry) } label: {
                                Label("Удалить", systemImage: "trash")
                            }

                            // Меню в свайп-кнопку не поставить, поэтому формат
                            // спрашивает диалог — теми же словами, что и меню
                            // на экране записи.
                            Button { shareTarget = entry } label: {
                                Label("Поделиться", systemImage: "square.and.arrow.up")
                            }
                            .tint(LoriPalette.lime)

                            Button { sendToObsidian(entry) } label: {
                                Label("Obsidian", systemImage: "book.closed")
                            }
                            .tint(LoriPalette.obsidian)
                        }
                    }
                } header: {
                    // Липкий заголовок едет поверх карточек. Без своей заливки
                    // «Сегодня» читалось прямо по тексту первой из них, а без
                    // отступов — вплотную к её краю.
                    Text(group.title)
                        .font(LoriFont.section)
                        .foregroundStyle(LoriPalette.muted)
                        .textCase(nil)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LoriPalette.canvas)
                        .listRowInsets(EdgeInsets())
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 10)
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if search.isIndexing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Готовлю поиск…")
                    }
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.muted)
                    .padding(.top, 12)
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Поиск идёт по тексту расшифровок и по названиям записей.")
                        .font(LoriFont.meta)
                        .foregroundStyle(LoriPalette.muted)
                        .padding(.top, 12)
                } else if search.hits.isEmpty {
                    Text("Ничего не нашлось.")
                        .font(LoriFont.meta)
                        .foregroundStyle(LoriPalette.muted)
                        .padding(.top, 12)
                } else {
                    ForEach(search.hits) { hit in
                        Button {
                            searchFocused = false
                            opened = audioEntry(for: hit)
                        } label: {
                            SearchResultRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topicFilter == nil ? "Пока ни одной записи" : "В этой теме пусто")
                .font(LoriFont.cardTitle)
                .foregroundStyle(LoriPalette.ink)
            Text(topicFilter == nil
                 ? "Нажми «Записать» или принеси готовый файл. После остановки Lori сама расшифрует запись."
                 : "Тема назначается свайпом по карточке или долгим нажатием.")
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.muted)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(LoriPalette.line, lineWidth: 1))
    }

    // MARK: - Низ экрана

    private var composerBar: some View {
        ComposerBar(
            model: composer,
            recorder: recorder,
            engines: engines,
            speed: speed,
            engine: engine,
            mode: TranscriptionSettings.mode(for: engine.kind),
            scopes: composerScopes,
            contextSummary: contextSummary,
            status: transcriptionStatus,
            actions: ComposerActions(
                record: startRecording,
                stop: stopRecording,
                togglePause: { recorder.isPaused ? recorder.resume() : recorder.pause() },
                cancelRecording: {
                    recorder.discard(in: workspace)
                    refresh()
                },
                pickFile: { showFileImporter = true },
                paste: pasteAudio,
                openSettings: { showSettings = true },
                chooseEngine: { showEnginePicker = true },
                setMode: { mode in
                    TranscriptionSettings.setMode(mode, for: engine.kind)
                    engines.refresh()
                },
                ask: askFromComposer,
                transcribe: transcribeAttached
            )
        )
        .sheet(isPresented: $showEnginePicker) {
            EnginePicker(directory: engines, selection: $engineRaw)
        }
        .onChange(of: engineRaw) { engines.refresh() }
        // Типы буфера читаются без содержимого, поэтому проверять их можно и на
        // возврате в приложение: системной плашки о вставке это не вызывает.
        .onAppear {
            composer.refreshClipboard()
            collectIncoming()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            composer.refreshClipboard()
            collectIncoming()
        }
        .onOpenURL { url in receive(url) }
        .onChange(of: composer.question.isEmpty) { _, _ in updateContextSummary() }
        .onChange(of: composer.scopeID) { _, _ in updateContextSummary() }
    }

    /// Выбранный движок в терминах интерфейса.
    private var engine: EngineDescriptor {
        EngineCatalog.descriptor(for: TranscriptionEngineKind(rawValue: engineRaw) ?? .gigaam)
    }

    // MARK: - Состояние

    private struct DayGroup: Identifiable {
        let day: Date
        let title: String
        let items: [WorkspaceEntry]

        var id: Date { day }
    }

    /// Охваты вопроса: весь архив и каждая заведённая тема. Полноценный выбор
    /// отдельных записей — отдельная работа; фильтр тем уже есть и уже понятен.
    private var askScopes: [AskScope] {
        var result = [AskScope(id: "all", title: "Все", entries: workspace.audio)]
        for topic in topics.topics {
            let entries = workspace.audio.filter { topics.topic(for: $0.relativePath) == topic }
            guard !entries.isEmpty else { continue }
            result.append(AskScope(id: topic, title: topic, entries: entries))
        }
        return result
    }

    /// Те же охваты, что у листа «Спросить», но в форме, понятной чипу панели:
    /// у «Всех» показывается число записей, у темы — её название.
    private var composerScopes: [ComposerScope] {
        askScopes.map { ComposerScope(id: $0.id, title: $0.title, count: $0.entries.count) }
    }

    /// Сколько текста уйдёт ассистенту. Знаки оцениваются по размеру файлов, а не
    /// чтением: расшифровок десятки, и открывать их ради строки над клавиатурой
    /// нельзя. В кириллическом UTF-8 знак весит около 1,8 байта.
    private func updateContextSummary() {
        guard !composer.question.isEmpty else {
            contextSummary = nil
            return
        }
        let scope = askScopes.first { $0.id == composer.scopeID } ?? askScopes.first
        let entries = scope?.entries ?? []
        let sizes = transcriptSizes()
        let found = entries.compactMap { entry -> Int? in
            sizes[(entry.name as NSString).deletingPathExtension]
        }
        guard !found.isEmpty else {
            contextSummary = "В этом охвате пока нет расшифровок"
            return
        }
        let characters = Int(Double(found.reduce(0, +)) / 1.8)
        let count = LoriFormat.plural(found.count, one: "расшифровке", few: "расшифровкам", many: "расшифровкам")
        contextSummary = "Спрошу по \(count) · \(thousands(characters)) знаков"
    }

    private func transcriptSizes() -> [String: Int] {
        let files = (try? workspace.entries(at: "Transcripts")) ?? []
        return Dictionary(
            files.map { ((($0.name as NSString).deletingPathExtension), $0.size) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func thousands(_ value: Int) -> String {
        value < 1_000 ? "\(value)" : "\((value + 500) / 1_000) тыс."
    }

    private func openPending() {
        guard let entry = pendingOpen else { return }
        pendingOpen = nil
        openedSeek = pendingSeek
        pendingSeek = nil
        opened = entry
    }

    private var visible: [WorkspaceEntry] {
        guard let topicFilter else { return workspace.audio }
        return workspace.audio.filter { topics.topic(for: $0.relativePath) == topicFilter }
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.modifiedAt) }
        return byDay.keys.sorted(by: >).map { day in
            DayGroup(
                day: day,
                title: LoriFormat.groupTitle(day),
                items: (byDay[day] ?? []).sorted { $0.modifiedAt > $1.modifiedAt }
            )
        }
    }

    /// Заголовок карточки. Порядок важен: имя, заданное человеком, главнее
    /// придуманного моделью, а оно — первой фразы расшифровки.
    private func title(for entry: WorkspaceEntry) -> String {
        if let title = summaries.title(for: entry.relativePath) { return title }
        if let title = previews.preview(for: entry.relativePath)?.title, !title.isEmpty { return title }
        return "Запись \(LoriFormat.stamp(entry.modifiedAt))"
    }

    /// Под заголовком — описание от модели, а без неё две строки расшифровки.
    ///
    /// Продолжение уместно только тогда, когда заголовок и правда взят из
    /// текста. Если запись названа человеком или моделью, отрезать «то, что
    /// ушло в заголовок» не от чего — и сниппет начинался бы с середины фразы.
    private func snippet(for entry: WorkspaceEntry) -> String? {
        if let detail = summaries.detail(for: entry.relativePath) { return detail }
        guard let preview = previews.preview(for: entry.relativePath) else { return nil }
        let titleIsFromText = summaries.title(for: entry.relativePath) == nil
        return titleIsFromText ? preview.snippet : preview.head
    }

    /// «20:20 · 4:12»: время записи и её длительность.
    private func stamp(for entry: WorkspaceEntry) -> String {
        let time = LoriFormat.stamp(entry.modifiedAt)
        guard let duration = durations.duration(for: entry.relativePath) else { return time }
        return "\(time) · \(LoriFormat.duration(duration))"
    }

    /// Пометка «Без темы» показывается только в общем списке и только когда
    /// темы вообще заведены — иначе она была бы на каждой карточке.
    private func needsTopic(_ entry: WorkspaceEntry) -> Bool {
        topicFilter == nil && !topics.topics.isEmpty && topics.topic(for: entry.relativePath) == nil
    }

    private func status(for entry: WorkspaceEntry) -> RecordingCard.Status? {
        let path = entry.relativePath
        if transcription.isRunning(path) {
            if let fraction = transcription.progressFraction(for: path) {
                return .init(text: "Расшифровывается · \(Int(fraction * 100))%", color: LoriPalette.info)
            }
            return .init(text: "Расшифровывается", color: LoriPalette.info)
        }
        if transcription.isQueued(path) {
            // «Жду память» и «в очереди» — разные вещи: первое может и не пройти,
            // если телефону и правда тесно, и человек вправе видеть разницу.
            let waiting = transcription.waitingForMemory.contains(path) ? "Жду память" : "В очереди"
            return .init(text: waiting, color: LoriPalette.warn)
        }
        if transcription.isInterrupted(path) {
            return .init(text: "Прервано", color: LoriPalette.warn)
        }
        if transcription.error(for: path) != nil {
            return .init(text: "Ошибка", color: LoriPalette.danger)
        }
        if workspace.existingTranscript(for: entry) == nil {
            return .init(text: "Без расшифровки", color: LoriPalette.muted)
        }
        return nil
    }

    /// Одна строка на любое число расшифровок в работе. Записей теперь может идти
    /// несколько сразу, и «Расшифровываю запись…» в единственном числе врало бы.
    private var transcriptionStatus: String? {
        if importingAttached { return "Добавляю запись…" }
        let running = transcription.running.sorted()
        let queued = transcription.queued.count
        guard let single = running.first else { return nil }
        var base: String
        if running.count == 1 {
            let progress = transcription.progressText(for: single)
            base = progress.map { "Расшифровываю запись… \($0)" } ?? "Расшифровываю запись…"
        } else {
            base = "Расшифровываю \(LoriFormat.plural(running.count, one: "запись", few: "записи", many: "записей"))"
        }
        if queued > 0 { base += " · в очереди \(queued)" }
        // Про фон говорим только тогда, когда его действительно нет: обещать его
        // молча нельзя, но и сообщать о нём каждый раз незачем.
        if case let .foregroundOnly(reason) = runway.state, !reason.isEmpty {
            base += " · только пока приложение открыто"
        }
        return base
    }

    private var activeError: String? { workspace.lastError ?? transcription.lastError ?? startError }

    private func clearErrors() {
        workspace.lastError = nil
        transcription.lastError = nil
        startError = nil
    }

    private func suggestion(for entry: WorkspaceEntry) -> String? {
        let text = previews.preview(for: entry.relativePath)?.snippet ?? ""
        return topics.suggestion(for: text)
    }

    /// Находка поиска — это расшифровка, а открывать нужно запись, к которой она относится.
    private func audioEntry(for hit: SearchHit) -> WorkspaceEntry? {
        guard hit.entry.relativePath.hasPrefix("Transcripts/") else { return hit.entry }
        let base = (hit.entry.name as NSString).deletingPathExtension
        return workspace.audio.first { ($0.name as NSString).deletingPathExtension == base }
    }

    private func isPresented(_ target: Binding<WorkspaceEntry?>) -> Binding<Bool> {
        Binding(get: { target.wrappedValue != nil }, set: { if !$0 { target.wrappedValue = nil } })
    }

    // MARK: - Действия

    private func startRecording() {
        Task {
            do {
                try await recorder.start(in: workspace)
            } catch {
                startError = error.localizedDescription
            }
        }
    }

    private func stopRecording() {
        guard let path = recorder.stop() else { return }
        refresh()
        guard autoTranscribe, let entry = try? workspace.entry(at: path) else { return }
        transcription.enqueue(entry, in: workspace)
    }

    /// Выбранный файл прикрепляется к панели, а не уходит в работу сам.
    /// Человек должен увидеть движок и цену до запуска, а не после.
    private func attachFiles(_ result: Result<[URL], Error>) {
        do {
            // Копия снимается сразу: доступ к чужому файлу живёт, пока держат
            // security scope, а до нажатия «Расшифровать» проходит сколько угодно.
            composer.attach(try result.get().map { try ImportInbox.stage($0) })
        } catch {
            workspace.lastError = error.localizedDescription
        }
    }

    /// «Поделиться» → Lori и Быстрые команды: файл уже лежит в промежуточной
    /// папке, панели остаётся его показать.
    private func collectIncoming() {
        ImportInbox.drainSystemInbox()
        let waiting = ImportInbox.waiting()
        guard !waiting.isEmpty else { return }
        composer.attach(waiting)
    }

    private func receive(_ url: URL) {
        do {
            composer.attach([try ImportInbox.stage(url)])
        } catch {
            workspace.lastError = error.localizedDescription
        }
    }

    /// Ленивый поставщик отдаёт файл асинхронно, поэтому вставка — задача,
    /// а не мгновенное действие.
    private func pasteAudio() {
        Task {
            do {
                composer.attach([try await ClipboardAudio.take()])
            } catch {
                workspace.lastError = error.localizedDescription
            }
            composer.refreshClipboard()
        }
    }

    /// Прикреплённое уходит в рабочую папку и в очередь — по явному нажатию.
    private func transcribeAttached() {
        let files = composer.attached
        guard !files.isEmpty, !importingAttached else { return }
        importingAttached = true
        Task {
            defer { importingAttached = false }
            do {
                var imported: [String] = []
                for file in files {
                    let path = try await workspace.importFileAsync(from: file.url)
                    // Пока модель не посчитала заголовок, сохраняем понятное имя
                    // файла. Это не запрет модели впоследствии назвать запись.
                    summaries.setImported(title: (file.name as NSString).deletingPathExtension, for: path)
                    imported.append(path)
                }
                // Только теперь: `clear` убирает файлы из промежуточной папки, и
                // сделай он это раньше — импортировать было бы уже нечего.
                composer.clear()
                refresh()
                for path in imported {
                    guard let entry = try? workspace.entry(at: path) else { continue }
                    transcription.enqueue(entry, in: workspace)
                }
            } catch {
                workspace.lastError = error.localizedDescription
            }
        }
    }

    private func askFromComposer() {
        let asked = composer.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        askedQuestion = asked
        composer.question = ""
        showAsk = true
    }

    /// Заголовок от локальной модели — после того, как расшифровка легла на диск.
    private func requestSummary(for relativePath: String) {
        let runner = summaryRunner
        guard let entry = try? workspace.entry(at: relativePath),
              let transcript = workspace.existingTranscript(for: entry),
              let markdown = try? workspace.readText(at: transcript) else { return }
        runner.summarize(path: relativePath, text: TranscriptTitle.plain(from: markdown))
    }

    private func delete(_ entry: WorkspaceEntry) {
        do {
            // Расшифровка уходит в корзину вместе с записью: одна без другой не нужна.
            if let transcript = workspace.existingTranscript(for: entry) {
                try workspace.moveToTrash(transcript)
            }
            try workspace.moveToTrash(entry.relativePath)
            topics.forget(entry.relativePath)
            summaries.forget(entry.relativePath)
            speakers.forget(entry.relativePath)
            previews.invalidate(entry.relativePath)
        } catch {
            workspace.lastError = error.localizedDescription
        }
    }

    private func commitRename() {
        guard let entry = renameTarget else { return }
        renameTarget = nil
        do {
            // Расшифровка переезжает вместе с записью: иначе текст остаётся
            // сиротой и на экране выглядит пропавшим.
            let path = try workspace.renameRecording(at: entry.relativePath, toName: renameDraft)
            // Тема привязана к пути, поэтому при переименовании её нужно перенести.
            if let topic = topics.topic(for: entry.relativePath) {
                topics.assign(topic, to: path)
                topics.forget(entry.relativePath)
            }
            summaries.move(from: entry.relativePath, to: path)
            speakers.move(from: entry.relativePath, to: path)
            summaries.setManual(title: renameDraft, for: path)
            previews.invalidate(entry.relativePath)
        } catch {
            workspace.lastError = error.localizedDescription
        }
    }

    /// Из списка расшифровка уходит тем же файлом, что и с экрана записи:
    /// раньше здесь наружу отдавался сырой текст `.md` — с решётками,
    /// звёздочками и метками «S1» вместо имён.
    private func export(_ entry: WorkspaceEntry, as format: TranscriptExportFormat) {
        shareTarget = nil
        guard let text = transcriptText(entry) else {
            workspace.lastError = "У этой записи ещё нет расшифровки."
            return
        }
        let payload = TranscriptExport.make(
            markdown: text,
            title: title(for: entry),
            recordedAt: entry.modifiedAt,
            duration: durations.duration(for: entry.relativePath),
            detail: summaries.detail(for: entry.relativePath),
            topic: topics.topic(for: entry.relativePath),
            names: speakers.names[entry.relativePath] ?? [:]
        )
        Task {
            do {
                share = SharePayload(url: try await payload.file(as: format), subject: payload.title)
            } catch {
                workspace.lastError = "Не удалось собрать файл: \(error.localizedDescription)"
            }
        }
    }

    private func sendToObsidian(_ entry: WorkspaceEntry) {
        guard let text = transcriptText(entry) else {
            workspace.lastError = "У этой записи ещё нет расшифровки."
            return
        }
        guard let url = ObsidianExport.url(title: title(for: entry), text: text) else {
            workspace.lastError = "Укажи название хранилища Obsidian: Настройки → Хранилище."
            return
        }
        openURL(url)
    }

    private func transcriptText(_ entry: WorkspaceEntry) -> String? {
        guard let path = workspace.existingTranscript(for: entry),
              let text = try? workspace.readText(at: path), !text.isEmpty else { return nil }
        return text
    }

    private func refresh() {
        workspace.requestRefresh()
    }
}

/// Карточка записи: заголовок, две строки текста, время с длительностью,
/// состояние и тема.
struct RecordingCard: View {
    struct Status {
        let text: String
        let color: Color
    }

    let entry: WorkspaceEntry
    let title: String
    let snippet: String?
    let stamp: String
    let status: Status?
    let topic: String?
    /// Запись без темы в общем списке. Это инбокс разбора: пометка нужна,
    /// чтобы такие записи не терялись среди разложенных.
    let needsTopic: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "waveform")
                .font(LoriFont.control)
                .foregroundStyle(LoriPalette.lime)
                .frame(width: 38, height: 38)
                .background(LoriPalette.limeSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(LoriFont.cardTitle)
                        .foregroundStyle(LoriPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(stamp)
                        .font(LoriFont.small.monospacedDigit())
                        .foregroundStyle(LoriPalette.muted)
                }

                if let snippet {
                    Text(snippet)
                        .font(LoriFont.meta)
                        .foregroundStyle(LoriPalette.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    if let status {
                        Text(status.text)
                            .font(LoriFont.small)
                            .foregroundStyle(status.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(status.color.opacity(0.12), in: Capsule())
                    }
                    if needsTopic {
                        Text("Без темы")
                            .font(LoriFont.small)
                            .foregroundStyle(LoriPalette.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(LoriPalette.bubble, in: Capsule())
                            .accessibilityIdentifier("noTopicBadge")
                    }
                    if let topic {
                        Text(topic)
                            .font(LoriFont.small)
                            .foregroundStyle(LoriPalette.lime)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(LoriPalette.limeSoft.opacity(0.6), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(LoriPalette.line, lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recordingCard")
    }
}

struct CircleIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(LoriFont.control)
                .foregroundStyle(LoriPalette.ink)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .accessibilityLabel(label)
        .buttonStyle(.plain)
    }
}
