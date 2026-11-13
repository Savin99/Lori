@preconcurrency import AVFoundation
import Foundation

/// Приводит внешнюю запись к файлу, который открывают все движки и плеер.
/// Работает вне главного актора; оригинал не переименовывает и не удаляет.
enum AudioImport {
    enum Branch: String, Sendable { case original, readerWriter, audioConverter, gateway }
    struct Prepared: Sendable {
        let url: URL
        let suffix: String
        let branch: Branch
        let duration: TimeInterval
        let sourceDescription: String
        let elapsed: TimeInterval
        var isTemporary: Bool { branch != .original }
        func discard() { if isTemporary { try? FileManager.default.removeItem(at: url) } }

        func journal(sourceName: String) -> String {
            let route = branch == .original ? "без перевода" : "→ M4A (\(sourceDescription))"
            return "импорт: «\(sourceName)» \(route), \(Self.decimal(duration)) с звука за \(Self.decimal(elapsed)) с"
        }
        private static func decimal(_ value: Double) -> String {
            String(format: "%.1f", locale: Locale(identifier: "ru_RU"), value)
        }
    }
    struct Source: Sendable {
        var duration: TimeInterval?
        var rate: Double = 48000
        var codec: String = "аудио"
        var description: String {
            guard codec != "аудио" else { return "источник не определён" }
            return "\(codec) \(String(format: "%g", locale: Locale(identifier: "ru_RU"), rate / 1000)) кГц"
        }
    }
    static func outputRate(for source: Double) -> Double {
        [16000.0, 22050, 24000, 32000, 44100, 48000].last { $0 <= max(16000, source) } ?? 16000
    }
    static func bitrate(for rate: Double) -> Int { rate >= 32000 ? 64000 : rate >= 22050 ? 48000 : 32000 }
    private static func aacSettings(rate: Double) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
         AVEncoderBitRateKey: bitrate(for: rate), AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
    }
    static func readable(_ url: URL) throws -> Source {
        let file = try AVAudioFile(forReading: url)
        let rate = file.fileFormat.sampleRate
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, rate > 0 else { throw ImportError.unreadable(fileName: url.lastPathComponent) }
        let identifier = file.fileFormat.streamDescription.pointee.mFormatID
        return Source(duration: duration, rate: rate, codec: codec(identifier))
    }
    private static func codec(_ identifier: AudioFormatID) -> String {
        switch identifier {
        case kAudioFormatOpus: "Opus"
        case kAudioFormatMPEGLayer2: "MP2"
        case kAudioFormatAC3: "AC3"
        case kAudioFormatEnhancedAC3: "EAC3"
        default: AudioMIME.describe(identifier)
        }
    }
    private static func audioRange(_ tracks: [AVAssetTrack]) async -> CMTimeRange? {
        var span: CMTimeRange?
        for track in tracks {
            guard let range = try? await track.load(.timeRange), range.isValid,
                  range.duration.seconds.isFinite, range.duration.seconds > 0 else { continue }
            if let previous = span {
                let start = CMTimeMinimum(previous.start, range.start)
                let end = CMTimeMaximum(CMTimeRangeGetEnd(previous), CMTimeRangeGetEnd(range))
                span = CMTimeRange(start: start, duration: CMTimeSubtract(end, start))
            } else { span = range }
        }
        return span
    }
    private static func sourceInfo(_ asset: AVURLAsset) async -> Source {
        var info = Source()
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        // Длительность видео не равна длительности звука: немой хвост не должен
        // превращать хороший перевод в «неполный». При нескольких дорожках берём весь звук.
        if let span = await audioRange(tracks) { info.duration = span.duration.seconds }
        else if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 { info.duration = duration }
        var rates: [Double] = []
        var codecs = Set<String>()
        for track in tracks {
            for description in (try? await track.load(.formatDescriptions)) ?? [] {
                guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
                if asbd.mSampleRate > 0 { rates.append(asbd.mSampleRate) }
                codecs.insert(codec(asbd.mFormatID))
            }
        }
        if let rate = rates.max() { info.rate = rate }
        if !codecs.isEmpty { info.codec = codecs.sorted().joined(separator: "/") }
        return info
    }
    static func validate(_ target: URL, source: Source, name: String) throws -> TimeInterval {
        let result = try readable(target)
        let file = try AVAudioFile(forReading: target)
        guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
              file.fileFormat.channelCount == 1 else { throw ImportError.unreadable(fileName: name) }
        let duration = result.duration!
        if let expected = source.duration, abs(duration - expected) > max(1, expected * 0.02) {
            throw ImportError.durationMismatch(fileName: name)
        }
        return duration
    }

    static func prepare(
        _ source: URL, in directory: URL, gateway: GatewayClient?,
        converting: @Sendable () async -> Void = {}
    ) async throws -> Prepared {
        let began = Date()
        let name = source.lastPathComponent
        let suffix = source.pathExtension.lowercased()
        guard let route = ImportFormats.route(for: suffix) else { throw ImportError.unsupportedFormat(fileName: name) }
        if route == .gateway, gateway == nil { throw ImportError.gatewayRequired(fileName: name) }
        if route == .original, let info = try? readable(source) {
            return Prepared(url: source, suffix: source.pathExtension, branch: .original, duration: info.duration!, sourceDescription: info.description, elapsed: Date().timeIntervalSince(began))
        }
        await converting()
        let partial = directory.appending(path: ".lori-import-\(UUID().uuidString).partial")
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: partial) } }
        let asset = AVURLAsset(url: source)
        var info = await sourceInfo(asset)
        if let readableInfo = try? readable(source) {
            if info.duration == nil { info.duration = readableInfo.duration }
            if info.codec == "аудио" { info.rate = readableInfo.rate; info.codec = readableInfo.codec }
        }
        func prepared(_ branch: Branch, info: Source) throws -> Prepared {
            let duration = try validate(partial, source: info, name: name)
            return Prepared(url: partial, suffix: "m4a", branch: branch, duration: duration, sourceDescription: info.description, elapsed: Date().timeIntervalSince(began))
        }
        // Контейнеры шлюза не открываются AVFoundation; остальные сначала пробуем на телефоне.
        if route != .gateway {
            do {
                try await readerWriter(asset: asset, to: partial, rate: outputRate(for: info.rate))
                let result = try prepared(.readerWriter, info: info)
                keep = true
                return result
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                try? FileManager.default.removeItem(at: partial)
                if case ImportError.durationMismatch = error { throw error }
            }
            do {
                try audioConverter(from: source, to: partial, rate: outputRate(for: info.rate))
                let result = try prepared(.audioConverter, info: info)
                keep = true
                return result
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                try? FileManager.default.removeItem(at: partial)
                if case ImportError.durationMismatch = error { throw error }
            }
        }
        guard let gateway else { throw ImportError.unreadable(fileName: name) }
        let downloaded = try await gateway.convert(file: source)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        // Ответ шлюза проверяется так же, как результат местного кодера.
        try FileManager.default.moveItem(at: downloaded, to: partial)
        let result: Prepared
        do { result = try prepared(.gateway, info: info) }
        catch {
            if case ImportError.durationMismatch = error { throw error }
            throw ImportError.gatewayFailed(reason: "шлюз вернул файл без читаемого звука M4A.")
        }
        keep = true
        return result
    }

    private static func readerWriter(asset: AVURLAsset, to target: URL, rate: Double) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw WorkspaceError.importFailed }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { throw WorkspaceError.importFailed }
        reader.add(output)
        let span = await audioRange(tracks)
        if let span { reader.timeRange = span }
        let writer = try AVAssetWriter(outputURL: target, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings(rate: rate))
        guard writer.canAdd(input) else { throw WorkspaceError.importFailed }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? WorkspaceError.importFailed }
        defer { if reader.status == .reading { reader.cancelReading() }; if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: span?.start ?? .zero)
        while reader.status == .reading {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? WorkspaceError.importFailed }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let buffer = output.copyNextSampleBuffer() else { break }
            guard input.append(buffer) else { throw writer.error ?? WorkspaceError.importFailed }
        }
        guard reader.status == .completed else { throw reader.error ?? WorkspaceError.importFailed }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? WorkspaceError.importFailed }
    }

    /// Пробуем AudioFile и когда AssetReader отказывает. Открытие контейнера само
    /// по себе ещё не доказывает наличие системного декодера (MP2 на iOS 27).
    static func audioConverter(from source: URL, to target: URL, rate: Double) throws {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: pcm) else { throw WorkspaceError.importFailed }
        var settings = aacSettings(rate: rate)
        // Скрытый .partial не имеет расширения M4A; контейнер задаём явно.
        settings[AVAudioFileTypeKey] = kAudioFileM4AType
        let output = try AVAudioFile(forWriting: target, settings: settings)
        var readFailure: Error?
        while true {
            try Task.checkCancellation()
            guard let piece = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(rate * 2)) else { throw WorkspaceError.importFailed }
            var failure: NSError?
            let status = converter.convert(to: piece, error: &failure) { _, status in
                guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
                    readFailure = WorkspaceError.importFailed; status.pointee = .endOfStream; return nil
                }
                guard file.framePosition < file.length else { status.pointee = .endOfStream; return nil }
                do { try file.read(into: input, frameCount: AVAudioFrameCount(min(Int64(input.frameCapacity), file.length - file.framePosition))) }
                catch { readFailure = error; status.pointee = .endOfStream; return nil }
                status.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                return input.frameLength > 0 ? input : nil
            }
            if let readFailure { throw readFailure }
            if let failure { throw failure }
            if status == .error { throw WorkspaceError.importFailed }
            if piece.frameLength > 0 { try output.write(from: piece) }
            if status == .endOfStream { break }
            if piece.frameLength == 0 { throw WorkspaceError.importFailed }
        }
    }
}
