import SwiftUI

/// Карточки утверждённого макета; отметки сохраняются атомарно в хранилище.
struct RecordingNote: View {
    @EnvironmentObject private var store: RecordingSummaryStore
    @EnvironmentObject private var speakers: SpeakerNames
    let path: String
    let entry: RecordingSummaryStore.Entry
    let refreshing: Bool
    let refresh: () -> Void
    @State private var saveFailed = false
    @ScaledMetric(relativeTo: .body) private var leading: CGFloat = 5
    @ScaledMetric(relativeTo: .footnote) private var providerMarkSize: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !entry.summary.brief.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { briefLabel; Spacer(minLength: 0); provenance }
                        VStack(alignment: .leading, spacing: 6) { briefLabel; provenance }
                    }
                    Text(entry.summary.brief)
                        .recordingFont(18).lineSpacing(leading)
                        .foregroundStyle(LoriPalette.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 20)
                .recordingCard()
            }
            section("Главное", items: entry.summary.highlights, icon: "circle.fill", color: LoriPalette.muted)
            section("Решения", items: entry.summary.decisions, icon: "checkmark.circle", color: LoriPalette.lime)
            let tasks = entry.summary.tasks.filter { !$0.text.isEmpty }
            if !tasks.isEmpty {
                heading("Задачи", count: "\(tasks.filter { entry.completedTasks.contains($0.text) }.count) из \(tasks.count) сделано")
                VStack(spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                        if index > 0 { separator }
                        taskRow(task, index: index)
                    }
                }.recordingCard()
            }
            section("Открытые вопросы", items: entry.summary.openQuestions, icon: "questionmark.circle", color: LoriPalette.warn)
            if saveFailed {
                Text("Не удалось сохранить отметку. Попробуй ещё раз.")
                    .recordingFont(13, relativeTo: .footnote).foregroundStyle(LoriPalette.danger).padding(.top, 12)
            }
            HStack {
                Spacer(minLength: 0)
                Button(action: refresh) {
                    Label(refreshing ? "Готовлю итог…" : "Обновить итог", systemImage: "arrow.clockwise")
                        .recordingFont(14, weight: .semibold, relativeTo: .subheadline).frame(minHeight: 44)
                }
                .buttonStyle(.plain).foregroundStyle(LoriPalette.lime).disabled(refreshing)
                .accessibilityIdentifier("makeRecordingSummary")
                Spacer(minLength: 0)
            }.padding(.top, 18)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordingNote")
    }

    private var briefLabel: some View {
        HStack(spacing: 8) {
            // Владелец: показывать бренд модели, которая сделала итог, вместо
            // общей AI-искры. Структурированный итог сейчас создаёт только Gemini.
            Image("GeminiMark").renderingMode(.template).resizable().scaledToFit()
                .foregroundStyle(LoriPalette.lime)
                .frame(width: providerMarkSize, height: providerMarkSize)
                .accessibilityHidden(true)
            Text("Суть записи").recordingFont(13, relativeTo: .footnote).foregroundStyle(LoriPalette.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Суть записи")
    }

    private var provenance: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text("Gemini · " + (entry.stale ? "текст менялся" : LoriFormat.ago(entry.createdAt, now: context.date)))
                .recordingFont(13, relativeTo: .footnote).foregroundStyle(LoriPalette.muted)
        }
    }
    private func heading(_ title: String, count: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { sectionTitle(title); Spacer(minLength: 8); counter(count) }
            VStack(alignment: .leading, spacing: 4) { sectionTitle(title); counter(count) }
        }.padding(.horizontal, 2).padding(.top, 26).padding(.bottom, 10)
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(LoriFont.noteSection).foregroundStyle(LoriPalette.ink).accessibilityAddTraits(.isHeader)
    }
    private func counter(_ value: String) -> some View {
        Text(value).recordingFont(13, relativeTo: .footnote).foregroundStyle(LoriPalette.tertiary)
    }
    private var separator: some View { Rectangle().fill(LoriPalette.line).frame(height: 1).accessibilityHidden(true) }

    @ViewBuilder private func section(_ title: String, items: [String], icon: String, color: Color) -> some View {
        let nonempty = items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !nonempty.isEmpty {
            heading(title, count: "\(nonempty.count)")
            VStack(spacing: 0) {
                ForEach(Array(nonempty.enumerated()), id: \.offset) { index, item in
                    if index > 0 { separator }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon).font(.system(size: icon == "circle.fill" ? 5 : 20))
                            .foregroundStyle(color).frame(width: 20, height: 23).accessibilityHidden(true)
                        Text(item).recordingFont(16).lineSpacing(4)
                            .foregroundStyle(LoriPalette.ink).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.horizontal, 16).padding(.vertical, 14)
                }
            }.recordingCard()
        }
    }

    private func taskRow(_ task: SummaryTask, index: Int) -> some View {
        let checked = entry.completedTasks.contains(task.text)
        return Button { saveFailed = !store.toggleTask(task.text, for: path) } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(checked ? LoriPalette.lime : .clear)
                    Circle().strokeBorder(checked ? .clear : LoriPalette.tertiary.opacity(0.7), lineWidth: 1.6)
                    if checked { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(LoriPalette.onInk) }
                }.frame(width: 24, height: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.text).strikethrough(checked)
                        .recordingFont(16).lineSpacing(4)
                        .foregroundStyle(checked ? LoriPalette.tertiary : LoriPalette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if task.owner != nil || task.due != nil {
                        RecordingFlow(spacing: 8) {
                            if let owner = task.owner {
                                let label = speakers.names[path]?.first(where: { $0.value == owner })?.key ?? owner
                                let name = speakers.name(of: label, in: path)
                                HStack(spacing: 6) {
                                    RecordingAvatar(label: label, name: name, size: 20)
                                    Text(name).recordingFont(13, relativeTo: .footnote).foregroundStyle(LoriPalette.muted)
                                }
                            }
                            if let due = task.due {
                                Text(due).recordingFont(12, weight: .medium, relativeTo: .caption).foregroundStyle(LoriPalette.warn)
                                    .padding(.horizontal, 8).frame(minHeight: 22)
                                    .background(LoriPalette.warn.opacity(0.14), in: Capsule())
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(minHeight: 44, alignment: .topLeading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.displayText)
        .accessibilityValue(checked ? "Выполнено" : "Не выполнено")
        .accessibilityHint(checked ? "Снять отметку" : "Отметить выполненной")
        .accessibilityIdentifier("summaryTask.\(index)")
    }
}
