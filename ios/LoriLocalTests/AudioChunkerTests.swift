import XCTest
@testable import LoriLocal

final class AudioChunkerTests: XCTestCase {
    /// Мелкая частота и короткие окна: тест проверяет арифметику, а не звук.
    private let sampleRate: Double = 1_000
    private var configuration: AudioChunker.Configuration {
        AudioChunker.Configuration(
            targetSeconds: 1.0,
            searchSeconds: 0.4,
            windowSeconds: 0.02,
            minimumTailSeconds: 0.1
        )
    }

    private func chunker() -> AudioChunker {
        AudioChunker(sampleRate: sampleRate, configuration: configuration)
    }

    private func tone(count: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { amplitude * Float(sin(Double($0) * 0.3)) }
    }

    func testShortAudioStaysWhole() {
        let bounds = chunker().bounds(for: tone(count: 500))
        XCTAssertEqual(bounds, [0..<500])
    }

    func testEmptyAudioGivesNoChunks() {
        XCTAssertTrue(chunker().bounds(for: []).isEmpty)
    }

    func testChunksCoverEverythingWithoutGaps() {
        let samples = tone(count: 3_500)
        let bounds = chunker().bounds(for: samples)

        XCTAssertGreaterThan(bounds.count, 1)
        XCTAssertLessThan(bounds.count, 20, "нарезка обязана продвигаться, а не топтаться на месте")
        XCTAssertEqual(bounds.first?.lowerBound, 0)
        XCTAssertEqual(bounds.last?.upperBound, samples.count)
        for (previous, next) in zip(bounds, bounds.dropFirst()) {
            XCTAssertLessThanOrEqual(next.lowerBound, previous.upperBound, "без разрывов в покрытии")
            XCTAssertGreaterThan(next.lowerBound, previous.lowerBound, "каждый кусок начинается позже")
        }
    }

    func testCutLandsInSilence() {
        // Тон на 3.5 секунды с тишиной на 0.9 секунде — граница должна уехать туда.
        var samples = tone(count: 3_500)
        let silenceStart = 900
        let silenceEnd = 960
        for index in silenceStart..<silenceEnd { samples[index] = 0 }

        let bounds = chunker().bounds(for: samples)

        guard let firstCut = bounds.first?.upperBound else {
            XCTFail("нет ни одного разреза")
            return
        }
        XCTAssertGreaterThanOrEqual(firstCut, silenceStart - 20)
        XCTAssertLessThanOrEqual(firstCut, silenceEnd + 20)
    }

    func testShortTailIsNotSplitOff() {
        // 1.05 секунды при цели 1.0 и минимальном хвосте 0.1 — резать нечего.
        let bounds = chunker().bounds(for: tone(count: 1_050))
        XCTAssertEqual(bounds, [0..<1_050])
    }

    func testCountOnlyBoundsMatchSampleCount() {
        let chunker = chunker()
        let bySize = chunker.bounds(for: 3_500)
        XCTAssertEqual(bySize.first?.lowerBound, 0)
        XCTAssertEqual(bySize.last?.upperBound, 3_500)
    }

    func testWritesReadableChunk() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "chunk-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = tone(count: 1_600)

        try AudioChunker.write(samples: samples[0..<800], sampleRate: 16_000, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let reloaded = try AudioSamples.load(from: url)
        XCTAssertEqual(reloaded.count, 800, "записалось столько отсчётов, сколько отдали")
    }
}

extension AudioChunkerTests {
    /// Перекрытие: следующий кусок начинается раньше конца предыдущего,
    /// иначе слово на стыке теряется целиком.
    func testChunksOverlap() {
        let chunker = AudioChunker(
            sampleRate: 1_000,
            configuration: AudioChunker.Configuration(
                targetSeconds: 1.0, searchSeconds: 0.0, windowSeconds: 0.02,
                minimumTailSeconds: 0.1, overlapSeconds: 0.2
            )
        )
        let bounds = chunker.bounds(for: (0..<3_000).map { 0.5 * Float(sin(Double($0) * 0.3)) })

        XCTAssertGreaterThan(bounds.count, 1)
        for (previous, next) in zip(bounds, bounds.dropFirst()) {
            XCTAssertLessThan(next.lowerBound, previous.upperBound, "куски должны перекрываться")
            XCTAssertEqual(previous.upperBound - next.lowerBound, 200, "перекрытие 0.2 с при 1 кГц")
        }
        XCTAssertEqual(bounds.first?.lowerBound, 0)
        XCTAssertEqual(bounds.last?.upperBound, 3_000)
    }
}
