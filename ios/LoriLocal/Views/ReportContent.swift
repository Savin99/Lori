import SwiftUI

/// Документ во вкладке. Метка обсуждения — настоящая кнопка общего плеера.
struct ReportContent: View {
    let markdown: String
    var seek: (TimeInterval) -> Void = { _ in }
    var canSeek = true

    private var rows: [ReportMarkdown.Row] {
        let rows = ReportMarkdown.rows(markdown)
        if let first = rows.first, first.headingLevel == 1, !["суть", "участники", "ход обсуждения"].contains(first.text.lowercased()) {
            return Array(rows.dropFirst())
        }
        return rows
    }
    var documentTitle: String {
        let first = ReportMarkdown.rows(markdown).first
        if let first, first.headingLevel == 1, !["суть", "участники", "ход обсуждения"].contains(first.text.lowercased()) { return first.text }
        return "Отчёт по встрече"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if row.heading {
                    Text(row.text).font(LoriFont.reportSection).foregroundStyle(LoriPalette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 22).padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        if let time = row.timestamp {
                            Button { seek(time) } label: {
                                Text(TranscriptSegment.stamp(time)).recordingFont(12, weight: .semibold, relativeTo: .caption, monospaced: true)
                                    .foregroundStyle(LoriPalette.lime)
                                    .padding(.horizontal, 8).frame(minHeight: 24)
                                    .background(LoriPalette.lime.opacity(0.12), in: Capsule())
                                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                    .padding(.vertical, -10)
                            }
                            .buttonStyle(.plain).disabled(!canSeek)
                            .accessibilityLabel("Слушать с " + TranscriptSegment.stamp(time))
                            .accessibilityIdentifier("reportTime.\(index)")
                        } else if let marker = row.marker {
                            if marker == "•" {
                                Circle().fill(LoriPalette.muted).frame(width: 5, height: 5)
                                    .padding(.horizontal, 5).padding(.top, 10).accessibilityHidden(true)
                            } else { Text(marker).recordingFont(16).foregroundStyle(LoriPalette.muted).accessibilityHidden(true) }
                        }
                        Text(.init(row.text)).recordingFont(16).lineSpacing(5)
                            .foregroundStyle(LoriPalette.prose).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, row.marker != nil || row.timestamp != nil ? 8 : 0)
                    .padding(.leading, CGFloat(min(row.indent, 24)) * 6)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reportMarkdown")
    }
}
