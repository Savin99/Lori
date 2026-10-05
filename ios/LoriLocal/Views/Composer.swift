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
    /// Подсказку убрали крестиком — до следующей смены содержимого буфера.
    @Published var clipboardDismissed = false
    private var lastSeenClipboard: ClipboardAudio.Content = .none

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
    var transcribe: () -> Void
}

/// Нижняя панель: записать голос или расшифровать принесённый файл.
///
/// В покое это одна строка: `+`, чип движка, чип режима и круглая кнопка
/// записи. Прикреплённый файл добавляет сверху карточку с оценкой времени, а
/// запись схлопывает панель в строку с таймером и волной. Капсула закреплена
/// у нижнего края и не переезжает: между состояниями меняется начинка, а не
/// сама панель, поэтому переход читается как перетекание, а не как подмена вью.
struct ComposerBar: View {
    @ObservedObject var model: ComposerModel
    @ObservedObject var recorder: AudioCaptureStore
    @ObservedObject var engines: EngineDirectory
    @ObservedObject var speed: TranscriptionSpeed

    let engine: EngineDescriptor
    let mode: TranscriptionMode?
    let status: String?
    let actions: ComposerActions

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
                if state == .attached {
                    attachedCard
                }
                controlRow
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
    }

    // MARK: - Прикреплённый файл

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

    // MARK: - Строка управления

    /// Строка, которая есть всегда: в покое она и есть вся панель, при
    /// прикреплённом файле стоит под его карточкой, во время записи
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
                plusMenu

                EngineChip(
                    engine: engine,
                    readiness: engines.readiness(of: engine.kind),
                    action: actions.chooseEngine
                )
                if let mode {
                    ModeChip(engine: engine, current: mode, select: actions.setMode)
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

    // Перечисления без `default`: новое состояние панели должно остановить
    // сборку здесь, а не молча достаться микрофону.
    private var roundSymbol: String {
        switch state {
        case .recording: "stop.fill"
        case .attached: "arrow.up"
        case .idle: "mic.fill"
        }
    }

    private var roundFill: Color {
        state == .recording ? LoriPalette.danger : LoriPalette.ink.opacity(0.9)
    }

    private var roundLabel: String {
        switch state {
        case .recording: "Остановить запись"
        case .attached: "Расшифровать"
        case .idle: "Записать"
        }
    }

    private var roundIdentifier: String {
        switch state {
        case .recording: "stopButton"
        case .attached: "transcribeButton"
        case .idle: "recordButton"
        }
    }

    private func roundAction() {
        switch state {
        case .recording: actions.stop()
        case .attached: actions.transcribe()
        case .idle: actions.record()
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
