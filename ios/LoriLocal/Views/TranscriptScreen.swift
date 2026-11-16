import SwiftUI
import UIKit

/// Экран записи: прочитать, послушать и отдать наружу файлом.
///
/// Под заголовком — итог, отчёт и расшифровка; плеер всегда под рукой внизу.
/// Позицию публикует только его карточка, а переключение вкладок не меняет звук.
struct TranscriptScreen: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var reports: ReportRunner
    @EnvironmentObject private var recordingSummaries: RecordingSummaryStore
    @EnvironmentObject private var summaries: SummaryStore
    @EnvironmentObject private var summaryModels: SummaryModelStore
    @EnvironmentObject private var summaryRunner: SummaryRunner
    @EnvironmentObject private var speakers: SpeakerNames
    @EnvironmentObject private var speed: TranscriptionSpeed
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Плеер лежит в `@State`, а не в `@StateObject`: позиция публикуется каждые
    /// 60 мс, и экран, подписанный на неё целиком, пересобирал бы шапку, блок
    /// состояния и сотни реплик на каждом тике. На плеер подписана только его
    /// карточка (`PlayerCard`), а длительность экран берёт один раз при открытии.
    @State private var playback = AudioPlaybackStore()

    let entry: WorkspaceEntry
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var topics: TopicStore
    @ObservedObject var previews: TranscriptPreviews
    /// Нельзя слушать и писать одновременно: аудиосессия одна.
    let isRecording: Bool
    /// Переименование делает список (`RecordRename.commit`): там все хранилища,
    /// привязанные к пути записи. nil — ни тапа по заголовку, ни пункта в «…».
    /// Ошибку (имя занято) показывает этот экран: алерт списка под открытым листом
    /// не показался бы, а то и закрыл бы лист.
    /// Получает набранное и заголовок, который был виден при открытии окна.
    var onRename: ((_ typed: String, _ shownTitle: String) throws -> Void)? = nil
    /// Удаление делает список — те же хранилища и корзина, что у свайпа. Спрашивает
    /// этот экран, теми же словами (`DeleteRecordCopy`); после удаления список
    /// закрывает лист. nil — пункта нет.
    var onDelete: (() throws -> Void)? = nil

    @State private var document = TranscriptDocument.empty
    /// Замечания файла после сверки «пропусков» со звуком (`GapRecheck`); nil —
    /// сверка ещё не кончилась или в файле не было плашек о пропусках.
    @State private var checkedWarnings: CheckedWarnings?
    /// Из какого файла собран `document`; nil — ни из какого.
    @State private var loadedFrom: String?
    @State private var isLoadingDocument = false
    @State private var documentLoadID = UUID()
    @State private var audioDuration: TimeInterval = 0
    private enum Sheet: Identifiable {
        case editor, topics, share(SharePayload)
        var id: String {
            switch self {
            case .editor: "editor"
            case .topics: "topics"
            case .share(let payload): payload.id.uuidString
            }
        }
    }
    /// nil только до первого открытия. Готовый итог не перебивает выбор человека.
    @State private var selectedTab: RecordingTab?
    @State private var reportMarkdown: String?
    @State private var reportReadFailed = false
    @State private var reportDate: Date?
    @State private var sheet: Sheet?
    @State private var editing = false
    @State private var exporting = false
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?
    @State private var notice: Notice?
    @State private var isRenaming = false
    @State private var titleDraft = ""
    /// Заголовок, который был виден, когда открылось окно переименования. С ним и
    /// сравнивается набранное: ответ модели, пришедший, пока окно открыто, не
    /// должен превратить «Сохранить» без правки в ручное имя из старого заголовка.
    @State private var titleWhenOpened = ""
    @State private var confirmingDelete = false
    /// Какого говорящего сейчас называют и как. Метка одна на всю запись,
    /// поэтому и переименование сразу по всей записи — иначе пришлось бы
    /// править каждую реплику.
    @State private var renamingSpeaker: String?
    @State private var speakerDraft = ""
    /// Движок, которым просят расшифровать заново, — до подтверждения.
    @State private var retranscribe: TranscriptionEngineKind?
    /// Готовность движков для подменю «Расшифровать заново» — та же, что у чипа
    /// панели. Читается при открытии экрана: пока он открыт, настройки закрыты.
    @StateObject private var engines = EngineDirectory.forInterface()
    /// Модель заголовков, которую предлагают скачать на месте.
    @State private var offeredModel: SummaryVariant?
    /// Человек сам попросил заголовок на этом экране. Только тогда строка даты
    /// говорит «Придумываю заголовок…», а ошибка модели — алертом: `failure`
    /// у бегунка общий, и чужая автоматическая заявка сюда не относится.
    @State private var titleRequested = false
    /// Колонка таймкодов растёт вместе с размером текста, иначе «1:05:20» на
    /// крупном шрифте обрезался бы. 46 + 12 — это и отступ `Skeleton`.
    @ScaledMetric(relativeTo: .footnote) private var timeColumn: CGFloat = 40
    @ScaledMetric(relativeTo: .footnote) private var hourTimeColumn: CGFloat = 62

    private var path: String { entry.relativePath }
    private var recordTitle: RecordTitle { RecordTitle.resolve(entry, summaries: summaries, previews: previews) }
    private var isActive: Bool { transcription.isActive(path) }
    /// Файл расшифровки по снимку рабочей папки — живое значение, а не копия в
    /// `@State`: когда работа кончилась, снимок уже знает файл, а `reload` ещё не
    /// отработал, и экран не должен на этот кадр сказать «Расшифровки пока нет».
    private var transcriptFile: String? { workspace.existingTranscript(for: entry) }
    /// Переименовать нельзя идущую запись (файл уехал бы из-под движка) и прерванную
    /// (её задание поднимется само, а переименование сняло бы его) —
    /// `TranscriptionRecordState.allowsRename`.
    private var canRename: Bool { onRename != nil && transcription.state(for: path).allowsRename }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    RecordingTabs(selection: tabSelection)
                        .padding(.top, 18)
                    tabContent
                        .id(activeTab)
                        .transition(.opacity)
                        .padding(.top, activeTab == .transcript ? 8 : 16)
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: activeTab)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .accessibilityIdentifier("recordingScroll")
            .recordingPlayerBar {
                PlayerCard(playback: playback, isRecording: isRecording)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 0)
            }
            .background(LoriPalette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(item: $sheet, onDismiss: {
                if editing { editing = false; editorClosed() }
            }) { target in
                switch target {
                case .editor:
                    if let file = transcriptFile { TranscriptEditorSheet(path: file, title: exportTitle) }
                case .topics:
                    TopicSheet(topics: topics, title: recordTitle.title, path: path, suggestion: topics.suggestion(for: document.plain))
                case .share(let payload): ShareSheet(payload: payload)
                }
            }
            .alert("Переименовать", isPresented: $isRenaming) {
                TextField("Название", text: $titleDraft)
                Button("Отмена", role: .cancel) {}
                Button("Сохранить") { commitRename() }
            }
            .alert("Кто говорит", isPresented: Binding(
                get: { renamingSpeaker != nil },
                set: { if !$0 { renamingSpeaker = nil } }
            )) {
                TextField("Имя", text: $speakerDraft)
                Button("Отмена", role: .cancel) { renamingSpeaker = nil }
                Button("Сохранить") {
                    if let label = renamingSpeaker {
                        speakers.rename(label, to: speakerDraft, in: path)
                    }
                    renamingSpeaker = nil
                }
            } message: {
                Text("Имя подставится во все реплики этого говорящего.")
            }
            .alert(
                notice?.title ?? "",
                isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
                presenting: notice
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { notice in
                if let message = notice.message { Text(message) }
            }
        }
        // Снаружи стека — внутри плашку перекрывает навигационная панель.
        .recordingBanner { dismiss() }
        .task { open() }
        // Плашки «Пропуск A–B» из файла сверяются со звуком записи заново:
        // прежнее правило находило их в обычной тишине. Файл не меняется.
        .task(id: CheckedWarnings.Request(path: path, warnings: document.warnings)) { await recheckGaps() }
        // Работа кончилась — успехом, ошибкой или отменой: текст перечитывается,
        // а заголовок карточки — без сброса, чтобы не мигнуть датой.
        .onChange(of: isActive) { _, active in
            guard !active else { return }
            reload()
            if transcriptFile != nil { previews.transcriptSaved(path, in: workspace) }
        }
        .onChange(of: reports.completed[path]) { _, value in
            if value != nil { loadReport() }
        }
        .onChange(of: document) { _, _ in updatePlaybackCursor() }
        .onChange(of: transcription.partialTranscript(for: path)) { _, _ in updatePlaybackCursor() }
        .onChange(of: transcriptFile) { _, _ in reload() }
        // Переименование меняет путь: экран переезжает за записью, а не играет
        // файл, которого уже нет.
        .onChange(of: path) { _, _ in open() }
        .onChange(of: summaryRunner.isQueued(path)) { _, queued in
            // Третья неудача снимает заявку с очереди тем же обновлением, что и
            // выставляет ошибку: сбрось флаг здесь раньше обработчика ошибки —
            // и человек не узнал бы, почему заголовка нет.
            if !queued, summaryRunner.failurePath != path { titleRequested = false }
        }
        .onChange(of: summaryRunner.failure) { _, failure in
            // `failure` у модели один на все записи: без сверки пути экран этой
            // записи показывал бы чужую неудачу как свою.
            guard titleRequested, let failure, summaryRunner.failurePath == path else { return }
            titleRequested = false
            notice = Notice(title: "Не получилось придумать заголовок", message: failure)
        }
        .onDisappear {
            playback.stop()
            copyReset?.cancel()
        }
    }

    private var activeTab: RecordingTab {
        selectedTab ?? (recordingSummaries.entry(for: path) == nil ? .transcript : .summary)
    }

    private var tabSelection: Binding<RecordingTab> {
        Binding(get: { activeTab }, set: { selectedTab = $0 })
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .summary:
            VStack(alignment: .leading, spacing: 18) {
                if let status { summaryTranscriptionLink(status) }
                summaryBlock
            }
        case .report:
            reportBlock
        case .transcript:
            VStack(alignment: .leading, spacing: 0) {
                if let status { statusBlock(status).padding(.bottom, 16) }
                notices
                transcriptText.padding(.top, 6)
            }
        }
    }

    /// Подробности и управление частями живут в расшифровке. В итоге — одна
    /// короткая строка, чтобы работа над звуком не вытесняла уже готовый текст.
    private func summaryTranscriptionLink(_ status: Status) -> some View {
        let title: String = switch status {
        case .queued: "Расшифровка в очереди"
        case .running, .sending, .awaitingService: "Идёт расшифровка"
        case .interrupted: "Расшифровка прервалась"
        case .failed: "Не получилось расшифровать"
        case .untranscribed: "Расшифровки пока нет"
        }
        return Button { selectedTab = .transcript } label: {
            Label(title, systemImage: "waveform")
                .font(LoriFont.small)
                .frame(minHeight: 44, alignment: .leading)
        }
        .foregroundStyle(LoriPalette.muted)
        .buttonStyle(.plain)
        .accessibilityHint("Открыть вкладку «Расшифровка»")
        .accessibilityIdentifier("summaryTranscriptionStatus")
    }

    // Автоматическая заявка Qwen может ждать весов: она не должна выключать
    // явный запрос итога через подписку. Работу за шлюзом сериализует бегунок.
    private var summaryBusy: Bool { summaryRunner.running == path }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry = recordingSummaries.entry(for: path) {
                RecordingNote(path: path, entry: entry, refreshing: summaryBusy) {
                    summaryRunner.requestSummary(for: path, text: document.plainText)
                }
            } else {
                Text("Итог соберёт главное из расшифровки.")
                    .font(LoriFont.body).foregroundStyle(LoriPalette.muted)
                    .accessibilityIdentifier("summaryEmpty")
                if GatewaySettings.isConfigured {
                    Button("Сделать итог") {
                        summaryRunner.requestSummary(for: path, text: document.plainText)
                    }
                    .recordingGlassButton()
                    .disabled(document.isEmpty || summaryBusy)
                    .accessibilityIdentifier("makeRecordingSummary")
                    if document.isEmpty {
                        Text("Сначала расшифруй запись.").font(LoriFont.small).foregroundStyle(LoriPalette.muted)
                    }
                } else {
                    gatewayDirections
                }
            }
            if summaryRunner.running == path, summaryRunner.preparingSummary {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Готовлю итог…").font(LoriFont.meta)
                }
            }
            if summaryRunner.isQueued(path), !summaryBusy {
                Text(summaryRunner.waitingReason ?? "Итог в очереди")
                    .font(LoriFont.meta).foregroundStyle(LoriPalette.muted)
            }
            if summaryRunner.failurePath == path, let failure = summaryRunner.failure {
                Text(failure).font(LoriFont.meta).foregroundStyle(LoriPalette.danger)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordingSummary")
    }

    private var gatewayDirections: some View {
        Text("Настрой подключение: Настройки → Подписка Gemini.")
            .font(LoriFont.small).foregroundStyle(LoriPalette.muted)
            .accessibilityIdentifier("recordingGatewayDirections")
    }

    private var reportBlock: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let markdown = reportMarkdown {
                VStack(alignment: .leading, spacing: 0) {
                    Text(ReportContent(markdown: markdown).documentTitle)
                        .font(LoriFont.reportTitle).foregroundStyle(LoriPalette.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let reportDate {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text("Gemini · " + LoriFormat.ago(reportDate, now: context.date))
                                .recordingFont(13, relativeTo: .footnote).foregroundStyle(LoriPalette.tertiary)
                        }.padding(.top, 6)
                    }
                    reportProgress.padding(.top, reports.running.contains(path) ? 16 : 0)
                    ReportContent(markdown: markdown, seek: seek, canSeek: !isRecording && audioDuration > 0)
                    HStack { Spacer(minLength: 0); refreshReportButton; Spacer(minLength: 0) }.padding(.top, 22)
                }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 24)
                .recordingCard()
            } else {
                if !reports.running.contains(path) {
                    Text(reportReadFailed ? "Не удалось прочитать файл отчёта." : "Отчёт соберёт запись в связный документ.")
                        .font(LoriFont.body).foregroundStyle(LoriPalette.muted)
                        .accessibilityIdentifier("reportEmpty")
                    if reportReadFailed {
                        Button("Открыть снова", action: loadReport).recordingGlassButton()
                    } else if GatewaySettings.isConfigured {
                        Button("Сделать отчёт", action: generateReport)
                            .recordingGlassButton()
                            .disabled(document.isEmpty)
                            .accessibilityIdentifier("makeReport")
                        if document.isEmpty {
                            Text("Сначала расшифруй запись.").font(LoriFont.small).foregroundStyle(LoriPalette.muted)
                        }
                    } else {
                        gatewayDirections
                    }
                }
                reportProgress
            }
            if let failure = reports.failures[path] {
                Text(failure).font(LoriFont.meta).foregroundStyle(LoriPalette.danger)
            }
        }
    }

    private var refreshReportButton: some View {
        Button(action: generateReport) {
            Label("Обновить отчёт", systemImage: "arrow.clockwise")
                .recordingFont(14, weight: .semibold, relativeTo: .subheadline).frame(minHeight: 44)
        }
        .buttonStyle(.plain).foregroundStyle(LoriPalette.lime)
        .disabled(document.isEmpty || reports.running.contains(path))
        .accessibilityIdentifier("refreshReport")
    }

    @ViewBuilder private var reportProgress: some View {
        if reports.running.contains(path) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Готовлю отчёт…").font(LoriFont.meta).foregroundStyle(LoriPalette.ink)
                ProgressTrack(fraction: nil, tint: LoriPalette.lime).accessibilityLabel("Готовлю отчёт")
                Button("Остановить") { reports.cancel(path) }.font(LoriFont.small).frame(minHeight: 44)
            }.accessibilityIdentifier("reportProgress")
        }
    }

    private func generateReport() {
        reports.generate(path: path, transcript: document.reportText(names: speakers.names[path] ?? [:]), title: exportTitle, workspace: workspace)
    }

    private func loadReport() {
        reportMarkdown = nil
        reportReadFailed = false
        reportDate = nil
        guard (try? workspace.fileURL(for: ReportRunner.path(for: path))) != nil else { return }
        do {
            reportMarkdown = try ReportRunner.read(for: path, in: workspace)
            if let url = try? workspace.fileURL(for: ReportRunner.path(for: path)) {
                reportDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
        }
        catch { reportReadFailed = true }
    }

    // MARK: - Шапка

    private var header: some View {
        let resolved = recordTitle
        return VStack(alignment: .leading, spacing: 6) {
            titleView(resolved.title)
            metaLine
        }
        .padding(.horizontal, 2)
    }

    /// Дата, длительность, говорящие и тема — одной тихой строкой под заголовком.
    /// Чипами (владелец, 16 ноября 2026) они занимали две строки и спорили с заголовком
    /// за внимание; назначают тему теперь из «…», здесь она только названа.
    private var metaLine: some View {
        let topic = topics.topic(for: path)
        let parts = [titleActivity ?? RecordClock.chipDate(entry.modifiedAt)]
            + (audioDuration > 0 ? [RecordClock.time(audioDuration)] : [])
            + (speakerLabels.isEmpty ? [] : [participantTitle])
            + (topic.map { [$0] } ?? [])
        return Text(parts.joined(separator: " · "))
            .recordingFont(15, relativeTo: .subheadline)
            .foregroundStyle(LoriPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(
                ([titleActivity ?? "Записано \(RecordClock.date(entry.modifiedAt))"] + Array(parts.dropFirst()))
                    .joined(separator: ", ")
            )
            .accessibilityIdentifier("recordingMeta")
    }

    /// Georgia связывает имя записи с заголовками итога/отчёта; основной текст
    /// остаётся системным, чтобы долгую расшифровку было легче читать.
    @ViewBuilder
    private func titleView(_ title: String) -> some View {
        let text = Text(title)
            .font(LoriFont.recordingTitle)
            .tracking(-0.32)
            .foregroundStyle(LoriPalette.ink)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        if canRename {
            Button { beginRename() } label: { text }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityHint("Переименовать запись")
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("recordTitle")
        } else {
            text
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("recordTitle")
        }
    }

    /// Что модель заголовков делает с этой записью прямо сейчас — тогда это
    /// вместо даты. Обещать «придумываю», пока модели нет, нельзя: заявка без
    /// весов просто ждёт, и строка висела бы вечно.
    private var titleActivity: String? {
        if titleRequested, summaryRunner.running == path { return "Придумываю заголовок…" }
        guard titleRequested, summaryRunner.isQueued(path) else { return nil }
        if summaryModels.downloading != nil {
            return "Скачиваю модель заголовков · \(Int(summaryModels.fraction * 100))%"
        }
        return summaryModels.isReady ? "Придумываю заголовок…" : nil
    }

    /// Чем расшифровано: «Расшифровано в облаке: ElevenLabs · scribe_v2 · Дословно».
    /// nil — файл движка не называет. Стоит первой строкой «…», а не под заголовком:
    /// владелец, 6 октября 2026, зачеркнул эту строку на снимке экрана. Сведение
    /// нужно, когда решают, расшифровать ли заново, — рядом с этим пунктом оно и
    /// лежит.
    ///
    /// Место сказано словами: иконку «облако / телефон» заголовок раздела меню не
    /// показывает, а главное в этой строке — уходила ли запись с телефона, а не
    /// бренд. Незнакомый движок места не получает: соврать про то, уходила ли
    /// запись наружу, хуже, чем промолчать.
    private var engineLine: String? {
        guard let name = document.processingLabel else { return nil }
        let place = document.engineStayedOnDevice.map { $0 ? " на этом iPhone" : " в облаке" } ?? ""
        return "Расшифровано\(place): \(name)"
    }


    private var speakerLabels: [String] {
        Array(Set(document.lines.compactMap(\.speaker))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var participantTitle: String {
        if speakerLabels.allSatisfy({ speakers.isNamed($0, in: path) }) {
            return speakerLabels.map { speakers.name(of: $0, in: path) }.joined(separator: ", ")
        }
        let count = speakerLabels.count
        let word = count % 10 == 1 && count % 100 != 11 ? "говорящий" : "говорящих"
        return "\(count) \(word)"
    }


    // MARK: - Поделиться и скопировать

    /// Оба действия относятся к открытой вкладке. Пока её текст ещё читается,
    /// сохраняем выключенную группу; пустая вкладка убирает всю группу стекла.
    private var currentContent: RecordingContent? {
        switch activeTab {
        case .summary: recordingSummaries.entry(for: path).map { .summary($0) }
        case .report: reportMarkdown.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .report($0) }
        case .transcript: document.isEmpty ? nil : .transcript(document)
        }
    }
    private var showsActions: Bool {
        currentContent != nil || (activeTab == .transcript && transcriptFile != nil && !isUntranscribed)
    }

    /// Формат выбирается тут же, а не в настройках: PDF нужен, когда расшифровку
    /// отправляют человеку, Markdown — когда её несут в свой редактор или в ИИ, и
    /// это решение каждого раза. Формулировки — те же, что в веб-интерфейсе.
    ///
    /// Подпись — `Label`: панель показывает от него одну иконку, слово отдаёт
    /// VoiceOver, а пункт выходит системным — нажимается вся стеклянная кнопка
    /// 44 pt, а не только рамка значка (см. подпись «…» в `moreMenu`).
    ///
    /// Оливковый — единственный цвет в панели: Apple советует красить значок
    /// панели, только когда цвет что-то значит, например призыв к действию (WWDC25,
    /// «Build a SwiftUI app with the new design»), а «Поделиться» — главное действие
    /// экрана. Сплошную заливку (стиль `.prominent`) HIG держит для «Готово» и
    /// «Отправить»: она «отделяет и красит» пункт — «Поделиться» ушла бы со своей
    /// подложки, и «Скопировать» осталась бы на ней одна.
    private var shareMenu: some View {
        Menu {
            ForEach(TranscriptExportFormat.allCases) { format in
                Button { export(format) } label: {
                    Text(format.title)
                    Text(format.note)
                    Image(systemName: format.icon)
                }
            }
        } label: {
            Label("Поделиться", systemImage: "square.and.arrow.up")
        }
        .disabled(currentContent == nil)
        .tint(LoriPalette.lime)
        .accessibilityLabel("Поделиться")
        .accessibilityHint("Выбор формата: PDF или Markdown")
        .accessibilityIdentifier("shareMenu")
    }

    /// PDF длинной записи — это десятки страниц вёрстки: без знака работы второе
    /// нажатие казалось бы нужным. Пока файл собирается, на месте «Поделиться» —
    /// кружок, и нажать её второй раз нельзя.
    private var exportProgress: some View {
        ProgressView()
            .accessibilityLabel("Собираю файл")
    }

    /// Копирует то же, что и прежняя кнопка: текст с именами говорящих
    /// (`outgoingText`). Галочка на две секунды отвечает там же, где нажали.
    private var copyButton: some View {
        Button(action: copy) {
            Label(copied ? "Скопировано" : "Скопировать", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .disabled(currentContent == nil)
        .tint(LoriPalette.ink)
        .accessibilityLabel(copied ? "Скопировано" : "Скопировать")
        .accessibilityHint("Скопировать: " + activeTab.title)
        .accessibilityIdentifier("copyTranscript")
    }

    // MARK: - Состояние расшифровки

    private enum Status: Equatable {
        case queued(position: Int, waitsForMemory: Bool)
        case running(starting: Bool)
        /// Облачная запись одним запросом: тело уходит, доля — по байтам системы.
        case sending(Double?)
        /// Тело у сервиса, ждём ответ.
        case awaitingService
        case interrupted
        case failed(String)
        case untranscribed
    }

    /// Блок состояния — одно значение сервиса (`state(for:)`), а не сборка из пяти
    /// коллекций: между «вышла из очереди» и «вошла в работу» у записи иначе не
    /// было ни одной отметки, и экран на секунды показывал «Расшифровки пока нет».
    ///
    /// Ошибка здесь же, строкой, а не вторым алертом: алерт про неё показывает
    /// список (`ContentView`), а на экране записи важно, что она висит рядом с
    /// кнопкой «Повторить».
    private var status: Status? {
        switch transcription.state(for: path) {
        case let .queued(position, waitsForMemory):
            .queued(position: position, waitsForMemory: waitsForMemory)
        case .starting:
            .running(starting: true)
        case .running:
            .running(starting: false)
        case let .sending(share):
            .sending(share)
        case .awaitingService:
            .awaitingService
        case .interrupted:
            .interrupted
        case let .failed(message):
            .failed(message)
        case .idle:
            isUntranscribed ? .untranscribed : nil
        }
    }

    /// Расшифровки нет: файла нет вовсе, или он прочитан и оказался пустым.
    private var isUntranscribed: Bool {
        guard document.isEmpty, !isLoadingDocument else { return false }
        guard let file = transcriptFile else { return true }
        return loadedFrom == file
    }

    @ViewBuilder
    private func statusBlock(_ status: Status) -> some View {
        if let parts = transcription.partProgress[path] {
            VStack(alignment: .leading, spacing: 8) {
                PartsProgressView(progress: parts, retry: isActive ? nil : { index in
                    transcription.retryPart(index, entry: entry, in: workspace)
                })
                if isActive { stripTextButton("Остановить") { transcription.cancel(path) } }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(LoriPalette.line.opacity(0.5)))
            .accessibilityIdentifier("transcriptionStatus")
        } else {
            switch status {
            case let .queued(position, waitsForMemory):
                StatusStrip(tint: LoriPalette.warn) {
                    SplitRow {
                        Label("В очереди · \(position)-я", systemImage: "clock")
                            .font(LoriFont.meta.weight(.semibold))
                            .foregroundStyle(LoriPalette.warn)
                        stripTextButton("Убрать из очереди") { transcription.cancel(path) }
                    }
                    // «В очереди» и «жду память» — разные вещи: первое пройдёт само,
                    // второе может и не пройти, и человек вправе видеть разницу.
                    if waitsForMemory {
                        Text("Жду, пока освободится память")
                            .font(LoriFont.small)
                            .foregroundStyle(LoriPalette.ink)
                    }
                }
            case let .running(starting):
                runningStrip(starting: starting)
            case let .sending(share):
                transferStrip(
                    title: share.map { "Отправляю запись · \(RecordStatus.percent($0))" } ?? "Отправляю запись",
                    fraction: share
                )
            case .awaitingService:
                transferStrip(title: "Жду ответ сервиса", fraction: nil)
            case .interrupted:
                StatusStrip(tint: LoriPalette.warn) {
                    Label("Расшифровка прервалась", systemImage: "pause.circle")
                        .font(LoriFont.meta.weight(.semibold))
                        .foregroundStyle(LoriPalette.warn)
                    Text(interruptedNote)
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    stripCapsuleButton("Продолжить", action: resume)
                        .padding(.top, 2)
                }
            case let .failed(message):
                StatusStrip(tint: LoriPalette.danger) {
                    Label("Не получилось расшифровать", systemImage: "exclamationmark.triangle")
                        .font(LoriFont.meta.weight(.semibold))
                        .foregroundStyle(LoriPalette.danger)
                    // Текст ошибки можно скопировать: с ним идут в настройки или в чат
                    // с разработчиком, и перепечатывать его руками незачем.
                    Text(message)
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    stripCapsuleButton("Повторить") { run(nil) }
                        .padding(.top, 2)
                }
            case .untranscribed:
                untranscribedBlock
            }
        }
    }

    private func runningStrip(starting: Bool) -> some View {
        let fraction = starting ? nil : transcription.progressFraction(for: path)
        let verb = transcriptFile == nil ? "Расшифровываю" : "Расшифровываю заново"
        let title = fraction.map { "\(verb) · \(Int($0 * 100))%" } ?? verb
        return StatusStrip(tint: LoriPalette.info) {
            SplitRow {
                Text(title)
                    .font(LoriFont.meta.weight(.semibold))
                    .foregroundStyle(LoriPalette.ink)
                stripTextButton("Остановить") { transcription.cancel(path) }
            }
            ProgressTrack(fraction: fraction, tint: LoriPalette.info)
            if let detail = runningDetail(starting: starting) {
                Text(detail)
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
            }
        }
    }

    /// Облачная запись одним запросом — отправка и ожидание ответа. Полоса меряет
    /// отправленные байты, а не расшифровку: поэтому заголовок говорит «Отправляю», а
    /// не «Расшифровываю · 100%» в конце загрузки. Пока ждём ответ, доли нет вовсе —
    /// полоса бегущим отрезком, без выдуманного процента. Строки движка под полосой
    /// нет: она повторяла бы заголовок.
    private func transferStrip(title: String, fraction: Double?) -> some View {
        StatusStrip(tint: LoriPalette.info) {
            SplitRow {
                Text(title)
                    .font(LoriFont.meta.weight(.semibold))
                    .foregroundStyle(LoriPalette.ink)
                stripTextButton("Остановить") { transcription.cancel(path) }
            }
            ProgressTrack(fraction: fraction, tint: LoriPalette.info)
        }
    }

    /// «часть 2 из 5 · осталось ~2 минуты». Слово движка «расшифровываю» уже
    /// стоит в заголовке блока — второй раз его не повторяем.
    private func runningDetail(starting: Bool) -> String? {
        guard !starting else { return "готовлю движок" }
        var parts: [String] = []
        if let note = transcription.progressText(for: path), note != "расшифровываю" {
            parts.append(note)
        }
        if let left = transcription.remainingTime(for: path) {
            parts.append("осталось ~\(LoriFormat.approximate(left))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Что сказать про оборванную расшифровку — так, как её поднимает код.
    ///
    /// `TranscriptionService.resumeInterrupted` ставит такие записи заново сам —
    /// при возвращении в приложение, при появлении сети и по таймеру после обрыва
    /// связи, — и облачные тоже: у каждого нового задания есть снимок настроек и
    /// явное нажатие человека, с которого всё началось. Раньше здесь было «сама
    /// она не начнётся» для любой облачной записи — это стало неправдой, как только
    /// задания начали хранить снимок. Сама не поднимается только облачная запись
    /// из файла сборки, где снимков ещё не было; для неё и для нетерпеливых — кнопка.
    private var interruptedNote: String {
        "Пропала связь или работу остановила система. Lori продолжит сама, когда сможет, — а чтобы не ждать, нажми «Продолжить»."
    }

    private var untranscribedBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Расшифровки пока нет.")
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.ink)
            Button { run(nil) } label: {
                Text("Расшифровать")
                    .font(LoriFont.control)
                    .foregroundStyle(LoriPalette.onInk)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 46)
                    .background(LoriPalette.lime, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("transcribeAction")
            // Куда уйдёт запись и надолго ли — до нажатия, а не после: облачный
            // движок отправит звук третьей стороне, и сказать это надо здесь.
            Text(estimate)
                .font(LoriFont.small)
                .foregroundStyle(LoriPalette.muted)
                .accessibilityIdentifier("transcribeEstimate")
            if TranscriptionSettings.engine == .geminiSubscription {
                Text(GatewaySettings.transcriptionNotice)
                    .font(LoriFont.small).foregroundStyle(LoriPalette.muted)
                    .accessibilityIdentifier("subscriptionTranscriptionNotice")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var estimate: String {
        let kind = TranscriptionSettings.engine
        let engine = EngineCatalog.descriptor(for: kind)
        let summary = speed.summary(audio: audioDuration, engine: engine, mode: TranscriptionSettings.mode(for: kind))
        return "\(engine.displayName) · \(summary)"
    }

    private func stripTextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(LoriFont.small.weight(.semibold))
            .foregroundStyle(LoriPalette.ink)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
    }

    private func stripCapsuleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(LoriFont.small.weight(.semibold))
                .foregroundStyle(LoriPalette.ink)
                .padding(.horizontal, 16)
                .frame(minHeight: 34)
                .background(LoriPalette.card, in: Capsule())
                .overlay(Capsule().stroke(LoriPalette.line, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Замечания к тексту

    @ViewBuilder
    private var notices: some View {
        let missingTimecodes = !document.isEmpty && !document.hasTimecodes
        let warnings = shownWarnings
        if !warnings.isEmpty || missingTimecodes {
            VStack(alignment: .leading, spacing: 8) {
                // Пропуски и срывы — про сам текст: о дырах надо знать до чтения.
                ForEach(warnings, id: \.self) { warning in
                    StatusStrip(tint: LoriPalette.warn) {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(LoriFont.small)
                            .foregroundStyle(LoriPalette.warn)
                    }
                }
                if missingTimecodes { noTimecodes }
            }
            .padding(.top, 16)
        }
    }

    /// Замечания, которые видны на экране: «пропуск», под которым в записи
    /// тишина, не показывается. Пока сверка идёт, «пропусков» не видно вовсе —
    /// плашка, мигнувшая и тут же пропавшая, хуже полусекундной задержки; прочие
    /// замечания (срыв ответа, обрыв по длине) видны сразу.
    private var shownWarnings: [String] {
        if let checkedWarnings, checkedWarnings.source == document.warnings {
            return checkedWarnings.visible
        }
        return document.warnings.filter { !GapRecheck.isGap($0) }
    }

    private func recheckGaps() async {
        let source = document.warnings
        guard source.contains(where: GapRecheck.isGap) else {
            checkedWarnings = nil
            return
        }
        let visible = await GapRecheck.shared.visible(in: document, audio: try? workspace.fileURL(for: path))
        guard !Task.isCancelled else { return }
        checkedWarnings = CheckedWarnings(source: source, visible: visible)
    }

    /// Почему у расшифровки нет таймкодов. Молчать нельзя: перемотка по таймкоду —
    /// одна из главных вещей экрана, и её пропажу человек примет за поломку, а не
    /// за следствие выбранного режима. Это не тревога, поэтому без цвета.
    private var noTimecodes: some View {
        Label(noTimecodesReason, systemImage: "clock.badge.xmark")
            .font(LoriFont.small)
            .foregroundStyle(LoriPalette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("noTimecodes")
    }

    /// Причина берётся из самого файла, а не из нынешних настроек: расшифровку
    /// могли сделать неделю назад другим движком, и «этот движок не дал
    /// таймкодов» про сегодняшний выбор было бы о другом.
    private var noTimecodesReason: String {
        if document.mode == "Причёсанный текст" {
            return "Режим «Причёсанный текст» не даёт таймкодов — перемотать к реплике нельзя."
        }
        if !TranscriptionSettings.timecodes {
            return "Таймкоды реплик выключены в настройках — перемотать к реплике нельзя."
        }
        return "Движок не дал таймкодов — перемотать к реплике нельзя."
    }

    // MARK: - Текст

    @ViewBuilder
    private var transcriptText: some View {
        if !document.isEmpty {
            let column = timeColumnWidth(upTo: document.lastStamp)
            // Часовая запись даёт сотни реплик. Обычный VStack создавал их все до
            // первого кадра; ленивый строит только видимую часть.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(document.lines) { line in
                    row(
                        id: line.id,
                        start: line.start,
                        approximate: line.isApproximate,
                        speaker: line.speaker,
                        text: line.text,
                        column: document.hasTimecodes ? column : nil
                    )
                }
            }
            .accessibilityIdentifier("transcriptLines")
        } else if let ready = transcription.partialTranscript(for: path), !ready.segments.isEmpty {
            // Файла ещё нет, а части уже готовы — показываем их сразу.
            let column = timeColumnWidth(upTo: ready.segments.last?.start)
            let marks = ready.segments.map { TranscriptDocument.speakerMark(in: $0.text) }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ready.segments.enumerated()), id: \.offset) { index, segment in
                    let mark = marks[index]
                    row(
                        id: index,
                        start: segment.start,
                        approximate: segment.isApproximate,
                        speaker: mark?.label,
                        text: mark?.rest ?? segment.text,
                        column: column
                    )
                }
                Skeleton()
                    .accessibilityLabel("Дальше ещё считается")
                    .accessibilityIdentifier("transcriptSkeleton")
            }
            .accessibilityIdentifier("partialTranscript")
        } else if isAwaitingDocument {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Открываю расшифровку…")
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.muted)
            }
            .accessibilityIdentifier("transcriptLoading")
        } else if isActive {
            Text("Текст появится здесь по мере готовности.")
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.muted)
        }
    }

    private var isAwaitingDocument: Bool {
        guard document.isEmpty, let file = transcriptFile else { return false }
        return isLoadingDocument || loadedFrom != file
    }

    private func timeColumnWidth(upTo last: TimeInterval?) -> CGFloat {
        (last ?? 0) >= 3600 ? hourTimeColumn : timeColumn
    }

    private func row(id: Int, start: TimeInterval?, approximate: Bool, speaker: String?, text: String, column: CGFloat?) -> some View {
        RecordingTranscriptLine(cursor: playback.cursor, id: id, start: start, approximate: approximate,
                                label: speaker, name: speaker.map { speakers.name(of: $0, in: path) }, text: text,
                                timeColumn: column, canSeek: !isRecording && audioDuration > 0, seek: seek,
                                rename: { if let speaker { beginNaming(speaker) } })
    }

    private func updatePlaybackCursor() {
        if !document.isEmpty { playback.cursor.configure(document.lines); return }
        let lines: [TranscriptDocument.Line] = transcription.partialTranscript(for: path)?.segments.enumerated().map { index, segment in
            let mark = TranscriptDocument.speakerMark(in: segment.text)
            return TranscriptDocument.Line(id: index, start: segment.start, end: segment.end,
                                           text: mark?.rest ?? segment.text, isApproximate: segment.isApproximate,
                                           speaker: mark?.label)
        } ?? []
        playback.cursor.configure(lines)
    }

    private func seek(_ start: TimeInterval) {
        guard !isRecording else { return }
        playback.seek(to: start)
        if !playback.isPlaying { playback.play() }
    }

    // MARK: - Панель навигации

    /// Слева «‹ Записи», справа две группы: «Поделиться» со «Скопировать» — и
    /// отдельно «…».
    ///
    /// На iOS 26 панель кладёт соседние пункты на одну стеклянную подложку, а
    /// фиксированный `ToolbarSpacer` разводит их на разные. Группы — по совету Apple:
    /// вместе то, что делает одно дело (HIG «Toolbars» → «Item groupings»;
    /// «Adopting Liquid Glass» → «Menus and toolbars»), а «…» — в своей группе у
    /// самого края, как в примере документации `ToolbarSpacer`: «тег, поделиться |
    /// ещё». Отдать текст наружу — одно дело, «…» — всё прочее о записи. Групп
    /// выходит три — больше HIG и не советует. Иконки и слова на одной подложке не
    /// смешиваются: «‹ Записи» со словом — в своей группе.
    ///
    /// Цвет: панель монохромна, оливковый — только у «Поделиться» (см. `shareMenu`).
    /// Акцент окна оливковый (`LoriLocalApp`), поэтому остальным пунктам цвет текста
    /// задан явно: четыре оливковых значка в ряд главного не выделяли бы.
    ///
    /// Ниже iOS 26 стекла и `ToolbarSpacer` нет: те же пункты стоят обычным рядом.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // «Готово» в углу не говорило, куда возвращает. Слово стоит текстом, а
        // не `Label`: панель iOS 26 показывает у `Label` одну иконку, и от
        // «‹ Расшифровки» на экране оставалась голая стрелка (и с
        // `.labelStyle(.titleAndIcon)` тоже). Цена — свой вид в панели нажимается
        // только своей рамкой, 90 × 36, а не всем стеклом: `.frame(minHeight: 44)`
        // панель зажимает обратно в 36 (замерено тапами у краёв, 6 октября).
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .fontWeight(.semibold)
                    Text("Записи")
                }
            }
            .tint(LoriPalette.ink)
            .accessibilityLabel("Записи")
        }
        if showsActions {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if exporting {
                    exportProgress
                } else {
                    shareMenu
                }
                copyButton
            }
            if #available(iOS 26, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            moreMenu
        }
    }

    /// Только то, что работает. Разложено по смыслу: назвать, править, отдать или
    /// расшифровать заново, удалить. Единым списком «Удалить» стояло вплотную к
    /// «Отправить в Obsidian».
    ///
    /// Первой строкой — чем расшифровано (`engineLine`), заголовком первого
    /// раздела: заголовок раздела в меню не нажимается и не выглядит выключенным
    /// пунктом, а читается подписью ко всему меню.
    private var moreMenu: some View {
        Menu {
            if let engineLine {
                Section(engineLine) { namingItems }
            } else {
                Section { namingItems }
            }
            Section {
                // Пока запись считается заново, правка ушла бы в файл, который
                // через минуту перезапишет движок.
                Button("Править текст", systemImage: "square.and.pencil") { editing = true; sheet = .editor }
                    .disabled(transcriptFile == nil || isActive)
                Button("Тема", systemImage: "tag") { sheet = .topics }
            }
            Section {
                Button("Отправить в Obsidian", systemImage: "book.closed") { sendToObsidian() }
                    .disabled(document.isEmpty)
                Menu(
                    transcriptFile == nil ? "Расшифровать другим движком" : "Расшифровать заново",
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    ForEach(retranscribeEngines) { engine in
                        // Иконка кодирует не бренд, а главное: уйдёт ли запись с
                        // телефона. Цена ошибки здесь — отправленный наружу звук.
                        Button(engine.kind.title, systemImage: engine.kind.leavesDevice ? "cloud" : "iphone") {
                            retranscribe = engine.kind
                        }
                    }
                    if retranscribeEngines.isEmpty {
                        Text("Готовых движков нет — Настройки → Движок")
                    }
                }
                .disabled(isActive)
            }
            if onDelete != nil {
                Section {
                    Button("Удалить запись", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                }
            }
        } label: {
            // `Label`, а не голая `Image`: из `Label` панель делает свой системный
            // пункт, и нажимается вся стеклянная кнопка 44 pt. Голую картинку она
            // вставляла чужим видом, и нажатие ловила только рамка 28 × 36 — тап
            // у края стекла не открывал меню (замерено тапами у краёв, 6 октября).
            Label("Ещё", systemImage: "ellipsis")
        }
        .tint(LoriPalette.ink)
        .accessibilityLabel("Ещё")
        .accessibilityHint(moreHint)
        .accessibilityIdentifier("transcriptMenu")
        // Вопросы к пунктам «…» висят на самой кнопке: в iOS 26 диалог встаёт
        // поповером у того вида, к которому привязан, — пусть это будет то место,
        // откуда человек пришёл, а не середина экрана.
        .confirmationDialog(
            retranscribeTitle,
            isPresented: Binding(get: { retranscribe != nil }, set: { if !$0 { retranscribe = nil } }),
            titleVisibility: .visible,
            presenting: retranscribe
        ) { kind in
            if transcriptFile == nil {
                Button("Расшифровать") { run(kind) }
            } else {
                Button("Расшифровать заново", role: .destructive) { run(kind) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { kind in
            Text(retranscribeMessage(kind))
        }
        .confirmationDialog(
            DeleteRecordCopy.title,
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) { deleteConfirmed() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(DeleteRecordCopy.message(active: isActive))
        }
        .confirmationDialog(
            "Заголовок придумывает модель на этом iPhone",
            isPresented: Binding(get: { offeredModel != nil }, set: { if !$0 { offeredModel = nil } }),
            titleVisibility: .visible,
            presenting: offeredModel
        ) { variant in
            Button("Скачать \(variant.accusative) · \(variant.sizeLabel)") {
                summaryModels.download(variant)
            }
            Button("Отмена", role: .cancel) {}
        } message: { variant in
            Text("Текст никуда не уходит. Модель скачивается один раз — около \(variant.sizeLabel), лучше по Wi‑Fi. Заголовок и описание появятся сами, когда она скачается.")
        }
    }

    /// Назвать запись: переименовать и придумать заголовок с описанием.
    @ViewBuilder
    private var namingItems: some View {
        if onRename != nil {
            Button("Переименовать", systemImage: "pencil") { beginRename() }
                .disabled(!canRename)
        }
        Button("Придумать заголовок и описание", systemImage: "text.quote") { requestTitle() }
            .disabled(document.isEmpty || summaryRunner.running == path)
    }

    /// Движки подменю «Расшифровать заново» — только готовые, то же правило, что у
    /// шита из панели (`EngineShortlist`): пункт, который тут же кончится «нет
    /// ключа», предлагать незачем. Исключения для выбранного в настройках здесь
    /// нет: подменю — действие, а не выбор, и галочки «выбран» в нём не бывает.
    private var retranscribeEngines: [EngineDescriptor] {
        EngineShortlist.engines(EngineCatalog.all, ready: engines.readyKinds, keeping: nil)
    }

    private var moreHint: String {
        var items: [String] = []
        if engineLine != nil { items.append("чем расшифровано") }
        if onRename != nil { items.append("переименовать") }
        items += ["заголовок и описание", "правка текста", "тема", "Obsidian"]
        items.append(transcriptFile == nil ? "расшифровать другим движком" : "расшифровать заново")
        if onDelete != nil { items.append("удалить") }
        let line = items.joined(separator: ", ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    // MARK: - Действия

    private func open() {
        if selectedTab == nil { selectedTab = recordingSummaries.entry(for: path) == nil ? .transcript : .summary }
        loadReport()
        if let url = try? workspace.fileURL(for: path) { playback.load(url) }
        // `load` узнаёт длительность сразу, без подготовки звука: этого числа
        // экрану хватает, а подписываться на плеер ради него незачем.
        audioDuration = playback.duration
        previews.load(entry, in: workspace)
        reload()
    }

    /// Перечитывает файл расшифровки вне главного потока.
    ///
    /// Заголовок здесь не сбрасывается: раньше `reload` звал `previews.invalidate`,
    /// и на время чтения шапка мигала «Запись 14:20». Превью перечитывается через
    /// `transcriptSaved` — прежнее стоит, пока не готово новое.
    private func reload() {
        let file = workspace.existingTranscript(for: entry)
        documentLoadID = UUID()
        let loadID = documentLoadID
        // Без предела в 1 МБ (`readableTextURL`): многочасовая расшифровка — тоже
        // расшифровка, и показать вместо неё «Расшифровки пока нет» было бы враньём.
        guard let file, let url = try? workspace.fileURL(for: file) else {
            document = .empty
            loadedFrom = nil
            isLoadingDocument = false
            return
        }
        isLoadingDocument = true
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let markdown = try? WorkspaceStore.readTextFile(at: url) else {
                    return TranscriptDocument.empty
                }
                return TranscriptDocument.parse(markdown)
            }.value
            guard documentLoadID == loadID else { return }
            document = loaded
            loadedFrom = file
            isLoadingDocument = false
        }
    }

    /// Правку видят все, кто читает файл: модель заголовков (прежний заголовок мог
    /// устареть) и карточка списка. Повторный вызов без правки ничего не делает.
    private func editorClosed() {
        summaryRunner.transcriptSaved(path: path)
        previews.transcriptSaved(path, in: workspace)
        reload()
    }

    private func run(_ kind: TranscriptionEngineKind?) {
        transcription.enqueue(entry, in: workspace, using: kind)
    }

    /// «Продолжить» — тем же движком, что считал до обрыва. Без движка сервис
    /// взял бы снимок, если он есть, а без снимка — движок из нынешних настроек:
    /// запись, прерванная на GigaAM, ушла бы в облако, которое выбрали позже.
    private func resume() {
        transcription.enqueue(entry, in: workspace, using: transcription.interruptedEngine(for: path))
    }

    private var retranscribeTitle: String {
        transcriptFile == nil ? "Расшифровать?" : "Расшифровать заново?"
    }

    /// Новая расшифровка заменяет файл целиком — вместе с правками руками. И куда
    /// уйдёт звук, сказано до нажатия: облачный движок отправит запись наружу.
    /// Движок назван так же, как в пункте, который человек только что нажал.
    private func retranscribeMessage(_ kind: TranscriptionEngineKind) -> String {
        let place = kind == .geminiSubscription ? GatewaySettings.transcriptionNotice : kind.leavesDevice
            ? "Запись целиком уйдёт в \(EngineCatalog.descriptor(for: kind).displayName)."
            : "Считает этот iPhone, запись никуда не уходит."
        guard transcriptFile != nil else { return "\(kind.title). \(place)" }
        return "\(kind.title). Текущий текст заменится новым, правки руками пропадут. \(place)"
    }

    private func beginRename() {
        guard canRename else { return }
        // Поле заполняется тем, что человек видит, а не именем файла: иначе
        // «Готово» без правки делало «Recording-2026-…» ручным заголовком навсегда.
        titleDraft = recordTitle.title
        titleWhenOpened = recordTitle.title
        isRenaming = true
    }

    private func commitRename() {
        let typed = titleDraft
        guard let onRename, !RecordTitle.isNoOpRename(typed: typed, current: titleWhenOpened) else { return }
        do {
            try onRename(typed, titleWhenOpened)
        } catch {
            notice = Notice(title: "Не получилось переименовать", message: RenameFailure.message(for: error))
        }
    }

    /// Удаление подтверждено. Лист закрывает список, когда запись ушла в корзину;
    /// не вышло — экран остаётся и говорит почему.
    private func deleteConfirmed() {
        do {
            try onDelete?()
        } catch {
            notice = Notice(title: "Не получилось удалить запись", message: error.localizedDescription)
        }
    }

    private func beginNaming(_ label: String) {
        speakerDraft = speakers.isNamed(label, in: path) ? speakers.name(of: label, in: path) : ""
        renamingSpeaker = label
    }

    /// Заголовок и описание по требованию — для записей, расшифрованных до того,
    /// как скачали модель, или когда прежний заголовок не подошёл.
    private func requestTitle() {
        switch summaryRunner.requestTitle(for: path, text: document.plainText) {
        case .queued:
            titleRequested = true
        case .needsModel:
            // Заявка уже ждёт модель: после скачивания заголовок придумается сам.
            titleRequested = true
            if summaryModels.downloading != nil {
                notice = Notice(
                    title: "Модель уже скачивается",
                    message: "Заголовок и описание появятся сами, когда она скачается."
                )
            } else {
                offeredModel = summaryModels.recommendedVariant
            }
        case let .waitingForMemory(message):
            titleRequested = true
            notice = Notice(title: "Заголовок придумается позже", message: message)
        case .tooShort:
            notice = Notice(title: "Запись короткая — заголовком служит первая фраза.")
        case let .failed(message):
            notice = Notice(title: "Не получилось придумать заголовок", message: message)
        }
    }

    /// Заголовок для файла, Obsidian и правки текста. У записи без имени он с
    /// полной датой — «Запись 5 октября 2026, 09:10»: файл переживёт сегодняшний
    /// день, и «Запись 09:10» завтра уже ни о чём не скажет.
    private var exportTitle: String {
        let resolved = recordTitle
        guard resolved.source == .date else { return resolved.title }
        return "Запись \(RecordClock.date(entry.modifiedAt))"
    }

    /// Текст открытой вкладки для «Скопировать»; в расшифровке — с назначенными именами.
    private var outgoingText: String {
        currentContent?.copiedText(names: speakers.names[path] ?? [:]) ?? ""
    }

    private func copy() {
        UIPasteboard.general.string = outgoingText
        copied = true
        AccessibilityNotification.Announcement("Текст скопирован").post()
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    /// Открытая вкладка уходит файлом, выбранным в единственном меню панели.
    private func export(_ format: TranscriptExportFormat) {
        guard let currentContent else { return }
        let draft = currentContent.export(title: exportTitle, recordedAt: entry.modifiedAt, duration: audioDuration,
                                          topic: topics.topic(for: path), names: speakers.names[path] ?? [:])
        let audio = try? workspace.fileURL(for: path)
        exporting = true
        Task {
            defer { exporting = false }
            // В файл — те же замечания, что на экране: «пропуск» над тишиной
            // наружу не уходит. Сверка уже в кэше, если экран успел её сделать.
            let payload = await draft.hidingSilentGaps(audio: audio)
            do {
                sheet = .share(SharePayload(url: try await payload.file(as: format), subject: payload.title))
            } catch {
                notice = Notice(title: "Не удалось собрать файл", message: error.localizedDescription)
            }
        }
    }

    private func sendToObsidian() {
        guard let url = ObsidianExport.url(title: exportTitle, text: speakers.applied(to: document.plain, in: path)) else {
            notice = Notice(
                title: "Obsidian не настроен",
                message: "Укажи название хранилища: Настройки → Хранилище."
            )
            return
        }
        openURL(url)
    }
}

/// Замечания файла после сверки со звуком — и для каких замечаний она сделана:
/// файл перечитали, и старый ответ к новому тексту не относится.
private struct CheckedWarnings {
    let source: [String]
    let visible: [String]

    /// Что сверять: запись и её замечания. Сменилось одно из двух — сверка заново.
    struct Request: Equatable {
        let path: String
        let warnings: [String]
    }
}

/// Сообщение экрана: что случилось и что делать.
private struct Notice {
    let title: String
    var message: String?
}

// MARK: - Время и дата

/// Время на экране записи — одной формой везде: таймкоды реплик (готовых и
/// частичных), остаток в плеере и длительность. «0:12», «12:03», а с часа —
/// «1:05:20». Раньше частичные реплики писали минуты без часов («84:06»), а
/// готовые — с часами, и одна запись выглядела на экране по-разному.
private enum RecordClock {
    static func time(_ seconds: TimeInterval) -> String {
        TranscriptSegment.stamp(seconds)
    }

    /// «5 октября 2026, 14:20» — как в шапке экспорта.
    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func chipDate(_ date: Date) -> String { chipFormatter.string(from: date).prefix(1).uppercased() + chipFormatter.string(from: date).dropFirst() }
    private static let chipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = LoriFormat.locale
        formatter.dateFormat = "EEE, d MMMM · HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = LoriFormat.locale
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        return formatter
    }()
}

// MARK: - Плеер

/// Плавающая капсула: кнопка, ползунок, остаток и скорость. Подписана на
/// плеер сам — позиция меняется каждые 60 мс, и это не повод пересобирать экран.
private struct PlayerCard: View {
    @ObservedObject var playback: AudioPlaybackStore
    let isRecording: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var canPlay: Bool { !isRecording && playback.duration > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 12) {
                        progress
                        HStack(spacing: 12) { playButton; Spacer(minLength: 0); rateButton }
                    }
                } else {
                    HStack(spacing: 12) { playButton; progress; rateButton }
                }
            }
            .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 10)
            .recordingPlayerSurface(expanded: typeSize.isAccessibilitySize)
            if let problem = playback.loadError {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(LoriFont.small).foregroundStyle(LoriPalette.danger)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floatingPlayer")
    }

    private var playButton: some View {
        Button(action: playback.toggle) {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LoriPalette.paleInk)
                .frame(width: 44, height: 44)
                .background(LoriPalette.pale, in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!canPlay).opacity(canPlay ? 1 : 0.45)
        .accessibilityLabel(playback.isPlaying ? "Пауза" : "Слушать")
    }
    private var progress: some View {
        VStack(spacing: 7) {
            RecordingSeekTrack(playback: playback, enabled: canPlay)
                .frame(height: 44).padding(.vertical, -20)
            HStack {
                Text(RecordClock.time(playback.position))
                    .recordingFont(12, relativeTo: .caption, monospaced: true).foregroundStyle(LoriPalette.muted)
                    .accessibilityLabel("Прошло " + RecordClock.time(playback.position))
                Spacer(minLength: 4)
                remaining
            }
        }
    }

    /// Минус не украшение: рядом в шапке стоит полная длительность, набранная
    /// теми же цифрами, и владелец прочитал «41:09» и «38:34» на одном экране как
    /// расхождение длительностей. Это остаток.
    private var remaining: some View {
        Text("−" + RecordClock.time(playback.remaining))
            .recordingFont(12, relativeTo: .caption, monospaced: true)
            .foregroundStyle(LoriPalette.muted)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Осталось \(RecordClock.time(playback.remaining))")
    }

    /// Скорость важнее перемотки: расшифровку слушают на 1,5–2×.
    private var rateButton: some View {
        Button {
            playback.rate = playback.rate >= 2 ? 1 : (playback.rate == 1 ? 1.5 : 2)
        } label: {
            Text(rateLabel)
                .recordingFont(13, weight: .semibold, relativeTo: .footnote, monospaced: true)
                .foregroundStyle(LoriPalette.ink)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(LoriPalette.bubble, in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Скорость воспроизведения")
        .accessibilityValue(rateLabel)
    }

    private var rateLabel: String {
        playback.rate == 1 ? "1×" : (playback.rate == 1.5 ? "1,5×" : "2×")
    }
}

// MARK: - Блок состояния

/// Полоса состояния: цвет только там, где состояние просит внимания (очередь и
/// обрыв — тёплый, ошибка — красный, работа — приглушённый оливковый), без рамок
/// и теней.
private struct StatusStrip<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcriptionStatus")
    }
}

/// Полоса прогресса. С долей — растёт честно; без доли — по дорожке бежит
/// отрезок, потому что честного числа взять негде. С «Уменьшением движения»
/// отрезок не бежит: подсвечена дорожка, а слово над ней говорит, что идёт работа.
private struct ProgressTrack: View {
    let fraction: Double?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.2))
                if let fraction {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, width * min(1, max(0, fraction))))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: fraction)
                } else if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.6) / 1.6
                        Capsule()
                            .fill(tint)
                            .frame(width: width * 0.3)
                            .offset(x: -width * 0.3 + width * 1.3 * phase)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Ход расшифровки")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) процентов" } ?? "Идёт работа")
    }
}

// MARK: - Раскладки

/// Два элемента в строку — первый слева, второй справа, а если вместе не
/// влезают, второй уходит под первый. Ничего не режется: в общем ряду с датой и
/// темой имя движка уже уходило в многоточие. Своя раскладка, а не `ViewThatFits`
/// с двумя вариантами: каждый элемент объявлен один раз и существует в одном
/// экземпляре, так что кнопка и её место в дереве доступности не зависят от того,
/// какой вариант выбран.
private struct SplitRow: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? ideal.map(\.width).reduce(0, +)
        if fitsInline(ideal, width: width) {
            return CGSize(width: width, height: ideal.map(\.height).max() ?? 0)
        }
        let stacked = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        return CGSize(width: width, height: stacked.map(\.height).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        if fitsInline(ideal, width: bounds.width) {
            for (index, subview) in subviews.enumerated() {
                let size = ideal[index]
                let x = index == subviews.count - 1 && index > 0 ? bounds.maxX - size.width : bounds.minX
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            }
            return
        }
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: size.height)
            )
            y += size.height
        }
    }

    private func fitsInline(_ sizes: [CGSize], width: CGFloat) -> Bool {
        sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1)) <= width
    }
}
