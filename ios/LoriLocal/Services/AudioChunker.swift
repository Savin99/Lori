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
        Self.energies(of: samples, window: max(1, Int(configuration.windowSeconds * sampleRate)))
    }

    /// Средний квадрат по окнам подряд. Считается один раз и переиспользуется:
    /// и нарезкой по энкодеру, и поиском паузы для нарезки файла на части.
    static func energies(of samples: [Float], window: Int) -> [Float] {
        let window = max(1, window)
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

    /// Порог тишины по энергии: −60 dBFS. Это тот же порог, которым
    /// `WhisperKitTranscriber` отличает тишину от речи, только выраженный
    /// энергией: там сравнивается амплитуда 0,001, здесь её квадрат.
    static let silenceFloor: Float = 1e-6

    /// Пауза внутри куска отсчётов — секунды от его начала.
    ///
    /// Нужна нарезке записи на части для облачных движков: разрез по таймеру
    /// приходится на середину слова, разрез по паузе — между фразами.
    ///
    /// **Окно тут длиннее, чем при нарезке по энкодеру, и это не произвол.**
    /// Провал энергии в двадцать миллисекунд бывает и посреди слова — между
    /// смычкой и взрывом согласного; паузе между фразами нужны сотни
    /// миллисекунд. По короткому окну разрез сел бы внутрь слова, формально
    /// попав в самое тихое место.
    ///
    /// **Ищется не абсолютный минимум, а ближайшая достаточная пауза.** Минимум
    /// сам по себе выбирает случайное место: на записи с длинной тишиной
    /// подходящих точек сотни, и та, что тише на волос, может лежать на двадцать
    /// секунд дальше нужной. А на ровной тишине минимум и вовсе всегда первый —
    /// разрез уехал бы в самое начало куска. Поэтому среди достаточно тихих
    /// окон берётся ближайшее к `preferred` (по умолчанию — к середине куска,
    /// куда и метил таймер).
    static func quietestOffset(
        in samples: [Float],
        sampleRate: Double = AudioSamples.sampleRate,
        windowSeconds: Double = 0.3,
        preferring preferred: TimeInterval? = nil
    ) -> TimeInterval? {
        let window = max(1, Int(windowSeconds * sampleRate))
        let energies = energies(of: samples, window: window)
        guard let quietest = energies.min() else { return nil }
        let center = preferred ?? Double(samples.count) / sampleRate / 2
        // «Достаточно тихо» — вдвое громче самого тихого окна либо тише порога
        // тишины: у настоящей паузы энергия скачет, и требовать точного минимума
        // значит цепляться за шум.
        let ceiling = max(quietest * 2, silenceFloor)

        var best: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for index in energies.indices where energies[index] <= ceiling {
            let offset = Self.offset(ofWindow: index, window: window, sampleRate: sampleRate)
            let distance = abs(offset - center)
            guard distance < bestDistance else { continue }
            bestDistance = distance
            best = index
        }
        guard let best else { return nil }
        return Self.offset(ofWindow: best, window: window, sampleRate: sampleRate)
    }

    /// Середина окна: у его краёв речь уже может начаться.
    private static func offset(ofWindow index: Int, window: Int, sampleRate: Double) -> TimeInterval {
        (Double(index) + 0.5) * Double(window) / sampleRate
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
