import SwiftUI

/// Заголовки: локальная модель, которая по расшифровке придумывает название и
/// краткое описание. Веса скачиваются по желанию — без них заголовком служит
/// первая фраза записи.
///
/// Экран отвечает на три вопроса и даёт одно главное действие: что это делает,
/// в каком состоянии модель, что нажать. Раньше тут стояли две равные строки
/// «Крупная» и «Лёгкая» с кнопками «Скачать», и выбирать между ними человеку
/// было не по чему; теперь одна кнопка — для модели, которая подходит телефону
/// (`SummaryModelStore.recommendedVariant`), вторая модель — запасным выбором.
struct SummaryScreen: View {
    @EnvironmentObject private var runner: SummaryRunner
    @ObservedObject var models: SummaryModelStore
    @State private var pendingDelete: SummaryVariant?

    private var recommended: SummaryVariant { models.recommendedVariant }
    private var alternative: SummaryVariant { recommended == .heavy ? .light : .heavy }
    private var installed: [SummaryVariant] { SummaryVariant.allCases.filter(models.installed.contains) }

    var body: some View {
        List {
            Section {
                Text("Lori придумывает каждой записи короткий заголовок и описание. Модель работает на этом iPhone — текст никуда не уходит.")
                    .font(LoriFont.body)
                    .foregroundStyle(LoriPalette.ink)
                    .padding(.vertical, 2)
            }

            Section {
                status
                if models.downloading == nil, installed.isEmpty {
                    primaryDownload
                }
            } header: {
                Text("Модель")
            } footer: {
                if installed.isEmpty {
                    Text("\(recommended.recommendation) Около \(recommended.sizeLabel) — лучше скачивать по Wi‑Fi.")
                }
            }

            Section {
                if installed.isEmpty {
                    row(alternative)
                } else {
                    ForEach(SummaryVariant.allCases) { row($0) }
                }
            } header: {
                Text(installed.isEmpty ? "Другая модель" : "Скачанные и доступные")
            } footer: {
                Text("Имя, заданное руками, модель не трогает. Если памяти мало, Lori возьмёт лёгкую модель, когда скачаны обе.")
            }

            if models.isReady { activity }

            if let failure = runner.failure {
                Section("Не получилось придумать") {
                    Text(failure).foregroundStyle(LoriPalette.danger)
                }
            }
            if let failure = models.failure {
                Section("Не получилось скачать") {
                    Text(failure)
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.danger)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Заголовки")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(LoriPalette.canvas)
        .onAppear {
            models.refresh()
            runner.refreshBacklog()
        }
        .confirmationDialog(
            "Удалить модель?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { variant in
            Button("Удалить \(variant.accusative)", role: .destructive) { models.delete(variant) }
        } message: { variant in
            Text(installed.count > 1
                 ? "Освободится около \(variant.sizeLabel). Заголовки будет придумывать вторая модель."
                 : "Освободится около \(variant.sizeLabel). Без модели заголовком снова станет первая фраза записи; скачать её можно в любой момент.")
        }
    }

    // MARK: - Состояние

    @ViewBuilder
    private var status: some View {
        if let variant = models.downloading {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Скачивается \(variant.accusative)")
                        .font(LoriFont.control)
                        .foregroundStyle(LoriPalette.ink)
                    Spacer(minLength: 8)
                    Text("\(Int(models.fraction * 100))%")
                        .font(LoriFont.small.monospacedDigit())
                        .foregroundStyle(LoriPalette.muted)
                }
                ProgressView(value: models.fraction)
                    .tint(LoriPalette.lime)
                Button("Отменить") { models.cancel() }
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("summaryStatus")
        } else if let ready = installed.first {
            statusLine(
                symbol: "checkmark.circle.fill",
                color: LoriPalette.lime,
                title: "Готова · \(ready.title)",
                detail: "Заголовок и описание появляются после расшифровки, пока Lori открыта."
            )
        } else {
            statusLine(
                symbol: "arrow.down.circle",
                color: LoriPalette.muted,
                title: "Не скачана",
                detail: "Пока заголовок — первая фраза записи."
            )
        }
    }

    private func statusLine(symbol: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(LoriFont.control)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LoriFont.control)
                    .foregroundStyle(LoriPalette.ink)
                Text(detail)
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("summaryStatus")
    }

    /// Одна главная кнопка — та же капсула, что «Расшифровать» на экране записи.
    private var primaryDownload: some View {
        Button { models.download(recommended) } label: {
            Text("Скачать · \(recommended.sizeLabel)")
                .font(LoriFont.control)
                .foregroundStyle(LoriPalette.onInk)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(LoriPalette.lime, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Скачать \(recommended.accusative), \(recommended.sizeLabel)")
        .accessibilityIdentifier("summaryDownload")
    }

    // MARK: - Модели

    @ViewBuilder
    private func row(_ variant: SummaryVariant) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(variant.title)
                    .font(LoriFont.control)
                    .foregroundStyle(LoriPalette.ink)
                Text(variant.detail)
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
            }
            Spacer(minLength: 8)
            action(variant)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("summaryModel.\(variant.rawValue)")
    }

    @ViewBuilder
    private func action(_ variant: SummaryVariant) -> some View {
        if models.installed.contains(variant) {
            Button("Удалить", role: .destructive) { pendingDelete = variant }
                .font(LoriFont.small)
        } else if models.downloading == variant {
            Text("\(Int(models.fraction * 100))%")
                .font(LoriFont.small.monospacedDigit())
                .foregroundStyle(LoriPalette.muted)
        } else {
            Button("Скачать · \(variant.sizeLabel)") { models.download(variant) }
                .font(LoriFont.small)
                .disabled(models.downloading != nil)
        }
    }

    // MARK: - Работа

    /// Что модель делает сейчас и что можно попросить.
    @ViewBuilder
    private var activity: some View {
        Section("Записи") {
            if runner.running != nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Придумываю заголовки · осталось \(runner.pendingCount)")
                        .font(LoriFont.meta)
                        .foregroundStyle(LoriPalette.ink)
                }
            } else if runner.pendingCount > 0 {
                Text(runner.waitingReason ?? "В очереди: \(runner.pendingCount)")
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.muted)
            }
            if runner.backlogCount > 0 {
                Button {
                    runner.summarizeBacklog()
                } label: {
                    Label(
                        "Придумать для \(LoriFormat.plural(runner.backlogCount, one: "записи", few: "записей", many: "записей"))",
                        systemImage: "text.quote"
                    )
                }
                .accessibilityIdentifier("summaryBacklog")
            } else if runner.running == nil, runner.pendingCount == 0 {
                Text("Новые записи получают заголовок сами, сразу после расшифровки.")
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.muted)
            }
        }
    }
}
