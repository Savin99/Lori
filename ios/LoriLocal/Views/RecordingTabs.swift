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

/// Системный сегмент: на iOS 26+ это Liquid Glass с родной «линзой» выбора и её
/// анимацией. Прежние самодельные сегменты (макет Granola, 9 ноября) владелец
/// 16 ноября забраковал — «ни анимации, ни внешнего вида».
///
/// С XXL системный сегмент режет «Расшифровку» до многоточия, поэтому на крупном
/// шрифте вкладки встают столбцом кнопок с целыми подписями.
struct RecordingTabs: View {
    @Binding var selection: RecordingTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize >= .xxLarge { stacked } else { segmented }
    }

    private var segmented: some View {
        Picker("Содержание записи", selection: $selection) {
            ForEach(RecordingTab.allCases, id: \.self) { tab in
                Text(tab.title)
                    .tag(tab)
                    .accessibilityIdentifier("recordingTab.\(tab.rawValue)")
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .accessibilityIdentifier("recordingTabs")
    }

    private var stacked: some View {
        VStack(spacing: 4) {
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
                        .padding(.vertical, 4)
                        .background {
                            if selection == tab { RoundedRectangle(cornerRadius: 12).fill(LoriPalette.raised) }
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
