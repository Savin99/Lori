import SwiftUI

/// Вкладки одной записи. Выбор хранится у экрана, аудио остаётся общим.
enum RecordingTab: String, CaseIterable {
    case summary, report, transcript

    var title: String {
        switch self {
        case .summary: "Итог"
        case .report: "Отчёт"
        case .transcript: "Расшифровка"
        }
    }
}

struct RecordingTabs: View {
    @Binding var selection: RecordingTab
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    // Уже на XXL три естественные подписи тесны на узком iPhone. Переход
    // раньше accessibility-размеров сохраняет целые слова без уменьшения шрифта.
    private var stacksTabs: Bool { typeSize >= .xxLarge }

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                // Встроенный inline segmented не обещает стеклянную подложку.
                // Один выбранный материал движется между тремя местами по общему ID
                // (Apple, Applying Liquid Glass to custom views). Стекла на стекле нет.
                GlassEffectContainer(spacing: 12) { tabs }
            } else {
                tabs
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .accessibilityLabel("Содержание записи")
        .accessibilityIdentifier("recordingTabs")
    }

    private var tabs: some View {
        // Длинная «Расшифровка» получает свою естественную ширину, а не треть
        // строки. На крупном шрифте все три пункта стоят друг под другом.
        let layout = stacksTabs
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            ForEach(Array(RecordingTab.allCases.enumerated()), id: \.element) { index, tab in
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { selection = tab }
                } label: {
                    tabLabel(tab)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
                .accessibilityValue(selection == tab ? "Выбрана" : "")
                .accessibilityHint("Вкладка \(index + 1) из 3")
                .accessibilityIdentifier("recordingTab.\(tab.rawValue)")
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func tabLabel(_ tab: RecordingTab) -> some View {
        let label = Text(tab.title)
            .font(LoriFont.meta.weight(selection == tab ? .semibold : .regular))
            .foregroundStyle(selection == tab ? LoriPalette.ink : LoriPalette.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: !stacksTabs, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: stacksTabs ? .infinity : nil, minHeight: 44)
        if selection == tab {
            if #available(iOS 26, *) {
                // Эффект на самой подписи оставляет её над стеклом. Отдельное
                // стекло в background размывало буквы как лежащий под ним контент.
                if stacksTabs {
                    label.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22))
                        .glassEffectID("selection", in: glass)
                } else {
                    label.glassEffect(.regular.interactive(), in: Capsule())
                        .glassEffectID("selection", in: glass)
                }
            } else {
                label.background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(LoriPalette.line))
            }
        } else {
            label
        }
    }
}

extension View {
    @ViewBuilder func recordingGlassButton() -> some View {
        if #available(iOS 26, *) {
            self.font(LoriFont.meta.weight(.semibold))
                .frame(minHeight: 44)
                .buttonStyle(.glass)
                .tint(LoriPalette.ink)
        } else {
            self.font(LoriFont.meta.weight(.semibold))
                .frame(minHeight: 44)
                .buttonStyle(.bordered)
                .tint(LoriPalette.ink)
        }
    }

    @ViewBuilder func recordingPlayerSurface(expanded: Bool) -> some View {
        if #available(iOS 26, *) {
            if expanded {
                self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
            } else {
                self.glassEffect(.regular, in: Capsule())
            }
        } else {
            self.background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(LoriPalette.line))
        }
    }

    /// Отступ сохраняет последнюю строку над капсулой, остальной текст идёт под
    /// стекло. safeAreaBar на iOS 27 ломает выбор текста: прежний экран и этот же
    /// экран с safeAreaInset проходят одинаковый UI-тест, с safeAreaBar — нет.
    /// Материал regular сам держит читаемость, сплошная подложка здесь не нужна.
    func recordingPlayerBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        self.safeAreaInset(edge: .bottom, spacing: 0, content: content)
    }
}
