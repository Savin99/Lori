import SwiftUI

/// Заголовки: локальная модель, которая по расшифровке придумывает название и
/// краткое описание. Веса скачиваются по желанию — без них всё работает как раньше.
struct SummaryScreen: View {
    @EnvironmentObject private var runner: SummaryRunner
    @ObservedObject var models: SummaryModelStore

    var body: some View {
        List {
            Section {
                ForEach(SummaryVariant.allCases) { variant in
                    row(variant)
                }
            } header: {
                Text("Модель")
            } footer: {
                Text(
                    "Заголовок и описание считаются на телефоне, текст никуда не уходит. "
                    + "Крупная модель формулирует лучше, но памяти ей нужно почти столько, "
                    + "сколько iOS вообще даёт приложению: если её не хватит, Lori возьмёт лёгкую. "
                    + "Имя, которое вы задали руками, модель не трогает."
                )
            }

            if let reason = runner.waitingReason {
                Section("Автоматические заголовки") { Text(reason) }
            }
            if let failure = runner.failure {
                Section("Генерация") { Text(failure).foregroundStyle(LoriPalette.danger) }
            }
            if let failure = models.failure {
                Section("Не получилось") {
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
        .onAppear { models.refresh() }
    }

    @ViewBuilder
    private func row(_ variant: SummaryVariant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
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

            if models.downloading == variant {
                ProgressView(value: models.fraction)
                    .tint(LoriPalette.lime)
                Button("Отменить") { models.cancel() }
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("summaryModel.\(variant.rawValue)")
    }

    @ViewBuilder
    private func action(_ variant: SummaryVariant) -> some View {
        if models.isInstalled(variant) {
            Button("Удалить", role: .destructive) { models.delete(variant) }
                .font(LoriFont.small)
        } else if models.downloading == variant {
            Text("\(Int(models.fraction * 100))%")
                .font(LoriFont.small.monospacedDigit())
                .foregroundStyle(LoriPalette.muted)
        } else {
            Button("Скачать") { models.download(variant) }
                .font(LoriFont.small)
                .disabled(models.downloading != nil)
        }
    }
}
