import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Палитра и шрифты внутренние, а не приватные: их использует и `RecordingPlayer.swift`.
enum LoriPalette {
    static let canvas = Color(red: 0.961, green: 0.957, blue: 0.914)
    static let card = Color.white.opacity(0.86)
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.11)
    static let muted = Color(red: 0.44, green: 0.44, blue: 0.41)
    static let line = Color.black.opacity(0.12)
    static let bubble = Color(red: 0.917, green: 0.914, blue: 0.878)
    static let lime = Color(red: 0.36, green: 0.47, blue: 0.0)
    static let limeSoft = Color(red: 0.89, green: 0.92, blue: 0.73)
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
    static let control = Font.system(.body, weight: .semibold)
}

struct ContentView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @StateObject private var assistant = AssistantStore()
    /// Рекордер один на приложение: раньше у главной и у чата были свои экземпляры,
    /// и переход между экранами глушил запись на полуслове.
    @StateObject private var recorder = AudioCaptureStore()
    @StateObject private var transcription = TranscriptionService()
    @State private var screen: LoriScreen = .notes
    @State private var showSettings = false
    /// Путь и факт показа — одно значение. С `.sheet(isPresented:)` браузер
    /// открывался на корне: замыкание содержимого успевало захватить пустой путь.
    @State private var workspaceTarget: WorkspacePath?

    var body: some View {
        ZStack {
            LoriPalette.canvas.ignoresSafeArea()

            switch screen {
            case .notes:
                NotesHomeView(
                    recorder: recorder,
                    transcription: transcription,
                    openChat: { prompt in
                        if let prompt { assistant.queue(prompt) }
                        withAnimation(.easeOut(duration: 0.26)) { screen = .chat }
                    },
                    askAbout: askAbout,
                    openWorkspace: { path in workspaceTarget = WorkspacePath(path: path) },
                    openSettings: { showSettings = true }
                )
                .transition(.opacity)
            case .chat:
                AssistantChatView(
                    assistant: assistant,
                    recorder: recorder,
                    transcription: transcription,
                    close: { withAnimation(.easeOut(duration: 0.26)) { screen = .notes } },
                    openSettings: { showSettings = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Кремовая палитра задана явно и не имеет тёмного варианта: без этого
        // Form и List уезжали в системные цвета, а статусная строка становилась белой на кремовом.
        .preferredColorScheme(.light)
        .tint(LoriPalette.lime)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $workspaceTarget) { target in
            WorkspaceBrowserView(
                initialPath: target.path,
                transcription: transcription,
                recorder: recorder,
                askAbout: askAbout
            )
        }
        .alert("Lori", isPresented: Binding(
            get: { activeError != nil },
            set: { if !$0 { clearErrors() } }
        )) {
            Button("OK", role: .cancel) { clearErrors() }
        } message: {
            Text(activeError ?? "")
        }
        // Только снаружи всех `.sheet`: объект окружения достаётся лишь тому,
        // что лежит внутри обёртки. Модификатор выше по цепочке оставлял
        // браузер и настройки без рекордера, и плашка записи роняла приложение.
        .environmentObject(recorder)
    }

    /// SwiftUI показывает не больше одного алерта на View, поэтому ошибки
    /// файловой части и расшифровки идут через один и тот же.
    private var activeError: String? { workspace.lastError ?? transcription.lastError }

    private func clearErrors() {
        workspace.lastError = nil
        transcription.lastError = nil
    }

    /// «Спросить про заметку» и «Спросить про папку»: чат открывается с готовым вопросом
    /// в поле ввода — отправить его решает человек.
    private func askAbout(_ question: String) {
        assistant.prefill(question)
        workspaceTarget = nil
        withAnimation(.easeOut(duration: 0.26)) { screen = .chat }
    }
}

/// Открытая папка браузера. Обёртка нужна только чтобы лист шёл через `item`.
private struct WorkspacePath: Identifiable, Hashable {
    let path: String

    var id: String { path }
}

private enum LoriScreen {
    case notes
    case chat
}

private struct NoteGroup: Identifiable {
    let day: Date
    let title: String
    let notes: [WorkspaceEntry]

    var id: Date { day }
}

private struct NotesHomeView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @ObservedObject var recorder: AudioCaptureStore
    @ObservedObject var transcription: TranscriptionService
    let openChat: (String?) -> Void
    let askAbout: (String) -> Void
    let openWorkspace: (String) -> Void
    let openSettings: () -> Void
    @State private var draft = ""
    @State private var sheet: EntrySheet?
    @State private var renameTarget: WorkspaceEntry?
    @State private var deleteTarget: WorkspaceEntry?
    @State private var showAddMenu = false
    @State private var showFileImporter = false
    @State private var showFolderDrawer = false
    @StateObject private var search = NotesSearchStore()
    @State private var query = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    /// Служебные папки приложения уезжают в конец: они не то, что человек писал руками.
    private var folders: [WorkspaceEntry] {
        workspace.entries.filter(\.isDirectory).sorted { lhs, rhs in
            let lhsGenerated = WorkspaceStore.generatedFolders.contains(lhs.name)
            let rhsGenerated = WorkspaceStore.generatedFolders.contains(rhs.name)
            if lhsGenerated != rhsGenerated { return !lhsGenerated }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Заметки группируются по дню правки, поэтому заголовок «Сегодня» больше не выдумка.
    private var noteGroups: [NoteGroup] {
        let calendar = Calendar.current
        let notes = workspace.entries
            .filter { !$0.isDirectory }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        var order: [Date] = []
        var buckets: [Date: [WorkspaceEntry]] = [:]
        for note in notes {
            let day = calendar.startOfDay(for: note.modifiedAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(note)
        }
        return order.map { day in
            NoteGroup(day: day, title: LoriFormat.groupTitle(day), notes: buckets[day] ?? [])
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isSearching {
                    // Заголовок экрана в поиске только отнимает высоту: поле должно быть сверху.
                    NotesSearchBar(query: $query, focus: $searchFocused, cancel: closeSearch)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 4)
                } else {
                    HStack(spacing: 6) {
                        CircleIconButton(symbol: "folder", label: "Открыть папки") {
                            withAnimation(.easeOut(duration: 0.24)) { showFolderDrawer = true }
                        }
                        Spacer()
                        CircleIconButton(symbol: "magnifyingglass", label: "Поиск", action: openSearch)
                        CircleIconButton(symbol: "gearshape", label: "Настройки", action: openSettings)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Мои заметки")
                            .font(LoriFont.display)
                            .foregroundStyle(LoriPalette.ink)
                        Text(LoriFormat.noteCount(workspace.noteTotal))
                            .font(LoriFont.meta)
                            .foregroundStyle(LoriPalette.muted)
                    }
                    .padding(.horizontal, 17)
                    .padding(.top, 24)
                    .padding(.bottom, 22)
                }

                if isSearching {
                    searchResults
                } else if folders.isEmpty, noteGroups.isEmpty {
                    EmptyWorkspaceHint { sheet = .editor(.draft(directory: "")) }
                        .padding(.horizontal, 17)
                } else {
                    if !folders.isEmpty {
                        SectionLabel(title: "Папки")
                        VStack(spacing: 8) {
                            ForEach(folders) { folder in
                                Button { openWorkspace(folder.relativePath) } label: { FolderRow(entry: folder) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        EntryMenuButtons(
                                            rename: { renameTarget = folder },
                                            delete: { deleteTarget = folder }
                                        )
                                    }
                            }
                        }
                        .padding(.horizontal, 17)
                    }

                    ForEach(noteGroups) { group in
                        SectionLabel(title: group.title)
                        VStack(spacing: 8) {
                            ForEach(group.notes) { note in
                                Button { open(note) } label: {
                                    NoteCard(
                                        entry: note,
                                        isTranscribing: transcription.isRunning(note.relativePath),
                                        progressText: transcription.progressText(for: note.relativePath)
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    EntryMenuButtons(
                                        rename: { renameTarget = note },
                                        delete: { deleteTarget = note },
                                        transcribe: note.isAudio ? { transcribe(note) } : nil,
                                        openTranscript: transcriptPath(for: note).map { path in
                                            { openTranscript(path) }
                                        }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 17)
                    }
                }

                Color.clear.frame(height: 20)
            }
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSearching {
                // В поиске композер не нужен, а над клавиатурой он съедает половину результатов.
                Color.clear.frame(height: 0)
            } else {
                NotesComposer(
                    draft: $draft,
                    recorder: recorder,
                    transcriptionStatus: transcriptionStatus(transcription),
                    submit: {
                        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft = ""
                        openChat(prompt.isEmpty ? nil : prompt)
                    },
                    add: { showAddMenu = true },
                    togglePause: { recorder.isPaused ? recorder.resume() : recorder.pause() },
                    cancelRecording: { recorder.discard(in: workspace) }
                )
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
                .background(LoriPalette.canvas)
            }
        }
        .sheet(item: $sheet) { target in
            switch target {
            case let .editor(editor):
                NoteEditorSheet(target: editor, askAbout: askAbout)
            case let .recording(entry):
                RecordingSheet(
                    entry: entry,
                    transcription: transcription,
                    isRecording: recorder.isCapturing,
                    openTranscript: openTranscript
                )
            case .wiki:
                WikiSheet(openNote: openTranscript)
            }
        }
        .modifier(EntryMutationAlerts(
            renameTarget: $renameTarget,
            deleteTarget: $deleteTarget,
            didChange: { if isSearching { search.reindex(workspace) } }
        ))
        .onChange(of: query) { search.apply(query) }
        .confirmationDialog("Добавить в Lori", isPresented: $showAddMenu, titleVisibility: .visible) {
            // Запись — единственный вход к микрофону. Кнопки микрофона в композере нет:
            // она путала диктовку вопроса с записью материала.
            Button("Записать") { toggleRecording() }
            Button("Новая заметка") { sheet = .editor(.draft(directory: "")) }
            Button("Выбрать файл") { showFileImporter = true }
            Button("Отмена", role: .cancel) {}
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { throw WorkspaceError.importFailed }
                try workspace.importFile(from: url)
                openWorkspace("Inbox")
            } catch {
                workspace.lastError = error.localizedDescription
            }
        }
        .refreshable { workspace.start() }
        .overlay {
            if showFolderDrawer {
                FolderDrawer(
                    close: { withAnimation(.easeOut(duration: 0.22)) { showFolderDrawer = false } },
                    openFolder: { path in
                        withAnimation(.easeOut(duration: 0.22)) { showFolderDrawer = false }
                        openWorkspace(path)
                    },
                    openWiki: {
                        withAnimation(.easeOut(duration: 0.22)) { showFolderDrawer = false }
                        sheet = .wiki
                    }
                )
                .transition(.opacity)
            }
        }
    }

    /// Результаты поиска плоские: группировка по дням тут только мешает,
    /// важнее, что совпало и в какой папке лежит.
    @ViewBuilder
    private var searchResults: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Ищет по названиям и по тексту заметок, включая вложенные папки.")
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.muted)
                .padding(.horizontal, 20)
                .padding(.top, 26)
        } else if search.hits.isEmpty {
            Text("Ничего не найдено.")
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.muted)
                .padding(.horizontal, 20)
                .padding(.top, 26)
        } else {
            SectionLabel(title: "Найдено: \(search.hits.count)")
            VStack(spacing: 8) {
                ForEach(search.hits) { hit in
                    Button { openHit(hit) } label: { SearchResultRow(hit: hit) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            EntryMenuButtons(
                                rename: { renameTarget = hit.entry },
                                delete: { deleteTarget = hit.entry }
                            )
                        }
                }
            }
            .padding(.horizontal, 17)
        }
    }

    private func openSearch() {
        withAnimation(.easeOut(duration: 0.2)) { isSearching = true }
        search.reindex(workspace)
        searchFocused = true
    }

    private func closeSearch() {
        searchFocused = false
        query = ""
        search.clear()
        withAnimation(.easeOut(duration: 0.2)) { isSearching = false }
    }

    private func openHit(_ hit: SearchHit) {
        if hit.entry.isDirectory {
            openWorkspace(hit.entry.relativePath)
        } else {
            open(hit.entry)
        }
    }

    private func toggleRecording() {
        Task {
            do {
                if recorder.isCapturing {
                    guard let path = recorder.stop() else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    // Сначала сохранённый звук становится видимым, и только потом расшифровка:
                    // если движок недоступен, запись всё равно остаётся на месте.
                    try? workspace.refresh()
                    let recording = try workspace.entry(at: path)
                    transcribe(recording)
                } else {
                    try await recorder.start(in: workspace)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            } catch {
                workspace.lastError = error.localizedDescription
            }
        }
    }

    /// Аудио открывается плеером: раньше тап сразу запускал распознавание,
    /// и прослушать собственную запись было нечем.
    private func open(_ entry: WorkspaceEntry) {
        sheet = entry.isAudio ? .recording(entry) : .editor(.existing(entry))
    }

    private func transcriptPath(for entry: WorkspaceEntry) -> String? {
        guard entry.isAudio else { return nil }
        return workspace.existingTranscript(for: entry)
    }

    private func openTranscript(_ path: String) {
        guard let entry = try? workspace.entry(at: path) else { return }
        sheet = .editor(.existing(entry))
    }

    /// Открывается карточка записи, а не файл расшифровки: в карточке лежат оба вида
    /// текста и переключатель между ними, и там же видно ход работы. Обработку
    /// в «Важное» карточка запускает сама, если она включена в настройках.
    private func transcribe(_ entry: WorkspaceEntry) {
        sheet = .recording(entry)
        Task { await transcription.transcribe(entry, in: workspace) }
    }
}

private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(LoriFont.section)
            .foregroundStyle(LoriPalette.muted)
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 10)
    }
}

private struct EmptyWorkspaceHint: View {
    let createNote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Здесь пока пусто")
                .font(LoriFont.cardTitle)
                .foregroundStyle(LoriPalette.ink)
            Text("Заметки, записи и добавленные файлы хранятся только на этом iPhone.")
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: createNote) {
                Text("Создать первую заметку")
                    .font(LoriFont.control)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(LoriPalette.ink.opacity(0.84), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(LoriPalette.line, lineWidth: 1))
    }
}

private struct FolderRow: View {
    let entry: WorkspaceEntry

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "folder.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(LoriPalette.lime)
                .frame(width: 38, height: 38)
                .background(LoriPalette.limeSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
            Text(entry.displayName)
                .font(LoriFont.cardTitle)
                .foregroundStyle(LoriPalette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LoriPalette.muted.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(LoriPalette.line, lineWidth: 1))
    }
}

private struct NoteCard: View {
    let entry: WorkspaceEntry
    var isTranscribing = false
    var progressText: String?

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: entry.isAudio ? "waveform" : "doc.text")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(LoriPalette.lime)
                .frame(width: 42, height: 42)
                .background(LoriPalette.limeSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(LoriFont.cardTitle)
                    .foregroundStyle(LoriPalette.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.muted)
            }
            Spacer(minLength: 0)
            if isTranscribing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(minHeight: 70)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(LoriPalette.line, lineWidth: 1))
    }

    private var subtitle: String {
        if isTranscribing {
            guard let progressText else { return "Расшифровываю…" }
            return "Расшифровываю… \(progressText)"
        }
        let stamp = LoriFormat.stamp(entry.modifiedAt)
        return entry.isAudio ? "Запись · \(stamp)" : stamp
    }
}

private struct NotesComposer: View {
    @Binding var draft: String
    @ObservedObject var recorder: AudioCaptureStore
    let transcriptionStatus: String?
    let submit: () -> Void
    let add: () -> Void
    let togglePause: () -> Void
    let cancelRecording: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let transcriptionStatus {
                TranscriptionStatusLine(text: transcriptionStatus)
                    .padding(.horizontal, 8)
            }

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    if recorder.isCapturing {
                        RecordingPill(recorder: recorder, togglePause: togglePause, cancel: cancelRecording)
                    } else {
                        TextField("Спросить Lori", text: $draft)
                            .font(LoriFont.body)
                            .foregroundStyle(LoriPalette.ink)
                            .submitLabel(.send)
                            .onSubmit(submit)
                        Spacer(minLength: 0)
                    }

                }
                .padding(.leading, recorder.isCapturing ? 6 : 18)
                .padding(.trailing, 4)
                .frame(minHeight: 62)
                .background(.white.opacity(0.88), in: Capsule())

                if !recorder.isCapturing {
                    Button(action: add) {
                        Image(systemName: "plus")
                            .font(.system(size: 23, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(LoriPalette.ink.opacity(0.84), in: Circle())
                    }
                    .accessibilityLabel("Добавить заметку или файл")
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: recorder.isCapturing)
    }
}

/// Расшифровка идёт фоном и больше не подменяет поле ввода: раньше на время
/// распознавания нельзя было ни написать вопрос, ни отправить его.
private struct TranscriptionStatusLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(LoriFont.small)
                .foregroundStyle(LoriPalette.muted)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Одна строка на любое число параллельных расшифровок.
@MainActor
private func transcriptionStatus(_ transcription: TranscriptionService) -> String? {
    let running = transcription.running
    guard let single = running.first else { return nil }
    if running.count > 1 { return "Расшифровываю записи: \(running.count)" }
    guard let progress = transcription.progressText(for: single) else { return "Расшифровываю запись…" }
    return "Расшифровываю запись… \(progress)"
}

/// Пилюля записи: пауза, живой уровень, время и отмена.
/// Без неё кнопка микрофона была единственным признаком, что запись вообще идёт.
private struct RecordingPill: View {
    @ObservedObject var recorder: AudioCaptureStore
    let togglePause: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: togglePause) {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LoriPalette.ink)
                    .frame(width: 34, height: 34)
                    .background(LoriPalette.canvas, in: Circle())
            }
            .accessibilityLabel(recorder.isPaused ? "Продолжить запись" : "Поставить на паузу")

            Circle()
                .fill(recorder.isPaused ? LoriPalette.muted : Color.red)
                .frame(width: 8, height: 8)
                .opacity(recorder.isPaused ? 0.5 : 0.5 + 0.5 * min(1, max(0, recorder.level)))

            Text(LoriFormat.duration(recorder.elapsed))
                .font(LoriFont.meta.monospacedDigit())
                .foregroundStyle(LoriPalette.ink)

            LevelMeter(level: recorder.isPaused ? 0 : recorder.level)

            Spacer(minLength: 2)

            Button("Отмена", action: cancel)
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.muted)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct LevelMeter: View {
    let level: Double

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(level >= Double(index + 1) / 6 ? LoriPalette.lime : LoriPalette.line)
                    .frame(width: 3, height: 7 + CGFloat(index) * 3)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

/// Что открыто поверх чата. Лист ровно один, как и на других экранах.
private enum ChatSheet: Identifiable, Hashable {
    case history
    case entry(WorkspaceEntry)

    var id: String {
        switch self {
        case .history: "history"
        case let .entry(entry): "entry:\(entry.relativePath)"
        }
    }
}

private struct AssistantChatView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var digests: DigestService
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var recorder: AudioCaptureStore
    @ObservedObject var transcription: TranscriptionService
    @AppStorage("allowAssistantMutations") private var allowMutations = false
    @AppStorage("deepSeekModel") private var model = DeepSeekModel.fallback.rawValue
    @AppStorage(TranscriptionEngineChoice.storageKey) private var transcriptionEngine = TranscriptionEngineChoice.fallback.rawValue
    let close: () -> Void
    let openSettings: () -> Void

    @AppStorage("autoProcessTranscripts") private var autoProcess = true
    @State private var draft = ""
    @State private var sheet: ChatSheet?
    @State private var showFileImporter = false
    @FocusState private var composerFocused: Bool

    private var hasConversation: Bool { !assistant.bubbles.isEmpty }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if hasConversation {
                        ChatTranscript(
                            bubbles: assistant.bubbles,
                            isSending: assistant.isSending,
                            transcription: transcription,
                            openEntry: { sheet = .entry($0) }
                        )
                        .padding(.top, 14)
                    } else {
                        EmptyChatWelcome(openSettings: openSettings) { suggestion in
                            draft = suggestion
                            composerFocused = true
                        }
                        .padding(.top, 28)
                    }
                }
                .padding(.bottom, 76)
            }
            .scrollIndicators(.hidden)
            // Шапка приколочена сверху: внутри прокрутки она уезжала вместе с ответом,
            // и на длинном ответе текст лез под статусную строку, а закрыть чат было нечем.
            .safeAreaInset(edge: .top, spacing: 0) {
                ChatToolbar(close: close, newChat: assistant.clear, history: { sheet = .history })
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    .background(LoriPalette.canvas)
            }
            .onChange(of: assistant.bubbles.count) { scrollToBottom(proxy) }
            .onChange(of: assistant.isSending) { scrollToBottom(proxy) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChatComposer(
                draft: $draft,
                model: $model,
                recorder: recorder,
                transcriptionStatus: transcriptionStatus(transcription),
                isSending: assistant.isSending,
                focus: $composerFocused,
                chooseFile: { showFileImporter = true },
                primaryAction: send,
                togglePause: { recorder.isPaused ? recorder.resume() : recorder.pause() },
                cancelRecording: { recorder.discard(in: workspace) }
            )
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            .background(LoriPalette.canvas)
        }
        .sheet(item: $sheet) { target in
            switch target {
            case .history:
                ChatHistorySheet(
                    conversations: assistant.history,
                    select: { assistant.restore($0); sheet = nil },
                    close: { sheet = nil }
                )
                .presentationDetents([.fraction(0.76), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(44)
            case let .entry(entry):
                // Аудио открывается карточкой записи, всё остальное — редактором.
                if entry.isAudio {
                    RecordingSheet(
                        entry: entry,
                        transcription: transcription,
                        isRecording: recorder.isCapturing,
                        openTranscript: { path in
                            guard let file = try? workspace.entry(at: path) else { return }
                            sheet = .entry(file)
                        }
                    )
                } else {
                    NoteEditorSheet(target: .existing(entry), askAbout: { _ in sheet = nil })
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { throw WorkspaceError.importFailed }
                Task {
                    await ChatIngest.bring(
                        externalURL: url,
                        into: workspace,
                        assistant: assistant,
                        transcription: transcription,
                        digests: digests,
                        model: model,
                        autoProcess: autoProcess
                    )
                }
            } catch {
                workspace.lastError = error.localizedDescription
            }
        }
        .alert("Lori", isPresented: Binding(
            get: { assistant.errorMessage != nil },
            set: { if !$0 { assistant.errorMessage = nil } }
        )) {
            Button("Настройки") { openSettings() }
            Button("OK", role: .cancel) { assistant.errorMessage = nil }
        } message: {
            Text(assistant.errorMessage ?? "")
        }
        .task {
            if let prefilled = assistant.takePrefilledDraft() {
                draft = prefilled
                composerFocused = true
            }
            guard let prompt = assistant.takeQueuedPrompt() else { return }
            await assistant.send(prompt, workspace: workspace, model: model, allowMutations: allowMutations)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard hasConversation else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(ChatTranscript.bottomAnchor, anchor: .bottom)
        }
    }

    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        draft = ""
        composerFocused = false
        Task {
            await assistant.send(prompt, workspace: workspace, model: model, allowMutations: allowMutations)
        }
    }
}

private struct ChatToolbar: View {
    let close: () -> Void
    let newChat: () -> Void
    let history: () -> Void

    var body: some View {
        HStack {
            CircleIconButton(symbol: "xmark", label: "Закрыть чат", action: close)
            Spacer()
            HStack(spacing: 13) {
                Button(action: newChat) { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("Новый чат")
                Button(action: history) { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("История чатов")
            }
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(LoriPalette.ink)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.white.opacity(0.88), in: Capsule())
        }
    }
}

private struct EmptyChatWelcome: View {
    let openSettings: () -> Void
    let chooseSuggestion: (String) -> Void
    @State private var hasKey = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Привет, Илья")
                .font(LoriFont.displaySmall)
                .foregroundStyle(LoriPalette.ink)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    SuggestionChip(text: "Что у меня в заметках?", action: chooseSuggestion)
                    SuggestionChip(text: "Какие задачи я записал?", action: chooseSuggestion)
                    SuggestionChip(text: "Собери итоги последней записи", action: chooseSuggestion)
                }
                .padding(.horizontal, 17)
            }

            if !hasKey {
                Button(action: openSettings) {
                    Label("Подключить DeepSeek", systemImage: "key")
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.muted)
                        .padding(.horizontal, 20)
                }
            }
        }
        .task { hasKey = (try? KeychainStore.deepSeekKey()) != nil }
    }
}

private struct SuggestionChip: View {
    let text: String
    let action: (String) -> Void

    var body: some View {
        Button { action(text) } label: {
            Text(text)
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 38)
                .background(LoriPalette.bubble, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ChatTranscript: View {
    static let bottomAnchor = "lori-transcript-bottom"

    let bubbles: [ChatBubble]
    let isSending: Bool
    @ObservedObject var transcription: TranscriptionService
    let openEntry: (WorkspaceEntry) -> Void

    var body: some View {
        // Новое сообщение и карточка вложения появляются движением: подстановка
        // рывком читается как перерисовка, а не как «пришло».
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(bubbles) { bubble in
                switch bubble.role {
                case .user:
                    HStack {
                        Spacer(minLength: 40)
                        Text(bubble.text)
                            .font(LoriFont.bubble)
                            .foregroundStyle(LoriPalette.ink)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 12)
                            .background(LoriPalette.bubble, in: RoundedRectangle(cornerRadius: 20))
                    }
                    .id(bubble.id)
                    .padding(.horizontal, 17)
                case .assistant:
                    VStack(alignment: .leading, spacing: 10) {
                        // Модель отвечает Markdown’ом всегда. Без разбора человек читал
                        // «**Где это записано:**» и обратные кавычки вокруг путей.
                        MarkdownText(text: bubble.text)
                        // Копируется исходный текст: в буфер нужен он, а не разобранный.
                        CopyAnswerButton(text: bubble.text)
                    }
                    .id(bubble.id)
                    .padding(.horizontal, 20)
                case .system:
                    Text(bubble.text)
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.muted)
                        .id(bubble.id)
                        .padding(.horizontal, 20)
                case .attachment:
                    // Принесённый файл — не текст, а карточка: видно и состояние
                    // расшифровки, и что с ней стало дальше.
                    if let path = bubble.path {
                        ChatAttachmentCard(
                            transcription: transcription,
                            path: path,
                            title: bubble.text,
                            open: openEntry
                        )
                        .id(bubble.id)
                        .padding(.horizontal, 17)
                        .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
                    }
                }
            }

            if isSending {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Думаю…")
                }
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.muted)
                .padding(.horizontal, 20)
            }

            Color.clear
                .frame(height: 1)
                .id(Self.bottomAnchor)
        }
        .animation(.easeOut(duration: 0.28), value: bubbles.count)
    }
}

/// Единственное действие под ответом, которое действительно что-то делает.
/// Лайк/дизлайк и «развернуть» были декорацией: их убрали.
private struct CopyAnswerButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Label(copied ? "Скопировано" : "Скопировать", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                .font(LoriFont.small)
                .foregroundStyle(LoriPalette.muted)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: copied)
    }
}

private struct ChatComposer: View {
    @Binding var draft: String
    @Binding var model: String
    @ObservedObject var recorder: AudioCaptureStore
    let transcriptionStatus: String?
    let isSending: Bool
    var focus: FocusState<Bool>.Binding
    let chooseFile: () -> Void
    let primaryAction: () -> Void
    let togglePause: () -> Void
    let cancelRecording: () -> Void

    private var selectedModel: DeepSeekModel { DeepSeekModel(storedValue: model) }
    /// Со своим провайдером выбор моделей DeepSeek ничего не решает, поэтому вместо
    /// меню в композере стоит имя той модели, к которой запрос действительно уйдёт.
    /// Раньше здесь горело «V4 Flash», хотя запрос шёл в свою модель — это ложь.
    private var customModelName: String? {
        guard LLMSettings.isCustom else { return nil }
        let name = LLMSettings.storedCustomModel
        return name.isEmpty ? nil : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let transcriptionStatus {
                TranscriptionStatusLine(text: transcriptionStatus)
            }

            if recorder.isCapturing {
                RecordingPill(recorder: recorder, togglePause: togglePause, cancel: cancelRecording)
                    .padding(.vertical, 2)
            } else {
                TextField("Спроси о своих заметках", text: $draft, axis: .vertical)
                    .font(LoriFont.body)
                    .foregroundStyle(LoriPalette.ink)
                    .lineLimit(1...5)
                    .focused(focus)
                    .submitLabel(.send)
                    .onSubmit(primaryAction)
            }

            HStack(spacing: 8) {
                Button(action: chooseFile) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(LoriPalette.canvas, in: Circle())
                }
                .foregroundStyle(LoriPalette.muted)
                .accessibilityLabel("Добавить файл")

                if let customModelName {
                    Text(customModelName)
                        .font(LoriFont.control)
                        .foregroundStyle(LoriPalette.ink.opacity(0.82))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(LoriPalette.canvas, in: Capsule())
                        .accessibilityIdentifier("chatModelName")
                } else {
                    Menu {
                        Picker("Модель", selection: $model) {
                            ForEach(DeepSeekModel.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(selectedModel.title)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .font(LoriFont.control)
                        .foregroundStyle(LoriPalette.ink.opacity(0.82))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(LoriPalette.canvas, in: Capsule())
                    }
                    .accessibilityIdentifier("chatModelName")
                }

                Spacer()
                Button(action: primaryAction) {
                    Image(systemName: primarySymbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(LoriPalette.lime)
                        .frame(width: 48, height: 48)
                        .background(LoriPalette.limeSoft.opacity(0.68), in: Circle())
                }
                .disabled(isSending || !hasDraft)
                .opacity(hasDraft ? 1 : 0.45)
                .accessibilityLabel(primaryLabel)
                // Опознаватель нужен тесту: у клавиатуры есть своя кнопка с той же
                // подписью «Отправить», и поиск по подписи находит две.
                .accessibilityIdentifier("chatPrimaryButton")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 25))
        .animation(.easeOut(duration: 0.2), value: recorder.isCapturing)
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Кнопка только отправляет. Микрофона в композере нет: он путал диктовку
    /// вопроса с записью материала, а запись живёт в «+» на главной.
    private var primarySymbol: String { "arrow.up" }

    private var primaryLabel: String { "Отправить" }
}

private struct ChatHistorySheet: View {
    let conversations: [SavedConversation]
    let select: (SavedConversation) -> Void
    let close: () -> Void
    @State private var query = ""

    private var filtered: [SavedConversation] {
        guard !query.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query)
        }
    }

    private var groups: [(title: String, items: [SavedConversation])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [SavedConversation]] = [:]
        for conversation in filtered.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let day = calendar.startOfDay(for: conversation.updatedAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(conversation)
        }
        return order.map { (LoriFormat.groupTitle($0), buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LoriPalette.ink)
                        .frame(width: 44, height: 44)
                        .background(LoriPalette.canvas, in: Circle())
                        .overlay(Circle().stroke(LoriPalette.line, lineWidth: 1))
                }
                .accessibilityLabel("Закрыть историю")
                Text("История")
                    .font(LoriFont.displaySmall)
                    .foregroundStyle(LoriPalette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 17)
            .padding(.top, 14)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LoriPalette.muted)
                TextField("Поиск по диалогам", text: $query)
                    .font(LoriFont.body)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(LoriPalette.canvas, in: Capsule())
            .padding(.horizontal, 17)
            .padding(.top, 16)

            if groups.isEmpty {
                Text(query.isEmpty ? "Диалогов пока нет." : "Ничего не найдено.")
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.muted)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.title) { group in
                            Text(group.title)
                                .font(LoriFont.section)
                                .foregroundStyle(LoriPalette.muted)
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                                .padding(.bottom, 8)

                            ForEach(group.items) { conversation in
                                Button { select(conversation) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(conversation.title)
                                                .font(LoriFont.cardTitle)
                                                .foregroundStyle(LoriPalette.ink)
                                                .lineLimit(1)
                                            Text(conversation.preview)
                                                .font(LoriFont.meta)
                                                .foregroundStyle(LoriPalette.muted)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                        }
                                        Spacer(minLength: 0)
                                        Text(LoriFormat.relative(conversation.updatedAt))
                                            .font(LoriFont.small)
                                            .foregroundStyle(LoriPalette.muted.opacity(0.8))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 13)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(LoriPalette.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 17)
                                .padding(.bottom, 8)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .background(.white)
        .recordingBanner(close: close)
    }
}

private struct FolderDrawer: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    let close: () -> Void
    let openFolder: (String) -> Void
    let openWiki: () -> Void

    @State private var folders: [WorkspaceEntry] = []
    @State private var query = ""
    @State private var showCreateFolder = false
    @State private var folderName = ""
    @State private var loadError: String?

    private var filteredFolders: [WorkspaceEntry] {
        guard !query.isEmpty else { return folders }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    showCreateFolder = true
                } label: {
                    Label("Создать новую папку", systemImage: "folder.badge.plus")
                        .font(LoriFont.control)
                        .foregroundStyle(LoriPalette.ink)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .frame(minHeight: 58)
                }
                .buttonStyle(.plain)

                // Вики живёт рядом с папками: это второй способ смотреть на то же
                // хранилище — по темам, тегам и связям, а не по дереву каталогов.
                Button(action: openWiki) {
                    Label("Вики: темы и связи", systemImage: "point.3.filled.connected.trianglepath.dotted")
                        .font(LoriFont.control)
                        .foregroundStyle(LoriPalette.ink)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .frame(minHeight: 50)
                }
                .buttonStyle(.plain)

                Text("Папки")
                    .font(LoriFont.section)
                    .foregroundStyle(LoriPalette.muted)
                    .padding(.horizontal, 20)
                    .padding(.top, 9)
                    .padding(.bottom, 12)

                if let loadError {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                } else if filteredFolders.isEmpty {
                    Text(query.isEmpty ? "Папок пока нет." : "Ничего не найдено.")
                        .font(LoriFont.meta)
                        .foregroundStyle(LoriPalette.muted)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredFolders) { folder in
                                Button { openFolder(folder.relativePath) } label: {
                                    Label(folder.name, systemImage: "folder.fill")
                                        .font(LoriFont.body)
                                        .foregroundStyle(LoriPalette.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 8)
                                        .frame(minHeight: 50)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(LoriPalette.muted)
                    TextField("Поиск папок", text: $query)
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(LoriPalette.canvas, in: Capsule())
                .padding(16)
            }
            .frame(maxWidth: 330, maxHeight: .infinity, alignment: .leading)
            .background(.white)
            .transition(.move(edge: .leading))
        }
        .task { reload() }
        .alert("Новая папка", isPresented: $showCreateFolder) {
            TextField("Название", text: $folderName)
            Button("Создать") {
                do {
                    let path = try workspace.createFolder(named: folderName)
                    folderName = ""
                    openFolder(path)
                } catch {
                    workspace.lastError = error.localizedDescription
                }
            }
            Button("Отмена", role: .cancel) { folderName = "" }
        } message: {
            Text("Папка останется локально на этом iPhone.")
        }
    }

    private func reload() {
        do {
            folders = try workspace.entries(at: "").filter(\.isDirectory)
            loadError = nil
        } catch {
            folders = []
            loadError = error.localizedDescription
        }
    }
}

private struct WorkspaceBrowserView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let initialPath: String
    @ObservedObject var transcription: TranscriptionService
    /// Нужен только чтобы плеер знал про идущую запись: аудиосессия одна на приложение.
    @ObservedObject var recorder: AudioCaptureStore
    let askAbout: (String) -> Void

    @State private var relativePath: String
    @State private var items: [WorkspaceEntry] = []
    @State private var sheet: EntrySheet?
    @State private var renameTarget: WorkspaceEntry?
    @State private var deleteTarget: WorkspaceEntry?
    @State private var showAddMenu = false
    @State private var showFileImporter = false
    @State private var loadError: String?

    init(
        initialPath: String,
        transcription: TranscriptionService,
        recorder: AudioCaptureStore,
        askAbout: @escaping (String) -> Void = { _ in }
    ) {
        self.initialPath = initialPath
        self.transcription = transcription
        self.recorder = recorder
        self.askAbout = askAbout
        _relativePath = State(initialValue: initialPath)
    }

    private var title: String {
        relativePath.isEmpty ? "Мои файлы" : URL(fileURLWithPath: relativePath).lastPathComponent
    }

    private var folderQuestion: String {
        relativePath.isEmpty
            ? "Что у меня есть в заметках?"
            : "Что лежит в папке «\(title)» и что там важного?"
    }

    private var parentPath: String {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        return components.dropLast().joined(separator: "/")
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView("Не удалось открыть папку", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "Папка пуста",
                        systemImage: "folder",
                        description: Text("Нажми «+», чтобы создать заметку или добавить файл с iPhone.")
                    )
                } else {
                    // `List` остаётся ради свайпа по строке, но строки — те же карточки,
                    // что на главной: системный список с разделителями выпадал из языка приложения.
                    List {
                        folderHeader
                            .listRowInsets(EdgeInsets(top: 4, leading: 17, bottom: 18, trailing: 17))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .selectionDisabled()

                        ForEach(items) { entry in
                            Button { open(entry) } label: {
                                if entry.isDirectory {
                                    FolderRow(entry: entry)
                                } else {
                                    NoteCard(
                                        entry: entry,
                                        isTranscribing: transcription.isRunning(entry.relativePath),
                                        progressText: transcription.progressText(for: entry.relativePath)
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 4, leading: 17, bottom: 4, trailing: 17))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                EntryMenuButtons(
                                    rename: { renameTarget = entry },
                                    delete: { deleteTarget = entry },
                                    transcribe: entry.isAudio ? { transcribe(entry) } : nil
                                )
                            }
                            .contextMenu {
                                EntryMenuButtons(
                                    rename: { renameTarget = entry },
                                    delete: { deleteTarget = entry },
                                    transcribe: entry.isAudio ? { transcribe(entry) } : nil,
                                    openTranscript: workspace.existingTranscript(for: entry).map { path in
                                        { openTranscript(path) }
                                    }
                                )
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { reload() }
                }
            }
            .background(LoriPalette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if relativePath.isEmpty {
                        Button("Готово") { dismiss() }
                    } else {
                        Button {
                            relativePath = parentPath
                        } label: {
                            Label("Назад", systemImage: "chevron.left")
                        }
                        .accessibilityLabel("Назад")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddMenu = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Добавить в эту папку")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { askAbout(folderQuestion) } label: {
                    Label("Спросить про папку", systemImage: "bubble.left.and.text.bubble.right")
                        .font(LoriFont.control)
                        .foregroundStyle(LoriPalette.ink)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                        .background(.white.opacity(0.9), in: Capsule())
                        .overlay(Capsule().stroke(LoriPalette.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 17)
                .padding(.bottom, 8)
                .background(LoriPalette.canvas)
            }
        }
        .recordingBanner { dismiss() }
        .onChange(of: relativePath) { reload() }
        .task { reload() }
        .sheet(item: $sheet) { target in
            switch target {
            case let .editor(editor):
                NoteEditorSheet(target: editor, didChange: reload, askAbout: askAbout)
            case let .recording(entry):
                RecordingSheet(
                    entry: entry,
                    transcription: transcription,
                    isRecording: recorder.isCapturing,
                    openTranscript: openTranscript
                )
            case .wiki:
                WikiSheet(openNote: openTranscript)
            }
        }
        .modifier(EntryMutationAlerts(renameTarget: $renameTarget, deleteTarget: $deleteTarget, didChange: reload))
        .confirmationDialog("Добавить в эту папку", isPresented: $showAddMenu, titleVisibility: .visible) {
            Button("Новая заметка") { sheet = .editor(.draft(directory: relativePath)) }
            Button("Выбрать файл") { showFileImporter = true }
            Button("Отмена", role: .cancel) {}
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { throw WorkspaceError.importFailed }
                try workspace.importFile(from: url, into: relativePath)
                reload()
            } catch {
                workspace.lastError = error.localizedDescription
            }
        }
    }

    private func reload() {
        do {
            items = try workspace.entries(at: relativePath)
            loadError = nil
        } catch {
            items = []
            loadError = error.localizedDescription
        }
    }

    /// Крупный заголовок папки вместо строки 17pt в навигационной панели —
    /// шапка экрана-документа, как «Мои заметки» на главной.
    private var folderHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LoriFont.display)
                .foregroundStyle(LoriPalette.ink)
                .lineLimit(2)
            Text(headerCount)
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerCount: String {
        let folders = items.filter(\.isDirectory).count
        let files = items.count - folders
        let filesText = LoriFormat.plural(files, one: "файл", few: "файла", many: "файлов")
        guard folders > 0 else { return filesText }
        let foldersText = LoriFormat.plural(folders, one: "папка", few: "папки", many: "папок")
        return files > 0 ? "\(foldersText) · \(filesText)" : foldersText
    }

    private func open(_ entry: WorkspaceEntry) {
        if entry.isDirectory {
            relativePath = entry.relativePath
        } else if entry.isAudio {
            sheet = .recording(entry)
        } else {
            sheet = .editor(.existing(entry))
        }
    }

    private func openTranscript(_ path: String) {
        guard let entry = try? workspace.entry(at: path) else { return }
        sheet = .editor(.existing(entry))
    }

    /// Как и на главной: результат показывает карточка записи с переключателем
    /// «Важное ↔ Расшифровка», а не сразу файл расшифровки.
    private func transcribe(_ entry: WorkspaceEntry) {
        sheet = .recording(entry)
        Task {
            await transcription.transcribe(entry, in: workspace)
            reload()
        }
    }
}

/// Что открыто поверх списка. Лист на экране ровно один: два модификатора
/// `.sheet` на одной View гасят друг друга так же, как два `.alert`.
private enum EntrySheet: Identifiable, Hashable {
    case editor(NoteEditorTarget)
    case recording(WorkspaceEntry)
    case wiki

    var id: String {
        switch self {
        case let .editor(target): target.id
        case let .recording(entry): "audio:\(entry.relativePath)"
        case .wiki: "wiki"
        }
    }
}

private enum NoteEditorTarget: Identifiable, Hashable {
    case existing(WorkspaceEntry)
    case draft(directory: String)

    var id: String {
        switch self {
        case let .existing(entry): "file:\(entry.relativePath)"
        case let .draft(directory): "draft:\(directory)"
        }
    }
}

/// Редактор заметки. Текст сохраняется по «Готово» и при закрытии свайпом,
/// поэтому набранное не теряется. Пустой черновик файла не создаёт.
private struct NoteEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    let target: NoteEditorTarget
    let didChange: () -> Void
    let askAbout: ((String) -> Void)?

    @State private var text = ""
    @State private var loadedText = ""
    @State private var path: String?
    @State private var title: String
    @State private var loadError: String?
    @State private var showRename = false
    @State private var draftName = ""
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    init(
        target: NoteEditorTarget,
        didChange: @escaping () -> Void = {},
        askAbout: ((String) -> Void)? = nil
    ) {
        self.target = target
        self.didChange = didChange
        self.askAbout = askAbout
        switch target {
        case let .existing(entry):
            _path = State(initialValue: entry.relativePath)
            _title = State(initialValue: entry.name)
        case .draft:
            _path = State(initialValue: nil)
            _title = State(initialValue: "Новая заметка")
        }
    }

    private var isDirty: Bool { text != loadedText }

    private var displayTitle: String { (title as NSString).deletingPathExtension }

    private var subtitle: String? {
        guard case let .existing(entry) = target else { return nil }
        return LoriFormat.stamp(entry.modifiedAt)
    }

    private var draftDirectory: String {
        switch target {
        case .existing: ""
        case let .draft(directory): directory
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Не удалось открыть",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayTitle)
                                .font(LoriFont.displaySmall)
                                .foregroundStyle(LoriPalette.ink)
                            if let subtitle {
                                Text(subtitle)
                                    .font(LoriFont.meta)
                                    .foregroundStyle(LoriPalette.muted)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 8)

                        TextEditor(text: $text)
                            .font(LoriFont.body)
                            .foregroundStyle(LoriPalette.ink)
                            .lineSpacing(4)
                            .scrollContentBackground(.hidden)
                            .focused($focused)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .background(LoriPalette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if let askAbout, path != nil {
                    Button {
                        askAbout("Что важного в заметке «\(displayTitle)»?")
                        save()
                        dismiss()
                    } label: {
                        Label("Спросить про заметку", systemImage: "bubble.left.and.text.bubble.right")
                            .font(LoriFont.control)
                            .foregroundStyle(LoriPalette.ink)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                            .background(.white.opacity(0.9), in: Capsule())
                            .overlay(Capsule().stroke(LoriPalette.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 17)
                    .padding(.bottom, 8)
                    .background(LoriPalette.canvas)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") {
                        save()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            draftName = (title as NSString).deletingPathExtension
                            showRename = true
                        } label: { Label("Переименовать", systemImage: "pencil") }
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("В корзину Lori", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(path == nil)
                }
            }
            .alert("Переименовать", isPresented: $showRename) {
                TextField("Название", text: $draftName)
                Button("Сохранить") { rename() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Заметка останется в той же папке Lori.")
            }
            .confirmationDialog("Удалить заметку?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Перенести в корзину Lori", role: .destructive) { moveToTrash() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Файл переедет в локальную корзину, а не удалится безвозвратно.")
            }
        }
        .recordingBanner {
            save()
            dismiss()
        }
        .task {
            guard case let .existing(entry) = target else {
                focused = true
                return
            }
            do {
                let loaded = try workspace.readText(at: entry.relativePath)
                text = loaded
                loadedText = loaded
            } catch {
                loadError = error.localizedDescription
            }
        }
        .onDisappear { save() }
    }

    private func save() {
        guard loadError == nil, isDirty else { return }
        do {
            if let path {
                try workspace.writeText(text, at: path)
            } else {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let created = try workspace.createNote(in: draftDirectory, content: text)
                path = created
                title = URL(fileURLWithPath: created).lastPathComponent
            }
            loadedText = text
            didChange()
        } catch {
            workspace.lastError = error.localizedDescription
        }
    }

    private func rename() {
        guard let current = path else { return }
        do {
            let updated = try workspace.renameItem(at: current, toName: draftName)
            path = updated
            title = URL(fileURLWithPath: updated).lastPathComponent
            didChange()
        } catch {
            workspace.lastError = error.localizedDescription
        }
    }

    private func moveToTrash() {
        guard let current = path else { return }
        do {
            try workspace.moveToTrash(current)
            loadedText = text
            didChange()
            dismiss()
        } catch {
            workspace.lastError = error.localizedDescription
        }
    }
}

private struct EntryMenuButtons: View {
    let rename: () -> Void
    let delete: () -> Void
    var transcribe: (() -> Void)?
    var openTranscript: (() -> Void)?

    var body: some View {
        if let openTranscript {
            Button(action: openTranscript) { Label("Открыть расшифровку", systemImage: "doc.text") }
        }
        if let transcribe {
            Button(action: transcribe) { Label("Расшифровать", systemImage: "waveform.badge.magnifyingglass") }
        }
        Button(action: rename) { Label("Переименовать", systemImage: "pencil") }
        Button(role: .destructive, action: delete) { Label("В корзину Lori", systemImage: "trash") }
    }
}

/// Диалоги переименования и удаления живут на контейнере, а не на строке списка:
/// строка исчезает вместе с файлом и увела бы диалог за собой.
private struct EntryMutationAlerts: ViewModifier {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Binding var renameTarget: WorkspaceEntry?
    @Binding var deleteTarget: WorkspaceEntry?
    let didChange: () -> Void
    @State private var draftName = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: renameTarget) { _, target in
                guard let target else { return }
                draftName = target.isDirectory ? target.name : (target.name as NSString).deletingPathExtension
            }
            .alert("Переименовать", isPresented: isPresented($renameTarget), presenting: renameTarget) { entry in
                TextField("Название", text: $draftName)
                Button("Сохранить") {
                    do {
                        _ = try workspace.renameItem(at: entry.relativePath, toName: draftName)
                        didChange()
                    } catch {
                        workspace.lastError = error.localizedDescription
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: { _ in
                Text("Элемент останется в той же папке Lori.")
            }
            .confirmationDialog(
                "Удалить?",
                isPresented: isPresented($deleteTarget),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { entry in
                Button("Перенести в корзину Lori", role: .destructive) {
                    do {
                        try workspace.moveToTrash(entry.relativePath)
                        didChange()
                    } catch {
                        workspace.lastError = error.localizedDescription
                    }
                }
                Button("Отмена", role: .cancel) {}
            } message: { entry in
                Text("«\(entry.name)» переедет в локальную корзину Lori, а не удалится безвозвратно.")
            }
    }

    private func isPresented(_ target: Binding<WorkspaceEntry?>) -> Binding<Bool> {
        Binding(get: { target.wrappedValue != nil }, set: { if !$0 { target.wrappedValue = nil } })
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var transcriptionEngineName = "—"
    @State private var key = ""
    @State private var hasKey = false
    @State private var result: String?
    @State private var isCheckingKey = false
    @AppStorage("deepSeekModel") private var model = DeepSeekModel.fallback.rawValue
    @AppStorage(TranscriptionEngineChoice.storageKey) private var transcriptionEngine = TranscriptionEngineChoice.fallback.rawValue
    @AppStorage("allowAssistantMutations") private var allowMutations = false
    @AppStorage("autoProcessTranscripts") private var autoProcess = true
    @AppStorage("loriMemory") private var memoryEnabled = true
    @AppStorage(LLMSettings.baseURLKey) private var llmBaseURL = ""
    @AppStorage(LLMSettings.customModelKey) private var llmCustomModel = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Рабочая папка") {
                    LabeledContent("Расположение", value: workspace.rootPath)
                    Text("Открой «Файлы» → «На моём iPhone» → Lori, чтобы видеть документы приложения.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("DeepSeek API") {
                    Picker("Модель", selection: $model) {
                        ForEach(DeepSeekModel.allCases) { option in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                Text(option.detail)
                                    .font(LoriFont.small)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(option.rawValue)
                        }
                    }
                    if LLMSettings.isCustom {
                        Text("Сейчас работает свой провайдер (ниже), и выбор модели DeepSeek ни на что не влияет.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    SecureField("API-ключ", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("apiKeyField")
                    Button("Сохранить в Keychain") {
                        do {
                            try KeychainStore.saveDeepSeekKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
                            key = ""
                            hasKey = true
                            result = "Ключ сохранён в Keychain этого iPhone."
                        } catch {
                            result = error.localizedDescription
                        }
                    }
                    if hasKey {
                        LabeledContent("Статус", value: "Ключ сохранён на этом iPhone")
                        Button(isCheckingKey ? "Проверяю подключение…" : "Проверить подключение") {
                            validateDeepSeekKey()
                        }
                        .disabled(isCheckingKey)
                        Button("Удалить ключ", role: .destructive) {
                            do {
                                try KeychainStore.deleteDeepSeekKey()
                                hasKey = false
                                result = "Ключ удалён."
                            } catch { result = error.localizedDescription }
                        }
                    }
                }
                Section("Расшифровка") {
                    Picker("Движок", selection: $transcriptionEngine) {
                        ForEach(TranscriptionEngineChoice.allCases) { option in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                Text(option.detail)
                                    .font(LoriFont.small)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(option.rawValue)
                        }
                    }
                    .accessibilityIdentifier("transcriptionEnginePicker")
                    // Выбор и работающий движок — разные вещи: моделей выбранного может
                    // не оказаться на устройстве, и тогда работает следующий по порядку.
                    LabeledContent("Работает", value: transcriptionEngineName)
                        .accessibilityIdentifier("transcriptionEngineName")
                    Text("Аудио и расшифровка остаются на этом iPhone. GigaAM и Whisper расставляют знаки препинания сами; их модели кладут в «Файлы» → Lori → Models, и без них работает движок Apple — текст без пунктуации.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Свой провайдер модели") {
                    TextField("Адрес API, например http://192.168.1.10:1234/v1", text: $llmBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("llmBaseURLField")
                    TextField("Имя модели у этого провайдера", text: $llmCustomModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("llmModelField")
                    LabeledContent("Запросы идут в", value: LLMSettings.describedTarget)
                    Text("Пусто — работает DeepSeek с моделью выше. Указан адрес — Lori обращается туда: любой сервис с API как у OpenAI, в том числе модель, поднятая на своём компьютере в домашней сети. Аудио и расшифровка остаются на iPhone в любом случае; наружу уходит только текст запроса.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Обработка расшифровки") {
                    Toggle("Сразу делать «Важное»", isOn: $autoProcess)
                    Text("После расшифровки Lori просит модель собрать читаемую заметку — заголовок, суть, важное, решения и задачи — и кладёт её в тематическую папку. Дословный текст остаётся в «Transcripts» и открывается переключателем в карточке. Обработка идёт через модель из настроек выше, то есть текст расшифровки уходит в неё; аудио с телефона не уходит никогда.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Память") {
                    Toggle("Использовать память", isOn: $memoryEnabled)
                    Text("Что запомнили, лежит в заметке «Память Lori» — её видно в списке, можно править и чистить руками. Память подставляется в каждый диалог, поэтому Lori помнит сказанное раньше. Выключить — значит и не запоминать, и не подставлять уже запомненное. Поиск по всем заметкам работает всегда, независимо от этого переключателя.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Работа ИИ с файлами") {
                    Toggle("Разрешить ИИ создавать и изменять файлы", isOn: $allowMutations)
                    Text("По умолчанию ИИ может только читать список и содержимое файлов. Удаление переносит файл в локальную корзину Lori.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(LoriPalette.canvas)
            .navigationTitle("Настройки")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
            .recordingBanner { dismiss() }
            .task(id: transcriptionEngine) {
                hasKey = (try? KeychainStore.deepSeekKey()) != nil
                // Пересчитывается на каждую смену выбора: иначе строка «Работает»
                // осталась бы от прошлого движка и врала бы.
                let choice = TranscriptionEngineChoice(storedValue: transcriptionEngine)
                transcriptionEngineName = await TranscriptionEngines.resolve(for: choice).name
            }
            .alert("Lori", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
                Button("OK", role: .cancel) { result = nil }
            } message: {
                Text(result ?? "")
            }
        }
    }

    private func validateDeepSeekKey() {
        Task {
            isCheckingKey = true
            defer { isCheckingKey = false }
            do {
                guard let savedKey = try KeychainStore.deepSeekKey(), !savedKey.isEmpty else {
                    throw AgentError.missingKey
                }
                try await DeepSeekClient().validate(apiKey: savedKey)
                result = "Подключение работает: \(LLMSettings.describedTarget)."
            } catch {
                result = error.localizedDescription
            }
        }
    }
}

private struct CircleIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(LoriPalette.ink)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.9), in: Circle())
                .overlay(Circle().stroke(LoriPalette.line, lineWidth: 1))
        }
        .accessibilityLabel(label)
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView().environmentObject(WorkspaceStore())
}
