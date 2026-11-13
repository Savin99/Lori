import AVFoundation
import UniformTypeIdentifiers
import XCTest
@testable import LoriLocal

@MainActor
final class AudioImportTests: XCTestCase {
    private var directory: URL!
    private var workspace: WorkspaceStore!
    private let manager = FileManager.default

    override func setUp() async throws {
        directory = manager.temporaryDirectory.appending(path: "FormatImport-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = WorkspaceStore(rootURL: directory.appending(path: "Workspace"))
        workspace.start()
        UserDefaults.standard.set("", forKey: GatewaySettings.baseURLKey)
    }
    override func tearDown() async throws {
        try? manager.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: GatewaySettings.baseURLKey)
        StubURLProtocol.reset()
    }
    private func expectFailure<T>(_ work: @autoclosure () async throws -> T, verify: (Error) -> Void) async {
        do { _ = try await work(); XCTFail("Ожидался отказ") } catch { verify(error) }
    }
    private func verify(_ name: String, branch: AudioImport.Branch, gateway: GatewayClient? = nil) async throws {
        // Своя копия источника позволяет доказать сохранность оригинала и его даты.
        let source = directory.appending(path: name)
        try manager.copyItem(at: FormatFixture.url(name), to: source)
        let original = try Data(contentsOf: source)
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try manager.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        let scratch = directory.appending(path: "Scratch")
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let prepared = try await Task.detached { try await AudioImport.prepare(source, in: scratch, gateway: gateway) }.value
        XCTAssertEqual(prepared.branch, branch, name)
        XCTAssertTrue(prepared.journal(sourceName: name).contains("импорт: «\(name)»"))
        XCTAssertTrue(prepared.journal(sourceName: name).contains("с звука за"))
        prepared.discard()
        let store = gateway.map { WorkspaceStore(rootURL: directory.appending(path: "Workspace"), importGateway: $0) } ?? workspace!
        store.start()
        let before = Date()
        let path = try await store.importFileAsync(from: source)
        let target = try store.fileURL(for: path)
        let expectedSuffix = branch == .original ? source.pathExtension : "m4a"
        XCTAssertEqual(target.lastPathComponent, source.deletingPathExtension().lastPathComponent + "." + expectedSuffix)
        let audio = try AVAudioFile(forReading: target)
        let player = try AVAudioPlayer(contentsOf: target)
        XCTAssertTrue(player.prepareToPlay())
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        XCTAssertEqual(duration, 1.6, accuracy: 0.2, name)
        XCTAssertEqual(player.duration, duration, accuracy: 0.1)
        if branch == .original { XCTAssertEqual(try Data(contentsOf: target), original) }
        else {
            XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
            XCTAssertEqual(audio.fileFormat.channelCount, 1)
            XCTAssertTrue([16000.0, 22050, 24000, 32000, 44100, 48000].contains(audio.fileFormat.sampleRate))
            // Полный путь после перевода: отправка в облако и настоящая нарезка файла.
            let cloud = try CloudAudio.prepare(target)
            defer { cloud.discard() }
            XCTAssertEqual(cloud.mime, "audio/mp4")
            let splitter = AudioSplitter()
            let parts = try await splitter.split(target, partSeconds: 0.4, overlapSeconds: 0)
            defer { splitter.discard(parts) }
            XCTAssertGreaterThan(parts.count, 1)
            for part in parts { XCTAssertNoThrow(try AVAudioFile(forReading: part.url)) }
        }
        XCTAssertEqual(try Data(contentsOf: source), original, "оригинал цел")
        XCTAssertEqual(try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 ?? 0, date.timeIntervalSince1970, accuracy: 1)
        XCTAssertGreaterThanOrEqual(try store.entry(at: path).modifiedAt.timeIntervalSince(before), -1)
        try store.refresh()
        XCTAssertEqual(store.audio.map(\.relativePath), [path])
        let names = try manager.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        XCTAssertEqual(names, [target.lastPathComponent], "никаких partial")
        XCTAssertTrue(try String(contentsOf: Journal.url, encoding: .utf8).contains("импорт: «\(name)»"))
        XCTAssertEqual(store.convertingImports, 0)
    }

    func testOggOpus() async throws { try await verify("opus.ogg", branch: .readerWriter) }
    func testOgaOpus() async throws { try await verify("opus.oga", branch: .readerWriter) }
    func testOpusExtension() async throws { try await verify("opus.opus", branch: .readerWriter) }
    func testFlacStaysOriginalAndVisible() async throws { try await verify("lossless.flac", branch: .original) }
    // На iOS 27 AudioFile узнаёт MP2, но декодер отказывает fmt? при первом чтении.
    // Проверяем реальный запасной путь, а не принимаем открытие файла за декодирование.
    func testMP2UsesGatewayWhenSystemDecoderRefuses() async throws { try await verify("layer2.mp2", branch: .gateway, gateway: gateway()) }
    func testAudioFileConverterActuallyEncodesAAC() async throws {
        let source = try FormatFixture.url("reference.wav")
        let target = directory.appending(path: ".lori-import-converter.partial")
        try await Task.detached { try AudioImport.audioConverter(from: source, to: target, rate: 16000) }.value
        let duration = try AudioImport.validate(target, source: AudioImport.readable(source), name: "reference.wav")
        XCTAssertEqual(duration, 1.6, accuracy: 0.2)
        let file = try AVAudioFile(forReading: target)
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
    }
    func testIncompleteConversionIsRefused() throws {
        let target = try FormatFixture.url("reference.m4a")
        XCTAssertThrowsError(try AudioImport.validate(target, source: .init(duration: 20, rate: 48000, codec: "AAC"), name: "test.ogg")) { error in
            XCTAssertEqual(error as? ImportError, .durationMismatch(fileName: "test.ogg"))
        }
    }

    func testAC3() async throws { try await verify("dolby.ac3", branch: .readerWriter) }
    func test3GP() async throws { try await verify("mobile.3gp", branch: .readerWriter) }
    func testMP4VideoBecomesPlayableAudio() async throws { try await verify("video.mp4", branch: .readerWriter) }
    func testMOVVideoBecomesPlayableAudio() async throws { try await verify("video.mov", branch: .readerWriter) }
    func testVideoWithSilentTailKeepsAllSound() async throws { try await verify("sparse-audio.mov", branch: .readerWriter) }
    func testMulawWavStaysOriginal() async throws { try await verify("mulaw.wav", branch: .original) }

    private func gateway() throws -> GatewayClient {
        let result = try FormatFixture.data("reference.m4a")
        return GatewayClient(baseURL: URL(string: "https://stub.invalid/gateway")!, token: "convert-fixture", session: StubURLProtocol.session { _, _ in
            .init(headers: ["Content-Type": "audio/mp4"], body: result)
        })
    }
    func testVorbisUsesGatewayWhenConfigured() async throws { try await verify("vorbis.ogg", branch: .gateway, gateway: gateway()) }
    func testWebMUsesGateway() async throws { try await verify("voice.webm", branch: .gateway, gateway: gateway()) }
    func testMKVUsesGateway() async throws { try await verify("matroska.mkv", branch: .gateway, gateway: gateway()) }
    func testWMAUsesGateway() async throws { try await verify("windows.wma", branch: .gateway, gateway: gateway()) }

    func testGatewayUploadsActualFileBytesAndHumanErrors() async throws {
        let client = try gateway()
        let source = try FormatFixture.url("voice.webm")
        let output = try await client.convert(file: source)
        defer { try? manager.removeItem(at: output) }
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(request.request.url?.path, "/gateway/v1/convert")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer convert-fixture")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "X-Lori-Filename")?.removingPercentEncoding, "voice.webm")
        XCTAssertEqual(request.body, try Data(contentsOf: source))
        XCTAssertEqual(try Data(contentsOf: output), try FormatFixture.data("reference.m4a"))
        for (code, status, word) in [("audio", 415, "звуковой"), ("size", 413, "95 МБ"), ("unavailable", 503, "ffmpeg"), ("timeout", 504, "не успел"), ("auth", 401, "токен"), ("rate", 429, "запросов")] {
            let client = GatewayClient(baseURL: URL(string: "https://stub.invalid")!, token: "test", session: StubURLProtocol.session { _, _ in .json("{\"error\":{\"code\":\"\(code)\",\"message\":\"PRIVATE\"}}", status: status) })
            await expectFailure(try await client.convert(file: source)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Mac mini"))
                XCTAssertTrue(error.localizedDescription.contains(word), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
            }
        }
    }

    func testGatewayOnlyFormatsWithoutGatewayExplainWhyAndLeaveNoOutput() async throws {
        for name in ["voice.webm", "matroska.mkv", "windows.wma"] {
            let source = try FormatFixture.url(name)
            await expectFailure(try await workspace.importFileAsync(from: source)) { error in
                XCTAssertEqual(error as? ImportError, .gatewayRequired(fileName: name))
                XCTAssertTrue(error.localizedDescription.contains("нужен шлюз на Mac mini"))
            }
            XCTAssertTrue(manager.fileExists(atPath: source.path))
        }
        XCTAssertEqual(workspace.audio, [])
    }
    func testVorbisAndBrokenOggWithoutGatewayLeaveNoPartialAndKeepSource() async throws {
        for name in ["vorbis.ogg", "broken.ogg", "layer2.mp2"] {
            let source = try FormatFixture.url(name)
            let before = try Data(contentsOf: source)
            await expectFailure(try await workspace.importFileAsync(from: source)) { error in
                XCTAssertEqual(error as? ImportError, .unreadable(fileName: name))
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
        }
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: directory.appending(path: "Workspace/Imported").path), [])
        XCTAssertEqual(workspace.convertingImports, 0)
    }
    func testFailedGatewayImportLeavesNothingAndKeepsSource() async throws {
        let client = GatewayClient(baseURL: URL(string: "https://stub.invalid")!, token: "test", session: StubURLProtocol.session { _, _ in .json(#"{"error":{"code":"timeout"}}"#, status: 504) })
        let store = WorkspaceStore(rootURL: directory.appending(path: "Workspace"), importGateway: client)
        let source = try FormatFixture.url("voice.webm")
        await expectFailure(try await store.importFileAsync(from: source)) { error in XCTAssertTrue(error.localizedDescription.contains("Mac mini")) }
        XCTAssertTrue(manager.fileExists(atPath: source.path))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: directory.appending(path: "Workspace/Imported").path), [])
    }
    func testCorruptGatewayResponseIsNeverPublished() async throws {
        let client = GatewayClient(baseURL: URL(string: "https://stub.invalid")!, token: "test", session: StubURLProtocol.session { _, _ in .init(headers: ["Content-Type": "audio/mp4"], body: Data([1, 2, 3])) })
        let store = WorkspaceStore(rootURL: directory.appending(path: "Workspace"), importGateway: client)
        await expectFailure(try await store.importFileAsync(from: FormatFixture.url("voice.webm"))) { _ in }
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: directory.appending(path: "Workspace/Imported").path), [])
    }
    func testConversionProgressAndMacMiniNoticeAreHonest() async throws {
        var phases: [Int] = []
        var macMini: [Int] = []
        let observer = workspace.$convertingImports.sink { phases.append($0) }
        let macMiniObserver = workspace.$convertingOnMacMini.sink { macMini.append($0) }
        defer { observer.cancel(); macMiniObserver.cancel() }
        _ = try await workspace.importFileAsync(from: FormatFixture.url("opus.ogg"))
        XCTAssertTrue(phases.contains(1))
        XCTAssertEqual(phases.last, 0)
        XCTAssertFalse(macMini.contains(1), "Ogg Opus переводит сам iPhone")
        XCTAssertNil(ImportFormats.conversionNotice(for: ["voice.webm"], gatewayConfigured: false))
        XCTAssertNil(ImportFormats.conversionNotice(for: ["audio.flac"], gatewayConfigured: true))
        XCTAssertTrue(ImportFormats.conversionNotice(for: ["voice.webm"], gatewayConfigured: true)?.contains("Mac mini") == true)
        // Голосовое Telegram iPhone читает сам: условной оговорки под каждым быть не должно.
        XCTAssertNil(ImportFormats.conversionNotice(for: ["voice.ogg"], gatewayConfigured: true))
    }

    /// Уход файла на Mac mini виден, пока идёт: и у формата шлюза, и у файла, который
    /// iPhone не раскодировал сам (MP2 на iOS 27).
    func testGatewayConversionIsNamedWhileItRuns() async throws {
        let store = WorkspaceStore(rootURL: directory.appending(path: "Workspace"), importGateway: try gateway())
        store.start()
        var macMini: [Int] = []
        let observer = store.$convertingOnMacMini.sink { macMini.append($0) }
        defer { observer.cancel() }
        for name in ["voice.webm", "layer2.mp2"] {
            macMini.removeAll()
            _ = try await store.importFileAsync(from: FormatFixture.url(name))
            XCTAssertTrue(macMini.contains(1), name)
            XCTAssertEqual(macMini.last, 0, name)
        }
        XCTAssertEqual(store.convertingImports, 0)
    }

    func testRateAndBitrateSelection() {
        for (source, rate, bits) in [(8000.0, 16000.0, 32000), (22050, 22050, 48000), (24000, 24000, 48000), (32000, 32000, 64000), (44100, 44100, 64000), (96000, 48000, 64000)] {
            XCTAssertEqual(AudioImport.outputRate(for: source), rate)
            XCTAssertEqual(AudioImport.bitrate(for: rate), bits)
        }
    }
    func testInfoPlistAndPickerKnowAllDeclaredTypes() throws {
        for suffix in ImportFormats.allExtensions {
            let type = try XCTUnwrap(UTType(filenameExtension: suffix), suffix)
            XCTAssertFalse(type.isDynamic, "Нужен импортированный тип для .\(suffix)")
        }
        let plist = Bundle.main.infoDictionary!
        let types = try XCTUnwrap(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        for declaration in ImportFormats.importedTypes {
            let value = try XCTUnwrap(types.first { $0["UTTypeIdentifier"] as? String == declaration.identifier })
            let tags = try XCTUnwrap(value["UTTypeTagSpecification"] as? [String: Any])
            XCTAssertEqual(Set(tags["public.filename-extension"] as? [String] ?? []), Set(declaration.extensions))
            XCTAssertEqual(tags["public.mime-type"] as? String, declaration.mime)
            XCTAssertTrue(ImportFormats.contentTypes.contains { $0.identifier == declaration.identifier })
        }
        let document = try XCTUnwrap((plist["CFBundleDocumentTypes"] as? [[String: Any]])?.first)
        XCTAssertEqual(document["LSHandlerRank"] as? String, "Alternate")
        let identifiers = Set(document["LSItemContentTypes"] as? [String] ?? [])
        for id in ["public.movie", "public.audiovisual-content", "org.xiph.ogg-audio", "org.xiph.flac", "org.webmproject.webm"] { XCTAssertTrue(identifiers.contains(id)) }
    }
    func testClipboardTypesAndTitlesUseInputExtensions() {
        for id in ["org.xiph.ogg-audio", "org.xiph.flac", "public.mpeg-4", "com.apple.quicktime-movie"] { XCTAssertTrue(ClipboardAudio.isAudio(id), id) }
        XCTAssertTrue(RecordTitle.isGenericName("audio_5_2.ogg"))
        XCTAssertEqual(ClipboardAudio.stagedName(suggestedName: "Встреча.mov", sourceName: nil, typeExtension: "mov"), "Встреча.mov")
        XCTAssertEqual(WorkspaceEntry.audioExtensions, ImportFormats.originalExtensions.union(["mp4", "mov"]))
    }
}
