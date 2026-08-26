import XCTest
@testable import LoriLocal

/// Сверка фронтенда с torchaudio. Эталон снят на тех же параметрах, что в config.json
/// модели GigaAM v3, скриптом из design/gigaam. Сигналы синтетические и воспроизводятся
/// в обеих средах точно, поэтому расхождение может дать только арифметика.
final class LogMelSpectrogramTests: XCTestCase {
    private struct Reference: Decodable {
        struct Case: Decodable {
            let frames: Int
            let min: Float
            let max: Float
            let mean: Float
            let frame0: [Float]
            let frame1: [Float]
            let frame2: [Float]
            let frameLast: [Float]
        }
        let sampleRate: Int
        let nMels: Int
        let nFFT: Int
        let winLength: Int
        let hopLength: Int
        let center: Bool
        let sampleCount: Int
        let cases: [String: Case]
    }

    /// Полосы с реальной энергией сверяются строго.
    private static let loudTolerance: Float = 2e-3
    /// Логарифм раздувает разницу в почти пустых полосах: у чистого тона они лежат
    /// на уровне 1e-9, где две разные реализации float32-FFT расходятся в последних
    /// битах. Там осмысленна только относительная линейная мощность.
    private static let relativeTolerance: Float = 1e-2
    private static let energyFloor: Float = -15

    private func loadReference() throws -> Reference {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "logmel-reference", withExtension: "json") else {
            throw XCTSkip("эталон logmel-reference.json не попал в тестовый бандл")
        }
        return try JSONDecoder().decode(Reference.self, from: try Data(contentsOf: url))
    }

    private func sine(count: Int, sampleRate: Int) -> [Float] {
        (0..<count).map { 0.5 * Float(sin(2 * Double.pi * 440 * Double($0) / Double(sampleRate))) }
    }

    private func lcgNoise(count: Int) -> [Float] {
        var state = 42
        let modulus = 1 << 31
        return (0..<count).map { _ in
            state = (1_103_515_245 * state + 12_345) % modulus
            return Float(Double(state) / Double(modulus) * 2 - 1)
        }
    }

    func testConfigurationMatchesModelConfig() throws {
        let reference = try loadReference()
        let configuration = LogMelSpectrogram.Configuration.gigaAMv3
        XCTAssertEqual(Int(configuration.sampleRate), reference.sampleRate)
        XCTAssertEqual(configuration.melCount, reference.nMels)
        XCTAssertEqual(configuration.fftSize, reference.nFFT)
        XCTAssertEqual(configuration.windowLength, reference.winLength)
        XCTAssertEqual(configuration.hopLength, reference.hopLength)
        XCTAssertEqual(configuration.center, reference.center)
    }

    func testMatchesTorchaudioOnSine() throws {
        try compare(caseName: "sine440") { reference in
            sine(count: reference.sampleCount, sampleRate: reference.sampleRate)
        }
    }

    func testMatchesTorchaudioOnNoise() throws {
        try compare(caseName: "lcgNoise") { reference in
            lcgNoise(count: reference.sampleCount)
        }
    }

    func testCenteringIsRejected() {
        let configuration = LogMelSpectrogram.Configuration(
            sampleRate: 16_000, melCount: 64, fftSize: 320, windowLength: 320,
            hopLength: 160, center: true, minimumFrequency: 0, maximumFrequency: 8_000
        )
        XCTAssertThrowsError(try LogMelSpectrogram(configuration: configuration))
    }

    func testShortSignalGivesNoFrames() throws {
        let spectrogram = try LogMelSpectrogram()
        let (values, frames) = spectrogram.features(from: [Float](repeating: 0, count: 100))
        XCTAssertEqual(frames, 0)
        XCTAssertTrue(values.isEmpty)
    }

    private func compare(caseName: String, signal: (Reference) -> [Float]) throws {
        let reference = try loadReference()
        guard let expected = reference.cases[caseName] else {
            XCTFail("нет случая \(caseName) в эталоне")
            return
        }
        let spectrogram = try LogMelSpectrogram()
        let (values, frames) = spectrogram.features(from: signal(reference))

        XCTAssertEqual(frames, expected.frames, "число кадров должно совпадать с torchaudio")
        let melCount = reference.nMels
        func frame(_ index: Int) -> [Float] {
            (0..<melCount).map { values[$0 * frames + index] }
        }

        for (label, want, got) in [
            ("frame0", expected.frame0, frame(0)),
            ("frame1", expected.frame1, frame(1)),
            ("frame2", expected.frame2, frame(2)),
            ("frameLast", expected.frameLast, frame(frames - 1)),
        ] {
            XCTAssertEqual(got.count, want.count, "\(caseName)/\(label): размер кадра")
            for (band, (wanted, actual)) in zip(want, got).enumerated() {
                let relative = abs(exp(actual) - exp(wanted)) / max(exp(wanted), 1e-6)
                XCTAssertLessThan(
                    relative, Self.relativeTolerance,
                    "\(caseName)/\(label): полоса \(band), эталон \(wanted), получено \(actual)"
                )
                if wanted > Self.energyFloor {
                    XCTAssertLessThan(
                        abs(actual - wanted), Self.loudTolerance,
                        "\(caseName)/\(label): громкая полоса \(band), эталон \(wanted), получено \(actual)"
                    )
                }
            }
        }

        // Сводные числа по всей матрице: максимум приходится на громкую полосу и сверяется
        // строго, минимум лежит на численном полу и допускает шум последних битов.
        let actualMean = values.reduce(0, +) / Float(values.count)
        XCTAssertLessThan(abs(actualMean - expected.mean), 0.02, "\(caseName): среднее по всей матрице")
        XCTAssertLessThan(abs((values.max() ?? 0) - expected.max), Self.loudTolerance, "\(caseName): максимум")
        XCTAssertLessThan(abs((values.min() ?? 0) - expected.min), 0.1, "\(caseName): минимум")
    }
}
