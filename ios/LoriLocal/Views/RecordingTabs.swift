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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize >= .xxLarge
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(Array(RecordingTab.allCases.enumerated()), id: \.element) { index, tab in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { selection = tab }
                } label: {
                    Text(tab.title)
                        .recordingFont(15, weight: selection == tab ? .semibold : .medium, relativeTo: .subheadline)
                        .foregroundStyle(selection == tab ? LoriPalette.ink : LoriPalette.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.vertical, typeSize >= .xxLarge ? 4 : 0)
                        .background {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 12).fill(LoriPalette.raised)
                                    .overlay(alignment: .top) {
                                        Capsule().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 12)
                                    }
                                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
                .accessibilityValue(selection == tab ? "Выбрана" : "")
                .accessibilityHint("Вкладка \(index + 1) из 3")
                .accessibilityIdentifier("recordingTab.\(tab.rawValue)")
            }
        }
        .padding(4)
        .recordingCard(radius: 16)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .accessibilityLabel("Содержание записи")
        .accessibilityIdentifier("recordingTabs")
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
