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
///
/// Элементов в буфере может быть несколько: «Файлы» копируют разом пять записей,
/// мессенджер — все выделенные сообщения. Раньше брался только первый, и остальные
/// молча пропадали; теперь `takeAll` проходит по каждому по очереди.
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

    /// Сколько в буфере элементов каждого рода — по типам, без чтения содержимого.
    struct Inventory: Equatable, Sendable {
        /// Элементы, у которых объявлен аудио-тип: данные или обещание файла.
        var audio = 0
        /// Элементы, где есть только ссылка на файл: что за файлом, до чтения неизвестно,
        /// поэтому в «аудио» они не считаются.
        var fileReferences = 0

        var isEmpty: Bool { audio == 0 && fileReferences == 0 }

        /// Подсказка для панели: «В буфере 5 аудио». Слово «аудио» не склоняется, так что
        /// правил числительных тут не нужно. Нет аудио — нет подсказки: ссылки на файлы
        /// подсказкой не предлагаются, как и раньше.
        var hint: String? {
            guard audio > 0 else { return nil }
            return audio == 1 ? "В буфере есть аудио" : "В буфере \(audio) аудио"
        }
    }

    /// Итог вставки: что забрано и что нет. Одна нечитаемая запись из пяти не должна
    /// отменять четыре остальные — но и пропасть молча она не вправе.
    struct PasteResult: Sendable {
        /// Забранные файлы в промежуточной папке — в том порядке, в каком лежали в буфере.
        var urls: [URL] = []
        var skipped: [Skipped] = []

        struct Skipped: Sendable {
            /// Номер элемента в буфере, с нуля.
            let index: Int
            let name: String?
            let error: any Error
        }

        /// Причины пропуска — готовым текстом для человека.
        var messages: [String] { skipped.map { $0.error.localizedDescription } }
    }

    static func content(in pasteboard: UIPasteboard = .general) -> Content {
        let types = allTypes(in: pasteboard)
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

    /// Сколько в буфере аудио и ссылок на файлы — **не читая содержимого**: только
    /// `numberOfItems` и типы каждого элемента. Системная плашка о вставке на это не
    /// показывается, поэтому звать можно при каждом появлении панели.
    static func inventory(in pasteboard: UIPasteboard = .general) -> Inventory {
        var result = Inventory()
        for types in typesPerItem(in: pasteboard) {
            if types.contains(where: isAudio) {
                result.audio += 1
            } else if types.contains(UTType.fileURL.identifier) {
                result.fileReferences += 1
            }
        }
        return result
    }

    // MARK: - Вставка

    /// Забирает **первое** аудио из буфера. Остальные элементы не трогаются — не
    /// копируются и не остаются лежать в промежуточной папке. Для нескольких файлов
    /// есть `takeAll`. Вызывается только по нажатию: здесь и появляется системная плашка.
    static func take(from pasteboard: UIPasteboard = .general) async throws -> URL {
        let result = try await collect(from: pasteboard, limit: 1)
        if let url = result.urls.first { return url }
        throw result.skipped[0].error
    }

    /// Забирает **всё** аудио из буфера, элемент за элементом, в порядке буфера.
    ///
    /// Бросает только когда не забрано ничего: тогда это ошибка первого пропущенного
    /// элемента (нечитаемый, неподдерживаемый формат) или «в буфере нет аудио».
    /// Если часть забрана — возвращает забранное; что пропущено и почему, расскажет
    /// `takeBatch`.
    static func takeAll(from pasteboard: UIPasteboard = .general) async throws -> [URL] {
        let result = try await takeBatch(from: pasteboard)
        if result.urls.isEmpty, let first = result.skipped.first { throw first.error }
        return result.urls
    }

    /// То же, что `takeAll`, но с отчётом о пропущенном. Бросает только если в буфере
    /// вовсе не было аудио.
    ///
    /// Элементы идут **строго по очереди**, а не одновременно: `NSItemProvider` не
    /// `Sendable`, а главное — порядок вставки это порядок очереди, и он не должен
    /// зависеть от того, чей поставщик ответил быстрее.
    static func takeBatch(from pasteboard: UIPasteboard = .general) async throws -> PasteResult {
        try await collect(from: pasteboard, limit: nil)
    }

    /// Как назвать отказ. Если тип аудио в буфере был, «в буфере нет аудио» —
    /// прямое противоречие тому, что человек только что прочитал в панели:
    /// забрать не вышло, но оно там есть.
    static func failure(hasAudioType: Bool, types: [String] = []) -> ClipboardAudioError {
        hasAudioType ? .unreadable(types) : .notAudio(types)
    }

    // MARK: - Элементы буфера

    /// Один элемент буфера: его типы и поставщик, если система его отдала.
    private struct Item {
        let index: Int
        let types: [String]
        let provider: NSItemProvider?

        var audioType: String? { types.first(where: ClipboardAudio.isAudio) }
        var hasFileReference: Bool { types.contains(UTType.fileURL.identifier) }
        /// Брать стоит то, где есть аудио-тип или ссылка на файл (что за файлом — увидим при чтении).
        var isCandidate: Bool { audioType != nil || hasFileReference }
    }

    /// Типы каждого элемента по отдельности. `pasteboard.types` отдаёт типы только
    /// первого, и пять файлов, скопированных разом, выглядели как один.
    private static func typesPerItem(in pasteboard: UIPasteboard) -> [[String]] {
        let count = pasteboard.numberOfItems
        guard count > 0 else { return [] }
        return pasteboard.types(forItemSet: IndexSet(integersIn: 0..<count)) ?? []
    }

    /// Все типы всех элементов. Типы первого элемента добавляются на случай, если
    /// буфер по каким-то причинам не отдал разбивку по элементам.
    private static func allTypes(in pasteboard: UIPasteboard) -> [String] {
        var seen = Set<String>()
        return (typesPerItem(in: pasteboard).flatMap { $0 } + pasteboard.types).filter { seen.insert($0).inserted }
    }

    private static func items(in pasteboard: UIPasteboard) -> [Item] {
        var perItem = typesPerItem(in: pasteboard)
        // Разбивки нет, а типы есть — это один элемент, как в прежней версии.
        if perItem.isEmpty, !pasteboard.types.isEmpty { perItem = [pasteboard.types] }
        let providers = pasteboard.itemProviders
        return perItem.enumerated().map { index, types in
            Item(index: index, types: types, provider: index < providers.count ? providers[index] : nil)
        }
    }

    private static func collect(from pasteboard: UIPasteboard, limit: Int?) async throws -> PasteResult {
        let all = items(in: pasteboard)
        let candidates = all.filter(\.isCandidate)
        var result = PasteResult()
        for item in candidates {
            if let limit, result.urls.count >= limit { break }
            do {
                if let url = try await take(item, from: pasteboard, soleItem: all.count == 1) { result.urls.append(url) }
            } catch {
                Diagnostics.note("буфер: элемент \(item.index) не забран — \(error.localizedDescription)")
                result.skipped.append(.init(index: item.index, name: item.provider?.suggestedName, error: error))
            }
        }
        guard !result.urls.isEmpty || !result.skipped.isEmpty else {
            // Что именно лежало в буфере — единственная зацепка, когда вставка не
            // сработала на чужом телефоне. Без неё остаётся гадать по описанию.
            let types = allTypes(in: pasteboard)
            Diagnostics.fault(
                "буфер: забрать не удалось; типы: \(types.joined(separator: ", ")); поставщиков: \(pasteboard.itemProviders.count)"
            )
            throw failure(hasAudioType: types.contains(where: isAudio), types: types)
        }
        return result
    }

    /// Дорог три, и нужны все три. Мессенджер кладёт готовые данные. «Файлы»,
    /// Диск и почта кладут **обещание**: тип в буфере объявлен, а самих данных
    /// нет, пока их не попросят у поставщика — и синхронный
    /// `data(forPasteboardType:)` возвращает на них `nil`. Именно поэтому
    /// панель честно говорила «в буфере есть аудио», а «Вставить» отвечало,
    /// что его нет. Третья дорога — обычная ссылка на файл.
    ///
    /// `nil` — элемент не аудио (ссылка на файл, за которым не звук): это не отказ, а
    /// «не наше», и человеку о нём сообщать нечего.
    private static func take(_ item: Item, from pasteboard: UIPasteboard, soleItem: Bool) async throws -> URL? {
        let itemSet = IndexSet(integer: item.index)
        if let type = item.audioType {
            let typeExtension = UTType(type)?.preferredFilenameExtension
            // Данные уже лежат в буфере — самый частый случай для мессенджеров.
            if let data = pasteboard.data(forPasteboardType: type, inItemSet: itemSet)?.first, !data.isEmpty {
                let name = stagedName(
                    suggestedName: item.provider?.suggestedName, sourceName: nil, typeExtension: typeExtension
                )
                // Формат проверяется до записи: негодное не нужно писать, чтобы потом стирать.
                guard ImportInbox.isSupported(fileName: name) else {
                    throw ImportError.unsupportedFormat(fileName: name)
                }
                try prepare()
                let url = ImportInbox.free(named: name)
                try data.write(to: url, options: .atomic)
                return url
            }
            if let provider = item.provider, let identifier = provider.registeredTypeIdentifiers.first(where: isAudio) {
                do {
                    return try await copyRepresentation(
                        of: provider, as: identifier, typeExtension: UTType(identifier)?.preferredFilenameExtension
                    )
                } catch let refusal as ImportError {
                    throw refusal
                } catch {
                    // Этот поставщик не отдал — остаётся ссылка на файл, если она есть.
                }
            }
        }
        if item.hasFileReference, let source = await fileURL(of: item, in: pasteboard, soleItem: soleItem) {
            if let url = try copyFileReference(source) { return url }
            // Ссылка не на звук — не наше дело.
            if item.audioType == nil { return nil }
        }
        // Тип аудио был объявлен, а забрать не вышло — отказ называется своим именем.
        guard item.audioType != nil else { return nil }
        throw ClipboardAudioError.unreadable(item.types)
    }

    /// Ленивый поставщик отдаёт файл асинхронно и удаляет его сразу после
    /// колбэка — копию снимаем прямо там, иначе копировать будет уже нечего.
    private static func copyRepresentation(
        of provider: NSItemProvider,
        as identifier: String,
        typeExtension: String?
    ) async throws -> URL {
        let suggested = provider.suggestedName
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
                let name = stagedName(suggestedName: suggested, sourceName: url.lastPathComponent, typeExtension: typeExtension)
                guard ImportInbox.isSupported(fileName: name) else {
                    continuation.resume(throwing: ImportError.unsupportedFormat(fileName: name))
                    return
                }
                do {
                    try prepare()
                    let destination = ImportInbox.free(named: name)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Адрес файла из конкретного элемента.
    ///
    /// Через поставщика элемента, а не через буфер: `pasteboard.url` отдаёт только первый
    /// элемент, а `values(forPasteboardType:inItemSet:)` по `public.file-url` возвращает
    /// сырой двоичный plist (проверено на симуляторе), который руками не разобрать. Поставщик
    /// выдаёт `URL` готовым и стоит на том же месте, что и элемент.
    ///
    /// Поставщика нет или он не отдал — а элемент в буфере единственный — берётся прежний
    /// `pasteboard.url`: так вставка одного файла работала до пакетов и работает дальше.
    private static func fileURL(of item: Item, in pasteboard: UIPasteboard, soleItem: Bool) async -> URL? {
        if let provider = item.provider, provider.canLoadObject(ofClass: URL.self) {
            let loaded: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let loaded { return loaded }
        }
        return soleItem ? pasteboard.url : nil
    }

    /// Копирование в «Файлах» кладёт ссылку. Копия обязательна: доступ к чужому
    /// файлу живёт недолго, а расшифровка может начаться и через минуту.
    ///
    /// `nil` — за ссылкой не звук. Звук неподдерживаемого формата — отказ с пояснением:
    /// «.ogg» молча пропасть не должен.
    private static func copyFileReference(_ source: URL) throws -> URL? {
        guard source.isFileURL else { return nil }
        let name = source.lastPathComponent
        guard ImportInbox.isSupported(fileName: name) else {
            if UTType(filenameExtension: source.pathExtension)?.conforms(to: .audio) == true {
                throw ImportError.unsupportedFormat(fileName: name)
            }
            return nil
        }

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try prepare()
        let url = ImportInbox.free(named: name)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    // MARK: - Имена

    /// Как назвать вставленный файл: тем, что назвал источник, иначе «Вставленное».
    ///
    /// Раньше имя было «Вставленное <секунды>», и пять файлов, вставленных за одну секунду,
    /// получали одно имя и сливались в один. Теперь имя берётся у источника
    /// (`suggestedName` поставщика, а за неимением — имя временного файла), а повтор
    /// разводит `ImportInbox.free(named:)`.
    ///
    /// Расширение: своё у имени, если оно звуковое; иначе у временного файла; иначе по
    /// типу; иначе «m4a», как было.
    static func stagedName(suggestedName: String?, sourceName: String?, typeExtension: String?) -> String {
        func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let cleaned = ImportInbox.cleanFileName(value)
            return cleaned.isEmpty ? nil : cleaned
        }
        /// Расширение, по которому видно звук: известное приложению или любой звуковой тип.
        func isAudioExtension(_ suffix: String) -> Bool {
            !suffix.isEmpty && (
                WorkspaceEntry.audioExtensions.contains(suffix.lowercased())
                    || UTType(filenameExtension: suffix)?.conforms(to: .audio) == true
            )
        }
        /// Имя без смысла — UUID, каким бывает временный файл. Именно UUID, а не «что-то из
        /// цифр и дефисов»: «20260901-123456» — настоящее имя, которое дал диктофон, и
        /// терять его нельзя.
        func isMeaningless(_ base: String) -> Bool {
            UUID(uuidString: base) != nil || (base.count == 32 && base.allSatisfy(\.isHexDigit))
        }

        let suggested = clean(suggestedName)
        let source = clean(sourceName)
        // «Совещание.m4a» от источника уже с расширением — второе не дописывается.
        if let suggested, isAudioExtension((suggested as NSString).pathExtension) { return suggested }

        let sourceBase = source.map { ($0 as NSString).deletingPathExtension }.flatMap { isMeaningless($0) ? nil : $0 }
        let base = suggested ?? sourceBase ?? "Вставленное"
        let sourceSuffix = source.map { ($0 as NSString).pathExtension } ?? ""
        let suffix = !sourceSuffix.isEmpty ? sourceSuffix : (typeExtension ?? "m4a")
        return "\(base).\(suffix)"
    }

    private static func prepare() throws {
        try FileManager.default.createDirectory(at: ImportInbox.staging, withIntermediateDirectories: true)
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
