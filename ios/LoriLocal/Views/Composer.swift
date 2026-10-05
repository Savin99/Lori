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

/// Охват вопроса: весь архив или одна тема.
struct ComposerScope: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
}

/// Что сейчас делает панель. Состояний пять, и они взаимоисключающие —
/// перечисление вместо набора флагов не даёт собрать «запись при прикреплённом
/// файле» и прочие несуществующие сочетания.
enum ComposerState: Equatable {
    case idle
    case typing
    case recording
    case attached
}

/// Состояние нижней панели. Живёт в модели, а не в `@State` экрана: панель
/// переживает открытие листов, а прикреплённый файл — переход в тред.
@MainActor
final class ComposerModel: ObservableObject {
    @Published var question = ""
    @Published var attached: [AttachedFile] = []
    @Published var clipboard: ClipboardAudio.Content = .none
    @Published var scopeID = "all"
    /// Подсказку убрали крестиком — до следующей смены содержимого буфера.
    @Published var clipboardDismissed = false
    private var lastSeenClipboard: ClipboardAudio.Content = .none

    func state(recording: Bool) -> ComposerState {
        if recording { return .recording }
        if !attached.isEmpty { return .attached }
        if !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .typing }
        return .idle
    }

    /// Показывать ли подсказку про буфер. Она живёт **над** капсулой отдельной
    /// строкой и ничего собой не закрывает: скопированное аудио может лежать в
    /// буфере часами, и всё это время поле вопроса обязано оставаться на месте.
    /// Раньше подсказка замещала поле — и спросить ассистента было нечем.
    var showsClipboardHint: Bool {
        clipboard == .audio && !clipboardDismissed && attached.isEmpty
    }

    /// Типы буфера читаются без содержимого, поэтому вызывать можно свободно.
    func refreshClipboard() {
        let found = ClipboardAudio.content()
        // Скопировали что-то новое — подсказка возвращается: отказ от прошлой
        // не должен молча распространяться на следующую запись.
        if found != lastSeenClipboard {
            lastSeenClipboard = found
            clipboardDismissed = false
        }
        clipboard = found
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
        question = ""
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
struct ComposerActions {
    var record: () -> Void
    var stop: () -> Void
    var togglePause: () -> Void
    var cancelRecording: () -> Void
    var pickFile: () -> Void
    var paste: () -> Void
    var openSettings: () -> Void
    var chooseEngine: () -> Void
    var setMode: (TranscriptionMode) -> Void
    var ask: () -> Void
    var transcribe: () -> Void
}

/// Нижняя панель: поле сверху, чипы снизу.
///
/// Одна капсула обслуживает три сценария — записать голос, прикрепить файл,
/// спросить ассистента. Она закреплена у нижнего края и не переезжает: между
/// состояниями меняется начинка, а не сама панель, поэтому переход читается
/// как перетекание, а не как подмена вью.
struct ComposerBar: View {
    @ObservedObject var model: ComposerModel
    @ObservedObject var recorder: AudioCaptureStore
    @ObservedObject var engines: EngineDirectory
    @ObservedObject var speed: TranscriptionSpeed

    let engine: EngineDescriptor
    let mode: TranscriptionMode?
    let scopes: [ComposerScope]
    /// «Спрошу по 5 расшифровкам · 92 тыс. знаков» — считает экран, у него
    /// под рукой рабочая папка и кэш расшифровок.
    let contextSummary: String?
    let status: String?
    let actions: ComposerActions

    @AppStorage(AssistantSettings.modelKey) private var assistantModel = ""
    @FocusState private var focused: Bool

    private var state: ComposerState { model.state(recording: recorder.isCapturing) }

    var body: some View {
        VStack(spacing: 8) {
            if let status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(status)
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.muted)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }

            if model.showsClipboardHint, state != .recording {
                clipboardRow
            }

            VStack(alignment: .leading, spacing: 8) {
                if state != .recording {
                    firstRow
                }
                secondRow
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            // Скругление непрерывное и фиксированное: `Capsule` на двух строках
            // превращает панель в стадион, а радиус перестаёт держать форму.
            .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(LoriPalette.line, lineWidth: 1)
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(LoriPalette.canvas.opacity(0.94))
        .animation(.easeOut(duration: 0.2), value: state)
        .onChange(of: recorder.isCapturing) { _, capturing in
            if capturing { focused = false }
        }
    }

    // MARK: - Первая строка

    @ViewBuilder
    private var firstRow: some View {
        switch state {
        case .attached:
            attachedCard
        default:
            VStack(alignment: .leading, spacing: 6) {
                TextField("Спросить записи…", text: $model.question, axis: .vertical)
                    .accessibilityIdentifier("questionField")
                    .focused($focused)
                    .font(LoriFont.body)
                    .foregroundStyle(LoriPalette.ink)
                    .lineLimit(1...5)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)

                if state == .typing, let contextSummary {
                    Text(contextSummary)
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.muted)
                        .padding(.horizontal, 10)
                        .accessibilityIdentifier("contextSummary")
                }
            }
        }
    }

    private var attachedCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.attached.count > 1 ? "square.on.square" : "waveform.circle")
                .font(LoriFont.control)
                .foregroundStyle(LoriPalette.lime)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachedTitle)
                    .font(LoriFont.cardTitle)
                    .foregroundStyle(LoriPalette.ink)
                    .lineLimit(1)
                Text(attachedDetail)
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                model.clear()
            } label: {
                Image(systemName: "xmark")
                    .font(LoriFont.small.weight(.semibold))
                    .foregroundStyle(LoriPalette.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Убрать файл")
            .accessibilityIdentifier("detachButton")
        }
        .padding(.leading, 8)
        .accessibilityIdentifier("attachedFile")
    }

    private var attachedTitle: String {
        guard let first = model.attached.first else { return "" }
        guard model.attached.count > 1 else { return first.name }
        return LoriFormat.plural(model.attached.count, one: "файл", few: "файла", many: "файлов")
    }

    /// Пересчитывается при смене чипа движка: «в облако · примерно 3 минуты»
    /// против «на телефоне · примерно 12 минут» — это и есть цена выбора.
    private var attachedDetail: String {
        let seconds = model.attachedDuration
        let place = speed.summary(audio: seconds, engine: engine, mode: mode)
        guard seconds > 0 else { return place }
        return "\(LoriFormat.duration(seconds)) · \(place)"
    }

    private var clipboardRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(LoriFont.small)
                .foregroundStyle(LoriPalette.muted)
            Text("В буфере есть аудио")
                .font(LoriFont.small)
                .foregroundStyle(LoriPalette.muted)
            Spacer(minLength: 4)
            Button("Вставить", action: actions.paste)
                .font(LoriFont.small.weight(.semibold))
                .foregroundStyle(LoriPalette.lime)
                .accessibilityIdentifier("pasteAudioButton")
            Button {
                model.clipboardDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(LoriFont.tiny.weight(.semibold))
                    .foregroundStyle(LoriPalette.muted)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Скрыть подсказку про буфер")
        }
        .accessibilityIdentifier("clipboardHint")
    }

    // MARK: - Вторая строка

    @ViewBuilder
    private var secondRow: some View {
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
                plusMenu

                if state == .typing {
                    assistantModelChip
                    scopeChip
                } else {
                    EngineChip(
                        engine: engine,
                        readiness: engines.readiness(of: engine.kind),
                        action: actions.chooseEngine
                    )
                    if let mode {
                        ModeChip(engine: engine, current: mode, select: actions.setMode)
                    }
                }

                Spacer(minLength: 0)
                roundButton
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
                Label("Вставить аудио", systemImage: "doc.on.clipboard")
            }
            .disabled(model.clipboard == .none)

            Divider()

            Button {
                actions.openSettings()
            } label: {
                Label("Настройки", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "plus")
                .font(LoriFont.control)
                .foregroundStyle(LoriPalette.ink)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Добавить запись")
        .accessibilityIdentifier("importButton")
    }

    private var assistantModelChip: some View {
        Menu {
            ForEach(assistantChoices, id: \.self) { name in
                Button {
                    assistantModel = name
                } label: {
                    if name == currentAssistantModel {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            chipLabel(icon: "cloud", text: currentAssistantModel)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("assistantModelChip")
        .accessibilityLabel("Модель ассистента: \(currentAssistantModel)")
    }

    private var currentAssistantModel: String {
        assistantModel.isEmpty ? AssistantSettings.model : assistantModel
    }

    /// Две-три модели, не список «ещё моделей»: выбор здесь — это выбор цены
    /// и скорости, а не каталог сервиса. Полный список живёт в настройках.
    private var assistantChoices: [String] {
        var names = [currentAssistantModel]
        for suggestion in ModelCatalog.chatSuggestions.map(\.id) where !names.contains(suggestion) {
            names.append(suggestion)
            if names.count == 3 { break }
        }
        return names
    }

    private var scopeChip: some View {
        Menu {
            ForEach(scopes) { scope in
                Button {
                    model.scopeID = scope.id
                } label: {
                    if scope.id == currentScope?.id {
                        Label(scope.title, systemImage: "checkmark")
                    } else {
                        Text(scope.title)
                    }
                }
            }
        } label: {
            chipLabel(icon: "doc.text", text: scopeTitle)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("scopeChip")
        .accessibilityLabel("Охват вопроса: \(scopeTitle)")
    }

    private var currentScope: ComposerScope? {
        scopes.first { $0.id == model.scopeID } ?? scopes.first
    }

    /// Весь архив показывается числом записей, тема — своим названием:
    /// «5 записей» отвечает на вопрос «сколько», «Работа» — на вопрос «что».
    private var scopeTitle: String {
        guard let scope = currentScope else { return "Нет записей" }
        guard scope.id == "all" else { return scope.title }
        return LoriFormat.plural(scope.count, one: "запись", few: "записи", many: "записей")
    }

    /// Чип рисуется на 32pt, а нажимается на 44pt — как круглые кнопки рядом.
    /// Крупная пилюля перетягивала на себя внимание с текста вопроса, ради
    /// которого панель и существует.
    private func chipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(LoriFont.tiny)
            Text(text)
                .font(LoriFont.small)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(LoriFont.tiny.weight(.semibold))
                .opacity(0.45)
        }
        .foregroundStyle(LoriPalette.ink)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(LoriPalette.bubble, in: Capsule())
        .frame(height: 44)
        .contentShape(Capsule())
    }

    // MARK: - Круглая кнопка справа

    /// Одна кнопка на все состояния: микрофон, стрелка, стоп. Именно поэтому
    /// смена состояния выглядит как превращение, а не как исчезновение одной
    /// кнопки и появление другой на её месте.
    private var roundButton: some View {
        Button(action: roundAction) {
            Image(systemName: roundSymbol)
                .font(LoriFont.control)
                .foregroundStyle(LoriPalette.onInk)
                .frame(width: 36, height: 36)
                .background(roundFill, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .contentTransition(.symbolEffect(.replace))
        .accessibilityLabel(roundLabel)
        .accessibilityIdentifier(roundIdentifier)
    }

    private var roundSymbol: String {
        switch state {
        case .recording: "stop.fill"
        case .typing: "arrow.up"
        case .attached: "arrow.up"
        default: "mic.fill"
        }
    }

    private var roundFill: Color {
        state == .recording ? LoriPalette.danger : LoriPalette.ink.opacity(0.9)
    }

    private var roundLabel: String {
        switch state {
        case .recording: "Остановить запись"
        case .typing: "Спросить"
        case .attached: "Расшифровать"
        default: "Записать"
        }
    }

    private var roundIdentifier: String {
        switch state {
        case .recording: "stopButton"
        case .typing: "sendButton"
        case .attached: "transcribeButton"
        default: "recordButton"
        }
    }

    private func roundAction() {
        switch state {
        case .recording: actions.stop()
        case .typing: actions.ask()
        case .attached: actions.transcribe()
        default: actions.record()
        }
    }
}

/// Строка записи: пауза, таймер, живая волна, отмена.
struct RecordingRow: View {
    @ObservedObject var recorder: AudioCaptureStore
    let togglePause: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: togglePause) {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(LoriFont.small.weight(.bold))
                    .foregroundStyle(LoriPalette.ink)
                    .frame(width: 34, height: 34)
                    .background(LoriPalette.canvas, in: Circle())
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

            LiveWave(levels: recorder.levels, paused: recorder.isPaused)

            Button("Отмена", action: cancel)
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.muted)
                .fixedSize()
                .accessibilityIdentifier("cancelRecordingButton")
        }
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

/// Композер треда: та же капсула, что на главном, но без микрофона —
/// в разговоре с ассистентом записывать нечего.
///
/// Кнопка отправки без ключа не «серая и молчит»: на её месте прямо написано,
/// чего не хватает. Мелкая строка выше кнопки этот вопрос не закрывала —
/// человек жал на неактивную кнопку и не понимал, почему ничего не происходит.
struct ThreadComposer: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool

    let model: String
    let models: [String]
    let hasKey: Bool
    let busy: Bool
    let selectModel: (String) -> Void
    let openSettings: () -> Void
    let send: () -> Void

    private var ready: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Спросить…", text: $text, axis: .vertical)
                .accessibilityIdentifier("threadField")
                .focused($focused)
                .font(LoriFont.body)
                .foregroundStyle(LoriPalette.ink)
                .lineLimit(1...5)
                .padding(.horizontal, 10)
                .padding(.top, 6)

            HStack(spacing: 6) {
                modelChip
                Spacer(minLength: 0)
                if hasKey {
                    sendButton
                } else {
                    missingKey
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(LoriPalette.line, lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(LoriPalette.canvas.opacity(0.94))
    }

    /// Две-три модели, а не каталог сервиса: здесь выбирают цену и скорость,
    /// а полный список живёт в настройках.
    private var modelChip: some View {
        Menu {
            ForEach(models, id: \.self) { name in
                Button {
                    selectModel(name)
                } label: {
                    if name == model {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cloud")
                    .font(LoriFont.tiny)
                Text(model)
                    .font(LoriFont.small)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(LoriFont.tiny.weight(.semibold))
                    .opacity(0.45)
            }
            .foregroundStyle(LoriPalette.ink)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(LoriPalette.bubble, in: Capsule())
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .accessibilityIdentifier("threadModelChip")
        .accessibilityLabel("Модель ассистента: \(model)")
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(LoriFont.control)
                .foregroundStyle(LoriPalette.onInk)
                .frame(width: 36, height: 36)
                .background(LoriPalette.ink.opacity(ready ? 0.9 : 0.35), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!ready)
        .accessibilityLabel("Спросить")
        .accessibilityIdentifier("threadSendButton")
    }

    private var missingKey: some View {
        Button(action: openSettings) {
            Text("Добавьте ключ ассистента")
                .font(LoriFont.small.weight(.semibold))
                .foregroundStyle(LoriPalette.warn)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(LoriPalette.warn.opacity(0.14), in: Capsule())
                .frame(height: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("threadNeedsKey")
    }
}
