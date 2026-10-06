import AVFoundation
import Foundation

/// Синтетические звуки для проверки детектора речи (`AudioLoudness`).
///
/// Ровный тон из `AudioFixture` годится, чтобы проверить порог, но не правило
/// «речь — это фразы»: у тона нет ни слогов, ни пауз. Здесь — то, из чего
/// состоят настоящие пропуски: речеподобный сигнал со слогами и паузами, шум
/// комнаты, щелчки, стуки по столу, приступы кашля и клавиатура. Всё
/// детерминировано (свой генератор с зерном), и прогоны не расходятся.
/// Те же звуки и те же числа — на стенде `ios/tools/silence-bench.py`.
enum SyntheticSound {
    static let rate: Double = 16_000

    /// Линейный конгруэнтный генератор: `Float.random` между прогонами разный,
    /// а тест обязан падать или проходить одинаково.
    struct Generator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed &* 2_654_435_761 &+ 1
        }

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }

        mutating func uniform(_ low: Double, _ high: Double) -> Double {
            low + (high - low) * next()
        }
    }

    /// Речеподобный сигнал: слоги-«гласные» по 0,12–0,26 с с тремя гармониками,
    /// между слогами провал 30–80 мс с тихим шумом («согласные»), фразы по
    /// 1,2–3 с, паузы между фразами 0,25–1 с. `level` — RMS звучащих частей.
    static func speechLike(seconds: Double, level: Float, seed: UInt64) -> [Float] {
        var random = Generator(seed: seed)
        let count = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: count)
        var time = 0.0
        while time < seconds {
            let phraseEnd = time + random.uniform(1.2, 3.0)
            let pitch = random.uniform(110, 220)
            while time < min(phraseEnd, seconds) {
                let syllable = random.uniform(0.12, 0.26)
                let from = Int(time * rate)
                let to = min(count, Int((time + syllable) * rate))
                let tone = pitch * random.uniform(0.9, 1.1)
                for index in from..<max(from, to) {
                    let local = Double(index - from) / Double(max(1, to - from))
                    let envelope = sin(Double.pi * local).squareRoot()
                    let phase = 2 * Double.pi * tone * Double(index) / rate
                    samples[index] += Float(envelope * (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)))
                }
                time += syllable
                let gap = random.uniform(0.03, 0.08)
                let gapFrom = Int(time * rate)
                let gapTo = min(count, Int((time + gap) * rate))
                for index in gapFrom..<max(gapFrom, gapTo) {
                    samples[index] += Float(0.1 * random.uniform(-1, 1))
                }
                time += gap
            }
            time += random.uniform(0.25, 1.0)
        }
        var sum: Float = 0
        var sounding = 0
        for value in samples where abs(value) > 1e-6 {
            sum += value * value
            sounding += 1
        }
        let rms = sounding > 0 ? (sum / Float(sounding)).squareRoot() : 1
        return samples.map { $0 * level / rms }
    }

    /// Ровный шум комнаты с заданным RMS.
    static func noise(seconds: Double, rms: Float, seed: UInt64) -> [Float] {
        var random = Generator(seed: seed)
        let scale = Double(rms) * 3.0.squareRoot()
        return (0..<Int(seconds * rate)).map { _ in Float(random.uniform(-1, 1) * scale) }
    }

    /// Щелчок: три миллисекунды, затухание 0,7 мс.
    static func click(peak: Float) -> [Float] {
        (0..<Int(0.003 * rate)).map { index in
            peak * Float(exp(-Double(index) / rate / 0.0007)) * (index.isMultiple(of: 2) ? 1 : -1)
        }
    }

    /// Стук по столу, на котором лежит телефон: затухающий тон 400 Гц, 120 мс.
    static func knock(peak: Float) -> [Float] {
        (0..<Int(0.12 * rate)).map { index in
            let time = Double(index) / rate
            return peak * Float(exp(-time / 0.025) * sin(2 * Double.pi * 400 * time))
        }
    }

    /// Приступ кашля: три шумовых всплеска по 0,3 с через 0,55 с.
    static func coughFit(rms: Float, seed: UInt64) -> [Float] {
        var random = Generator(seed: seed)
        let burst = Int(0.3 * rate)
        let step = Int(0.55 * rate)
        var samples = [Float](repeating: 0, count: step * 2 + burst)
        for start in [0, step, step * 2] {
            var part = (0..<burst).map { index -> Float in
                let time = Double(index) / rate
                let envelope = min(1, time / 0.01) * exp(-time / 0.12)
                return Float(random.uniform(-1, 1) * envelope)
            }
            let energy = part.reduce(0) { $0 + $1 * $1 } / Float(burst)
            let gain = rms / energy.squareRoot()
            part = part.map { $0 * gain }
            for (offset, value) in part.enumerated() { samples[start + offset] += value }
        }
        return samples
    }

    /// Клавиатура: семь нажатий в секунду.
    static func typing(seconds: Double, peak: Float) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * rate))
        let press = click(peak: peak)
        var time = 0.0
        while time < seconds - 0.01 {
            add(press, to: &samples, at: time)
            time += 1.0 / 7
        }
        return samples
    }

    /// Наложить звук на дорожку с заданной секунды.
    static func add(_ part: [Float], to base: inout [Float], at seconds: Double) {
        let start = Int(seconds * rate)
        guard start < base.count else { return }
        for (offset, value) in part.enumerated() where start + offset < base.count {
            base[start + offset] += value
        }
    }

    /// Записать дорожку в WAV 16 кГц моно — так её читает `AudioSamples`.
    static func write(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, value) in samples.enumerated() { channel[index] = value }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// «Минута разговора — проверяемый участок — минута разговора» с шумом
    /// комнаты на всей дорожке (−35 dB от речи): так выглядели пропуски на записи
    /// владельца 43:28. Участок начинается на 60-й секунде.
    static func conversation(around middle: [Float], level: Float = 0.1, seed: UInt64 = 1) -> [Float] {
        var samples = speechLike(seconds: 60, level: level, seed: seed)
            + middle
            + speechLike(seconds: 60, level: level, seed: seed &+ 1)
        let room = noise(seconds: Double(samples.count) / rate, rms: level * 0.018, seed: seed &+ 2)
        for index in samples.indices where index < room.count { samples[index] += room[index] }
        return samples
    }

    /// Минута тишины, какая бывает посреди разговора: шум комнаты, щелчки громче
    /// пика речи, стуки по столу, два приступа кашля и четыре секунды клавиатуры.
    /// Каждое из этого в прежнем правиле (пик в десятисекундном окне) делало
    /// громким всё окно.
    static func busySilence(seconds: Double = 60, speech level: Float, seed: UInt64) -> [Float] {
        let speechPeak = level * 2.4
        var samples = noise(seconds: seconds, rms: level * 0.018, seed: seed)
        for at in [3.2, 11.7, 19.1, 33.3, 47.9, 55.5] where at < seconds {
            add(click(peak: speechPeak * 1.5), to: &samples, at: at)
        }
        for at in [7.4, 26.0, 41.2] where at < seconds {
            add(knock(peak: speechPeak * 2), to: &samples, at: at)
        }
        for (index, at) in [14.0, 37.5].enumerated() where at < seconds {
            add(coughFit(rms: level * 1.4, seed: seed &+ UInt64(index) &+ 7), to: &samples, at: at)
        }
        if seconds > 54 {
            add(typing(seconds: 4, peak: speechPeak * 0.6), to: &samples, at: 50)
        }
        return samples
    }
}
