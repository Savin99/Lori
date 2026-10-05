import AppIntents

/// Действие для Быстрых команд: «Расшифровать в Lori».
///
/// Действие только приносит запись и открывает приложение — расшифровку
/// запускает человек. Причина та же, что и у «Поделиться»: движок и цена
/// (в облако или на телефоне, три минуты или двенадцать) видны в панели, и
/// решение принимается там. Команда, которая молча отправляет часовую запись
/// в облако, — это счёт, о котором не спросили.
struct TranscribeInLoriIntent: AppIntent {
    static let title: LocalizedStringResource = "Расшифровать в Lori"
    static let description = IntentDescription(
        "Открывает Lori с прикреплённой записью. Движок и запуск — за вами."
    )
    /// Без этого действие выполнялось бы в фоне, а прикреплённый файл ждал бы
    /// в панели, которую никто не открыл.
    static let openAppWhenRun = true

    @Parameter(title: "Аудио", supportedContentTypes: [.audio])
    var audio: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Расшифровать \(\.$audio) в Lori")
    }

    func perform() async throws -> some IntentResult {
        try ImportInbox.stage(audio)
        return .result()
    }
}

struct LoriShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TranscribeInLoriIntent(),
            phrases: ["Расшифровать в \(.applicationName)"],
            shortTitle: "Расшифровать",
            systemImageName: "waveform"
        )
    }
}
