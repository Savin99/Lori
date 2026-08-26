import Accelerate
import Foundation

/// Лог-мел признаки для GigaAM.
///
/// Параметры взяты из `config.json` модели v3 и обязаны совпадать с torchaudio:
/// модель обучалась на этих признаках, и любое расхождение она отработает молча,
/// просто выдавая текст хуже. Дефолты `gigaam/preprocess.py` (win 400, `center=true`)
/// от конфига v3 отличаются — доверять им нельзя.
struct LogMelSpectrogram {
    struct Configuration: Sendable, Equatable {
        let sampleRate: Double
        let melCount: Int
        let fftSize: Int
        let windowLength: Int
        let hopLength: Int
        let center: Bool
        let minimumFrequency: Double
        let maximumFrequency: Double

        static let gigaAMv3 = Configuration(
            sampleRate: 16_000,
            melCount: 64,
            fftSize: 320,
            windowLength: 320,
            hopLength: 160,
            center: false,
            minimumFrequency: 0,
            maximumFrequency: 8_000
        )
    }

    enum Failure: LocalizedError {
        case unsupportedCentering
        case transformUnavailable(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedCentering:
                "Реализован только center=false: именно так настроена модель GigaAM v3."
            case let .transformUnavailable(size):
                "vDSP не умеет преобразование длины \(size)."
            }
        }
    }

    let configuration: Configuration

    private let window: [Float]
    /// Матрица melCount × binCount, построчно.
    private let filterbank: [Float]
    private let binCount: Int
    private let transform: vDSP.DiscreteFourierTransform<Float>

    init(configuration: Configuration = .gigaAMv3) throws {
        guard !configuration.center else { throw Failure.unsupportedCentering }
        self.configuration = configuration
        binCount = configuration.fftSize / 2 + 1
        window = Self.hannWindow(count: configuration.windowLength)
        filterbank = Self.melFilterbank(configuration: configuration, binCount: binCount)
        do {
            transform = try vDSP.DiscreteFourierTransform(
                previous: nil,
                count: configuration.fftSize,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
            )
        } catch {
            throw Failure.transformUnavailable(configuration.fftSize)
        }
    }

    func frameCount(forSampleCount count: Int) -> Int {
        guard count >= configuration.windowLength else { return 0 }
        return (count - configuration.windowLength) / configuration.hopLength + 1
    }

    /// Возвращает признаки в раскладке `[mel][frame]` — так же, как тензор `[1, 64, T]`.
    func features(from samples: [Float]) -> (values: [Float], frames: Int) {
        let frames = frameCount(forSampleCount: samples.count)
        guard frames > 0 else { return ([], 0) }

        let melCount = configuration.melCount
        var values = [Float](repeating: 0, count: melCount * frames)

        var windowed = [Float](repeating: 0, count: configuration.fftSize)
        var imaginaryInput = [Float](repeating: 0, count: configuration.fftSize)
        var real = [Float](repeating: 0, count: configuration.fftSize)
        var imaginary = [Float](repeating: 0, count: configuration.fftSize)
        var power = [Float](repeating: 0, count: binCount)

        for frame in 0..<frames {
            let start = frame * configuration.hopLength
            for index in 0..<configuration.windowLength {
                windowed[index] = samples[start + index] * window[index]
            }

            transform.transform(
                inputReal: windowed,
                inputImaginary: imaginaryInput,
                outputReal: &real,
                outputImaginary: &imaginary
            )

            for bin in 0..<binCount {
                power[bin] = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
            }

            for mel in 0..<melCount {
                let energy = filterbank.withUnsafeBufferPointer { bank in
                    power.withUnsafeBufferPointer { spectrum in
                        cblas_sdot(
                            Int32(binCount),
                            bank.baseAddress! + mel * binCount, 1,
                            spectrum.baseAddress!, 1
                        )
                    }
                }
                // torch.log(x.clamp_(1e-9, 1e9)) — натуральный логарифм.
                values[mel * frames + frame] = logf(min(max(energy, 1e-9), 1e9))
            }
        }

        return (values, frames)
    }

    /// Периодическое окно Ханна — то, что torchaudio берёт по умолчанию.
    private static func hannWindow(count: Int) -> [Float] {
        (0..<count).map { index in
            0.5 - 0.5 * cosf(2 * .pi * Float(index) / Float(count))
        }
    }

    private static func hertzToMel(_ hertz: Double) -> Double {
        2595 * log10(1 + hertz / 700)
    }

    private static func melToHertz(_ mel: Double) -> Double {
        700 * (pow(10, mel / 2595) - 1)
    }

    /// Повторяет `torchaudio.functional.melscale_fbanks` с `mel_scale="htk"` и `norm=None`.
    private static func melFilterbank(configuration: Configuration, binCount: Int) -> [Float] {
        let melCount = configuration.melCount
        let binFrequencies = (0..<binCount).map { index in
            configuration.sampleRate / 2 * Double(index) / Double(binCount - 1)
        }

        let melMin = hertzToMel(configuration.minimumFrequency)
        let melMax = hertzToMel(configuration.maximumFrequency)
        let points = (0..<(melCount + 2)).map { index in
            melToHertz(melMin + (melMax - melMin) * Double(index) / Double(melCount + 1))
        }
        let differences = (0..<(melCount + 1)).map { points[$0 + 1] - points[$0] }

        var bank = [Float](repeating: 0, count: melCount * binCount)
        for mel in 0..<melCount {
            for bin in 0..<binCount {
                let frequency = binFrequencies[bin]
                let down = (frequency - points[mel]) / differences[mel]
                let up = (points[mel + 2] - frequency) / differences[mel + 1]
                bank[mel * binCount + bin] = Float(max(0, min(down, up)))
            }
        }
        return bank
    }
}
