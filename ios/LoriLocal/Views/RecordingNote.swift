import SwiftUI

/// Итог читается как заметка; отметки — в хранилище, а не в состоянии экрана.
struct RecordingNote: View {
    @EnvironmentObject private var store: RecordingSummaryStore
    let path: String
    let entry: RecordingSummaryStore.Entry
    let refreshing: Bool
    let refresh: () -> Void
    @State private var saveFailed = false
    @ScaledMetric(relativeTo: .body) private var leading: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !entry.summary.brief.isEmpty {
                Text(entry.summary.brief)
                    .font(LoriFont.body).lineSpacing(leading)
                    .foregroundStyle(LoriPalette.ink)
                    .textSelection(.enabled)
            }
            section("Главное", items: entry.summary.highlights)
            section("Решения", items: entry.summary.decisions)
            let tasks = entry.summary.tasks.filter { !$0.text.isEmpty }
            if !tasks.isEmpty {
                heading("Задачи")
                ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                    let checked = entry.completedTasks.contains(task.text)
                    Button {
                        saveFailed = !store.toggleTask(task.text, for: path)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(checked ? LoriPalette.lime : LoriPalette.muted)
                                .frame(width: 22).padding(.top, 3)
                            (Text(task.text).foregroundColor(checked ? LoriPalette.muted : LoriPalette.ink)
                             + Text(task.attribution.map { " " + $0 } ?? "").foregroundColor(LoriPalette.muted))
                                .strikethrough(checked)
                                .font(LoriFont.body).lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 44, alignment: .topLeading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(task.displayText)
                    .accessibilityValue(checked ? "Выполнено" : "Не выполнено")
                    .accessibilityHint("Отметить задачу")
                    .accessibilityIdentifier("summaryTask.\(index)")
                    .padding(.bottom, 8)
                }
            }
            section("Открытые вопросы", items: entry.summary.openQuestions, color: LoriPalette.accentAlt)
            if saveFailed {
                Text("Не удалось сохранить отметку. Попробуй ещё раз.")
                    .font(LoriFont.small).foregroundStyle(LoriPalette.danger)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { provenance(now: context.date); refreshButton }
                    VStack(alignment: .leading, spacing: 4) { provenance(now: context.date); refreshButton }
                }
            }
            .padding(.top, 22)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recordingNote")
    }

    private func provenance(now: Date) -> some View {
        Text("Итог Gemini по подписке · " + (entry.stale ? "текст менялся" : LoriFormat.ago(entry.createdAt, now: now)) + " ·")
            .font(LoriFont.small).foregroundStyle(LoriPalette.muted)
    }
    private var refreshButton: some View {
        Button(refreshing ? "Готовлю итог…" : "Обновить", action: refresh)
            .font(LoriFont.small.weight(.semibold)).foregroundStyle(LoriPalette.lime)
            .frame(minHeight: 44)
            .disabled(refreshing)
            .accessibilityIdentifier("makeRecordingSummary")
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(LoriFont.noteSection).foregroundStyle(LoriPalette.ink)
            .accessibilityAddTraits(.isHeader).padding(.top, 26).padding(.bottom, 10)
    }
    @ViewBuilder private func section(_ title: String, items: [String], color: Color = LoriPalette.ink) -> some View {
        let nonempty = items.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !nonempty.isEmpty {
            heading(title)
            ForEach(Array(nonempty.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(color).frame(width: 5, height: 5).frame(width: 22).padding(.top, 11)
                    Text(item).font(LoriFont.body).lineSpacing(4).foregroundStyle(LoriPalette.ink)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.bottom, 8)
            }
        }
    }
}
