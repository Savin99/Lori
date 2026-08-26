import AVFoundation
import Foundation

/// Нарезка длинного аудио на куски для распознавания.
///
/// `SFSpeechURLRecognitionRequest` рассчитан на короткую диктовку и на записи
/// в несколько минут перестаёт отдавать результат. Поэтому длинное аудио режется,
/// причём не по таймеру: рядом с целевой границей ищется самый тихий участок,
/// чтобы разрез не приходился на середину слова.
struct AudioChunker {
    struct Configuration: Sendable {
        /// Целевая длина куска.
        var targetSeconds: Double = 40
        /// Насколько можно сдвинуть границу в поисках тишины.
        var searchSeconds: Double = 4
        /// Окно, по которому считается энергия.
        var windowSeconds: Double = 0.02
        /// Куски короче этого к предыдущему не добавляются отдельным файлом.
        var minimumTailSeconds: Double = 0.5
        /// Насколько следующий кусок заходит на предыдущий. Без перекрытия слово
        /// на стыке теряется: обрезанную половину не узнаёт ни один кусок.
        var overlapSeconds: Double = 1.5

        static let `default` = Configuration()
    }

    let sampleRate: Double
    let configuration: Configuration

    init(sampleRate: Double = AudioSamples.sampleRate, configuration: Configuration = .default) {
        self.sampleRate = sampleRate
        self.configuration = configuration
    }

    /// Границы кусков в отсчётах. Для короткого сигнала — один кусок целиком.
    func bounds(for sampleCount: Int) -> [Range<Int>] {
        let target = Int(configuration.targetSeconds * sampleRate)
        guard sampleCount > target else { return sampleCount > 0 ? [0..<sampleCount] : [] }
        return boundsBySilence(sampleCount: sampleCount, energies: nil)
    }

    /// Границы с учётом тишины: разрез сдвигается к самому тихому окну рядом с целевой точкой.
    func bounds(for samples: [Float]) -> [Range<Int>] {
        let target = Int(configuration.targetSeconds * sampleRate)
        guard samples.count > target else { return samples.isEmpty ? [] : [0..<samples.count] }
        return boundsBySilence(sampleCount: samples.count, energies: windowEnergies(samples))
    }

    private func boundsBySilence(sampleCount: Int, energies: [Float]?) -> [Range<Int>] {
        let target = Int(configuration.targetSeconds * sampleRate)
        let search = Int(configuration.searchSeconds * sampleRate)
        let window = max(1, Int(configuration.windowSeconds * sampleRate))
        let minimumTail = Int(configuration.minimumTailSeconds * sampleRate)

        var result: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let remaining = sampleCount - start
            if remaining <= target + minimumTail {
                result.append(start..<sampleCount)
                break
            }
            let ideal = start + target
            var cut = ideal
            if let energies {
                let from = max(start + target - search, start + window)
                let to = min(start + target + search, sampleCount - 1)
                cut = quietestPoint(in: from...to, energies: energies, window: window) ?? ideal
            }
            result.append(start..<cut)
            // Следующий кусок начинается раньше разреза — на величину перекрытия.
            // Перекрытие не должно съедать продвижение: иначе нарезка топчется
            // на месте и плодит куски по одному отсчёту.
            let overlap = min(Int(configuration.overlapSeconds * sampleRate), target / 2)
            start = max(start + target / 2, cut - overlap)
        }
        return result
    }

    /// Индекс отсчёта, рядом с которым энергия минимальна.
    private func quietestPoint(in range: ClosedRange<Int>, energies: [Float], window: Int) -> Int? {
        let firstWindow = range.lowerBound / window
        let lastWindow = min(range.upperBound / window, energies.count - 1)
        guard firstWindow <= lastWindow else { return nil }
        var best = firstWindow
        var bestValue = energies[firstWindow]
        for index in firstWindow...lastWindow where energies[index] < bestValue {
            bestValue = energies[index]
            best = index
        }
        return min(max(best * window, range.lowerBound), range.upperBound)
    }

    private func windowEnergies(_ samples: [Float]) -> [Float] {
        let window = max(1, Int(configuration.windowSeconds * sampleRate))
        let count = samples.count / window
        guard count > 0 else { return [] }
        var energies = [Float](repeating: 0, count: count)
        for index in 0..<count {
            var sum: Float = 0
            let offset = index * window
            for position in offset..<(offset + window) {
                let value = samples[position]
                sum += value * value
            }
            energies[index] = sum / Float(window)
        }
        return energies
    }

    /// Пишет кусок во временный WAV: распознавателю нужен файл, а не буфер.
    static func write(
        samples: ArraySlice<Float>,
        sampleRate: Double,
        to url: URL
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioSamples.Failure.conversionFailed(url.lastPathComponent)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
            ]
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw AudioSamples.Failure.conversionFailed(url.lastPathComponent)
        }
        for (index, value) in samples.enumerated() { channel[index] = value }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }
}
