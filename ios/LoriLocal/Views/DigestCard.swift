import SwiftUI

/// Блок обработанной заметки. Разметка у выжимки своя и очень простая,
/// поэтому рисуем её сами: `Text(markdown:)` не умеет ни списков, ни заголовков.
private enum DigestBlock: Identifiable {
    case title(String)
    case section(String)
    case bullet(String)
    case task(String)
    case paragraph(String)

    var id: String {
        switch self {
        case let .title(text): "t\(text)"
        case let .section(text): "s\(text)"
        case let .bullet(text): "b\(text)"
        case let .task(text): "k\(text)"
        case let .paragraph(text): "p\(text)"
        }
    }

    static func blocks(from body: String) -> [DigestBlock] {
        body.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("## ") { return .section(String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .title(String(line.dropFirst(2))) }
            if line.hasPrefix("- [ ] ") { return .task(String(line.dropFirst(6))) }
            if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") { return .task(String(line.dropFirst(6))) }
            if line.hasPrefix("- ") { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }
}

/// Карточка текста записи: сверху переключатель «Важное ↔ Расшифровка», снизу одно действие.
///
/// «Важное» — обработанная заметка из тематической папки. Пока обработки нет, там лежит
/// та же расшифровка, разбитая на абзацы локально: показывать пустой экран, когда текст
/// уже есть, значит прятать от человека его собственную запись.
struct TranscriptCard: View {
    enum Mode: String, CaseIterable, Identifiable {
        case important
        case verbatim

        var id: String { rawValue }
        var title: String {
            switch self {
            case .important: "Важное"
            case .verbatim: "Расшифровка"
            }
        }
    }

    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var digests: DigestService
    @ObservedObject var transcription: TranscriptionService
    @AppStorage("deepSeekModel") private var model = DeepSeekModel.fallback.rawValue
    @AppStorage("autoProcessTranscripts") private var autoProcess = true

    let entry: WorkspaceEntry
    /// Открыть файл в редакторе. Проигрыватель гасит звук сам, до вызова.
    let openFile: (String) -> Void

    @State private var mode: Mode = .important
    @State private var transcriptPath: String?
    @State private var verbatim = ""
    @State private var digestPath: String?
    @State private var digestBlocks: [DigestBlock] = []
    @State private var theme: String?

    private var isTranscribing: Bool { transcription.isRunning(entry.relativePath) }
    private var isProcessing: Bool { transcriptPath.map { digests.isRunning($0) } ?? false }
    private var hasTranscript: Bool { !verbatim.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(LoriPalette.line)
                .frame(height: 1)

            if hasTranscript {
                Picker("Вид", selection: $mode) {
                    ForEach(Mode.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            content
                .frame(maxHeight: .infinity, alignment: .top)

            action
                .padding(.horizontal, 17)
                .padding(.bottom, 10)
        }
        .task { reload() }
        .onChange(of: isTranscribing) { _, running in
            guard !running else { return }
            reload()
            processIfPossible(automatic: true)
        }
        .onChange(of: isProcessing) { _, running in
            guard !running else { return }
            reload()
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hasTranscript {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(isTranscribing ? "Текст появится здесь." : "Расшифровки пока нет.")
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.muted)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch mode {
                    case .important:
                        if digestBlocks.isEmpty {
                            Text("Обработки пока нет — это дословный текст, разбитый на абзацы.")
                                .font(LoriFont.small)
                                .foregroundStyle(LoriPalette.muted)
                                .padding(.bottom, 12)
                            plainText(TranscriptReadability.readable(fromMarkdown: verbatim))
                        } else {
                            digestBody
                        }
                    case .verbatim:
                        plainText(TranscriptReadability.plainText(fromMarkdown: verbatim))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func plainText(_ text: String) -> some View {
        Text(text)
            .font(LoriFont.body)
            .foregroundStyle(LoriPalette.ink)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var digestBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(digestBlocks) { block in
                switch block {
                case let .title(text):
                    Text(text)
                        .font(LoriFont.displaySmall)
                        .foregroundStyle(LoriPalette.ink)
                        .padding(.bottom, 8)
                        // Опознаватель для теста: заголовок придумывает модель,
                        // и по тексту его не найти.
                        .accessibilityIdentifier("digestTitle")
                case let .section(text):
                    Text(text)
                        .font(LoriFont.section)
                        .foregroundStyle(LoriPalette.muted)
                        .padding(.top, 18)
                        .padding(.bottom, 6)
                case let .bullet(text):
                    bulletRow(text, symbol: "circle.fill", size: 6)
                case let .task(text):
                    bulletRow(text, symbol: "square", size: 13)
                case let .paragraph(text):
                    Text(MarkdownBlock.inline(text))
                        .font(LoriFont.body)
                        .foregroundStyle(LoriPalette.ink)
                        .lineSpacing(4)
                        .padding(.bottom, 4)
                }
            }
            if let theme {
                Label("Тема · \(theme)", systemImage: "folder")
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
                    .padding(.top, 20)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletRow(_ text: String, symbol: String, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(LoriPalette.lime)
                .frame(width: 14, alignment: .center)
            Text(MarkdownBlock.inline(text))
                .font(LoriFont.body)
                .foregroundStyle(LoriPalette.ink)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var action: some View {
        if isTranscribing {
            progress(transcription.progressText(for: entry.relativePath).map { "Расшифровываю… \($0)" } ?? "Расшифровываю…")
        } else if isProcessing {
            progress("Обрабатываю…")
        } else if let digestPath {
            Button {
                openFile(digestPath)
            } label: {
                pill("Открыть заметку", symbol: "doc.text", filled: false)
            }
            .buttonStyle(.plain)
        } else if hasTranscript {
            VStack(spacing: 8) {
                Button { processIfPossible() } label: {
                    pill("Обработать", symbol: "sparkles", filled: true)
                }
                .buttonStyle(.plain)
                if let error = digests.lastError {
                    Text(error)
                        .font(LoriFont.small)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else if !digests.hasKey {
                    Text("Обработка идёт через модель из настроек — добавь её ключ.")
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.muted)
                        .multilineTextAlignment(.center)
                }
            }
        } else {
            Button {
                Task {
                    guard await transcription.transcribe(entry, in: workspace) != nil else { return }
                    reload()
                    processIfPossible(automatic: true)
                }
            } label: {
                pill("Расшифровать", symbol: "waveform.badge.magnifyingglass", filled: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(LoriFont.meta)
        .foregroundStyle(LoriPalette.muted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func pill(_ title: String, symbol: String, filled: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(LoriFont.control)
            .foregroundStyle(filled ? .white : LoriPalette.ink)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                filled ? AnyShapeStyle(LoriPalette.ink.opacity(0.84)) : AnyShapeStyle(Color.white.opacity(0.9)),
                in: Capsule()
            )
            .overlay(Capsule().stroke(filled ? Color.clear : LoriPalette.line, lineWidth: 1))
    }

    private func processIfPossible(automatic: Bool = false) {
        guard let transcriptPath else { return }
        guard DigestService.shouldProcess(
            automatic: automatic,
            autoEnabled: autoProcess,
            hasTranscript: !verbatim.isEmpty,
            hasDigest: digestPath != nil,
            hasKey: digests.hasKey,
            isRunning: digests.isRunning(transcriptPath)
        ) else { return }
        digests.lastError = nil
        Task {
            guard await digests.process(
                transcriptPath: transcriptPath,
                audioPath: entry.relativePath,
                in: workspace,
                model: model
            ) != nil else { return }
            reload()
            mode = .important
        }
    }

    private func reload() {
        transcriptPath = workspace.existingTranscript(for: entry)
        if let transcriptPath, let raw = try? workspace.readText(at: transcriptPath) {
            verbatim = raw
        } else {
            verbatim = ""
        }

        digestPath = digests.digestPath(for: entry.relativePath, in: workspace)
        guard let digestPath, let note = try? workspace.readText(at: digestPath) else {
            digestBlocks = []
            theme = nil
            return
        }
        digestBlocks = DigestBlock.blocks(from: NoteMeta.body(of: note))
        theme = NoteMeta.parse(note).theme
    }
}
