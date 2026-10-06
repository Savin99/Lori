import SwiftUI
import UIKit

/// Экран записи: прочитать, послушать и отдать наружу файлом.
///
/// Сверху вниз — в том порядке, в каком человек спрашивает о записи: что это
/// (заголовок, описание, дата с темой), послушать (плеер), что с ней сейчас (блок
/// состояния — только когда есть что сказать) и сам текст. Отдать — «Поделиться»
/// и «Скопировать» — в панели навигации, чем расшифровано — первой строкой «…».
///
/// «Поделиться» остаётся главным глаголом экрана: владелец, 5 октября 2026, «я
/// чатам там с ИИ не пользуюсь» — расшифровка уходит из Lori файлом. Но 6 октября
/// он обвёл две крупные капсулы под плеером и строку движка под заголовком: «мне
/// не нравятся эти кнопки, перенеси наверх». Капсулы отнимали у текста целую
/// строку экрана, а строка движка — ещё одну, ради сведения, которое нужно редко.
/// Главным «Поделиться» теперь делает оливковый цвет — единственный в панели.
struct TranscriptScreen: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var summaries: SummaryStore
    @EnvironmentObject private var summaryModels: SummaryModelStore
    @EnvironmentObject private var summaryRunner: SummaryRunner
    @EnvironmentObject private var speakers: SpeakerNames
    @EnvironmentObject private var speed: TranscriptionSpeed
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
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
    @State private var showEditor = false
    @State private var showTopics = false
    @State private var share: SharePayload?
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
    @ScaledMetric(relativeTo: .footnote) private var timeColumn: CGFloat = 46
    @ScaledMetric(relativeTo: .footnote) private var hourTimeColumn: CGFloat = 62
    /// Предел колонки говорящих: «Марина Кузнецова» не должна съедать полстроки,
    /// длинное имя обрезается многоточием.
    @ScaledMetric(relativeTo: .caption2) private var speakerCap: CGFloat = 96

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
                    PlayerCard(playback: playback, isRecording: isRecording)
                        .padding(.top, 14)
                    if let status {
                        statusBlock(status)
                            .padding(.top, 16)
                    }
                    notices
                    transcriptText
                        .padding(.top, 22)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .background(LoriPalette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showEditor, onDismiss: editorClosed) {
                if let file = transcriptFile {
                    TranscriptEditorSheet(path: file, title: exportTitle)
                }
            }
            .sheet(isPresented: $showTopics) {
                TopicSheet(
                    topics: topics,
                    title: recordTitle.title,
                    path: path,
                    suggestion: topics.suggestion(for: document.plain)
                )
            }
            .sheet(item: $share) { payload in
                ShareSheet(payload: payload)
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

    // MARK: - Шапка

    private var header: some View {
        let resolved = recordTitle
        return VStack(alignment: .leading, spacing: 0) {
            titleView(resolved.title)

            // Только описание модели. Начало расшифровки сюда не подставляется:
            // текст стоит прямо ниже, и повторять его первые строки незачем.
            if let detail = resolved.generatedDetail {
                Text(detail)
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.muted)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .accessibilityIdentifier("recordDescription")
            }

            // Дата и тема — одной строкой: тема справа, а не влезли вместе — тема
            // уходит под дату (`SplitRow`). В одной строке её высоту держит
            // 44-точечный чип темы, и дата стоит по его середине. Поля у даты —
            // для второго случая, крупного шрифта: без них она вставала вплотную
            // под описание и читалась его последней строкой. Поля поровну сверху
            // и снизу, иначе в одной строке дата съехала бы с середины чипа.
            SplitRow {
                Text(titleActivity ?? meta)
                    .font(LoriFont.small.monospacedDigit())
                    .foregroundStyle(LoriPalette.muted)
                    .padding(.vertical, 8)
                    .accessibilityLabel(titleActivity ?? spokenMeta)
                    .accessibilityIdentifier("recordingMeta")
                topicChip
            }
        }
    }

    /// Georgia — только здесь: это единственный «выставочный» момент экрана,
    /// всё остальное системными стилями.
    @ViewBuilder
    private func titleView(_ title: String) -> some View {
        let text = Text(title)
            .font(LoriFont.displaySmall)
            .foregroundStyle(LoriPalette.ink)
            .lineLimit(3)
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

    /// «5 октября 2026, 14:20 · 24:10». Дата абсолютная, а не «сегодня, 14:20»:
    /// здесь человек смотрит на одну запись, и день недели назад ему ничего не скажет.
    private var meta: String {
        let stamp = RecordClock.date(entry.modifiedAt)
        guard audioDuration > 0 else { return stamp }
        return "\(stamp) · \(RecordClock.time(audioDuration))"
    }

    private var spokenMeta: String {
        let stamp = "Записано \(RecordClock.date(entry.modifiedAt))"
        guard audioDuration > 0 else { return stamp }
        return "\(stamp), длительность \(RecordClock.time(audioDuration))"
    }

    /// Что модель заголовков делает с этой записью прямо сейчас — тогда это
    /// вместо даты. Обещать «придумываю», пока модели нет, нельзя: заявка без
    /// весов просто ждёт, и строка висела бы вечно.
    private var titleActivity: String? {
        if summaryRunner.running == path { return "Придумываю заголовок…" }
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

    private var topicChip: some View {
        let topic = topics.topic(for: path)
        return Button { showTopics = true } label: {
            HStack(spacing: 4) {
                if topic == nil {
                    Image(systemName: "plus")
                        .font(LoriFont.tiny.weight(.bold))
                }
                Text(topic ?? "Тема")
                    .font(LoriFont.small)
                    .lineLimit(1)
            }
            .foregroundStyle(topic == nil ? LoriPalette.muted : LoriPalette.lime)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(topic == nil ? LoriPalette.card : LoriPalette.limeSoft.opacity(0.6), in: Capsule())
            .overlay(Capsule().stroke(LoriPalette.line, lineWidth: topic == nil ? 1 : 0))
            // Рисуется на 28 pt, нажимается на 44 — как чипы нижней панели.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(topic.map { "Тема: \($0)" } ?? "Тема не выбрана")
        .accessibilityHint("Выбрать тему записи")
        .accessibilityIdentifier("topicChip")
    }

    // MARK: - Поделиться и скопировать

    /// Без расшифровки этих кнопок нет вовсе: из панели уходит весь пункт, а не
    /// вид внутри него — иначе на стекле осталась бы пустая подложка (Apple,
    /// «Adopting Liquid Glass» → «Check how you hide toolbar items»). Выключенные
    /// серые кнопки спорили бы с единственной живой — «Расшифровать». Пока файл
    /// расшифровки дочитывается, кнопки видны (и выключены): исчезни они на этот
    /// миг — панель мигала бы при каждом открытии записи.
    private var showsActions: Bool {
        !document.isEmpty || (transcriptFile != nil && !isUntranscribed)
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
        .disabled(document.isEmpty)
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
        .disabled(document.isEmpty)
        .tint(LoriPalette.ink)
        .accessibilityLabel(copied ? "Скопировано" : "Скопировать")
        .accessibilityHint("Текст расшифровки с именами говорящих")
        .accessibilityIdentifier("copyTranscript")
    }

    // MARK: - Состояние расшифровки

    private enum Status: Equatable {
        case queued(position: Int, waitsForMemory: Bool)
        case running(starting: Bool)
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
            let pills = speakerPills(document.lines.compactMap(\.speaker))
            // Часовая запись даёт сотни реплик. Обычный VStack создавал их все до
            // первого кадра; ленивый строит только видимую часть.
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(document.lines) { line in
                    row(
                        start: line.start,
                        approximate: line.isApproximate,
                        speaker: line.speaker,
                        text: line.text,
                        column: document.hasTimecodes ? column : nil,
                        pills: pills
                    )
                }
            }
            .accessibilityIdentifier("transcriptLines")
        } else if let ready = transcription.partialTranscript(for: path), !ready.segments.isEmpty {
            // Файла ещё нет, а части уже готовы — показываем их сразу.
            let column = timeColumnWidth(upTo: ready.segments.last?.start)
            let marks = ready.segments.map { TranscriptDocument.speakerMark(in: $0.text) }
            let pills = speakerPills(marks.compactMap { $0?.label })
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(ready.segments.enumerated()), id: \.offset) { index, segment in
                    let mark = marks[index]
                    row(
                        start: segment.start,
                        approximate: segment.isApproximate,
                        speaker: mark?.label,
                        text: mark?.rest ?? segment.text,
                        column: column,
                        pills: pills
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

    /// Ширина кружка каждого говорящего и общая колонка под них.
    ///
    /// Колонка одна на весь документ — по самому широкому кружку, но не шире
    /// `speakerCap`. Раньше у каждой реплики была своя ширина: «Марина» рядом с «S2»
    /// сдвигала текст своих реплик правее соседних, и столбец текста шёл лесенкой.
    /// Меряется заранее, по шрифту, а не раскладкой: ленивый список строит только
    /// видимые строки, и колонка, собранная из них, прыгала бы при прокрутке.
    private func speakerPills(_ labels: [String]) -> SpeakerPills? {
        let unique = Set(labels)
        guard !unique.isEmpty else { return nil }
        let category = UIContentSizeCategory(typeSize)
        let base = UIFont.preferredFont(forTextStyle: .caption2, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        let font = UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
        var widths: [String: CGFloat] = [:]
        for label in unique {
            let named = speakers.isNamed(label, in: path)
            let text = named ? speakers.name(of: label, in: path) : label
            let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
            // Поля — как у `SpeakerDot`: у имени шире, у метки «S1» уже.
            let ideal = ceil(textWidth) + (named ? 16 : 8)
            widths[label] = min(speakerCap, max(26, ideal))
        }
        return SpeakerPills(widths: widths, column: widths.values.max() ?? 26)
    }

    /// Реплика: таймкод — кнопка, текст — нет.
    ///
    /// Раньше кнопкой была вся строка, и текст нельзя было выделить: долгое
    /// нажатие уходило в кнопку. Теперь перематывает таймкод, а реплику можно
    /// выделить и скопировать — часто нужна одна реплика, а не вся запись.
    /// `column` — ширина колонки времени; nil — таймкодов в расшифровке нет вовсе.
    @ViewBuilder
    private func row(
        start: TimeInterval?,
        approximate: Bool,
        speaker: String?,
        text: String,
        column: CGFloat?,
        pills: SpeakerPills?
    ) -> some View {
        if typeSize.isAccessibilitySize {
            // На самых крупных размерах три колонки в строку оставляли тексту
            // одно слово на строку. Время и говорящий встают над репликой, а
            // текст получает всю ширину.
            VStack(alignment: .leading, spacing: 4) {
                if start != nil || speaker != nil {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let start { timeButton(start, approximate: approximate, width: nil) }
                        if let speaker { speakerDot(speaker) }
                    }
                }
                replica(text)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let column {
                    if let start {
                        timeButton(start, approximate: approximate, width: column)
                    } else {
                        // Продолжение реплики: колонка времени пустая, но она есть.
                        // Без неё абзацы одной реплики разъезжаются по левому краю,
                        // и читается это как разные реплики.
                        Color.clear.frame(width: column, height: 1)
                    }
                }
                if let pills {
                    // Колонка говорящих есть у каждой строки документа с говорящими:
                    // без метки она пустая, но держит текст на одной вертикали.
                    if let speaker {
                        speakerDot(speaker, width: pills.widths[speaker])
                            .frame(width: pills.column, alignment: .leading)
                    } else {
                        Color.clear.frame(width: pills.column, height: 1)
                    }
                }
                replica(text)
            }
        }
    }

    private func replica(_ text: String) -> some View {
        Text(text)
            .font(LoriFont.body)
            .foregroundStyle(LoriPalette.ink)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// «≈» — время это границы отправленного куска, а не реплики: выдать его за
    /// таймкод речи значило бы соврать.
    /// `width` — ширина колонки; nil — по самому времени (время над репликой).
    private func timeButton(_ start: TimeInterval, approximate: Bool, width: CGFloat?) -> some View {
        let stamp = RecordClock.time(start)
        return Button {
            guard !isRecording else { return }
            playback.seek(to: start)
            if !playback.isPlaying { playback.play() }
        } label: {
            Text((approximate ? "≈" : "") + stamp)
                .font(LoriFont.small.monospacedDigit())
                .foregroundStyle(LoriPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: width, alignment: .leading)
                // Точка нажатия 44 pt, а строка не раздувается: мелкий таймкод
                // рядом с одной строкой текста иначе сделал бы ленту вдвое реже.
                .padding(.vertical, 13)
                .contentShape(Rectangle())
                .padding(.vertical, -13)
        }
        .buttonStyle(.plain)
        .disabled(isRecording)
        .accessibilityLabel(approximate ? "Примерно \(stamp)" : stamp)
        .accessibilityHint("Слушать с \(stamp)")
        .accessibilityIdentifier("lineTime")
    }

    /// Кружок называет говорящего долгим нажатием — сразу по всей записи.
    /// `width` — ширина кружка, посчитанная для колонки; nil — по содержимому.
    private func speakerDot(_ label: String, width: CGFloat? = nil) -> some View {
        SpeakerDot(
            label: label,
            name: speakers.isNamed(label, in: path) ? speakers.name(of: label, in: path) : nil,
            width: width
        )
        .onLongPressGesture(minimumDuration: 0.5) { beginNaming(label) }
        .accessibilityAction(named: "Назвать говорящего") { beginNaming(label) }
        .accessibilityIdentifier("speakerDot")
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
                Button("Править текст", systemImage: "square.and.pencil") { showEditor = true }
                    .disabled(transcriptFile == nil || isActive)
                Button("Тема", systemImage: "tag") { showTopics = true }
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
        let place = kind.leavesDevice
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

    /// Текст для «Скопировать» и Obsidian: с именами вместо меток — снаружи
    /// приложения кружков нет, и «S1» ничего не значит.
    private var outgoingText: String {
        speakers.applied(to: document.plain, in: path)
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

    /// Расшифровка уходит наружу файлом: в нём шапка, описание, таймкоды и имена
    /// говорящих — всё, что видно на экране.
    private func export(_ format: TranscriptExportFormat) {
        let draft = TranscriptExport.make(
            document: document,
            title: exportTitle,
            recordedAt: entry.modifiedAt,
            duration: audioDuration,
            detail: recordTitle.generatedDetail,
            topic: topics.topic(for: path),
            names: speakers.names[path] ?? [:]
        )
        let audio = try? workspace.fileURL(for: path)
        exporting = true
        Task {
            defer { exporting = false }
            // В файл — те же замечания, что на экране: «пропуск» над тишиной
            // наружу не уходит. Сверка уже в кэше, если экран успел её сделать.
            let payload = await draft.hidingSilentGaps(audio: audio)
            do {
                share = SharePayload(url: try await payload.file(as: format), subject: payload.title)
            } catch {
                notice = Notice(title: "Не удалось собрать файл", message: error.localizedDescription)
            }
        }
    }

    private func sendToObsidian() {
        guard let url = ObsidianExport.url(title: exportTitle, text: outgoingText) else {
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

/// Ширины кружков говорящих в документе и колонка под самый широкий.
private struct SpeakerPills {
    let widths: [String: CGFloat]
    let column: CGFloat
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = LoriFormat.locale
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        return formatter
    }()
}

// MARK: - Плеер

/// Плеер одной карточкой: кнопка, ползунок, остаток и скорость. Подписан на
/// плеер сам — позиция меняется каждые 60 мс, и это не повод пересобирать экран.
private struct PlayerCard: View {
    @ObservedObject var playback: AudioPlaybackStore
    let isRecording: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var canPlay: Bool { !isRecording && playback.duration > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                // На самых крупных размерах текста ползунку в одной строке с тремя
                // кнопками не остаётся места — он встаёт отдельной строкой.
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        slider.padding(.horizontal, 8)
                        HStack(spacing: 8) {
                            playButton
                            remaining
                            Spacer(minLength: 8)
                            rateButton
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        playButton
                        slider
                        remaining
                        rateButton
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(LoriPalette.line, lineWidth: 1))

            if let problem = playback.loadError {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.danger)
            }
        }
    }

    private var playButton: some View {
        Button(action: playback.toggle) {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(LoriFont.meta.weight(.bold))
                .foregroundStyle(LoriPalette.ink)
                .frame(width: 38, height: 38)
                .background(LoriPalette.bubble, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .opacity(canPlay ? 1 : 0.45)
        .accessibilityLabel(playback.isPlaying ? "Пауза" : "Слушать")
    }

    private var slider: some View {
        Slider(
            value: Binding(get: { playback.position }, set: { playback.scrub(to: $0) }),
            in: 0...max(playback.duration, 0.01),
            onEditingChanged: { editing in
                if editing { playback.beginScrub() } else { playback.endScrub() }
            }
        )
        .tint(LoriPalette.lime)
        .disabled(playback.duration == 0)
        .accessibilityLabel("Позиция в записи")
        .accessibilityValue(RecordClock.time(playback.position))
    }

    /// Минус не украшение: рядом в шапке стоит полная длительность, набранная
    /// теми же цифрами, и владелец прочитал «41:09» и «38:34» на одном экране как
    /// расхождение длительностей. Это остаток.
    private var remaining: some View {
        Text("−" + RecordClock.time(playback.remaining))
            .font(LoriFont.small.monospacedDigit())
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
                .font(LoriFont.small.monospacedDigit())
                .foregroundStyle(LoriPalette.ink)
                .padding(.horizontal, 9)
                .frame(minWidth: 38, minHeight: 30)
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

// MARK: - Говорящий

/// Цветной кружок говорящего: реплики разных людей различаются с одного
/// взгляда, а не чтением меток в тексте. Цвет стабилен для номера — «S1»
/// всегда одного цвета в пределах приложения.
struct SpeakerDot: View {
    let label: String
    /// Имя, если человек его дал. Цвет всё равно считается по метке: он должен
    /// остаться прежним и после переименования.
    var name: String?
    /// Точная ширина — в колонке говорящих. Длинное имя в ней обрезается.
    var width: CGFloat?

    /// Палитра из токенов приложения: у каждой пары «светлый — тёмный» уже
    /// подобрана плотность, случайные оттенки в тёмной теме бы выпадали.
    private static let colors: [Color] = [
        LoriPalette.lime, LoriPalette.accentAlt, LoriPalette.warn, LoriPalette.info,
    ]

    var body: some View {
        Text(name ?? label)
            .font(LoriFont.tiny.weight(.semibold))
            .foregroundStyle(LoriPalette.onInk)
            .lineLimit(1)
            .truncationMode(.tail)
            // Поля и у метки: на крупном шрифте «S2» шире кружка в 26 pt и без
            // них упиралась бы в его край.
            .padding(.horizontal, name == nil ? 4 : 8)
            .frame(width: width)
            .frame(minWidth: 26, minHeight: 26)
            .background(color, in: Capsule())
            .accessibilityLabel("Говорящий \(name ?? label)")
            .accessibilityHint("Долгое нажатие — назвать говорящего")
    }

    private var color: Color {
        let number = Int(label.filter(\.isNumber)) ?? 1
        let index = (number - 1) % Self.colors.count
        return Self.colors[index < 0 ? index + Self.colors.count : index]
    }
}
