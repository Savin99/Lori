import AVFoundation
import Foundation

/// Настоящий короткий аудиофайл для тестов.
///
/// Подделка из строки не годится: облачные движки спрашивают у `AVAsset`
/// длительность, чтобы решить, резать ли запись на части, и на не-аудио падают.
enum AudioFixture {
    /// Длинная запись нужна там, где проверяется нарезка и контроль полноты:
    /// на секундном файле частей не бывает вовсе.
    static func wav(seconds: Double = 1, at url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(16_000 * seconds)
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// Запись из отрезков разной громкости.
    ///
    /// Тишина и речь на одном файле — единственный способ проверить, что порог
    /// тишины считается **от уровня речи**, а не от абсолютного нуля: в настоящей
    /// записи молчание это шум комнаты, и он заведомо громче нуля.
    /// Вне перечисленных отрезков — цифровой ноль.
    static func wav(seconds: Double, levels: [(ClosedRange<Double>, Float)], at url: URL) throws {
        let rate: Double = 16_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(rate * seconds)
              ), let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let time = Double(frame) / rate
            let level = levels.first { $0.0.contains(time) }?.1 ?? 0
            channel[frame] = level * Float(sin(2 * Double.pi * 220 * time))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// Запись со звуком и одной паузой в заданном месте.
    ///
    /// Ровная тишина для проверки нарезки по паузам не годится: в ней любая
    /// точка одинаково тиха, и «нашли паузу» ничего не доказывает. Здесь есть
    /// что отличить от чего.
    static func wav(seconds: Double, silenceAt gap: ClosedRange<Double>, at url: URL) throws {
        let rate: Double = 16_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(rate * seconds)
              ), let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let time = Double(frame) / rate
            let silent = gap.contains(time)
            channel[frame] = silent ? 0 : 0.5 * Float(sin(2 * Double.pi * 220 * time))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
