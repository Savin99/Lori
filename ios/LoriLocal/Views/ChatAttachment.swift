import SwiftUI

/// Как Lori приносит принесённый файл в разговор.
///
/// Раньше скрепка молча копировала файл в `Inbox` — ни расшифровки, ни следа в ленте,
/// файл просто исчезал. Теперь у вложения есть карточка, аудио расшифровывается,
/// а его текст уходит в контекст диалога, чтобы по нему можно было сразу спрашивать.
@MainActor
enum ChatIngest {
    enum Kind: Equatable, Sendable {
        case audio
        case text
        /// Картинки и прочее, что Lori прочитать не может. Врать про это нельзя.
        case unreadable
    }

    /// Решение вынесено отдельно, потому что это единственная развилка приёма
    /// и её надо проверять тестом, а не глазами. `nonisolated` — чистая функция.
    nonisolated static func decide(isAudio: Bool, text: String?) -> Kind {
        if isAudio { return .audio }
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text }
        return .unreadable
    }

    /// Полный путь вложения: копия в рабочей папке, карточка в ленте, расшифровка,
    /// текст в контекст и — если разрешено — обработка в «Важное».
    static func bring(
        externalURL: URL,
        into workspace: WorkspaceStore,
        assistant: AssistantStore,
        transcription: TranscriptionService,
        digests: DigestService,
        model: String,
        autoProcess: Bool
    ) async {
        let path: String
        let entry: WorkspaceEntry
        do {
            path = try workspace.importFile(from: externalURL)
            entry = try workspace.entry(at: path)
        } catch {
            workspace.lastError = error.localizedDescription
            return
        }

        assistant.attach(path, title: entry.displayName)
        await ingest(entry: entry,
                     in: workspace,
                     assistant: assistant,
                     transcription: transcription,
                     digests: digests,
                     model: model,
                     autoProcess: autoProcess)
    }

    /// То же для файла, который уже лежит в рабочей папке.
    static func ingest(
        entry: WorkspaceEntry,
        in workspace: WorkspaceStore,
        assistant: AssistantStore,
        transcription: TranscriptionService,
        digests: DigestService,
        model: String,
        autoProcess: Bool
    ) async {
        let text = entry.isAudio ? nil : try? workspace.readText(at: entry.relativePath)
        switch decide(isAudio: entry.isAudio, text: text) {
        case .text:
            assistant.addContext(title: entry.displayName, text: text ?? "")
        case .unreadable:
            assistant.note("Файл «\(entry.displayName)» лежит в рабочей папке, но прочитать его я не могу — умею текст и аудио.")
        case .audio:
            var transcriptPath = workspace.existingTranscript(for: entry)
            if transcriptPath == nil {
                transcriptPath = await transcription.transcribe(entry, in: workspace)
            }
            guard let transcriptPath, let raw = try? workspace.readText(at: transcriptPath) else { return }
            assistant.addContext(
                title: "расшифровка записи «\(entry.displayName)»",
                text: TranscriptReadability.plainText(fromMarkdown: raw)
            )
            guard DigestService.shouldProcess(
                automatic: true,
                autoEnabled: autoProcess,
                hasTranscript: true,
                hasDigest: digests.digestPath(for: entry.relativePath, in: workspace) != nil,
                hasKey: digests.hasKey,
                isRunning: digests.isRunning(transcriptPath)
            ) else { return }
            await digests.process(
                transcriptPath: transcriptPath,
                audioPath: entry.relativePath,
                in: workspace,
                model: model
            )
        }
    }
}

/// Вложение в ленте чата: состояние, короткая выжимка и действия.
///
/// Нарочно компактная и без своей прокрутки: читать целиком — в карточке записи
/// или в заметке, а здесь важно видеть, что файл дошёл и что с ним стало.
struct ChatAttachmentCard: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var digests: DigestService
    @ObservedObject var transcription: TranscriptionService
    @AppStorage("deepSeekModel") private var model = DeepSeekModel.fallback.rawValue

    let path: String
    let title: String
    /// Открыть файл: аудио — карточкой записи, текст — редактором.
    let open: (WorkspaceEntry) -> Void

    @State private var entry: WorkspaceEntry?
    @State private var transcriptPath: String?
    @State private var digestPath: String?
    @State private var digestTitle: String?
    @State private var theme: String?
    @State private var preview: String?

    private var isTranscribing: Bool { entry.map { transcription.isRunning($0.relativePath) } ?? false }
    private var isProcessing: Bool { transcriptPath.map { digests.isRunning($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // Пока идёт расшифровка — кольцо с настоящей долей работы (вариант 1Б).
                // В остальное время иконка: рисовать кольцо без прогресса незачем.
                if isTranscribing {
                    ProgressRing(fraction: entry.flatMap { transcription.progressFraction(for: $0.relativePath) })
                        .frame(width: 38, height: 38)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(LoriPalette.lime)
                        .frame(width: 38, height: 38)
                        .background(LoriPalette.limeSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(digestTitle ?? title)
                        .font(LoriFont.cardTitle)
                        .foregroundStyle(LoriPalette.ink)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                    // Обработка идёт одним запросом: доли нет, поэтому вместо процентов
                    // строка с бегущим блеском — она не обещает того, чего не знает.
                    if isProcessing {
                        ShimmerLabel(text: state)
                    } else {
                        Text(state)
                            .font(LoriFont.small)
                            .foregroundStyle(LoriPalette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            // Текст проявляется строками (вариант 4В): в переписке видно начало,
            // читать целиком — в карточке записи.
            if let preview {
                RevealedLines(text: preview)
                    .id(preview)
            }

            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(LoriPalette.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.3), value: isTranscribing)
        .animation(.easeOut(duration: 0.3), value: isProcessing)
        .task { reload() }
        .onChange(of: isTranscribing) { _, running in if !running { reload() } }
        .onChange(of: isProcessing) { _, running in if !running { reload() } }
    }

    private var symbol: String {
        guard let entry else { return "doc" }
        return entry.isAudio ? "waveform" : "doc.text"
    }

    private var state: String {
        if entry == nil { return "файла больше нет" }
        if isTranscribing { return "Расшифровываю…" }
        if isProcessing { return "Собираю «Важное»…" }
        if let theme { return "Важное готово · \(theme)" }
        // Подсказку «нажмите, чтобы открыть» не пишем: об этом говорит сама кнопка,
        // а в одну строку подпись не влезала и обрывалась посреди слова.
        if transcriptPath != nil { return "Расшифровка готова" }
        if let entry, entry.isAudio { return "Запись без расшифровки" }
        return path
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if let entry {
                Button { open(entry) } label: {
                    pill(digestPath != nil || !entry.isAudio ? "Открыть" : "Открыть запись", filled: false)
                }
                .buttonStyle(.plain)
            }
            if transcriptPath != nil, digestPath == nil, !isProcessing, digests.hasKey {
                Button(action: process) {
                    pill("Обработать", filled: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func pill(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(LoriFont.small.weight(.semibold))
            .foregroundStyle(filled ? .white : LoriPalette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                filled ? AnyShapeStyle(LoriPalette.ink.opacity(0.84)) : AnyShapeStyle(Color.white.opacity(0.9)),
                in: Capsule()
            )
            .overlay(Capsule().stroke(filled ? Color.clear : LoriPalette.line, lineWidth: 1))
    }

    private func process() {
        guard let entry, let transcriptPath else { return }
        digests.lastError = nil
        Task {
            await digests.process(
                transcriptPath: transcriptPath,
                audioPath: entry.relativePath,
                in: workspace,
                model: model
            )
            reload()
        }
    }

    private func reload() {
        entry = try? workspace.entry(at: path)
        guard let entry else {
            transcriptPath = nil
            digestPath = nil
            preview = nil
            return
        }

        transcriptPath = entry.isAudio ? workspace.existingTranscript(for: entry) : nil
        digestPath = digests.digestPath(for: entry.relativePath, in: workspace)

        if let digestPath, let note = try? workspace.readText(at: digestPath) {
            let meta = NoteMeta.parse(note)
            theme = meta.theme
            let body = NoteMeta.body(of: note)
            digestTitle = WikiIndex.title(of: body, fallback: title)
            preview = summary(of: body)
            return
        }

        theme = nil
        digestTitle = nil
        if let transcriptPath, let raw = try? workspace.readText(at: transcriptPath) {
            preview = TranscriptReadability.plainText(fromMarkdown: raw)
        } else if !entry.isAudio, let text = try? workspace.readText(at: entry.relativePath) {
            preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            preview = nil
        }
    }

    /// Первый абзац выжимки: заголовок уже стоит в шапке карточки.
    private func summary(of body: String) -> String? {
        body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.hasPrefix("#") && !$0.hasPrefix("-") }
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}
