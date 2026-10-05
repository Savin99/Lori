import Foundation

/// Есть ли в участке записи звук — и насколько он громкий.
///
/// Контроль полноты (`TranscriptCoverage`) умеет заметить, что для куска записи не
/// пришло ни одного слова, но отличить потерянную речь от тишины он не может: в
/// разговоре молчат минутами, и плашка «похоже на пропуск» на такой тишине — ложная
/// тревога. Владелец увидел четыре таких плашки на одной записи и справедливо
/// спросил, настоящие ли они. Ответить на это может только сам звук.
///
/// **Порог не может быть абсолютным.** −60 dBFS отделяет цифровой ноль от чего
/// угодно, но в настоящей записи молчание — это не ноль: шум комнаты, вентилятор,
/// дыхание в микрофон заведомо громче. Поэтому тишина считается **от уровня речи
/// этой же записи**: участок, который на 20 dB тише того, что модель расшифровала,
/// потерянной речью не является.
enum AudioLoudness {
    /// Окно прослушивания. Короче окно — точнее названный отрезок и больше чтений;
    /// десять секунд — это 640 КБ в памяти за раз и точность до десяти секунд в
    /// тексте плашки. Держать в памяти весь пропуск нельзя: четыре минуты на
    /// 16 кГц — это 15 МБ, а по памяти приложение уже падало.
    static let window: TimeInterval = 10

    /// Абсолютный низ: −60 dBFS по пику. Тот же порог, которым
    /// `WhisperKitTranscriber` отличает тишину от речи. Нужен как страховка на
    /// случай, когда уровень речи посчитать не удалось.
    static let floor: Float = 0.001

    /// Насколько тише речи должен быть участок, чтобы считаться тишиной: −12 dB.
    ///
    /// **Число выставлено по живому прогону, а не по учебнику.** На записи 41:09
    /// уровень речи вышел 0,307 (−10 dBFS), а порог в −20 dB дал 0,031 — и под него
    /// подошёл шум комнаты во всех четырёх «пропусках». Приложение потратило три
    /// оплаченных переспроса и уверенно написало «в записи есть речь» там, где её
    /// не было. Настоящая потерянная речь звучит как речь, то есть у самого уровня,
    /// а не на 20 dB ниже.
    static let quietShare: Float = 0.25

    /// Сколько звука должно набраться, чтобы считать его потерянным разговором.
    ///
    /// Скрип стула или один хлопок посреди тихой минуты — не пропущенная речь.
    /// Разговор же занимает участок целиком: полминуты набираются сразу.
    static let sustain: TimeInterval = 30

    struct Window {
        let range: ClosedRange<TimeInterval>
        let peak: Float
    }

    /// Пик по модулю в каждом окне отрезка.
    ///
    /// Пик, а не средняя громкость: одно слово в конце тихой минуты не должно
    /// потерять всю минуту — ровно этот же выбор сделан в `WhisperKitTranscriber`.
    static func peaks(
        in url: URL,
        range: ClosedRange<TimeInterval>,
        window size: TimeInterval = window
    ) -> [Window] {
        guard size > 0, range.upperBound > range.lowerBound else { return [] }
        var result: [Window] = []
        var start = range.lowerBound
        while start < range.upperBound {
            let length = min(size, range.upperBound - start)
            guard length > 0.01 else { break }
            // Пустое чтение — это конец файла, а не тихое окно: слушать дальше нечего.
            guard let samples = try? AudioSamples.load(from: url, at: start, length: length),
                  !samples.isEmpty else { break }
            result.append(Window(range: start...(start + length), peak: peak(of: samples)))
            start += length
        }
        return result
    }

    /// Уровень речи записи: медиана пиков по отрезкам, для которых расшифровка есть.
    ///
    /// Медиана, а не максимум: один хлопок или кашель задрал бы порог так, что
    /// тишиной оказалась бы вся запись. `nil` — мерить было нечем, и порог
    /// придётся брать абсолютный.
    static func speechLevel(
        in url: URL,
        speech: [ClosedRange<TimeInterval>],
        probes: Int = 12,
        window size: TimeInterval = window
    ) -> Float? {
        guard probes > 0, size > 0 else { return nil }
        var candidates: [TimeInterval] = []
        for range in speech {
            // **Окну разрешено выходить за реплику.** Требовать реплику длиной в
            // окно нельзя: в живой расшифровке реплики по три–пять секунд, мерить
            // было бы нечем, и порог падал бы к абсолютному — то есть к шуму
            // комнаты, названному потерянной речью. Пик от захвата соседней тишины
            // не страдает: тишина его не поднимает.
            var start = range.lowerBound
            repeat {
                candidates.append(start)
                start += size
            } while start < range.upperBound
        }
        guard !candidates.isEmpty else { return nil }

        // Пробы берутся вразброс по всей записи: громкость в начале и в конце
        // разговора разная, и слушать подряд первые окна значит мерить не то.
        let step = max(1, candidates.count / probes)
        var levels: [Float] = []
        for index in stride(from: 0, to: candidates.count, by: step) {
            guard levels.count < probes else { break }
            guard let samples = try? AudioSamples.load(from: url, at: candidates[index], length: size),
                  !samples.isEmpty else { continue }
            levels.append(peak(of: samples))
        }
        guard !levels.isEmpty else { return nil }
        levels.sort()
        return levels[levels.count / 2]
    }

    /// Порог, ниже которого участок считается тишиной.
    static func threshold(speechLevel level: Float?) -> Float {
        max((level ?? 0) * quietShare, floor)
    }

    /// Отрезок со звуком внутри `range`, или `nil` — там нечего расшифровывать.
    ///
    /// Возвращается место, а не «да/нет»: переспрашивать надо именно его, а не
    /// весь пропуск целиком. Одиночный громкий выброс отрезком не считается —
    /// см. `sustain`.
    static func sound(
        in url: URL,
        range: ClosedRange<TimeInterval>,
        louderThan threshold: Float,
        window size: TimeInterval = window,
        sustain: TimeInterval = sustain
    ) -> ClosedRange<TimeInterval>? {
        let loud = peaks(in: url, range: range, window: size).filter { $0.peak >= threshold }
        guard let first = loud.first, let last = loud.last else { return nil }
        let total = loud.reduce(0.0) { $0 + ($1.range.upperBound - $1.range.lowerBound) }
        guard total >= min(sustain, range.upperBound - range.lowerBound) else { return nil }
        return first.range.lowerBound...last.range.upperBound
    }

    private static func peak(of samples: [Float]) -> Float {
        var top: Float = 0
        for value in samples { top = max(top, abs(value)) }
        return top
    }
}
