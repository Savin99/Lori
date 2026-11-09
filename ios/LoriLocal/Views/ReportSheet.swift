import SwiftUI

struct ReportSheet: View {
    let markdown: String
    let title: String
    let regenerate: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var share: SharePayload?
    @State private var exporting = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(markdown.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                            let level = line.prefix(while: { $0 == "#" }).count
                            let heading = level > 0 && line.dropFirst(level).hasPrefix(" ")
                            Text(.init(heading ? String(line.dropFirst(level + 1)) : line))
                                .font(heading ? LoriFont.control : LoriFont.body)
                                .foregroundStyle(LoriPalette.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let failure { Text(failure).foregroundStyle(LoriPalette.danger) }
                }
                .textSelection(.enabled)
                .padding(20)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("reportMarkdown")
            }
            .background(LoriPalette.canvas)
            .navigationTitle("Отчёт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(TranscriptExportFormat.allCases) { format in
                            Button(format.title, systemImage: format.icon) { export(format) }
                        }
                        Button("Сделать заново", systemImage: "arrow.clockwise") { dismiss(); regenerate() }
                    } label: {
                        if exporting { ProgressView() } else { Label("Поделиться", systemImage: "square.and.arrow.up") }
                    }
                    .disabled(exporting)
                    .accessibilityIdentifier("reportShare")
                }
            }
            .sheet(item: $share) { ShareSheet(payload: $0) }
        }
    }
    private func export(_ format: TranscriptExportFormat) {
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let payload = TranscriptExport.report(markdown: markdown, title: title)
                share = SharePayload(url: try await payload.file(as: format), subject: title)
            } catch { failure = "Не удалось собрать файл отчёта." }
        }
    }
}
