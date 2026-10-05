import SwiftUI

/// Журнал работы прямо в приложении: читать и отдавать, не подключая Mac.
struct JournalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "Журнал пуст — расшифровок ещё не было." : text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("journalText")
            }
            .navigationTitle("Журнал")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: Journal.url) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .task { text = (try? String(contentsOf: Journal.url, encoding: .utf8)) ?? "" }
    }
}
