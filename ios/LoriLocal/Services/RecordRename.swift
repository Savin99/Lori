import Foundation

/// Переименование записи целиком: файл, расшифровка, заголовок и всё, что
/// привязано к пути, — одним вызовом.
///
/// Раньше эти шаги жили в экране списка, и «Готово» без правки проходило их
/// все: путь не менялся, а перенос темы и имён говорящих «со старого пути на
/// новый» на совпавших путях их стирал. Ещё раньше поле заполнялось именем
/// файла, и нажатие без правки делало «Recording-2026-…» ручным заголовком
/// навсегда. Поэтому поле заполняют видимым заголовком (`RecordTitle.resolve`),
/// а сюда передают его же как `currentTitle`.
@MainActor
enum RecordRename {
    /// - Returns: путь записи после переименования; nil — менять было нечего.
    /// - Throws: `WorkspaceError.nameTaken` («Запись с таким именем уже есть»),
    ///   `WorkspaceError.invalidName` — от заголовка не осталось имени файла.
    @discardableResult
    static func commit(
        _ entry: WorkspaceEntry,
        typed: String,
        currentTitle: String,
        workspace: WorkspaceStore,
        summaries: SummaryStore,
        topics: TopicStore,
        speakers: SpeakerNames,
        previews: TranscriptPreviews,
        runner: SummaryRunner? = nil
    ) throws -> String? {
        guard !RecordTitle.isNoOpRename(typed: typed, current: currentTitle) else { return nil }
        let old = entry.relativePath
        let new = try workspace.renameRecording(at: old, toName: typed)
        // Заголовок мог поменяться и без смены имени файла («Итоги: план» и
        // «Итоги- план» дают один файл) — тогда переносить нечего и некуда.
        if new != old {
            if let topic = topics.topic(for: old) {
                topics.assign(topic, to: new)
                topics.forget(old)
            }
            speakers.move(from: old, to: new)
            summaries.move(from: old, to: new)
            previews.move(from: old, to: new)
            runner?.move(from: old, to: new)
        }
        summaries.setManual(title: typed, for: new)
        return new
    }
}
