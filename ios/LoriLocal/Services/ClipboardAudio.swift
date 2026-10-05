import Foundation
import UniformTypeIdentifiers
import UIKit

/// Аудио в буфере обмена.
///
/// Главное правило: **наличие проверяется по типам, а не по содержимому**.
/// Чтение `UIPasteboard.general.data(...)` или `.url` показывает системную плашку
/// «Lori вставила из…», и делать это на каждое появление панели нельзя — человек
/// ничего не просил. Список типов таким событием не считается, поэтому подсказка
/// в панели строится по нему, а сам файл читается уже по нажатию «Вставить».
enum ClipboardAudio {
    /// Что лежит в буфере, насколько это видно без чтения.
    enum Content: Equatable {
        /// Само аудио: сохранение из мессенджера кладёт данные с их типом.
        case audio
        /// Ссылка на файл: копирование в «Файлах» кладёт `public.file-url`,
        /// и что за файлом — до чтения неизвестно.
        case fileURL
        case none
    }

    static func content(in pasteboard: UIPasteboard = .general) -> Content {
        let types = pasteboard.types
        if types.contains(where: isAudio) { return .audio }
        if types.contains(UTType.fileURL.identifier) || types.contains(UTType.url.identifier) {
            return .fileURL
        }
        return .none
    }

    static func isAudio(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .audio)
    }

    /// Забирает содержимое буфера во временный файл. Вызывается **только** по
    /// нажатию: здесь и появляется системная плашка о вставке.
    ///
    /// Дорог три, и нужны все три. Мессенджер кладёт готовые данные. «Файлы»,
    /// Диск и почта кладут **обещание**: тип в буфере объявлен, а самих данных
    /// нет, пока их не попросят у поставщика — и синхронный
    /// `data(forPasteboardType:)` возвращает на них `nil`. Именно поэтому
    /// панель честно говорила «в буфере есть аудио», а «Вставить» отвечало,
    /// что его нет. Третья дорога — обычная ссылка на файл.
    static func take(from pasteboard: UIPasteboard = .general) async throws -> URL {
        if let url = try immediate(from: pasteboard) { return url }
        if let url = try await fromProviders(pasteboard.itemProviders) { return url }
        if let url = try fileReference(in: pasteboard) { return url }

        // Что именно лежало в буфере — единственная зацепка, когда вставка не
        // сработала на чужом телефоне. Без неё остаётся гадать по описанию.
        let types = pasteboard.types
        Diagnostics.fault(
            "буфер: забрать не удалось; типы: \(types.joined(separator: ", ")); поставщиков: \(pasteboard.itemProviders.count)"
        )
        throw failure(hasAudioType: types.contains(where: isAudio), types: types)
    }

    /// Как назвать отказ. Если тип аудио в буфере был, «в буфере нет аудио» —
    /// прямое противоречие тому, что человек только что прочитал в панели:
    /// забрать не вышло, но оно там есть.
    static func failure(hasAudioType: Bool, types: [String] = []) -> ClipboardAudioError {
        hasAudioType ? .unreadable(types) : .notAudio(types)
    }

    /// Данные уже лежат в буфере — самый частый случай для мессенджеров.
    private static func immediate(from pasteboard: UIPasteboard) throws -> URL? {
        guard let type = pasteboard.types.first(where: isAudio),
              let data = pasteboard.data(forPasteboardType: type) else { return nil }
        let url = temporary(extension: UTType(type)?.preferredFilenameExtension ?? "m4a")
        try prepare()
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Ленивый поставщик отдаёт файл асинхронно и удаляет его сразу после
    /// колбэка — копию снимаем прямо там, иначе копировать будет уже нечего.
    private static func fromProviders(_ providers: [NSItemProvider]) async throws -> URL? {
        for provider in providers {
            guard let identifier = provider.registeredTypeIdentifiers.first(where: isAudio) else { continue }
            let destination = temporary(extension: UTType(identifier)?.preferredFilenameExtension ?? "m4a")
            try prepare()
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        guard let url else {
                            continuation.resume(throwing: ClipboardAudioError.unreadable([identifier]))
                            return
                        }
                        do {
                            try? FileManager.default.removeItem(at: destination)
                            try FileManager.default.copyItem(at: url, to: destination)
                            continuation.resume(returning: destination)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                // Один поставщик не отдал — пробуем следующий, их бывает несколько.
                continue
            }
        }
        return nil
    }

    /// Копирование в «Файлах» кладёт ссылку. Копия обязательна: доступ к чужому
    /// файлу живёт недолго, а расшифровка может начаться и через минуту.
    private static func fileReference(in pasteboard: UIPasteboard) throws -> URL? {
        guard let source = pasteboard.url, source.isFileURL else { return nil }
        guard UTType(filenameExtension: source.pathExtension)?.conforms(to: .audio) == true else { return nil }

        let url = temporary(extension: source.pathExtension)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try prepare()
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    private static func prepare() throws {
        try FileManager.default.createDirectory(at: ImportInbox.staging, withIntermediateDirectories: true)
    }

    /// Вставленное сразу ложится в ту же промежуточную папку, что и всё
    /// принесённое снаружи: точка входа третья, а место одно.
    private static func temporary(extension suffix: String) -> URL {
        ImportInbox.staging
            .appending(path: "Вставленное \(Int(Date().timeIntervalSince1970)).\(suffix.isEmpty ? "m4a" : suffix)")
    }
}

enum ClipboardAudioError: LocalizedError, Equatable {
    case notAudio([String])
    case unreadable([String])

    var errorDescription: String? {
        switch self {
        case let .notAudio(types):
            "В буфере обмена нет аудио.\(Self.listed(types))"
        case let .unreadable(types):
            "Аудио из буфера забрать не удалось — приложение отдаёт его только по ссылке. Сохраните запись в «Файлы» и добавьте через «Аудио из Файлов».\(Self.listed(types))"
        }
    }

    /// Типы в тексте ошибки, а не только в журнале: иначе разбираться с чужим
    /// буфером приходится через переспросы, а так их видно на экране сразу.
    private static func listed(_ types: [String]) -> String {
        guard !types.isEmpty else { return "" }
        return "\n\nВ буфере: \(types.prefix(4).joined(separator: ", "))"
    }
}
