import SwiftUI

/// Тело отчёта внутри вкладки; экспорт использует общий лист экрана записи.
struct ReportContent: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(ReportMarkdown.rows(markdown).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let marker = row.marker { Text(marker).accessibilityHidden(true) }
                    Text(.init(row.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(row.heading ? LoriFont.noteSection : LoriFont.body)
                .foregroundStyle(LoriPalette.ink)
                .padding(.leading, CGFloat(min(row.indent, 24)) * 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel((row.marker.map { $0 + " " } ?? "") + row.text)
                .accessibilityAddTraits(row.heading ? [.isHeader] : [])
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reportMarkdown")
    }
}
