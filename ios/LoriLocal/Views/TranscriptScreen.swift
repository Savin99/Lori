import SwiftUI
import UIKit

/// Экран записи: главное здесь — текст, а не плеер.
///
/// Раньше две трети экрана занимал проигрыватель, а расшифровка жила в маленькой
/// карточке. Теперь плеер — одна строка сверху, дальше текст с таймкодами: тап по
/// реплике перематывает звук туда, и это точнее любых «минус пятнадцать секунд».
struct TranscriptScreen: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var summaries: SummaryStore
    @EnvironmentObject private var summaryModels: SummaryModelStore
    @EnvironmentObject private var summaryRunner: SummaryRunner
    @EnvironmentObject private var assistant: AssistantThreadStore
    @EnvironmentObject private var speakers: SpeakerNames
    @EnvironmentObject private var speed: TranscriptionSpeed
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var playback = AudioPlaybackStore()

    let entry: WorkspaceEntry
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var topics: TopicStore
    @ObservedObject var previews: TranscriptPreviews
    /// Нельзя слушать и писать одновременно: аудиосессия одна.
    let isRecording: Bool
    /// Секунда из пилюли в ответе ассистента: запись открывается сразу на ней.
    var startAt: TimeInterval?

    @State private var document = TranscriptDocument.empty
    @State private var transcriptPath: String?
    @State private var showEditor = false
    @State private var showTopics = false
    @State private var showAsk = false
    @State private var share: SharePayload?
    @State private var copied = false
    @State private var error: String?
    /// Какого говорящего сейчас называют и как. Метка одна на всю запись,
    /// поэтому и переименование сразу по всей записи — иначе пришлось бы
    /// править каждую реплику.
    @State private var renamingSpeaker: String?
    @State private var speakerDraft = ""
    @State private var isLoadingDocument = false
    @State private var documentLoadID = UUID()

    private var path: String { entry.relativePath }
    private var isTranscribing: Bool { transcription.isRunning(path) }
    private var isQueued: Bool { transcription.isQueued(path) }

    private var title: String {
        if let title = previews.preview(for: path)?.title, !title.isEmpty { return title }
        return "Запись \(LoriFormat.stamp(entry.modifiedAt))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    player.padding(.top, 14)
                    if isTranscribing || isQueued { progress.padding(.top, 12) }
                    if let failure = transcription.error(for: path) { warning(failure).padding(.top, 12) }
                    if transcription.isInterrupted(path) {
                        warning(interruptedNote).padding(.top, 12)
                    }
                    ForEach(document.warnings, id: \.self) { warning($0).padding(.top, 10) }
                    if !document.isEmpty, !document.hasTimecodes { noTimecodes.padding(.top, 10) }
                    body(for: document).padding(.top, 18)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .background(LoriPalette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // «Готово» в углу не говорило, куда возвращает. Теперь видно.
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Label("Расшифровки", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { copy() } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(document.isEmpty)
                    .accessibilityLabel("Скопировать")

                    // Формат выбирается тут же, а не в настройках: PDF нужен,
                    // когда расшифровку отправляют человеку, Markdown — когда
                    // её несут в свой редактор, и это решение каждого раза.
                    Menu {
                        ForEach(TranscriptExportFormat.allCases) { format in
                            Button { export(format) } label: {
                                Text(format.title)
                                Text(format.note)
                                Image(systemName: format.icon)
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(document.isEmpty)
                    .accessibilityLabel("Поделиться")
                    .accessibilityHint("Выбор формата: PDF или Markdown")
                    .accessibilityIdentifier("shareMenu")

                    // Пункты разложены по смыслу: спросить и назвать, править,
                    // отдать наружу, удалить. Единым списком из шести штук
                    // «Удалить» стояло вплотную к «Отправить в Obsidian».
                    Menu {
                        Section {
                            Button("Спросить по этой записи", systemImage: "sparkles") { showAsk = true }
                                .disabled(document.isEmpty)
                            Button("Придумать заголовок", systemImage: "text.quote") { makeTitle() }
                                .disabled(document.isEmpty || summaryRunner.running != nil)
                        }
                        Section {
                            Button("Править текст", systemImage: "pencil") { showEditor = true }
                                .disabled(transcriptPath == nil)
                            Button("Тема", systemImage: "tag") { showTopics = true }
                        }
                        Section {
                            Button("Отправить в Obsidian", systemImage: "book.closed") { sendToObsidian() }
                                .disabled(document.isEmpty)
                            Menu("Расшифровать заново", systemImage: "arrow.triangle.2.circlepath") {
                                ForEach(TranscriptionEngineKind.allCases) { kind in
                                    // Иконка кодирует не бренд, а главное: уйдёт ли
                                    // запись с телефона. Выбор здесь делается в один
                                    // тап, и цена ошибки — отправленный наружу звук.
                                    Button(
                                        kind.title,
                                        systemImage: kind.leavesDevice ? "cloud" : "iphone"
                                    ) { run(kind) }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Ещё")
                    .accessibilityHint("Спросить, править, поделиться, удалить")
                    .accessibilityIdentifier("transcriptMenu")
                }
            }
            .sheet(isPresented: $showEditor, onDismiss: reload) {
                if let transcriptPath {
                    TranscriptEditorSheet(path: transcriptPath, title: title)
                }
            }
            .sheet(isPresented: $showTopics) {
                TopicSheet(
                    topics: topics,
                    title: title,
                    path: path,
                    suggestion: topics.suggestion(for: document.plain)
                )
            }
            .sheet(isPresented: $showAsk) {
                // Охват один — переключателя на экране не будет.
                AssistantThreadScreen(
                    store: assistant,
                    scopes: [AskScope(id: path, title: title, entries: [entry])],
                    initialScopeID: path,
                    title: { _ in summaries.title(for: path) ?? title },
                    detail: { _ in summaries.detail(for: path) },
                    topic: { _ in topics.topic(for: path) },
                    onOpen: { citation in
                        guard let start = citation.start else { return }
                        playback.seek(to: start)
                        if !playback.isPlaying { playback.play() }
                    }
                )
            }
            .sheet(item: $share) { payload in
                ShareSheet(payload: payload)
            }
            .alert("Кто говорит", isPresented: Binding(
                get: { renamingSpeaker != nil },
                set: { if !$0 { renamingSpeaker = nil } }
            )) {
                TextField("Имя", text: $speakerDraft)
                Button("Отмена", role: .cancel) { renamingSpeaker = nil }
                Button("Готово") {
                    if let label = renamingSpeaker {
                        speakers.rename(label, to: speakerDraft, in: path)
                    }
                    renamingSpeaker = nil
                }
            } message: {
                Text("Имя подставится во все реплики этого говорящего.")
            }
            .alert("Lori", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
        .onChange(of: summaryRunner.failure) { _, failure in
            if let failure { error = failure }
        }
        .recordingBanner { dismiss() }
        .task {
            if let url = try? workspace.fileURL(for: path) { playback.load(url) }
            reload()
            // Пришли по пилюле из ответа ассистента — открываемся сразу на той
            // секунде, о которой шла речь, а не в начале записи.
            if let startAt {
                playback.seek(to: startAt)
                playback.play()
            }
        }
        // Текст появляется по мере готовности: части уже расшифрованы, ждать нечего.
        .onChange(of: transcription.running) { _, _ in reload() }
        .onDisappear { playback.stop() }
    }

    // MARK: - Шапка

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summaries.title(for: path) ?? title)
                .font(LoriFont.displaySmall)
                .foregroundStyle(LoriPalette.ink)
                .lineLimit(3)

            HStack(spacing: 8) {
                Text(summaryRunner.running == path ? "Придумываю заголовок…" : meta)
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.muted)
                    .accessibilityIdentifier("recordingMeta")

                Button { showTopics = true } label: {
                    HStack(spacing: 4) {
                        if topics.topic(for: path) == nil {
                            Image(systemName: "plus")
                                .font(LoriFont.tiny.weight(.bold))
                        }
                        Text(topics.topic(for: path) ?? "Тема")
                            .font(LoriFont.small)
                    }
                    .foregroundStyle(topics.topic(for: path) == nil ? LoriPalette.muted : LoriPalette.lime)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        (topics.topic(for: path) == nil ? LoriPalette.card : LoriPalette.limeSoft.opacity(0.6)),
                        in: Capsule()
                    )
                    .overlay(Capsule().stroke(LoriPalette.line, lineWidth: topics.topic(for: path) == nil ? 1 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("topicChip")

                Spacer(minLength: 0)
            }

            // Чем расшифровано — своей строкой, а не в ряду с датой и темой.
            //
            // Сначала это стояло там, и ряд переполнился: дата переехала на две
            // строки, а имя движка ушло в многоточие. Та же ловушка, что и с чипами
            // панели: три элемента и распорка не делят одну ширину по-хорошему.
            //
            // На карточке в списке движка нет намеренно — там это настройка, а не
            // свойство записи. Здесь наоборот: расшифровку можно перезапустить другим
            // движком, и какой отработал — свойство именно этого текста.
            if let name = document.processingLabel {
                HStack(spacing: 4) {
                    if let onDevice = document.engineStayedOnDevice {
                        // Иконка кодирует не бренд, а главное: уходила ли запись с телефона.
                        Image(systemName: onDevice ? "iphone" : "cloud")
                            .font(LoriFont.tiny)
                    }
                    Text(name)
                        .font(LoriFont.small)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .foregroundStyle(LoriPalette.muted)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Расшифровано движком \(name)")
                .accessibilityIdentifier("transcriptEngine")
            }
        }
    }

    private var meta: String {
        let stamp = LoriFormat.stamp(entry.modifiedAt)
        guard playback.duration > 0 else { return stamp }
        return "\(stamp) · \(LoriFormat.duration(playback.duration))"
    }

    // MARK: - Плеер одной строкой

    private var player: some View {
        HStack(spacing: 12) {
            Button(action: playback.toggle) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(LoriFont.meta.weight(.bold))
                    .foregroundStyle(LoriPalette.ink)
                    .frame(width: 38, height: 38)
                    .background(LoriPalette.card, in: Circle())
                    .overlay(Circle().stroke(LoriPalette.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isRecording || playback.duration == 0)
            .accessibilityLabel(playback.isPlaying ? "Пауза" : "Слушать")

            Slider(
                value: Binding(get: { playback.position }, set: { playback.scrub(to: $0) }),
                in: 0...max(playback.duration, 0.01),
                onEditingChanged: { editing in
                    if editing { playback.beginScrub() } else { playback.endScrub() }
                }
            )
            .tint(LoriPalette.lime)
            .accessibilityLabel("Позиция в записи")
            .accessibilityValue(LoriFormat.duration(playback.position))
            .disabled(playback.duration == 0)

            // Минус не украшение: рядом в шапке стоит полная длительность, набранная
            // тем же кеглем и теми же цифрами, и владелец прочитал «41:09» и «38:34»
            // на одном экране как расхождение длительностей. Это остаток.
            Text("−" + LoriFormat.duration(playback.remaining))
                .font(LoriFont.small.monospacedDigit())
                .foregroundStyle(LoriPalette.muted)
                .accessibilityLabel("Осталось \(LoriFormat.duration(playback.remaining))")

            // Скорость важнее перемотки: расшифровку слушают на 1.5–2×.
            Button {
                playback.rate = playback.rate >= 2 ? 1 : (playback.rate == 1 ? 1.5 : 2)
            } label: {
                Text(playback.rate == 1 ? "1×" : (playback.rate == 1.5 ? "1,5×" : "2×"))
                    .font(LoriFont.small.monospacedDigit())
                    .foregroundStyle(LoriPalette.ink)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(LoriPalette.card, in: Capsule())
                    .overlay(Capsule().stroke(LoriPalette.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Скорость воспроизведения")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(LoriPalette.line, lineWidth: 1))
    }

    /// Прогресс — тонкая полоса с оценкой и отменой, а не карточка на пол-экрана.
    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(progressText)
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.info)
                if let left = transcription.remainingTime(for: path) {
                    Text("осталось ~\(LoriFormat.approximate(left))")
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.muted)
                        .accessibilityIdentifier("remainingTime")
                }
                Spacer(minLength: 8)
                Button("Отменить") { transcription.cancel(path) }
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
            }
            if let fraction = transcription.progressFraction(for: path) {
                ProgressView(value: fraction)
                    .tint(LoriPalette.info)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LoriPalette.info.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var progressText: String {
        if isQueued {
            return transcription.waitingForMemory.contains(path)
                ? "Жду, пока освободится память"
                : "В очереди"
        }
        guard let note = transcription.progressText(for: path) else { return "Расшифровываю" }
        return "Расшифровываю · \(note)"
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(LoriFont.small.weight(.semibold))
            Text(text)
                .font(LoriFont.small)
            Spacer(minLength: 0)
        }
        .foregroundStyle(LoriPalette.warn)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LoriPalette.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Текст

    private func row(_ line: TranscriptDocument.Line, start: TimeInterval?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let start {
                Text((line.isApproximate ? "≈" : "") + TranscriptSegment.stamp(start))
                    .font(LoriFont.small.monospacedDigit())
                    .foregroundStyle(LoriPalette.muted)
                    .frame(width: 44, alignment: .leading)
            } else if document.hasTimecodes {
                // Продолжение реплики: колонка времени пустая, но она есть.
                // Без неё абзацы одной реплики разъезжаются по левому краю, и
                // читается это как разные реплики.
                Color.clear.frame(width: 44, height: 0)
            }
            if let speaker = line.speaker { speakerDot(speaker) }
            Text(line.text)
                .font(LoriFont.body)
                .foregroundStyle(LoriPalette.ink)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Долгое нажатие живёт рядом с тапом по строке, а не вместо него:
    /// `simultaneousGesture` не перехватывает перемотку, ради которой строка
    /// и кликабельна.
    private func speakerDot(_ label: String) -> some View {
        SpeakerDot(
            label: label,
            name: speakers.isNamed(label, in: path) ? speakers.name(of: label, in: path) : nil
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                speakerDraft = speakers.isNamed(label, in: path) ? speakers.name(of: label, in: path) : ""
                renamingSpeaker = label
            }
        )
        .accessibilityIdentifier("speakerDot")
    }

    /// Что сказать про оборванную расшифровку.
    ///
    /// **Правда тут разная у разных движков, и одной фразой не обойтись.**
    /// Локальная расшифровка и правда начнётся заново на следующем запуске.
    /// Облачная — нет, и это не недоделка: автоматический перезапуск отправил бы
    /// звук третьей стороне и потратил деньги без единого нажатия, поэтому
    /// `TranscriptionService.resumeInterrupted` её пропускает намеренно.
    ///
    /// Раньше здесь стояло «и она начнётся заново» для всех. Для облачной записи
    /// это было прямое враньё: человек ждал перезапуска, которого не будет, а
    /// кнопка «Расшифровать» стояла тут же и выглядела ненужной.
    private var interruptedNote: String {
        let cause = "Расшифровку оборвала система. Такое бывает, когда телефону не хватило памяти или приложение закрыли из переключателя задач."
        guard transcription.interruptedEngine(for: path)?.leavesDevice == true else {
            return cause + " Она начнётся заново сама."
        }
        return cause + " Сама она не начнётся: запись ушла бы в облако и стоила бы денег без вашего нажатия. Нажмите «Расшифровать» — готовые части сохранены, спросим только остаток."
    }

    /// Почему у расшифровки нет таймкодов. Молчать нельзя: перемотка тапом —
    /// главное, ради чего экран так устроен, и её пропажу человек примет за
    /// поломку, а не за следствие выбранного режима.
    @ViewBuilder
    private var noTimecodes: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock.badge.xmark")
                .font(LoriFont.small.weight(.semibold))
            Text(noTimecodesReason)
                .font(LoriFont.small)
            Spacer(minLength: 0)
        }
        .foregroundStyle(LoriPalette.warn)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LoriPalette.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("noTimecodes")
    }

    private var noTimecodesReason: String {
        let engine = TranscriptionSettings.engine
        if engine == .gemini, TranscriptionSettings.geminiMode == .smart {
            return "Режим «Причёсанный текст» не даёт таймкодов — перемотка по тапу не работает."
        }
        if !TranscriptionSettings.timecodes {
            return "Таймкоды реплик выключены в настройках — перемотка по тапу не работает."
        }
        return "Этот движок не дал таймкодов — перемотка по тапу не работает."
    }

    @ViewBuilder
    private func body(for document: TranscriptDocument) -> some View {
        // Пока файла с расшифровкой нет, но части уже готовы — показываем их.
        if document.isEmpty, let ready = transcription.partialTranscript(for: path), !ready.segments.isEmpty {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(ready.segments.enumerated()), id: \.offset) { _, segment in
                    Button {
                        playback.seek(to: segment.start)
                        if !playback.isPlaying { playback.play() }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(LoriFormat.duration(segment.start))
                                .font(LoriFont.small.monospacedDigit())
                                .foregroundStyle(LoriPalette.muted)
                                .frame(width: 46, alignment: .leading)
                            let mark = TranscriptDocument.speakerMark(in: segment.text)
                            if let mark { speakerDot(mark.label) }
                            Text(mark?.rest ?? segment.text)
                                .font(LoriFont.body)
                                .foregroundStyle(LoriPalette.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Skeleton()
                    .accessibilityLabel("Дальше ещё считается")
                    .accessibilityIdentifier("transcriptSkeleton")
            }
            .accessibilityIdentifier("partialTranscript")
        } else if document.isEmpty, isLoadingDocument {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Открываю расшифровку…")
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.muted)
            }
            .accessibilityIdentifier("transcriptLoading")
        } else if document.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(isTranscribing || isQueued
                     ? "Текст появится здесь по мере готовности."
                     : "Расшифровки пока нет.")
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.muted)
                if !isTranscribing, !isQueued {
                    Button { run(nil) } label: {
                        Text("Расшифровать")
                            .font(LoriFont.control)
                            .foregroundStyle(LoriPalette.onInk)
                            .padding(.horizontal, 20)
                            .frame(height: 46)
                            .background(LoriPalette.lime, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("transcribeAction")

                    Text(speed.summary(
                        audio: playback.duration,
                        engine: EngineCatalog.descriptor(for: TranscriptionSettings.engine),
                        mode: TranscriptionSettings.mode(for: TranscriptionSettings.engine)
                    ))
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
                    .accessibilityIdentifier("transcribeEstimate")
                }
            }
        } else {
            // Часовая запись даёт сотни реплик. Обычный VStack создавал их
            // все до первого кадра; ленивый строит только видимую часть.
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(document.lines) { line in
                    if let start = line.start {
                        Button {
                            playback.seek(to: start)
                            if !playback.isPlaying { playback.play() }
                        } label: {
                            row(line, start: start)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Слушать с \(TranscriptSegment.stamp(start))")
                    } else {
                        // Без таймкода перематывать некуда, и кнопки тут нет.
                        // Обёрнутый в `disabled` текст система красит серым —
                        // абзац выглядел выключенным, хотя это обычный текст
                        // расшифровки, который читают.
                        row(line, start: nil)
                    }
                }

                // Скелетон намекает, что продолжение придёт.
                if isTranscribing {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 6)
                                .fill(LoriPalette.line.opacity(0.5))
                                .frame(height: 14)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Действия

    private func reload() {
        transcriptPath = workspace.existingTranscript(for: entry)
        previews.invalidate(path)
        previews.load(entry, in: workspace)
        documentLoadID = UUID()
        let loadID = documentLoadID
        guard let transcriptPath,
              let url = try? workspace.readableTextURL(at: transcriptPath) else {
            isLoadingDocument = false
            document = .empty
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
            isLoadingDocument = false
        }
    }

    private func run(_ kind: TranscriptionEngineKind?) {
        transcription.enqueue(entry, in: workspace, using: kind)
    }

    /// Заголовок и описание по требованию: для записей, расшифрованных до того,
    /// как веса скачали, ждать нового прогона незачем.
    private func makeTitle() {
        summaryRunner.failure = nil
        if let obstacle = summaryRunner.obstacle() {
            error = obstacle.message
            return
        }
        guard summaries.allowGeneratedTitle(for: path) else {
            error = "Не удалось сохранить настройку заголовка. Попробуйте ещё раз."
            return
        }
        summaryRunner.summarize(
            path: path,
            text: TranscriptTitle.plain(from: document.plainText),
            force: true
        )
    }

    /// Текст для копирования, шаринга и Obsidian: с именами вместо меток.
    private var outgoingText: String {
        speakers.applied(to: document.plain, in: path)
    }

    private func copy() {
        UIPasteboard.general.string = outgoingText
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    /// Расшифровка уходит наружу файлом: в нём есть и шапка, и таймкоды, и имена
    /// говорящих — всё, что видно на экране.
    private func export(_ format: TranscriptExportFormat) {
        let payload = TranscriptExport.make(
            document: document,
            title: title,
            recordedAt: entry.modifiedAt,
            duration: playback.duration,
            detail: summaries.detail(for: path),
            topic: topics.topic(for: path),
            names: speakers.names[path] ?? [:]
        )
        Task {
            do {
                share = SharePayload(url: try await payload.file(as: format), subject: payload.title)
            } catch {
                self.error = "Не удалось собрать файл: \(error.localizedDescription)"
            }
        }
    }

    private func sendToObsidian() {
        guard let url = ObsidianExport.url(title: title, text: outgoingText) else {
            error = "Укажи название хранилища Obsidian: Настройки → Хранилище."
            return
        }
        openURL(url)
    }
}

/// Цветной кружок говорящего: реплики разных людей различаются с одного
/// взгляда, а не чтением меток в тексте. Цвет стабилен для номера — «S1»
/// всегда одного цвета в пределах приложения.
struct SpeakerDot: View {
    let label: String
    /// Имя, если человек его дал. Цвет всё равно считается по метке: он должен
    /// остаться прежним и после переименования.
    var name: String?

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
            .padding(.horizontal, name == nil ? 0 : 8)
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
