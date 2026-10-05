import AVFoundation
import Foundation

/// Подготовка записи к отправке в облачный сервис расшифровки.
///
/// Диктофон пишет ALAC (Apple Lossless) 48 кГц — честный архив, но такого
/// формата нет среди тех, что принимают сервисы расшифровки: у Google это
/// WAV, MP3, AIFF, AAC, OGG и FLAC. Файл при этом уходил без возражений и
/// возвращался пустой ответ — именно так пропала расшифровка записи 11:32.
///
/// Поэтому перед отправкой запись приводится к 16 кГц моно FLAC: этот формат
/// сервисы понимают, он без потерь для распознавания (движки внутри и так
/// работают на 16 кГц) и весит примерно в десять раз меньше — 54 МБ той же
/// записи превращаются в 5 МБ, а значит чаще проходят без Files API.
enum CloudAudio {
    struct Prepared {
        let url: URL
        let mime: String
        /// Файл создан для отправки — после запроса его нужно убрать.
        let isTemporary: Bool

        func discard() {
            guard isTemporary else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Форматы, которые сервисы принимают как есть.
    static let passThrough: Set<AudioFormatID> = [
        kAudioFormatMPEG4AAC, kAudioFormatMPEGLayer3, kAudioFormatLinearPCM, kAudioFormatFLAC,
    ]

    /// - Parameter limit: предел размера запроса у сервиса, если он есть.
    ///   Файл в подходящем формате и в пределах лимита отправляется как есть:
    ///   перегон уже сжатого AAC в FLAC делал запрос **больше** (7 МБ → 8 МБ).
    static func prepare(_ source: URL, limit: Int? = nil) throws -> Prepared {
        let file = try AVAudioFile(forReading: source)
        let format = file.fileFormat
        let sampleRate = format.sampleRate
        let identifier = format.streamDescription.pointee.mFormatID

        // Формат сервису подходит — трогаем файл только если он не влезает в лимит.
        if passThrough.contains(identifier) {
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let fits = limit.map { size <= $0 } ?? true
            let modest = sampleRate <= 16_000 && format.channelCount == 1
            if fits || modest {
                return Prepared(url: source, mime: AudioMIME.type(for: source), isTemporary: false)
            }
        }

        let target = FileManager.default.temporaryDirectory
            .appending(path: "cloud-\(UUID().uuidString).flac")
        do {
            try write(file: file, to: target)
        } catch {
            try? FileManager.default.removeItem(at: target)
            // Перевод не удался — отправляем исходник: пусть решает сервис,
            // это всё равно лучше, чем отказ ещё до запроса.
            Diagnostics.fault("не удалось привести аудио к FLAC: \(error.localizedDescription)")
            return Prepared(url: source, mime: AudioMIME.type(for: source), isTemporary: false)
        }

        let before = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        Diagnostics.note(
            "аудио для облака: \(AudioMIME.describe(identifier)) \(Int(sampleRate)) Гц "
            + "\(before / 1024 / 1024) МБ → FLAC 16 кГц моно \(after / 1024 / 1024) МБ"
        )
        return Prepared(url: target, mime: "audio/flac", isTemporary: true)
    }

    /// Перегон потоком: держать в памяти сорокаминутную запись нельзя —
    /// приложение на устройстве уже падало именно от этого.
    private static func write(file: AVAudioFile, to target: URL) throws {
        let source = file.processingFormat
        guard let reading = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioSamples.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: source, to: reading) else {
            throw AudioSamples.Failure.conversionFailed(file.url.lastPathComponent)
        }

        let output = try AVAudioFile(forWriting: target, settings: [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: AudioSamples.sampleRate,
            AVNumberOfChannelsKey: 1,
            // 16 бит — стандарт для распознавания речи; по умолчанию вышло бы
            // 24, и запрос весил бы вдвое больше без всякой пользы.
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])

        let inputCapacity = AVAudioFrameCount(source.sampleRate)          // секунда исходника
        let outputCapacity = AVAudioFrameCount(AudioSamples.sampleRate * 2)
        var finished = false

        while !finished {
            guard let piece = AVAudioPCMBuffer(pcmFormat: reading, frameCapacity: outputCapacity) else {
                throw AudioSamples.Failure.conversionFailed(file.url.lastPathComponent)
            }
            var failure: NSError?
            let status = converter.convert(to: piece, error: &failure) { _, outStatus in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: inputCapacity) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: buffer)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if buffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return buffer
            }
            if let failure { throw failure }
            if piece.frameLength > 0 { try output.write(from: piece) }
            if status == .endOfStream || status == .error || piece.frameLength == 0 { finished = true }
        }
    }
}
