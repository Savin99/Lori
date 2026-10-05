import SwiftUI

// MARK: - Карточка записи

/// Карточка записи: что это (заголовок), что внутри (описание), что с ней
/// (строка состояния — только когда запись не готова), когда и сколько длится.
///
/// Иконки-плашки слева больше нет: она одинакова у всех карточек и ничего не
/// различает, а заголовку отдаёт ширину. Даты на карточке тоже нет — она в
/// заголовке дня над карточками; здесь только время и длительность.
struct RecordingCard: View {
    let title: String
    let detail: String?
    /// «14:20»
    let time: String
    /// «24:10»; nil — длительность ещё читается.
    let duration: String?
    let topic: String?
    /// Запись без темы в общем списке. Это инбокс разбора: пометка нужна,
    /// чтобы такие записи не терялись среди разложенных.
    let needsTopic: Bool
    let status: RecordStatus?
    let perform: (RecordStatus.Action) -> Void

    var body: some View {
        info
            // Кнопка действия — поверх строки состояния, а не внутри неё: внутри
            // она слилась бы с текстом карточки в один элемент VoiceOver и
            // потерялась бы для UI-теста. Место под неё держит невидимая копия.
            .overlay(alignment: Alignment(horizontal: .trailing, vertical: .cardStatus)) {
                if let action = status?.action {
                    CardActionButton(action: action, record: title) { perform(action) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(LoriPalette.line, lineWidth: 1))
            .contentShape(Rectangle())
            // Превью долгого нажатия — сама карточка, а не прямоугольник строки
            // с кремовыми полями вокруг неё.
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(LoriFont.cardTitle)
                .foregroundStyle(LoriPalette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let detail {
                Text(Self.sentence(detail))
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            if let status {
                StatusRow(status: status, record: title)
                    .alignmentGuide(.cardStatus) { $0[VerticalAlignment.center] }
            }

            meta
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("recordingCard")
    }

    /// Описание — отдельная строка, и начинается она с заглавной. Продолжение
    /// первой фразы после двоеточия («Созвон с дизайнером: убираем иконки…»)
    /// иначе стояло бы со строчной и читалось как обрывок.
    static func sentence(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private var meta: some View {
        HStack(spacing: 8) {
            Text(duration.map { "\(time) · \($0)" } ?? time)
                .font(LoriFont.small.monospacedDigit())
                .foregroundStyle(LoriPalette.muted)
                .fixedSize()
            if needsTopic {
                Text("Без темы")
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(LoriPalette.bubble, in: Capsule())
                    .accessibilityIdentifier("noTopicBadge")
            }
            if let topic {
                Text(topic)
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.lime)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(LoriPalette.limeSoft.opacity(0.6), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }
}

/// Строка состояния под заголовком: значок, слова и — пока запись считается —
/// тонкая полоса. Полоса здесь не бежит, даже когда доли нет: живой элемент на
/// экране один, блок очереди сверху, а карточка только показывает, что работа идёт.
private struct StatusRow: View {
    let status: RecordStatus
    let record: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if status.showsBar {
                ProgressLine(fraction: status.fraction, height: 3)
            }
            HStack(alignment: .center, spacing: 6) {
                if let symbol = status.symbol {
                    Image(systemName: symbol)
                        .font(LoriFont.small.weight(.semibold))
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                }
                Text(status.text)
                    .font(LoriFont.small.weight(.medium))
                    .foregroundStyle(color)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                if let action = status.action {
                    // Место под настоящую кнопку, которая лежит поверх карточки.
                    CardActionButton.capsule(action)
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var color: Color {
        switch status.tone {
        case .working: LoriPalette.info
        case .waiting: LoriPalette.warn
        case .failure: LoriPalette.danger
        case .quiet: LoriPalette.muted
        }
    }
}

/// «Расшифровать», «Повторить», «Продолжить» прямо на карточке. Стиль `borderless`
/// обязателен: с обычным стилем кнопка в строке `List` забирает себе тап по всей
/// строке, и карточка перестаёт открываться.
struct CardActionButton: View {
    let action: RecordStatus.Action
    let record: String
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            Self.capsule(action)
                // Рисуется на 30, нажимается на 44 — тот же приём, что у чипов панели.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel(action.title)
        .accessibilityHint(record)
        .accessibilityIdentifier("cardAction")
    }

    /// Видимая часть кнопки. Ею же строка состояния держит место под кнопку:
    /// держать место под все 44 точки значило бы раздуть строку пустотой.
    static func capsule(_ action: RecordStatus.Action) -> some View {
        Text(action.title)
            .font(LoriFont.small.weight(.semibold))
            .foregroundStyle(LoriPalette.lime)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(LoriPalette.limeSoft.opacity(0.7), in: Capsule())
            .fixedSize()
    }
}

extension VerticalAlignment {
    /// Середина строки состояния карточки — к ней прикладывается кнопка действия.
    /// Умолчание — середина: по нему меряется сама кнопка в оверлее, и с низом по
    /// умолчанию она садилась нижним краем на середину строки, то есть выше неё.
    private enum CardStatus: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    /// Середина полосы в блоке очереди — к ней прикладывается «Остановить».
    private enum QueueBar: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }

    static let cardStatus = VerticalAlignment(CardStatus.self)
    static let queueBar = VerticalAlignment(QueueBar.self)
}

// MARK: - Полоса прогресса

/// Тонкая полоса прогресса. С долей — заполняется по сделанному; без доли — в блоке
/// очереди бежит отрезок (там это единственное движение на экране), на карточке
/// стоит пустая дорожка. «Уменьшение движения» останавливает бег: остаётся дорожка.
struct ProgressLine: View {
    let fraction: Double?
    var height: CGFloat = 4
    var animatesUnknown = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(LoriPalette.limeSoft)
                if let fraction {
                    Capsule()
                        .fill(LoriPalette.lime)
                        .frame(width: width * min(1, max(0, fraction)))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fraction)
                } else if animatesUnknown, !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let period = 1.6
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: period) / period
                        let segment = max(24, width * 0.28)
                        Capsule()
                            .fill(LoriPalette.lime)
                            .frame(width: segment)
                            .offset(x: -segment + (width + segment) * phase)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Блок очереди

/// Блок очереди над списком — единственный живой элемент экрана.
///
/// Говорит три вещи: сколько всего и какая по счёту («Расшифровка · 2 из 5»),
/// что считается и докуда дошло (заголовок, проценты, полоса), что будет дальше.
/// Остаток времени стоит рядом с процентами записи, а не рядом с «2 из 5»: это
/// остаток **этой** записи, и в первой строке он читался бы как время всей пачки.
struct QueueBlock: View {
    let summary: QueueSummary
    /// Почему фона нет (`TranscriptionRunway.State.foregroundOnly`); nil — фон есть.
    let backgroundReason: String?
    let stop: () -> Void
    let explainBackground: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            info
                .overlay(alignment: Alignment(horizontal: .trailing, vertical: .queueBar)) {
                    StopQueueButton(action: stop)
                }
            if backgroundReason != nil {
                Button(action: explainBackground) {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle")
                            .accessibilityHidden(true)
                        Text("Идёт, пока Lori открыта · почему?")
                            .multilineTextAlignment(.leading)
                    }
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.muted)
                    .frame(minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Расшифровка идёт, только пока Lori открыта. Почему?")
                .accessibilityIdentifier("queueBackgroundNote")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(LoriPalette.line, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var headline: String {
        ["Расшифровка", summary.counter].compactMap { $0 }.joined(separator: " · ")
    }

    /// «63% · ещё ~2 мин», «63%», «ещё ~2 мин» или ничего.
    private var progress: String? {
        let parts = [summary.fraction.map(RecordStatus.percent), summary.remaining.map(HomeFormat.remaining)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(headline)
                .font(LoriFont.small.weight(.medium))
                .foregroundStyle(LoriPalette.muted)

            // Узкий экран и крупный шрифт: проценты уходят под заголовок, а не
            // выдавливают его в многоточие.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleText
                    Spacer(minLength: 0)
                    progressText
                }
                VStack(alignment: .leading, spacing: 3) {
                    titleText
                    progressText
                }
            }

            HStack(spacing: 12) {
                ProgressLine(fraction: summary.fraction, height: 6, animatesUnknown: !summary.isWaiting)
                StopQueueButton.capsule
                    .hidden()
                    .accessibilityHidden(true)
            }
            .alignmentGuide(.queueBar) { $0[VerticalAlignment.center] }

            if summary.isWaiting {
                note("Ждёт своей очереди", color: LoriPalette.warn)
            } else if let note = summary.note {
                self.note(note, color: LoriPalette.muted)
            }
            if summary.waitsForMemory {
                note("Следующая ждёт свободную память телефона", color: LoriPalette.warn)
            }
            if let next = summary.next {
                note(next, color: LoriPalette.muted)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Открыть запись")
        .accessibilityIdentifier("queueBlock")
    }

    private var titleText: some View {
        Text(summary.title)
            .font(LoriFont.cardTitle)
            .foregroundStyle(LoriPalette.ink)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private var progressText: some View {
        if let progress {
            Text(progress)
                .font(LoriFont.meta.monospacedDigit())
                .foregroundStyle(LoriPalette.ink)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(LoriFont.small)
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
    }
}

/// «Остановить» в блоке очереди. Спокойная кнопка, не красная: записи никуда не
/// деваются, снимается только расшифровка — и это ещё переспрашивается.
private struct StopQueueButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Self.capsule
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityIdentifier("stopQueueButton")
    }

    /// Видимая часть — ею же строка полосы держит место под кнопку.
    static var capsule: some View {
        Text("Остановить")
            .font(LoriFont.small.weight(.semibold))
            .foregroundStyle(LoriPalette.ink)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(LoriPalette.bubble, in: Capsule())
            .fixedSize()
    }
}

// MARK: - Подсказка про модель заголовков

/// Одна строка над списком, пока модель заголовков не скачана: без неё заголовок —
/// первая фраза записи, и человек не знает, что бывает лучше. Убирается крестиком
/// навсегда; пока модель качается — показывает, сколько скачалось.
struct TitlesHint: View {
    @ObservedObject var models: SummaryModelStore
    let dismiss: () -> Void

    private var variant: SummaryVariant { models.recommendedVariant }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text("Заголовки и короткие описания придумывает модель на этом iPhone")
                    .font(LoriFont.meta)
                    .foregroundStyle(LoriPalette.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(LoriFont.tiny.weight(.semibold))
                        .foregroundStyle(LoriPalette.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Скрыть подсказку про заголовки")
                .accessibilityIdentifier("titlesHintClose")
            }

            if models.downloading != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Модель заголовков \(models.statusLine)")
                        .font(LoriFont.small.monospacedDigit())
                        .foregroundStyle(LoriPalette.muted)
                    ProgressLine(fraction: models.fraction, height: 4)
                }
                .padding(.bottom, 10)
                .accessibilityElement(children: .combine)
            } else {
                Button { models.download(variant) } label: {
                    Label("Скачать \(variant.accusative) · \(variant.sizeLabel)", systemImage: "arrow.down.circle")
                        .font(LoriFont.small.weight(.semibold))
                        .foregroundStyle(LoriPalette.lime)
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("titlesHintDownload")
                if let failure = models.failure {
                    Text("Не скачалась: \(failure)")
                        .font(LoriFont.small)
                        .foregroundStyle(LoriPalette.danger)
                        .lineLimit(3)
                        .padding(.bottom, 8)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 2)
        .background(LoriPalette.bubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("titlesHint")
    }
}
