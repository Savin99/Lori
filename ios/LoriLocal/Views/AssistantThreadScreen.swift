import SwiftUI
import UIKit

/// Охват вопроса: набор записей с человеческим названием.
///
/// Экран записи передаёт один охват из одной записи, главный — «Все» и темы.
/// Движку разница безразлична: он получает готовый список источников.
struct AskScope: Identifiable, Equatable {
    let id: String
    let title: String
    let entries: [WorkspaceEntry]
}

/// Тред по расшифровкам: вопрос — ответ со ссылками на секунды записей.
///
/// Контекст замораживается при создании треда и дальше не пересобирается —
/// см. `ContextSnapshot`. Поэтому строка сверху говорит, по чему именно идёт
/// разговор, а «Изменить» — единственный способ это поменять.
struct AssistantThreadScreen: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @ObservedObject var store: AssistantThreadStore
    @Environment(\.dismiss) private var dismiss

    let scopes: [AskScope]
    var initialScopeID: String?
    /// Вопрос, набранный в панели: тред открывается уже с ним.
    var initialQuestion: String = ""
    /// Заголовок записи берётся у вызывающего: на главном экране он уже посчитан
    /// моделью заголовков, и второй раз считать его тут незачем.
    let title: (WorkspaceEntry) -> String
    /// Описание записи для оглавления — то, что посчитала модель заголовков.
    var detail: (WorkspaceEntry) -> String? = { _ in nil }
    /// Тема записи для оглавления.
    var topic: (WorkspaceEntry) -> String? = { _ in nil }
    /// Тап по ссылке. Экран записи перематывает плеер, главный — открывает запись.
    var onOpen: ((AssistantService.Citation) -> Void)?

    @State private var scopeID = ""
    @State private var question = ""
    @State private var running = false
    @State private var error: String?
    @State private var showScopePicker = false
    @State private var lastCachedTokens: Int?
    @State private var didStart = false
    /// Свой проигрыватель: пилюля включает кусок прямо в ленте. Уводить человека
    /// на экран записи ради пятнадцати секунд — значит терять место в разговоре.
    @StateObject private var playback = AudioPlaybackStore()
    @State private var playing: String?
    @FocusState private var focused: Bool

    @AppStorage(AssistantSettings.modelKey) private var assistantModel = ""

    private var scope: AskScope? {
        scopes.first { $0.id == scopeID } ?? scopes.first
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                contextBar
                Divider().overlay(LoriPalette.line)
                conversation
            }
            .background(LoriPalette.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle("Ассистент")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Назад") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
            .alert("Lori", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("Скопировать") {
                    UIPasteboard.general.string = error
                    error = nil
                }
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
            .confirmationDialog("По чему спрашивать", isPresented: $showScopePicker, titleVisibility: .visible) {
                ForEach(scopes) { candidate in
                    Button(candidate.title) { rebuild(with: candidate.id) }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Контекст соберётся заново, и кэш начнётся с нуля.")
            }
        }
        // Плашка записи — снаружи `NavigationStack`: внутри её накрывает заголовок.
        .recordingBanner { dismiss() }
        .onDisappear { playback.stop() }
        .task {
            guard !didStart else { return }
            didStart = true
            scopeID = initialScopeID.flatMap { id in scopes.first { $0.id == id }?.id } ?? scopes.first?.id ?? ""

            // Разговор при открытии не стирается. Раньше «Спросить по этой
            // записи» поверх разговора про архив убивало его молча, ещё до
            // того как человек что-то спросил, — он возвращался в чат и
            // находил пустоту. Смена охвата теперь случается от нового
            // вопроса, а не от того, что экран открыли; в шапке про это
            // написано заранее.
            if !initialQuestion.isEmpty {
                question = initialQuestion
                await send()
            } else if store.thread == nil {
                focused = true
            }
        }
    }

    // MARK: - Строка контекста

    private var contextBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "doc.text")
                .font(LoriFont.small)
                .foregroundStyle(LoriPalette.muted)

            VStack(alignment: .leading, spacing: 2) {
                Text(contextLine)
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
                    .accessibilityIdentifier("threadContext")
                // Молчать об урезанном контексте нельзя: иначе «в записях этого
                // нет» читается как факт, а это может быть просто не влезшая часть.
                if let note = scopeMismatch ?? contextNote {
                    Text(note)
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.muted)
                        .accessibilityIdentifier("threadNote")
                }
            }

            Spacer(minLength: 8)

            Button("Изменить") { showScopePicker = true }
                .font(LoriFont.small.weight(.semibold))
                .foregroundStyle(LoriPalette.lime)
                .accessibilityIdentifier("changeScope")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var contextLine: String {
        guard let thread = store.thread else {
            return scope.map { "Спрошу по охвату «\($0.title)»" } ?? "Записей нет"
        }
        return thread.headline
    }

    private var contextNote: String? { store.thread?.note }

    /// Открыли по одному охвату, а разговор идёт по другому. Сказать об этом
    /// надо до вопроса, а не молча стереть разговор при открытии экрана.
    private var scopeMismatch: String? {
        guard let current = store.thread?.context.scopeTitle,
              let scope, current != scope.title else { return nil }
        return "Разговор идёт по охвату «\(current)». Новый вопрос начнёт разговор по «\(scope.title)»"
    }

    // MARK: - Лента

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // Пустой экран пустым и остаётся: поле уже в фокусе, и
                    // объяснять человеку, что сейчас произойдёт, незачем.
                    ForEach(store.thread?.messages ?? []) { message in
                        bubble(message).id(message.id)
                    }
                    if running { thinking.id(Self.thinkingID) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.thread?.messages.count) { _, _ in scroll(proxy) }
            .onChange(of: running) { _, _ in scroll(proxy) }
        }
    }

    private static let thinkingID = "thinking"

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if running {
                proxy.scrollTo(Self.thinkingID, anchor: .bottom)
            } else if let last = store.thread?.messages.last?.id {
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    /// Вопрос — пузырём справа, ответ — обычным текстом. Ответ длинный и его
    /// читают; обрамление тут только мешает.
    @ViewBuilder
    private func bubble(_ message: ThreadMessage) -> some View {
        if message.role == .question {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(LoriFont.body)
                    .foregroundStyle(LoriPalette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(LoriPalette.bubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .accessibilityIdentifier("threadQuestion")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(paragraphs(of: message)) { paragraph in
                    VStack(alignment: .leading, spacing: 8) {
                        MarkdownText(text: paragraph.text)
                        if !paragraph.citations.isEmpty {
                            citations(paragraph.citations)
                        }
                    }
                }
                .accessibilityIdentifier("threadAnswer")

                Button {
                    UIPasteboard.general.string = AssistantService.withoutMarkers(message.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.muted)
                        .frame(width: 44, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Скопировать ответ")
            }
        }
    }

    /// Ответ раскладывается на абзацы прямо при показе: маркеры нужны только
    /// для того, чтобы понять, к какому абзацу какая ссылка, — а человеку они
    /// в тексте ни к чему.
    private func paragraphs(of message: ThreadMessage) -> [AssistantService.Paragraph] {
        // Контекст с дописанным: ссылка на запись, текст которой пришёл вместе
        // с вопросом, обязана вести туда же, куда и на замороженную.
        guard let context = store.thread?.merged else {
            return [.init(id: 0, text: AssistantService.withoutMarkers(message.text), citations: message.citations)]
        }
        let split = AssistantService.paragraphs(of: message.text, context: context)
        // Контекст мог смениться, и тогда номера в старом ответе уже ни на что
        // не указывают: показываем ссылки, сохранённые вместе с ответом.
        let found = split.flatMap(\.citations)
        guard !found.isEmpty || message.citations.isEmpty else {
            return [.init(id: 0, text: AssistantService.withoutMarkers(message.text), citations: message.citations)]
        }
        return split
    }

    /// Пилюли «Интеграция · 0:38». Ради них всё и делалось: тап открывает
    /// запись на той самой секунде, а не «где-то в этом файле».
    private func citations(_ list: [AssistantService.Citation]) -> some View {
        FlowRow(spacing: 8) {
            ForEach(list) { citation in
                let sounding = playing == citation.id && playback.isPlaying
                Button {
                    toggle(citation)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: sounding ? "pause.fill" : "play.fill")
                            .font(LoriFont.tiny)
                        Text(citation.title)
                            .font(LoriFont.small)
                            .lineLimit(1)
                        if let start = citation.start {
                            Text("· \(TranscriptSegment.stamp(start))")
                                .font(LoriFont.small.monospacedDigit())
                                .foregroundStyle(LoriPalette.muted)
                        }
                    }
                    .foregroundStyle(LoriPalette.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(sounding ? LoriPalette.bubble : LoriPalette.card, in: Capsule())
                    .overlay(Capsule().stroke(sounding ? LoriPalette.lime : LoriPalette.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(sounding ? "Остановить \(citation.title)" : "Послушать \(citation.title)")
                // Открыть запись целиком иногда всё-таки нужно, но это не то,
                // чего ждут от нажатия на кусок звука.
                .contextMenu {
                    Button {
                        playback.stop()
                        onOpen?(citation)
                        dismiss()
                    } label: {
                        Label("Открыть запись", systemImage: "doc.text")
                    }
                    .disabled(onOpen == nil)
                }
            }
        }
        .accessibilityIdentifier("threadCitations")
    }

    private var thinking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("Спрашиваю…")
                .font(LoriFont.small)
                .foregroundStyle(LoriPalette.muted)
        }
        .accessibilityIdentifier("threadProgress")
    }

    // MARK: - Композер

    private var composer: some View {
        ThreadComposer(
            text: $question,
            focused: $focused,
            model: currentModel,
            models: modelChoices,
            hasKey: AssistantSettings.hasKey,
            busy: running,
            selectModel: { assistantModel = $0 },
            openSettings: { error = "Ключ ассистента живёт в «Настройки → Ассистент»." },
            send: { Task { await send() } }
        )
    }

    private var currentModel: String {
        assistantModel.isEmpty ? AssistantSettings.model : assistantModel
    }

    private var modelChoices: [String] {
        var names = [currentModel]
        for suggestion in ModelCatalog.chatSuggestions.map(\.id) where !names.contains(suggestion) {
            names.append(suggestion)
            if names.count == 3 { break }
        }
        return names
    }

    // MARK: - Меню

    private var menu: some View {
        Menu {
            Button {
                store.forget()
                question = ""
                lastCachedTokens = nil
            } label: {
                Label("Новый разговор", systemImage: "square.and.pencil")
            }
            .disabled(store.thread == nil)

            Section {
                Text(AssistantSettings.describedTarget)
                if let cached = lastCachedTokens {
                    Text("Из кэша: \(cached) токенов")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(LoriFont.control)
                .foregroundStyle(LoriPalette.ink)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Ещё")
        .accessibilityIdentifier("threadMenu")
    }

    // MARK: - Действия

    /// Пилюля включает кусок на месте. Переход на экран записи здесь был
    /// худшим из возможных ответов на нажатие: человек терял место в разговоре,
    /// а попадал в начало расшифровки.
    private func toggle(_ citation: AssistantService.Citation) {
        if playing == citation.id, playback.isPlaying {
            playback.pause()
            return
        }
        guard let url = try? workspace.fileURL(for: citation.path) else {
            error = "Не нашёл файл записи «\(citation.title)»."
            return
        }
        playback.load(url)
        playback.seek(to: citation.start ?? 0)
        playback.play()
        playing = citation.id
    }

    private func send() async {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !running else { return }

        // Без ключа вопрос не уходит вовсе. Иначе он улетал бы в сеть и
        // возвращался ошибкой Keychain, которая ничего человеку не объясняет, —
        // а на месте кнопки отправки уже написано, чего не хватает.
        guard AssistantSettings.hasKey else {
            question = asked
            focused = false
            return
        }

        question = ""
        focused = false
        running = true
        defer { running = false }

        // Смена охвата — новый разговор, но случается она от вопроса, а не от
        // открытия экрана: человек должен успеть увидеть, что разговор пропадёт.
        if let current = store.thread?.context.scopeTitle, current != scope?.title {
            store.forget()
        }
        if store.thread == nil {
            guard await freezeContext(question: asked) else {
                question = asked
                return
            }
        }
        // История берётся **до** того, как вопрос ляжет в ленту: иначе он уходит
        // сервису дважды — один раз из истории, второй раз как сам вопрос.
        guard let history = store.thread else {
            question = asked
            return
        }
        store.append(ThreadMessage(role: .question, text: asked))

        // Расшифровки нужны, только когда охват не влез целиком: тогда под
        // каждый вопрос дописываются тексты записей, которых сервис не видел.
        let sources: [AssistantSource]
        if history.context.whole {
            sources = []
        } else {
            sources = await collect()?.sources ?? []
        }
        do {
            let reply = try await AssistantService().answer(question: asked, in: history, sources: sources)
            lastCachedTokens = reply.cachedTokens
            store.attach(added: reply.added)
            store.append(ThreadMessage(role: .answer, text: reply.text, citations: reply.citations))
        } catch {
            // Вопрос без ответа не должен остаться висеть в ленте: человек
            // перечитает его и решит, что ответ потерялся.
            store.removeLastQuestion()
            question = asked
            self.error = error.localizedDescription
        }
    }

    /// Расшифровки охвата. Читает файлы, поэтому зовётся только когда нужно.
    private func collect() async -> AssistantCollection? {
        guard let scope else { return nil }
        return await AssistantSources.collect(
            scope.entries,
            in: workspace,
            title: title,
            detail: detail,
            topic: topic
        )
    }

    /// Заморозка префикса под первый вопрос. Дальше он не пересобирается:
    /// тексты, которых не хватило, дописываются в конец, к самому вопросу.
    @discardableResult
    private func freezeContext(question asked: String? = nil) async -> Bool {
        guard let scope, let collection = await collect() else {
            error = AssistantError.noSources.errorDescription
            return false
        }
        guard !collection.sources.isEmpty else {
            error = AssistantError.noSources.errorDescription
            return false
        }
        let prompt = asked ?? question
        let sources = collection.sources
        let scopeTitle = scope.title
        // Разбор всех Markdown-файлов и локальный отбор контекста — CPU-работа;
        // на главном потоке кнопка отправки выглядела не нажатой.
        let context = await Task.detached(priority: .userInitiated) {
            AssistantService.snapshot(
                question: prompt,
                sources: sources,
                scopeTitle: scopeTitle
            )
        }.value
        guard !context.isEmpty else {
            error = AssistantError.noSources.errorDescription
            return false
        }
        if store.thread == nil {
            store.start(with: context)
        } else {
            store.replaceContext(with: context)
        }
        return true
    }

    private func rebuild(with id: String) {
        scopeID = id
        // История остаётся, а префикс становится другим — про сброс кэша
        // человека предупредили в самом диалоге.
        let asked = store.thread?.title ?? question
        Task {
            guard !running else { return }
            running = true
            defer { running = false }
            _ = await freezeContext(question: asked)
        }
    }
}

/// Строка, переносящая элементы на следующую, когда они не помещаются.
/// Нужна пилюлям ссылок: их бывает три подряд, и `HStack` их сплющивает.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if next > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = next
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
