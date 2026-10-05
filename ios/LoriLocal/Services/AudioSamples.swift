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
        try load(from: url, at: 0, length: .infinity)
    }

    /// Кусок записи, а не вся запись.
    ///
    /// Нарезке на части нужно послушать двадцать секунд вокруг будущего разреза,
    /// чтобы посадить его на паузу. Грузить ради этого весь файл нельзя: час звука
    /// на 16 кГц — это 57 миллионов отсчётов, 230 МБ, а потолок приложения около
    /// трёх гигабайт и по памяти оно уже падало.
    static func load(from url: URL, at start: TimeInterval, length: TimeInterval) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let source = file.processingFormat
        guard file.length > 0, source.sampleRate > 0 else { return [] }

        let first = max(0, AVAudioFramePosition((start * source.sampleRate).rounded()))
        guard first < file.length else { return [] }
        let available = file.length - first
        let wanted = length.isFinite
            ? AVAudioFramePosition((length * source.sampleRate).rounded())
            : available
        let frames = AVAudioFrameCount(max(0, min(available, wanted)))
        guard frames > 0 else { return [] }

        guard let input = try read(file: file, format: source, from: first, frames: frames) else {
            return []
        }
        if source.sampleRate == sampleRate, source.channelCount == 1 {
            return mono(from: input)
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: source, to: target), let output = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: AVAudioFrameCount(Double(input.frameLength) * sampleRate / source.sampleRate) + 1024
        ) else {
            throw Failure.conversionFailed(url.lastPathComponent)
        }

        // Конвертер тянет вход порциями сам; отдаём прочитанный кусок одним буфером.
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

    private static func read(
        file: AVAudioFile,
        format: AVAudioFormat,
        from first: AVAudioFramePosition,
        frames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        file.framePosition = first
        try file.read(into: buffer, frameCount: frames)
        return buffer.frameLength > 0 ? buffer : nil
    }

    private static func mono(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
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
