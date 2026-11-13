import Foundation
import UniformTypeIdentifiers

/// Одна таблица: входной контейнер ещё не означает, что его можно хранить и играть.
/// Фактическую поддержку кодека проверяет AudioImport, в том числе на старых iOS.
enum ImportFormats {
    enum Route: String, Sendable { case original, phone, gateway }
    struct Group: Sendable {
        let route: Route
        let extensions: Set<String>
    }
    static let groups: [Group] = [
        Group(route: .original, extensions: ["m4a", "mp3", "wav", "aac", "caf", "aiff", "aif", "flac"]),
        Group(route: .phone, extensions: ["ogg", "oga", "opus", "amr", "awb", "3gp", "3g2", "3gpp", "ac3", "eac3", "ec3", "m4b", "m4r", "aifc", "au", "snd", "mp2", "mpga", "mpa", "adts", "mp4", "m4v", "mov", "qt"]),
        Group(route: .gateway, extensions: ["webm", "weba", "mkv", "mka", "ogv", "wma", "wmv", "asf", "avi", "flv", "spx", "ape", "wv", "ts", "mts", "m2ts", "mpg", "mpeg", "vob", "dss"]),
    ]
    static let allExtensions = Set(groups.flatMap(\.extensions))
    static let originalExtensions = groups.first { $0.route == .original }!.extensions
    // Старые MP4/MOV уже лежат у владельца: список и корзина обязаны их видеть.
    static let storedExtensions = originalExtensions.union(["mp4", "mov"])

    static func route(for suffix: String) -> Route? {
        groups.first { $0.extensions.contains(suffix.lowercased()) }?.route
    }
    static func accepts(_ name: String, gatewayConfigured: Bool) -> Bool {
        guard let route = route(for: (name as NSString).pathExtension) else { return false }
        return route != .gateway || gatewayConfigured
    }
    static let supportedFormatsTitle: String = {
        let local = groups.filter { $0.route != .gateway }.flatMap(\.extensions).sorted().map { $0.uppercased() }.joined(separator: ", ")
        let remote = groups.first { $0.route == .gateway }!.extensions.sorted().map { $0.uppercased() }.joined(separator: ", ")
        return "Аудио, голосовые Telegram и WhatsApp, видео: " + local + ". Через шлюз на Mac mini: " + remote
    }()
    static func conversionNotice(for names: [String], gatewayConfigured: Bool) -> String? {
        guard gatewayConfigured else { return nil }
        let routes = names.compactMap { route(for: ($0 as NSString).pathExtension) }
        if routes.contains(.gateway) { return "Перевод в M4A — на Mac mini. Расшифровка — выбранным движком." }
        if routes.contains(.phone) { return "Если iPhone не откроет звук, перевод в M4A пройдёт на Mac mini." }
        return nil
    }
    struct ImportedType: Sendable {
        let identifier: String
        let extensions: [String]
        let mime: String
        let parent: String
    }
    // Те же объявления проверяются тестом против сгенерированного Info.plist.
    static let importedTypes: [ImportedType] = [
        ImportedType(identifier: "org.xiph.ogg", extensions: ["ogg", "oga"], mime: "audio/ogg", parent: "public.audio"),
        ImportedType(identifier: "org.xiph.opus", extensions: ["opus"], mime: "audio/opus", parent: "public.audio"),
        ImportedType(identifier: "org.matroska.mkv", extensions: ["mkv"], mime: "video/x-matroska", parent: "public.movie"),
        ImportedType(identifier: "org.matroska.mka", extensions: ["mka"], mime: "audio/x-matroska", parent: "public.audio"),
        ImportedType(identifier: "ru.ilyaqa.lori.weba", extensions: ["weba"], mime: "audio/webm", parent: "public.audio"),
        ImportedType(identifier: "ru.ilyaqa.lori.spx", extensions: ["spx"], mime: "audio/ogg", parent: "public.audio"),
        ImportedType(identifier: "ru.ilyaqa.lori.ape", extensions: ["ape"], mime: "audio/x-ape", parent: "public.audio"),
        ImportedType(identifier: "ru.ilyaqa.lori.wv", extensions: ["wv"], mime: "audio/wavpack", parent: "public.audio"),
        ImportedType(identifier: "ru.ilyaqa.lori.dss", extensions: ["dss"], mime: "audio/dss", parent: "public.audio"),
        ImportedType(identifier: "ru.ilyaqa.lori.awb", extensions: ["awb"], mime: "audio/amr-wb", parent: "public.audio"),
        ImportedType(identifier: "ru.ilyaqa.lori.ogv", extensions: ["ogv"], mime: "video/ogg", parent: "public.movie"),
        ImportedType(identifier: "ru.ilyaqa.lori.flv", extensions: ["flv"], mime: "video/x-flv", parent: "public.movie"),
        ImportedType(identifier: "ru.ilyaqa.lori.mpa", extensions: ["mpa"], mime: "audio/mpeg", parent: "public.audio"),
        ImportedType(identifier: "ru.ilyaqa.lori.mts", extensions: ["mts"], mime: "video/mp2t", parent: "public.movie"),
        ImportedType(identifier: "ru.ilyaqa.lori.m2ts", extensions: ["m2ts"], mime: "video/mp2t", parent: "public.movie"),
        ImportedType(identifier: "ru.ilyaqa.lori.vob", extensions: ["vob"], mime: "video/mpeg", parent: "public.movie"),
    ]
    static let contentTypes: [UTType] = {
        let identifiers = importedTypes.map(\.identifier) + ["org.xiph.ogg-audio", "org.xiph.flac", "org.3gpp.adaptive-multi-rate-audio", "com.microsoft.windows-media-wma", "org.webmproject.webm"]
        return [.audiovisualContent] + identifiers.compactMap(UTType.init) + allExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }()
    static func acceptsType(_ identifier: String, gatewayConfigured: Bool = GatewaySettings.isConfigured) -> Bool {
        if let known = importedTypes.first(where: { $0.identifier == identifier }) {
            return known.extensions.contains { accepts("record." + $0, gatewayConfigured: gatewayConfigured) }
        }
        guard let type = UTType(identifier) else { return false }
        if let suffix = type.preferredFilenameExtension, allExtensions.contains(suffix.lowercased()) {
            return accepts("record." + suffix, gatewayConfigured: gatewayConfigured)
        }
        return type == .audio || type == .movie || type == .audiovisualContent
    }
}
