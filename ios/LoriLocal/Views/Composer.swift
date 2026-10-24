import AVFoundation
import SwiftUI

/// Файл, прикреплённый к панели и ещё не отданный в расшифровку.
///
/// Импорт всегда проходит через подтверждение: файл сначала виден в панели
/// с движком и оценкой времени, и только потом уходит в работу. Раньше выбор
/// в «Файлах» немедленно ставил запись в очередь — человек узнавал, каким
/// движком и почём, уже постфактум.
struct AttachedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var duration: TimeInterval?

    var name: String { url.lastPathComponent }
}

/// Что сейчас делает панель. Состояний три, и они взаимоисключающие —
/// перечисление вместо набора флагов не даёт собрать «запись при прикреплённом
/// файле» и прочие несуществующие сочетания.
///
/// Четвёртое, `typing` (набор вопроса ассистенту), ушло вместе с чатом
/// «Спроси свой архив» 5 октября 2026: владелец им не пользовался — он
/// расшифровывает и сам относит файл в ИИ.
enum ComposerState: Equatable {
    case idle
    case recording
    case attached
}

/// Состояние нижней панели. Живёт в модели, а не в `@State` экрана: панель
/// и прикреплённый файл переживают открытие листов — настроек, выбора движка.
@MainActor
final class ComposerModel: ObservableObject {
    @Published var attached: [AttachedFile] = []
    @Published var clipboard: ClipboardAudio.Content = .none
    /// Сколько в буфере аудио — по типам, без чтения: «В буфере 5 аудио».
    @Published var clipboardInventory = ClipboardAudio.Inventory()
    /// Подсказку убрали крестиком — до следующей смены содержимого буфера.
    @Published var clipboardDismissed = false
    private var lastSeenClipboard: ClipboardAudio.Content = .none
    private var lastSeenInventory = ClipboardAudio.Inventory()

    func state(recording: Bool) -> ComposerState {
        if recording { return .recording }
        if !attached.isEmpty { return .attached }
        return .idle
    }

    /// Показывать ли подсказку про буфер. Она живёт **над** капсулой отдельной
    /// строкой и ничего собой не закрывает: скопированное аудио может лежать в
    /// буфере часами, и всё это время кнопка записи и чипы обязаны оставаться
    /// на месте. Раньше подсказка замещала собой часть панели (тогда — поле
    /// вопроса ассистенту), и той частью было не воспользоваться.
    var showsClipboardHint: Bool {
        clipboard == .audio && !clipboardDismissed && attached.isEmpty
    }

    /// Текст подсказки: «В буфере 5 аудио», а без счёта — «В буфере есть аудио».
    var clipboardHint: String {
        clipboardInventory.hint ?? "В буфере есть аудио"
    }

    /// Пункт меню `+`: «Вставить 5 аудио» — сразу видно, что уйдут все, а не первое.
    var pasteTitle: String {
        clipboardInventory.audio > 1 ? "Вставить \(clipboardInventory.audio) аудио" : "Вставить аудио"
    }

    /// Типы буфера читаются без содержимого, поэтому вызывать можно свободно.
    func refreshClipboard() {
        let found = ClipboardAudio.content()
        let inventory = ClipboardAudio.inventory()
        // Скопировали что-то новое — подсказка возвращается: отказ от прошлой
        // не должен молча распространяться на следующую запись.
        if found != lastSeenClipboard || inventory != lastSeenInventory {
            lastSeenClipboard = found
            lastSeenInventory = inventory
            clipboardDismissed = false
        }
        clipboard = found
        clipboardInventory = inventory
    }

    func attach(_ urls: [URL]) {
        for url in urls where !attached.contains(where: { $0.url == url }) {
            attached.append(AttachedFile(url: url))
            loadDuration(of: url)
        }
    }

    func detach(_ file: AttachedFile) {
        attached.removeAll { $0.id == file.id }
        ImportInbox.forget(file.url)
    }

    /// Снятый крестиком или уже отданный в работу файл удаляется из
    /// промежуточной папки — иначе он прицепится обратно при следующем
    /// возвращении в приложение, когда панель заново соберёт принесённое.
    func clear() {
        for file in attached { ImportInbox.forget(file.url) }
        attached = []
    }

    /// Суммарная длительность прикреплённого — из неё считается оценка времени.
    var attachedDuration: TimeInterval {
        attached.compactMap(\.duration).reduce(0, +)
    }

    private func loadDuration(of url: URL) {
        Task { [weak self] in
            let value = try? await AVURLAsset(url: url).load(.duration).seconds
            guard let self, let value, value.isFinite, value > 0 else { return }
            guard let index = attached.firstIndex(where: { $0.url == url }) else { return }
            attached[index].duration = value
        }
    }
}

/// Всё, что панель делает наружу. Отдельной структурой, иначе у `ComposerBar`
/// набирается полтора десятка замыканий в списке параметров.
///
/// «Настройки» из меню `+` убраны: шестерёнка в шапке открывает то же самое, а
/// второй вход в одно место — лишний пункт там, где выбирают, что добавить.
struct ComposerActions {
    var record: () -> Void
    var stop: () -> Void
    var togglePause: () -> Void
    var cancelRecording: () -> Void
    var pickFile: () -> Void
    var paste: () -> Void
    var chooseEngine: () -> Void
    var setMode: (TranscriptionMode) -> Void
    var transcribe: () -> Void
}

/// Нижняя панель: записать голос или расшифровать принесённые файлы.
///
/// В покое это одна строка: `+`, чип движка, чип режима и круглая кнопка
/// записи. Прикреплённые файлы добавляют сверху их список с оценкой времени, а
/// круглая кнопка вытягивается в капсулу «Расшифровать 5» во всю ширину под
/// чипами: рядом с чипами ей не хватает места даже на большом телефоне, а
/// урезать название движка в момент выбора нельзя — это и есть цена решения.
/// Запись схлопывает панель в строку с таймером и волной. Капсула панели
/// закреплена у нижнего края: между состояниями меняется начинка, а не сама
/// панель, поэтому переход читается как перетекание, а не как подмена вью.
struct ComposerBar: View {
    @ObservedObject var model: ComposerModel
    @ObservedObject var recorder: RecordingController
    @ObservedObject var engines: EngineDirectory
    @ObservedObject var speed: TranscriptionSpeed

    let engine: EngineDescriptor
    let mode: TranscriptionMode?
    /// Строка над панелью: «Добавляю 5 записей…». Состояние очереди живёт в блоке
    /// над списком, здесь — только то, что относится к нажатию в самой панели.
    let status: String?
    /// Идёт приём прикреплённого: кнопки панели ждут, пока он кончится.
    let busy: Bool
    let actions: ComposerActions

    @Namespace private var morph
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Сколько файлов видно без раскрытия списка.
    private static let collapsedCount = 4

    private var state: ComposerState { model.state(recording: recorder.isCapturing) }

    /// Строка над панелью во время записи: причина паузы важнее подсказки про островок.
    private var recordingNote: String? {
        guard recorder.isCapturing else { return nil }
        if recorder.isPaused, let words = recorder.pauseWords { return "Пауза · \(words)" }
        return recorder.activityHint
    }

    var body: some View {
        VStack(spacing: 8) {
            if let status = status ?? (recorder.phase == .finishing ? "Сохраняю запись…" : nil) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(status)
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.muted)
                    Spacer(minLength: 0)
                }
                .composerAccessory(leading: 14, trailing: 14, minHeight: 36)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("composerStatus")
            } else if let note = recordingNote {
                // Одна строка, и только когда есть что сказать: почему запись встала
                // («Пауза · звонок») или что кнопок в островке не будет.
                Text(note)
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .composerAccessory(leading: 14, trailing: 14, minHeight: 36)
                    .accessibilityIdentifier("recordingNote")
            }

            if model.showsClipboardHint, state != .recording {
                clipboardRow
                    // Своих 4 точек слева у строки мало для плашки: текст лёг бы
                    // вплотную к скруглению.
                    .composerAccessory(leading: 10, trailing: 0, minHeight: 44)
            }

            VStack(alignment: .leading, spacing: 8) {
                if state == .attached {
                    attachedSection
                }
                controlRow
                if state == .attached {
                    primaryButton
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .composerPanelSurface()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .composerGlassGroup()
        .composerBackdrop()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: state)
        .onChange(of: model.attached.count) { _, count in
            if count <= Self.collapsedCount { expanded = false }
        }
    }

    // MARK: - Прикреплённые файлы

    private var attachedSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            fileList

            VStack(alignment: .leading, spacing: 2) {
                if model.attached.count > 1 {
                    HStack(spacing: 8) {
                        Text(summaryLine)
                            .font(LoriFont.meta.weight(.medium).monospacedDigit())
                            .foregroundStyle(LoriPalette.ink)
                        Spacer(minLength: 4)
                        Button("Убрать все") { model.clear() }
                            .font(LoriFont.small)
                            .foregroundStyle(LoriPalette.muted)
                            .frame(minHeight: 32)
                            .disabled(busy)
                            .accessibilityIdentifier("detachAllButton")
                    }
                    // Край текста — по столбцу крестиков выше, а не вплотную к рамке.
                    .padding(.trailing, 14)
                }
                Text(estimateLine)
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
                    .accessibilityIdentifier("attachedEstimate")
            }
            .padding(.leading, 8)
            .padding(.top, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachedFile")
    }

    @ViewBuilder
    private var fileList: some View {
        let files = model.attached
        let hidden = max(0, files.count - Self.collapsedCount)
        if expanded, hidden > 0 {
            // Раскрытый список прокручивается в своих пределах: двадцать файлов не
            // должны вытолкнуть панель за верх экрана.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(files) { fileRow($0) }
                }
            }
            .frame(maxHeight: 44 * 5.5)
            .scrollIndicatorsFlash(onAppear: true)
            moreButton(title: "Свернуть список", symbol: "chevron.up") { expanded = false }
        } else {
            VStack(spacing: 0) {
                ForEach(files.prefix(Self.collapsedCount)) { fileRow($0) }
            }
            if hidden > 0 {
                moreButton(title: "Ещё \(hidden)", symbol: "chevron.down") { expanded = true }
            }
        }
    }

    private func fileRow(_ file: AttachedFile) -> some View {
        HStack(spacing: 8) {
            Text((file.name as NSString).deletingPathExtension)
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let duration = file.duration {
                Text(HomeFormat.clock(duration))
                    .font(LoriFont.small.monospacedDigit())
                    .foregroundStyle(LoriPalette.muted)
                    .fixedSize()
            }
            Button {
                model.detach(file)
            } label: {
                Image(systemName: "xmark")
                    .font(LoriFont.tiny.weight(.semibold))
                    .foregroundStyle(LoriPalette.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel("Убрать «\(file.name)»")
            .accessibilityIdentifier("detachButton")
        }
        .padding(.leading, 8)
        .frame(minHeight: 44)
    }

    private func moreButton(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: symbol)
                    .font(LoriFont.tiny.weight(.semibold))
            }
            .font(LoriFont.small.weight(.medium))
            .foregroundStyle(LoriPalette.lime)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .accessibilityIdentifier("attachedMore")
    }

    /// «5 файлов · 1:41:12». Пока длительности читаются — без времени.
    private var summaryLine: String {
        let count = HomeFormat.files(model.attached.count)
        let seconds = model.attachedDuration
        return seconds > 0 ? "\(count) · \(HomeFormat.clock(seconds))" : count
    }

    /// Пересчитывается при смене чипа движка: «в облако · примерно 3 минуты»
    /// против «на телефоне · примерно 12 минут» — это и есть цена выбора.
    private var estimateLine: String {
        speed.summary(audio: model.attachedDuration, engine: engine, mode: mode)
    }

    private var clipboardRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(LoriFont.small)
                .foregroundStyle(LoriPalette.muted)
                .accessibilityHidden(true)
            Text(model.clipboardHint)
                .font(LoriFont.small)
                .foregroundStyle(LoriPalette.muted)
            Spacer(minLength: 4)
            Button("Вставить", action: actions.paste)
                .font(LoriFont.small.weight(.semibold))
                .foregroundStyle(LoriPalette.lime)
                .frame(minHeight: 44)
                .accessibilityIdentifier("pasteAudioButton")
            Button {
                model.clipboardDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(LoriFont.tiny.weight(.semibold))
                    .foregroundStyle(LoriPalette.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Скрыть подсказку про буфер")
        }
        .padding(.leading, 4)
        .accessibilityIdentifier("clipboardHint")
    }

    // MARK: - Строка управления

    /// Строка, которая есть всегда: в покое она и есть вся панель, при
    /// прикреплённых файлах стоит под их списком, во время записи
    /// превращается в таймер с волной.
    @ViewBuilder
    private var controlRow: some View {
        if state == .recording {
            HStack(spacing: 6) {
                RecordingRow(
                    recorder: recorder,
                    togglePause: actions.togglePause,
                    cancel: actions.cancelRecording
                )
                roundButton
            }
        } else {
            HStack(spacing: 6) {
                // Полные подписи не помещаются — чипы прокручиваются вбок, а не
                // режутся до «E…» и «Дос…»: при крупном шрифте по такому огрызку
                // не понять, какой движок выбран. Кнопка записи при этом на месте.
                ViewThatFits(in: .horizontal) {
                    chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        chips.fixedSize()
                    }
                }

                Spacer(minLength: 0)
                if state == .idle {
                    roundButton
                }
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            plusMenu

            EngineChip(
                engine: engine,
                readiness: engines.readiness(of: engine.kind),
                action: actions.chooseEngine
            )
            if let mode {
                ModeChip(engine: engine, current: mode, select: actions.setMode)
            }
        }
    }

    /// Меню `+`. Диктофона здесь нет: оттуда файл приходит через «Поделиться».
    private var plusMenu: some View {
        Menu {
            Button {
                actions.pickFile()
            } label: {
                Label("Аудио из Файлов", systemImage: "folder")
            }
            Button {
                actions.paste()
            } label: {
                Label(model.pasteTitle, systemImage: "doc.on.clipboard")
            }
            .disabled(model.clipboard == .none)
        } label: {
            Image(systemName: "plus")
                .font(LoriFont.control)
                .foregroundStyle(LoriPalette.ink)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(busy)
        .accessibilityLabel(state == .attached ? "Добавить ещё" : "Добавить запись")
        .accessibilityIdentifier("importButton")
    }

    // MARK: - Главная кнопка

    /// Одна кнопка на все состояния: микрофон, стоп — и вытянутая капсула
    /// «Расшифровать». Круг и капсула делят одно место в анимации
    /// (`matchedGeometryEffect`), поэтому смена состояния выглядит как
    /// превращение, а не как исчезновение одной кнопки и появление другой.
    private var roundButton: some View {
        Button(action: roundAction) {
            Image(systemName: state == .recording ? "stop.fill" : "mic.fill")
                .font(LoriFont.control)
                .foregroundStyle(LoriPalette.onInk)
                .frame(width: 36, height: 36)
                .background(roundFill, in: Capsule())
                .matchedGeometryEffect(id: "primary", in: morph, isSource: true)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        // Пока куски склеиваются, второй «стоп» нажимать нечего.
        .disabled(recorder.phase == .finishing)
        .contentTransition(.symbolEffect(.replace))
        // Значок в круге на 36 точек: при самом крупном шрифте он вылезал за круг.
        // Крупно его показывает просмотр по долгому нажатию, как у системных панелей.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
        .accessibilityLabel(state == .recording ? "Остановить запись" : "Записать")
        .accessibilityIdentifier(state == .recording ? "stopButton" : "recordButton")
    }

    /// «Расшифровать» или «Расшифровать 5» — во всю ширину под чипами.
    private var primaryButton: some View {
        Button(action: actions.transcribe) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LoriPalette.onInk)
                }
                Text(primaryTitle)
                    .font(LoriFont.control)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(LoriPalette.onInk)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background(LoriPalette.ink.opacity(busy ? 0.55 : 0.9), in: Capsule())
            .matchedGeometryEffect(id: "primary", in: morph, isSource: true)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(model.attached.count > 1
            ? "Расшифровать \(HomeFormat.files(model.attached.count))"
            : "Расшифровать")
        .accessibilityIdentifier("transcribeButton")
    }

    private var primaryTitle: String {
        model.attached.count > 1 ? "Расшифровать \(model.attached.count)" : "Расшифровать"
    }

    private var roundFill: Color {
        state == .recording ? LoriPalette.danger : LoriPalette.ink.opacity(0.9)
    }

    // Перечисление без `default`: новое состояние панели должно остановить
    // сборку здесь, а не молча достаться микрофону.
    private func roundAction() {
        switch state {
        case .recording: actions.stop()
        case .attached: actions.transcribe()
        case .idle: actions.record()
        }
    }
}

// MARK: - Поверхность панели

/// Как нижняя панель лежит поверх списка.
///
/// iOS 26 — жидкое стекло (владелец, 6 октября 2026: «внизу, где селектор, его
/// нужно сделать в стиле Apple жидкое стекло»). Панель — слой управления над
/// контентом: список прокручивается под ней и просвечивает. Читаемость держит
/// само стекло — вариант `.regular` размывает то, что под ним, и подстраивает
/// яркость (HIG, «Materials»), — а край прокрутки под панелью (`safeAreaBar` в
/// `ContentView`) ещё и гасит строки у нижнего края. Поэтому сплошной подложки,
/// которой раньше закрывали проступавший текст, на iOS 26 нет.
///
/// Ниже iOS 26 — ровно как было: сплошная карточка на сплошной подложке.
private extension View {
    /// Сама панель: скруглённый прямоугольник 26 — на iOS 26 стеклянный.
    ///
    /// Стекло без оттенка и без `interactive()`: цвет Apple советует оставлять
    /// главному действию (HIG, «Liquid Glass color»), а реакция на касание — для
    /// отдельных кнопок, панель же — подложка под несколькими. Чипы и кнопки на ней
    /// своего стекла не получают: стекло на стекле Apple просит не класть
    /// («avoid layering Liquid Glass elements on top of each other»).
    @ViewBuilder
    func composerPanelSurface() -> some View {
        // Скругление непрерывное и фиксированное: `Capsule` на двух строках
        // превращает панель в стадион, а радиус перестаёт держать форму.
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(LoriPalette.card, in: shape)
                .overlay(shape.stroke(LoriPalette.line, lineWidth: 1))
        }
    }

    /// Строка над панелью — подсказка буфера или «Добавляю…». На iOS 26 под ней
    /// нет сплошной подложки, и голый текст читался бы прямо по карточкам, поэтому
    /// у строки своя стеклянная плашка — рядом с панелью, а не на ней (как
    /// мини-плеер над полосой вкладок). Ниже iOS 26 строка как была.
    @ViewBuilder
    func composerAccessory(leading: CGFloat, trailing: CGFloat, minHeight: CGFloat) -> some View {
        if #available(iOS 26, *) {
            padding(.leading, leading)
                .padding(.trailing, trailing)
                .frame(minHeight: minHeight)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            self
        }
    }

    /// Стеклянные формы панели — в одном контейнере: так Apple советует ради
    /// скорости отрисовки («Applying Liquid Glass to custom views»). Интервал меньше
    /// просвета между строкой и панелью (8): при большем формы сливались бы в одну
    /// и в покое.
    @ViewBuilder
    func composerGlassGroup() -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 4) { self }
        } else {
            self
        }
    }

    /// Подложка под всей панелью — только ниже iOS 26.
    @ViewBuilder
    func composerBackdrop() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            // Подложка сплошная и уходит под полоску «домой». Полупрозрачная
            // пропускала текст карточек сквозь панель: в тёмной теме заливка
            // карточки — шесть процентов белого, и строки списка читались прямо
            // поверх чипов.
            background(LoriPalette.canvas.ignoresSafeArea(edges: .bottom))
        }
    }
}

/// Строка записи: пауза, таймер, живая волна, отмена.
struct RecordingRow: View {
    @ObservedObject var recorder: RecordingController
    let togglePause: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: togglePause) {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(LoriFont.small.weight(.bold))
                    .foregroundStyle(LoriPalette.ink)
                    .frame(width: 34, height: 34)
                    .background(LoriPalette.panelButton, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(recorder.isPaused ? "Продолжить запись" : "Поставить на паузу")
            .accessibilityIdentifier("pauseButton")

            Text(LoriFormat.duration(recorder.elapsed))
                .font(LoriFont.meta.monospacedDigit())
                .foregroundStyle(LoriPalette.ink)
                .fixedSize()

            LiveWave(levels: recorder.levels, paused: !recorder.isRecording)

            // У записи, поднятой после перезапуска Lori, это уже не «отмена» начатого,
            // а решение о целой записи — и слово то же, что в островке.
            Button(recorder.isRestored ? "Удалить" : "Отмена", action: cancel)
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.muted)
                .fixedSize()
                .accessibilityIdentifier("cancelRecordingButton")
        }
        .disabled(recorder.phase == .finishing)
        .accessibilityElement(children: .contain)
    }
}

/// Живая волна: столбик на каждый замер, новое справа.
///
/// Рисуется в `Canvas`, а не стопкой вью, по вполне практической причине:
/// `HStack` из полусотни столбиков требует свою ширину целиком и не сжимается —
/// панель распирало шире экрана, и весь список уезжал влево. Холст берёт ту
/// ширину, что дали, и сам решает, сколько отсчётов в неё поместится.
struct LiveWave: View {
    let levels: [Double]
    let paused: Bool

    private let step: CGFloat = 4.5
    private let barWidth: CGFloat = 2.5

    var body: some View {
        Canvas { context, size in
            let fits = max(1, Int(size.width / step))
            let recent = Array(levels.suffix(fits))
            let color = paused ? LoriPalette.line : LoriPalette.lime
            for (index, value) in recent.enumerated() {
                let height = 3 + 17 * min(1, max(0, value))
                // Волна набегает справа: свежий звук ближе к кнопке остановки.
                let x = size.width - CGFloat(recent.count - index) * step
                let bar = CGRect(
                    x: x,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(Path(roundedRect: bar, cornerRadius: barWidth / 2), with: .color(color))
            }
        }
        .frame(height: 20)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
