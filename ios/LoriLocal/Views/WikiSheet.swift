import SwiftUI

/// Вики: темы, теги и связи между заметками.
///
/// Отдельного хранилища у вики нет — она пересобирается из файлов на открытие.
/// Так её нельзя расстроить с реальностью, а связи человек правит прямо в тексте
/// заметки, ставя `[[имя другой заметки]]`.
struct WikiSheet: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    /// Открыть заметку в редакторе. Лист вики при этом закрывается.
    let openNote: (String) -> Void

    @State private var index = WikiIndex.empty

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if index.notes.isEmpty {
                        Text("Заметок пока нет — вики соберётся из них сама.")
                            .font(LoriFont.meta)
                            .foregroundStyle(LoriPalette.muted)
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                    } else {
                        topics("Темы", items: index.themes, symbol: "folder.fill") { theme in
                            WikiTopicView(
                                title: theme.name,
                                notes: index.notes(inTheme: theme.name),
                                index: index,
                                openNote: open
                            )
                        }
                        topics("Теги", items: index.tags, symbol: "number") { tag in
                            WikiTopicView(
                                title: "#\(tag.name)",
                                notes: index.notes(withTag: tag.name),
                                index: index,
                                openNote: open
                            )
                        }
                        allNotes
                    }

                    Color.clear.frame(height: 24)
                }
            }
            .scrollIndicators(.hidden)
            .background(LoriPalette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .recordingBanner { dismiss() }
        .task { index = WikiIndex.build(workspace) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Вики")
                .font(LoriFont.display)
                .foregroundStyle(LoriPalette.ink)
            Text("\(LoriFormat.noteCount(index.notes.count)) · темы, теги и связи")
                .font(LoriFont.meta)
                .foregroundStyle(LoriPalette.muted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private func topics<Destination: View>(
        _ title: String,
        items: [WikiTopic],
        symbol: String,
        destination: @escaping (WikiTopic) -> Destination
    ) -> some View {
        if !items.isEmpty {
            SectionHeader(title)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    NavigationLink { destination(item) } label: {
                        WikiRow(
                            title: item.name,
                            detail: LoriFormat.noteCount(item.count),
                            symbol: symbol
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var allNotes: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Все заметки")
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(index.notes) { note in
                    NavigationLink {
                        WikiNoteView(note: note, index: index, openNote: open)
                    } label: {
                        WikiRow(
                            title: note.title,
                            detail: detail(for: note),
                            symbol: "doc.text"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func detail(for note: WikiNote) -> String {
        var parts: [String] = []
        if let theme = note.theme { parts.append(theme) }
        let connections = note.links.count + index.backlinks(to: note).count
        if connections > 0 {
            parts.append(LoriFormat.plural(connections, one: "связь", few: "связи", many: "связей"))
        }
        return parts.isEmpty ? "в корне" : parts.joined(separator: " · ")
    }

    private func open(_ path: String) {
        dismiss()
        openNote(path)
    }
}

/// Заметки одной темы или тега.
private struct WikiTopicView: View {
    let title: String
    let notes: [WikiNote]
    let index: WikiIndex
    let openNote: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(notes) { note in
                    NavigationLink {
                        WikiNoteView(note: note, index: index, openNote: openNote)
                    } label: {
                        WikiRow(
                            title: note.title,
                            detail: note.tags.isEmpty ? note.path : note.tags.map { "#\($0)" }.joined(separator: " "),
                            symbol: "doc.text"
                        )
                    }
                    .buttonStyle(.plain)
                }
                Color.clear.frame(height: 24)
            }
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .background(LoriPalette.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Страница вики для одной заметки: теги, куда ссылается и кто ссылается сюда.
private struct WikiNoteView: View {
    let note: WikiNote
    let index: WikiIndex
    let openNote: (String) -> Void

    private var backlinks: [WikiNote] { index.backlinks(to: note) }
    private var outgoing: [WikiNote] { note.links.compactMap { index.resolve(link: $0) } }
    private var missing: [String] { index.unresolvedLinks(from: note) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title)
                        .font(LoriFont.displaySmall)
                        .foregroundStyle(LoriPalette.ink)
                    Text(note.path)
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.muted)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)

                if !note.tags.isEmpty {
                    Text(note.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(LoriFont.meta)
                        .foregroundStyle(LoriPalette.lime)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                Button { openNote(note.path) } label: {
                    Label("Открыть заметку", systemImage: "doc.text")
                        .font(LoriFont.control)
                        .foregroundStyle(LoriPalette.ink)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.9), in: Capsule())
                        .overlay(Capsule().stroke(LoriPalette.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 17)
                .padding(.top, 18)

                links("Ссылается на", notes: outgoing)
                links("Ссылаются сюда", notes: backlinks)

                if !missing.isEmpty {
                    SectionHeader("Ссылки без заметки")
                    ForEach(missing, id: \.self) { name in
                        WikiRow(title: name, detail: "заметки ещё нет", symbol: "link.badge.plus")
                    }
                }

                if outgoing.isEmpty, backlinks.isEmpty, missing.isEmpty {
                    Text("Связей пока нет. Поставь в тексте заметки [[имя другой заметки]] — связь появится здесь.")
                        .font(LoriFont.meta)
                        .foregroundStyle(LoriPalette.muted)
                        .padding(.horizontal, 20)
                        .padding(.top, 22)
                }

                Color.clear.frame(height: 24)
            }
        }
        .scrollIndicators(.hidden)
        .background(LoriPalette.canvas)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func links(_ title: String, notes: [WikiNote]) -> some View {
        if !notes.isEmpty {
            SectionHeader(title)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(notes) { linked in
                    NavigationLink {
                        WikiNoteView(note: linked, index: index, openNote: openNote)
                    } label: {
                        WikiRow(title: linked.title, detail: linked.path, symbol: "arrow.turn.down.right")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Заголовок раздела с волосяной линией — как в остальных экранах Lori.
private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(LoriPalette.line)
                .frame(height: 1)
            Text(title)
                .font(LoriFont.section)
                .foregroundStyle(LoriPalette.muted)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
        }
        .padding(.top, 14)
    }
}

/// Строка вики. Без рамки и фона: по правилу проекта обведён только ввод,
/// глубина — волоском и весом текста.
private struct WikiRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LoriPalette.lime)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LoriFont.cardTitle)
                    .foregroundStyle(LoriPalette.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LoriPalette.muted.opacity(0.6))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
