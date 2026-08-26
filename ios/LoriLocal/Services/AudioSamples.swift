import AVFoundation
import Foundation

/// Чтение любого поддерживаемого аудиофайла в моно float на 16 кГц —
/// формат, на котором обучался GigaAM.
enum AudioSamples {
    enum Failure: LocalizedError {
        case unreadable(String)
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(name): "Не удалось прочитать аудио «\(name)»."
            case let .conversionFailed(name): "Не удалось привести «\(name)» к 16 кГц моно."
            }
        }
    }

    static let sampleRate: Double = 16_000

    static func load(from url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw Failure.conversionFailed(url.lastPathComponent)
        }

        let source = file.processingFormat
        if source.sampleRate == sampleRate, source.channelCount == 1 {
            return try readAll(file: file, format: source)
        }

        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw Failure.conversionFailed(url.lastPathComponent)
        }
        let raw = try readAll(file: file, format: source)
        guard !raw.isEmpty else { return [] }

        // Конвертер тянет вход порциями сам; отдаём весь файл одним буфером.
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)),
              let output = AVAudioPCMBuffer(
                  pcmFormat: target,
                  frameCapacity: AVAudioFrameCount(Double(file.length) * sampleRate / source.sampleRate) + 1024
              ) else {
            throw Failure.conversionFailed(url.lastPathComponent)
        }

        file.framePosition = 0
        try file.read(into: input)

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil else {
            throw Failure.conversionFailed(url.lastPathComponent)
        }
        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private static func readAll(file: AVAudioFile, format: AVAudioFormat) throws -> [Float] {
        file.framePosition = 0
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return [] }

        let frames = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }
        // Смешиваем в моно так же, как это делает ffmpeg с -ac 1: простое среднее.
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let pointer = channels[channel]
            for frame in 0..<frames {
                mono[frame] += pointer[frame] / Float(channelCount)
            }
        }
        return mono
    }
}
