import SwiftUI

/// «Куда положить запись»: выбор темы прямо с карточки.
///
/// Тема предлагается по словам из расшифровки — человек только подтверждает.
/// «Без темы» работает как инбокс: видно, что не разобрано, но разбирать никто
/// не заставляет.
struct TopicSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var topics: TopicStore

    let title: String
    let path: String
    /// Тема, которую подсказала расшифровка.
    let suggestion: String?

    @State private var newTopic = ""
    @State private var isAdding = false
    @FocusState private var focused: Bool

    private var current: String? { topics.topic(for: path) }

    /// Предложенная тема идёт первой: её и подтверждают чаще всего.
    private var ordered: [String] {
        guard let suggestion, topics.topics.contains(suggestion) else { return topics.topics }
        return [suggestion] + topics.topics.filter { $0 != suggestion }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(LoriFont.cardTitle)
                        .foregroundStyle(LoriPalette.ink)
                        .lineLimit(2)
                    Text("Куда положить запись")
                        .font(LoriFont.meta)
                        .foregroundStyle(LoriPalette.muted)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 14)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(ordered, id: \.self) { topic in
                            row(topic)
                        }

                        if current != nil {
                            Button { assign(nil) } label: {
                                rowLabel("Без темы", trailing: nil, selected: false)
                            }
                            .buttonStyle(.plain)
                        }

                        if isAdding {
                            HStack(spacing: 10) {
                                TextField("Название темы", text: $newTopic)
                                    .focused($focused)
                                    .font(LoriFont.body)
                                    .submitLabel(.done)
                                    .onSubmit { assign(newTopic) }
                                    .accessibilityIdentifier("newTopicField")
                                Button("Готово") { assign(newTopic) }
                                    .font(LoriFont.control)
                                    .foregroundStyle(LoriPalette.lime)
                                    .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 54)
                            .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(LoriPalette.line, lineWidth: 1))
                        } else {
                            Button {
                                isAdding = true
                                focused = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus")
                                    Text("Новая тема")
                                    Spacer(minLength: 0)
                                }
                                .font(LoriFont.body)
                                .foregroundStyle(LoriPalette.ink)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 54)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(LoriPalette.card, in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(LoriPalette.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("addTopic")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LoriPalette.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ topic: String) -> some View {
        Button { assign(topic) } label: {
            rowLabel(
                topic,
                trailing: topic == suggestion ? "Предложено" : nil,
                selected: topic == current
            )
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ text: String, trailing: String?, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(LoriFont.body)
                .foregroundStyle(LoriPalette.ink)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(LoriFont.small)
                    .foregroundStyle(LoriPalette.lime)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(LoriPalette.limeSoft.opacity(0.7), in: Capsule())
            }
            if selected {
                Image(systemName: "checkmark")
                    .font(LoriFont.meta.weight(.semibold))
                    .foregroundStyle(LoriPalette.lime)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? LoriPalette.bubble : LoriPalette.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(selected ? LoriPalette.lime.opacity(0.6) : LoriPalette.line, lineWidth: selected ? 2 : 1)
        )
    }

    private func assign(_ topic: String?) {
        topics.assign(topic, to: path)
        dismiss()
    }
}
