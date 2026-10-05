import AVFoundation
import XCTest
@testable import LoriLocal

/// Подготовка аудио к отправке: именно здесь пряталась пустая расшифровка —
/// диктофон писал ALAC, которого нет среди форматов сервисов расшифровки.
final class CloudAudioTests: XCTestCase {
    private var source: URL!

    override func tearDownWithError() throws {
        if let source { try? FileManager.default.removeItem(at: source) }
    }

    /// Запись диктофона — ALAC 48 кГц — становится FLAC 16 кГц моно.
    func testLosslessRecordingBecomesFLAC() throws {
        source = try Self.alac(seconds: 2)

        let prepared = try CloudAudio.prepare(source)
        defer { prepared.discard() }

        XCTAssertEqual(prepared.mime, "audio/flac", "ALAC сервисы не понимают, FLAC понимают")
        XCTAssertTrue(prepared.isTemporary, "исходная запись остаётся как есть")
        let file = try AVAudioFile(forReading: prepared.url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / 16_000, 2, accuracy: 0.2, "речь не потерялась")
    }

    /// Перевод должен уменьшать запрос, а не раздувать его.
    func testPreparedFileIsSmallerThanLosslessSource() throws {
        source = try Self.alac(seconds: 5)

        let prepared = try CloudAudio.prepare(source)
        defer { prepared.discard() }

        let before = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let after = try prepared.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertLessThan(after, before, "48 кГц без потерь → 16 кГц без потерь")
    }

    /// Готовый 16 кГц моно файл переводить незачем.
    func testSuitableFileIsSentAsIs() throws {
        source = FileManager.default.temporaryDirectory.appending(path: "ready-\(UUID().uuidString).wav")
        try AudioFixture.wav(seconds: 1, at: source)

        let prepared = try CloudAudio.prepare(source)

        XCTAssertEqual(prepared.url, source)
        XCTAssertFalse(prepared.isTemporary)
        XCTAssertEqual(prepared.mime, "audio/wav")
    }

    /// Запись такая же, как на устройстве: Apple Lossless, 48 кГц.
    private static func alac(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "alac-\(UUID().uuidString).m4a")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
        ])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(48_000 * seconds)
        ))
        buffer.frameLength = buffer.frameCapacity
        // Немного шума: тишина сжимается идеально и сравнение размеров теряет смысл.
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) {
                channel[index] = Float((index % 97)) / 97 - 0.5
            }
        }
        try file.write(from: buffer)
        return url
    }
}
