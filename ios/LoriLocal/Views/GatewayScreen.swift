import SwiftUI

struct GatewayScreen: View {
    @EnvironmentObject private var runner: SummaryRunner
    @AppStorage(GatewaySettings.baseURLKey) private var address = BundledAPIKeys.gatewayURL?.absoluteString ?? ""
    @State private var token = ""
    @FocusState private var tokenFocused: Bool
    @State private var saved = KeychainStore.hasKey(for: .gateway)
    @State private var status: String?
    @State private var failure: String?
    @State private var checking = false

    var body: some View {
        List {
            Section {
                TextField("Адрес шлюза", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("gatewayAddress")
                SecureField("Токен Bearer", text: $token)
                    .keyboardType(.asciiCapable)
                    .focused($tokenFocused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("gatewayToken")
                if saved { Text("Токен сохранён").font(LoriFont.meta).foregroundStyle(LoriPalette.muted) }
                // Строка остаётся на месте во время ввода: вставка новой строки
                // List после первого знака на iOS 27 обрывает ввод SecureField.
                Button("Сохранить токен") { saveToken() }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("gatewaySaveToken")
                Button {
                    check()
                } label: {
                    HStack {
                        Text("Проверить подключение")
                        if checking { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(checking)
                .accessibilityIdentifier("gatewayCheck")
                if saved, !KeychainStore.usesBundledKey(for: .gateway) {
                    Button(KeychainStore.hasBundledKey(for: .gateway) ? "Вернуть встроенный токен" : "Удалить токен", role: .destructive) {
                        do {
                            try KeychainStore.delete(.gateway)
                            saved = KeychainStore.hasKey(for: .gateway)
                            status = nil
                            failure = nil
                        } catch { failure = "Не удалось удалить токен с этого iPhone." }
                    }
                }
                if let status { Text(status).font(LoriFont.meta).foregroundStyle(LoriPalette.ink).accessibilityIdentifier("gatewayStatus") }
                if let failure { Text(failure).font(LoriFont.meta).foregroundStyle(LoriPalette.danger).accessibilityIdentifier("gatewayFailure") }
            } header: { Text("Подключение") } footer: {
                Text("Текст расшифровки уходит на Mac mini и оттуда в Google по подписке; по условиям Antigravity сотрудники Google вправе его читать.")
            }
        }
        .font(LoriFont.body)
        .scrollContentBackground(.hidden)
        .background(LoriPalette.canvas)
        .navigationTitle("Подписка Gemini")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: address) { _, _ in status = nil; failure = nil }
        .onDisappear { runner.settingsChanged() }
    }

    @discardableResult
    private func saveToken() -> Bool {
        do {
            try KeychainStore.save(token, for: .gateway)
            tokenFocused = false
            token = ""
            saved = true
            failure = nil
            return true
        } catch { failure = "Не удалось сохранить токен на этом iPhone."; return false }
    }

    private func check() {
        status = nil
        failure = nil
        guard token.isEmpty || saveToken() else { return }
        guard GatewaySettings.validatedURL(address) != nil else {
            failure = "Укажи адрес шлюза с http:// или https:// и именем хоста."
            return
        }
        checking = true
        Task {
            defer { checking = false }
            do { status = try await GatewayClient.configured().checkConnection().status }
            catch { failure = (error as? GatewayError)?.localizedDescription ?? GatewayError(code: "network").localizedDescription }
        }
    }
}
