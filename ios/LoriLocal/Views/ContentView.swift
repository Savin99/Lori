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

/// Главный экран: библиотека записей, а не пульт.
///
/// Сверху — блок очереди, единственный живой элемент; под ним записи по дням.
/// Карточка отвечает на три вопроса без открытия: что это (заголовок), что
/// внутри (описание), что с ней (только если не готова). Название движка
/// сюда не выведено — это настройка, а не свойство записи.
struct ContentView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var runway: TranscriptionRunway
    @EnvironmentObject private var summaries: SummaryStore
    @EnvironmentObject private var summaryModels: SummaryModelStore
    @EnvironmentObject private var summaryRunner: SummaryRunner
    /// Превью живут на уровне приложения: расшифровку, сохранённую движком, надо
    /// перечитать и тогда, когда этот экран ещё не построен (`LoriLocalApp`).
    @EnvironmentObject private var previews: TranscriptPreviews
    @StateObject private var recorder = AudioCaptureStore()
    @StateObject private var search = TranscriptSearchStore()
    @StateObject private var topics = TopicStore()
    @StateObject private var durations = RecordingDurations()
    @StateObject private var engines = ContentView.makeEngineDirectory()
    @StateObject private var composer = ComposerModel()
    @StateObject private var speakers = SpeakerNames()
    @StateObject private var speed = TranscriptionSpeed()

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
    /// Заголовок, который был виден, когда открылось окно переименования. С ним
    /// сравнивается набранное: «Готово» без правки ничего не переименовывает.
    @State private var renameOriginal = ""
    @State private var newTopicName = ""
    @State private var showNewTopic = false
    @State private var share: SharePayload?
    /// Запись, для которой спрашивают формат экспорта.
    @State private var shareTarget: WorkspaceEntry?
    /// Запись, удаление которой ждёт подтверждения.
    @State private var deleteTarget: WorkspaceEntry?
    @State private var showStopQueue = false
    @State private var notice: ImportNotice.Message?
    /// Почему фона нет — показывается по «почему?» в блоке очереди.
    @State private var backgroundExplanation: String?
    /// Сколько файлов сейчас принимается в работу; ноль — приёма нет.
    @State private var importing = 0
    @State private var showEnginePicker = false
    @FocusState private var searchFocused: Bool

    @AppStorage(TranscriptionSettings.autoTranscribeKey) private var autoTranscribe = true
    @AppStorage(TranscriptionSettings.engineKey) private var engineRaw = TranscriptionEngineKind.gigaam.rawValue
    /// Подсказку про модель заголовков убрали крестиком — навсегда.
    @AppStorage("titlesHintDismissed") private var titlesHintDismissed = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        dialogs(sheets(screen))
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff],
                allowsMultipleSelection: true,
                onCompletion: attachFiles
            )
            // Только снаружи всех `.sheet`: объект окружения достаётся лишь тому,
            // что лежит внутри обёртки, иначе плашка записи в листе роняет приложение.
            .environmentObject(recorder)
            .environmentObject(speakers)
            .environmentObject(speed)
    }

    private var screen: some View {
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
    }

    // MARK: - Шапка

    /// Шапка без названия экрана: слева — меню тем, подписанное тем, что сейчас
    /// показано («Все записи ▾» или имя темы), справа — поиск и настройки.
    /// Больше здесь ничего нет: всё остальное — в карточках и в панели.
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
                HStack(spacing: 4) {
                    topicMenu

                    Spacer(minLength: 8)

                    CircleIconButton(symbol: "magnifyingglass", label: "Искать по расшифровкам") {
                        isSearching = true
                        searchFocused = true
                        // Тот же заголовок, что на карточке: строка поиска и так
                        // подписана датой, повторять её в заголовке незачем.
                        search.reindex(workspace) { entry in
                            cardTitle(RecordTitle.resolve(entry, summaries: summaries, previews: previews), entry)
                        }
                    }
                    CircleIconButton(symbol: "gearshape", label: "Настройки") { showSettings = true }
                }
                .padding(.leading, 20)
                .padding(.trailing, 14)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// Меню тем. Подпись — то, что сейчас на экране: иконка фильтра сама по себе
    /// не говорила, открыт ли весь архив или одна тема.
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
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(LoriFont.meta.weight(.semibold))
                    .foregroundStyle(LoriPalette.muted)
                Text(topicFilter ?? "Все записи")
                    .font(LoriFont.cardTitle)
                    .foregroundStyle(LoriPalette.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(LoriFont.tiny.weight(.semibold))
                    .foregroundStyle(LoriPalette.muted)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Фильтр по теме")
        .accessibilityValue(topicFilter ?? "Все записи")
        .accessibilityIdentifier("topicMenu")
    }

    // MARK: - Список записей

    private var recordings: some View {
        List {
            if let summary = queueSummary {
                Section {
                    QueueBlock(
                        summary: summary,
                        backgroundReason: backgroundReason,
                        stop: { showStopQueue = true },
                        explainBackground: { backgroundExplanation = backgroundReason }
                    )
                    .onTapGesture { opened = entry(at: summary.focusPath) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                }
            }

            if showsTitlesHint {
                Section {
                    TitlesHint(models: summaryModels) { titlesHintDismissed = true }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                }
            }

            if visible.isEmpty {
                empty
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { entry in
                        row(entry)
                    }
                } header: {
                    // Липкий заголовок едет поверх карточек. Без своей заливки
                    // «Сегодня» читалось прямо по тексту первой из них, а без
                    // отступов — вплотную к её краю.
                    // Сверху отступ почти нулевой: у простого списка над заголовком
                    // секции и так своя полоса, и с прежними десятью точками дни
                    // распадались на острова.
                    Text(group.title)
                        .font(LoriFont.section)
                        .foregroundStyle(LoriPalette.muted)
                        .textCase(nil)
                        .padding(.horizontal, 20)
                        .padding(.top, 2)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LoriPalette.canvas)
                        .listRowInsets(EdgeInsets())
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 10)
    }

    /// Строка списка. Заголовок, состояние и наличие расшифровки считаются здесь
    /// один раз и расходятся по карточке, свайпам и меню долгого нажатия — иначе
    /// карточка и её меню могли бы разойтись в том, что считают заголовком.
    @ViewBuilder
    private func row(_ entry: WorkspaceEntry) -> some View {
        let path = entry.relativePath
        let resolved = RecordTitle.resolve(entry, summaries: summaries, previews: previews)
        let title = cardTitle(resolved, entry)
        let state = transcription.state(for: path)
        let hasTranscript = workspace.existingTranscript(for: entry) != nil
        let status = RecordStatus.make(
            state: state,
            hasTranscript: hasTranscript,
            fraction: transcription.progressFraction(for: path),
            remaining: transcription.remainingTime(for: path)
        )

        RecordingCard(
            title: title,
            detail: resolved.detail,
            time: HomeFormat.time(entry.modifiedAt),
            duration: durations.duration(for: path).map(HomeFormat.clock),
            topic: topics.topic(for: path),
            needsTopic: needsTopic(entry),
            status: status,
            perform: { _ in transcription.enqueue(entry, in: workspace) }
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
        .onTapGesture { opened = entry }
        .contextMenu {
            contextMenu(for: entry, title: title, state: state, hasTranscript: hasTranscript, action: status?.action)
        }
        .task {
            previews.load(entry, in: workspace)
            if let url = try? workspace.fileURL(for: path) {
                durations.load(path, url: url)
            }
        }
        // «Поделиться» — главный глагол: файл уходит в ИИ снаружи, и это одно
        // движение пальцем от края. Без расшифровки делиться нечем, и полный
        // свайп тогда не делает ничего неожиданного.
        .swipeActions(edge: .leading, allowsFullSwipe: hasTranscript) {
            if hasTranscript {
                // Меню в свайп-кнопку не поставить, поэтому формат спрашивает
                // диалог — теми же словами, что и меню на экране записи.
                Button { shareTarget = entry } label: {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
                .tint(LoriPalette.lime)
            }
            Button { topicTarget = entry } label: {
                Label("Тема", systemImage: "tag")
            }
            .tint(LoriPalette.muted)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Без `role: .destructive`: такая кнопка сама убирает строку, ещё до
            // подтверждения, а удаление здесь всегда переспрашивается.
            Button { deleteTarget = entry } label: {
                Label("Удалить", systemImage: "trash")
            }
            .tint(LoriPalette.danger)

            if !state.isActive {
                Button { startRename(entry, title: title) } label: {
                    Label("Переименовать", systemImage: "pencil")
                }
                .tint(LoriPalette.muted)
            }

            if hasTranscript {
                Button { sendToObsidian(entry) } label: {
                    Label("Obsidian", systemImage: "book.closed")
                }
                .tint(LoriPalette.obsidian)
            }
        }
    }

    /// Долгое нажатие — все действия с записью в одном месте. Раньше оно сразу
    /// открывало выбор темы, и про остальное можно было узнать только свайпом.
    @ViewBuilder
    private func contextMenu(
        for entry: WorkspaceEntry,
        title: String,
        state: TranscriptionRecordState,
        hasTranscript: Bool,
        action: RecordStatus.Action?
    ) -> some View {
        if hasTranscript {
            Menu {
                ForEach(TranscriptExportFormat.allCases) { format in
                    Button { export(entry, as: format) } label: {
                        Text(format.title)
                        Text(format.note)
                        Image(systemName: format.icon)
                    }
                }
            } label: {
                Label("Поделиться", systemImage: "square.and.arrow.up")
            }
        }
        if !state.isActive {
            Button { startRename(entry, title: title) } label: {
                Label("Переименовать", systemImage: "pencil")
            }
        }
        Button { topicTarget = entry } label: {
            Label("Тема", systemImage: "tag")
        }
        if hasTranscript {
            Button { sendToObsidian(entry) } label: {
                Label("Отправить в Obsidian", systemImage: "book.closed")
            }
        }
        if let action {
            Button { transcription.enqueue(entry, in: workspace) } label: {
                Label(action.title, systemImage: action == .transcribe ? "waveform" : "arrow.clockwise")
            }
        }
        Divider()
        Button(role: .destructive) { deleteTarget = entry } label: {
            Label("Удалить", systemImage: "trash")
        }
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
                    Text("Поиск идёт по заголовкам и тексту расшифровок.")
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
                            opened = hit.entry
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
            Text(emptyHint)
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.muted)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(LoriPalette.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("emptyState")
    }

    private var emptyHint: String {
        guard topicFilter == nil else {
            return "Назначь тему свайпом вправо по карточке или долгим нажатием на неё."
        }
        // Обещать расшифровку после остановки можно, только если она и правда
        // начнётся сама: тумблер «Расшифровывать сразу» мог быть выключен.
        let after = autoTranscribe ? " После остановки Lori сама расшифрует запись." : ""
        return "Запиши разговор кнопкой с микрофоном внизу или добавь готовые файлы через «+»." + after
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
            status: importing > 0 ? "Добавляю \(HomeFormat.records(importing))…" : nil,
            busy: importing > 0,
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
                chooseEngine: { showEnginePicker = true },
                setMode: { mode in
                    TranscriptionSettings.setMode(mode, for: engine.kind)
                    engines.refresh()
                },
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
    }

    /// Выбранный движок в терминах интерфейса.
    private var engine: EngineDescriptor {
        EngineCatalog.descriptor(for: TranscriptionEngineKind(rawValue: engineRaw) ?? .gigaam)
    }

    /// Готовность движков для чипа. С проверочным движком QA считает он, и любой
    /// выбор в панели честно готов — иначе снимки показывали бы «Нет ключа».
    private static func makeEngineDirectory() -> EngineDirectory {
        #if DEBUG
        if QAStubEngine.enabled {
            return EngineDirectory(hasKey: { _ in true }, hasModel: { _ in true }, hasWhisperModel: { true })
        }
        #endif
        return EngineDirectory()
    }

    // MARK: - Состояние

    private struct DayGroup: Identifiable {
        let day: Date
        let title: String
        let items: [WorkspaceEntry]

        var id: Date { day }
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

    /// Блок очереди виден, пока в пачке есть записи или хоть одна запись занята.
    private var queueSummary: QueueSummary? {
        let current = transcription.currentPath
        guard transcription.batchTotal > 0 || current != nil || !transcription.queued.isEmpty else { return nil }
        return QueueSummary.make(
            current: current,
            queued: transcription.queued,
            batchDone: transcription.batchDone,
            batchTotal: transcription.batchTotal,
            fraction: current.flatMap(transcription.progressFraction(for:)),
            remaining: current.flatMap(transcription.remainingTime(for:)),
            note: current.flatMap(transcription.progressText(for:)),
            waitingForMemory: transcription.waitingForMemory,
            title: title(forPath:)
        )
    }

    /// Про фон говорим только тогда, когда его действительно нет: обещать его
    /// молча нельзя, но и сообщать о нём каждый раз незачем.
    private var backgroundReason: String? {
        guard case let .foregroundOnly(reason) = runway.state, !reason.isEmpty else { return nil }
        return reason
    }

    /// Подсказка про модель заголовков: есть что называть, модели нет, и человек
    /// её не убирал. Во время скачивания она остаётся — показывает проценты.
    private var showsTitlesHint: Bool {
        !workspace.audio.isEmpty && !summaryModels.isReady && !titlesHintDismissed
    }

    /// Заголовок на карточке. У записи без заголовка — «Запись 14:58», без «вчера»
    /// и без даты: день назван заголовком секции над карточкой, а «Запись 12 августа»
    /// у трёх записей одного дня было бы одним и тем же словом.
    private func cardTitle(_ resolved: RecordTitle, _ entry: WorkspaceEntry) -> String {
        resolved.source == .date ? "Запись \(HomeFormat.time(entry.modifiedAt))" : resolved.title
    }

    private func title(forPath path: String) -> String {
        let recordedAt = workspace.audio.first { $0.relativePath == path }?.modifiedAt ?? .now
        return RecordTitle.resolve(path: path, recordedAt: recordedAt, summaries: summaries, previews: previews).title
    }

    private func entry(at path: String) -> WorkspaceEntry? {
        workspace.audio.first { $0.relativePath == path } ?? (try? workspace.entry(at: path))
    }

    /// Пометка «Без темы» показывается только в общем списке и только когда
    /// темы вообще заведены — иначе она была бы на каждой карточке.
    private func needsTopic(_ entry: WorkspaceEntry) -> Bool {
        topicFilter == nil && !topics.topics.isEmpty && topics.topic(for: entry.relativePath) == nil
    }

    /// Что показать алертом. Ошибку расшифровки конкретной записи алертом не
    /// показываем: она уже стоит на карточке с «Повторить», а алерт посреди
    /// пачки из пяти записей только прерывает. Остальные ошибки — как были.
    private var activeError: String? {
        if let error = workspace.lastError ?? startError { return error }
        guard let error = transcription.lastError else { return nil }
        return transcription.failed.values.contains(error) ? nil : error
    }

    private func clearErrors() {
        workspace.lastError = nil
        transcription.lastError = nil
        startError = nil
    }

    private func suggestion(for entry: WorkspaceEntry) -> String? {
        let text = previews.preview(for: entry.relativePath)?.snippet ?? ""
        return topics.suggestion(for: text)
    }

    private func isPresented<T>(_ target: Binding<T?>) -> Binding<Bool> {
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

    /// Выбранные файлы прикрепляются к панели, а не уходят в работу сами.
    /// Человек должен увидеть движок и цену до запуска, а не после. Негодный
    /// файл не отменяет остальные: они прикрепляются, а о нём — одно сообщение.
    private func attachFiles(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            // Копия снимается сразу: доступ к чужому файлу живёт, пока держат
            // security scope, а до нажатия «Расшифровать» проходит сколько угодно.
            let report = ImportInbox.stageAll(urls)
            composer.attach(report.staged)
            notice = ImportNotice.rejected(report.rejected.map(\.message))
        case let .failure(error):
            workspace.lastError = error.localizedDescription
        }
    }

    /// «Поделиться» → Lori и Быстрые команды: файл уже лежит в промежуточной
    /// папке или ждёт в `Documents/Inbox`, панели остаётся его показать.
    private func collectIncoming() {
        let report = ImportInbox.collectSystemInbox()
        let waiting = ImportInbox.waiting()
        if !waiting.isEmpty { composer.attach(waiting) }
        if let message = ImportNotice.rejected(report.rejected.map(\.message)) { notice = message }
    }

    private func receive(_ url: URL) {
        let report = ImportInbox.stageAll([url])
        composer.attach(report.staged)
        if let message = ImportNotice.rejected(report.rejected.map(\.message)) { notice = message }
    }

    /// Вставка забирает **всё** аудио из буфера, по порядку. Ленивый поставщик
    /// отдаёт файл асинхронно, поэтому это задача, а не мгновенное действие.
    private func pasteAudio() {
        Task {
            do {
                let result = try await ClipboardAudio.takeBatch()
                composer.attach(result.urls)
                notice = ImportNotice.pasteSkipped(result.messages, taken: result.urls.count)
            } catch {
                workspace.lastError = error.localizedDescription
            }
            composer.refreshClipboard()
        }
    }

    /// Прикреплённое уходит в рабочую папку и в очередь — по явному нажатию,
    /// одной пачкой: проверка движка один раз, потом копирование всех, потом все
    /// разом в очередь (`importAndEnqueue`).
    ///
    /// Снимаются из панели только ушедшие в работу. `composer.clear()` здесь нельзя:
    /// он стёр бы и промежуточные копии тех, что не вошли, — повторять было бы нечего.
    private func transcribeAttached() {
        let files = composer.attached
        guard !files.isEmpty, importing == 0 else { return }
        importing = files.count
        let kind = engine.kind
        Task {
            defer { importing = 0 }
            let report = await transcription.importAndEnqueue(
                files.map(\.url),
                into: workspace,
                using: kind
            ) { source, path in
                // Пока модель не посчитала заголовок, у записи понятное имя файла.
                // Это не запрет модели впоследствии назвать запись.
                summaries.setImported(title: (source.lastPathComponent as NSString).deletingPathExtension, for: path)
            }
            if let problem = report.blockedBy {
                notice = ImportNotice.blocked(problem)
                return
            }
            let imported = Set(report.imported.map(\.source))
            for file in files {
                // Неподдерживаемый файл сервис уже убрал из промежуточной папки —
                // в панели от него осталась бы пустая строка.
                let gone = !FileManager.default.fileExists(atPath: file.url.path)
                if imported.contains(file.url) || gone { composer.detach(file) }
            }
            notice = ImportNotice.partial(report.failed.map(\.message), imported: report.imported.count)
        }
    }

    private func startRename(_ entry: WorkspaceEntry, title: String) {
        renameOriginal = title
        renameDraft = title
        renameTarget = entry
    }

    private func commitRename() {
        guard let entry = renameTarget else { return }
        renameTarget = nil
        let old = entry.relativePath
        let wasActive = transcription.state(for: old).isActive
        do {
            guard let new = try RecordRename.commit(
                entry,
                typed: renameDraft,
                currentTitle: renameOriginal,
                workspace: workspace,
                summaries: summaries,
                topics: topics,
                speakers: speakers,
                previews: previews,
                runner: summaryRunner
            ) else { return }
            // Ошибка прошлой попытки привязана к старому пути: оставь её — и она
            // висела бы в памяти сервиса за записью, которой больше нет.
            if new != old, !wasActive { transcription.forget(old) }
        } catch {
            workspace.lastError = Self.renameMessage(for: error)
        }
    }

    private static func renameMessage(for error: Error) -> String {
        switch error as? WorkspaceError {
        case .nameTaken:
            "Запись с таким названием уже есть. Выбери другое."
        case .invalidName:
            "Из этого названия не получается имя файла. Добавь буквы или цифры."
        default:
            "Не получилось переименовать: \(error.localizedDescription)"
        }
    }

    /// Удаление — только после подтверждения, и сначала снимается расшифровка
    /// записи: иначе движок дописал бы текст к записи, которая уже в корзине.
    private func delete(_ entry: WorkspaceEntry) {
        let path = entry.relativePath
        transcription.forget(path)
        summaryRunner.forget(path)
        do {
            // Расшифровка уходит в корзину вместе с записью: одна без другой не нужна.
            if let transcript = workspace.existingTranscript(for: entry) {
                try workspace.moveToTrash(transcript)
            }
            try workspace.moveToTrash(path)
            topics.forget(path)
            summaries.forget(path)
            speakers.forget(path)
            previews.invalidate(path)
        } catch {
            workspace.lastError = "Не получилось удалить запись: \(error.localizedDescription)"
        }
    }

    /// Имя, под которым запись уходит наружу. Заголовок «Запись 09:10» для файла не
    /// годится: файл переживёт день, и через неделю время без даты ни о чём не
    /// скажет. Поэтому у записи без заголовка — абсолютная дата.
    private func outgoingTitle(_ entry: WorkspaceEntry) -> (title: String, detail: String?) {
        let resolved = RecordTitle.resolve(entry, summaries: summaries, previews: previews)
        let title = resolved.source == .date ? HomeFormat.absoluteTitle(entry.modifiedAt) : resolved.title
        return (title, resolved.generatedDetail)
    }

    /// Из списка расшифровка уходит тем же файлом, что и с экрана записи:
    /// раньше здесь наружу отдавался сырой текст `.md` — с решётками,
    /// звёздочками и метками «S1» вместо имён.
    private func export(_ entry: WorkspaceEntry, as format: TranscriptExportFormat) {
        shareTarget = nil
        guard let text = transcriptText(entry) else {
            workspace.lastError = "У этой записи ещё нет расшифровки — делиться пока нечем."
            return
        }
        let outgoing = outgoingTitle(entry)
        let payload = TranscriptExport.make(
            markdown: text,
            title: outgoing.title,
            recordedAt: entry.modifiedAt,
            duration: durations.duration(for: entry.relativePath),
            // В шапку файла — только описание модели: текст записи идёт следом
            // целиком, и повторять его начало незачем.
            detail: outgoing.detail,
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

    /// В Obsidian уходит то же, что «Скопировать» на экране записи: текст без
    /// служебной разметки и с именами говорящих вместо «S1».
    private func sendToObsidian(_ entry: WorkspaceEntry) {
        guard let text = transcriptText(entry) else {
            workspace.lastError = "У этой записи ещё нет расшифровки — отправлять пока нечего."
            return
        }
        let plain = speakers.applied(to: TranscriptDocument.parse(text).plain, in: entry.relativePath)
        guard let url = ObsidianExport.url(title: outgoingTitle(entry).title, text: plain) else {
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

    // MARK: - Листы и диалоги

    /// Листы экрана. Отдельными функциями, а не одной цепочкой в `body`: десяток
    /// листов и диалогов подряд упирается в проверку типов компилятора.
    private func sheets(_ content: some View) -> some View {
        content
            .sheet(isPresented: $showSettings) {
                SettingsRoot(transcription: transcription, topics: topics)
            }
            .sheet(item: $opened) { entry in
                TranscriptScreen(
                    entry: entry,
                    transcription: transcription,
                    topics: topics,
                    previews: previews,
                    isRecording: recorder.isCapturing
                )
            }
            .sheet(item: $topicTarget) { entry in
                TopicSheet(
                    topics: topics,
                    title: cardTitle(RecordTitle.resolve(entry, summaries: summaries, previews: previews), entry),
                    path: entry.relativePath,
                    suggestion: suggestion(for: entry)
                )
            }
            .sheet(item: $share) { payload in
                ShareSheet(payload: payload)
            }
    }

    /// Диалоги экрана: формат экспорта, удаление, остановка очереди, имена и ошибки.
    private func dialogs(_ content: some View) -> some View {
        content
            .confirmationDialog(
                "Поделиться расшифровкой",
                isPresented: isPresented($shareTarget),
                titleVisibility: .visible,
                presenting: shareTarget
            ) { entry in
                // Те же слова, что в веб-интерфейсе и в меню экрана записи:
                // продукт один, и формат не должен называться по-разному.
                ForEach(TranscriptExportFormat.allCases) { format in
                    Button("\(format.title) · \(format.note)") { export(entry, as: format) }
                }
                Button("Отмена", role: .cancel) {}
            }
            .confirmationDialog(
                "Удалить запись?",
                isPresented: isPresented($deleteTarget),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { entry in
                Button("Удалить", role: .destructive) { delete(entry) }
                Button("Отмена", role: .cancel) {}
            } message: { entry in
                Text(transcription.state(for: entry.relativePath).isActive
                     ? "Аудио и расшифровка переедут в корзину Lori. Расшифровка этой записи остановится."
                     : "Аудио и расшифровка переедут в корзину Lori.")
            }
            .confirmationDialog(
                "Остановить расшифровку?",
                isPresented: $showStopQueue,
                titleVisibility: .visible
            ) {
                Button("Остановить", role: .destructive) { transcription.cancelAll() }
                Button("Не останавливать", role: .cancel) {}
            } message: {
                Text("Записи останутся — расшифровку можно запустить снова.")
            }
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
            .alert(
                notice?.title ?? "",
                isPresented: isPresented($notice),
                presenting: notice
            ) { _ in
                Button("Понятно", role: .cancel) {}
            } message: { notice in
                Text(notice.text)
            }
            .alert(
                "Фоновая расшифровка недоступна",
                isPresented: isPresented($backgroundExplanation),
                presenting: backgroundExplanation
            ) { _ in
                Button("Понятно", role: .cancel) {}
            } message: { reason in
                Text("\(reason)\n\nПока Lori открыта, расшифровка идёт как обычно.")
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
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel(label)
        .buttonStyle(.plain)
    }
}
