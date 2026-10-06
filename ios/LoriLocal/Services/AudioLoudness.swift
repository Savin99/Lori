import Foundation

/// Есть ли в участке записи речь — или там тишина с помехами.
///
/// Контроль полноты (`TranscriptCoverage`) замечает, что для куска записи не
/// пришло ни одного слова, но отличить потерянную речь от молчания он не может:
/// в разговоре молчат минутами, и плашка «пропуск» на такой тишине — ложная
/// тревога. Ответить может только сам звук.
///
/// **Почему больше не пик.** До 6 октября 2026 участок считался звучащим, если в
/// десятисекундном окне хоть один отсчёт был громче порога, а таких окон
/// набиралось на полминуты. Один щелчок, стук по столу, кашель или вдох делали
/// громким всё окно — и владелец увидел на записи 43:28 (ElevenLabs, «Дословно»)
/// плашки «Пропуск 4:19–5:19» и «Пропуск 20:17–20:34» там, где была тишина. На
/// стенде (`ios/tools/silence-bench.py`, 30 минут на клетку) прежнее правило
/// назвало пропуском от 14 до 30 минут тишины из 30 со щелчками, стуками,
/// кашлем, клавиатурой или вдохами; новое — ни одной (одну из 30 — при кашле без
/// перерыва).
///
/// **Теперь три шага, и каждый отсекает своё** (числа — со стенда, раздел
/// «Ложный пропуск на тишине» в `ios/CLAUDE.md`):
/// 1. Уровень окна в полсекунды — громкость, которую держит хотя бы пятая часть
///    его двадцатимиллисекундных кадров. Щелчок, стук и клавиша живут
///    миллисекунды и до пятой части окна не дотягивают; гласные речи тянутся
///    сотнями миллисекунд.
/// 2. Порог — от уровня речи этой же записи (−12 dB, живой прогон 3 сентября)
///    и не ниже фона самого участка +6 dB: ровный шум — кондиционер, улица —
///    речью не становится, даже когда говорящие тихие.
/// 3. Речь — это фразы. Громкие окна, между которыми не больше одного тихого,
///    тянутся от четырёх секунд, и громкого времени в таких фразах набирается от
///    пяти секунд (на длинном участке — от 10% его длины). Кашель, хлопок двери
///    и вдох короче фразы.
enum AudioLoudness {
    /// Версия правила. Сменилось правило — вердикты, сохранённые по старому
    /// (`GapRecheck`), больше не годятся.
    static let rule = 2

    /// Окно оценки — полсекунды. Короче — слог и кашель неотличимы по длине,
    /// длиннее — паузы между словами растворяют фразу.
    static let window: TimeInterval = 0.5

    /// Кадр внутри окна: 20 мс, обычный кадр анализа речи.
    static let frame: TimeInterval = 0.02

    /// Какая доля кадров окна должна звучать: пятая часть, 100 мс из 500.
    ///
    /// На стенде щелчки (3 мс) и клавиатура не дали ни одного громкого окна,
    /// стук (до 40 мс) — не больше одного подряд, а в минуте, полной речи,
    /// громких окон 84% (речь с запинками — 66%). Пик, которым это мерилось
    /// раньше, — та же громкость, но одного отсчёта.
    static let heldShare: Double = 0.2

    /// Файл читается кусками по десять секунд: 640 КБ в памяти за раз. Держать
    /// весь участок нельзя — четыре минуты на 16 кГц это 15 МБ, а по памяти
    /// приложение уже падало.
    static let chunk: TimeInterval = 10

    /// Абсолютный низ: −60 dBFS. Тот же порог, которым `WhisperKitTranscriber`
    /// отличает цифровую тишину. Нужен, когда уровень речи посчитать не удалось.
    static let floor: Float = 0.001

    /// Насколько тише речи должен быть звук, чтобы считаться тишиной: −12 dB.
    ///
    /// **Число выставлено по живому прогону, а не по учебнику.** На записи 41:09
    /// уровень речи вышел 0,307 (−10 dBFS), и порог −20 dB пропустил шум комнаты
    /// во всех четырёх «пропусках»; −12 dB — уже нет. Потерянная речь звучит как
    /// речь, у самого уровня, а не на 20 dB ниже.
    static let quietShare: Float = 0.25

    /// Порог не ниже фона самого участка, умноженного на это: +6 dB.
    ///
    /// Относительный порог один не спасает, когда говорящие тихие: на стенде при
    /// шуме комнаты на 12 dB тише речи без этой поправки пропуском звались все
    /// 30 минут тишины из 30 — с любыми помехами и без них, — с ней ни одной.
    /// Фон — тихие окна участка (`noisePercentile`): в любой паузе между фразами
    /// звучит именно он.
    static let aboveNoise: Float = 2

    /// Какие окна участка считаются его фоном: десятый перцентиль громкости.
    static let noisePercentile: Double = 0.1

    /// …но поправка не поднимает порог выше уровня речи −3 dB. Иначе звук ровной
    /// громкости — музыка, телевизор, тон в тестах — не прошёл бы ни при какой
    /// громкости, а он и есть «в записи что-то звучит, а текста нет».
    static let noiseCap: Float = 0.7

    /// Сколько тихих окон подряд фраза переживает: одно, полсекунды. Между
    /// словами и фразами одного человека паузы короче, а без склейки речь с
    /// запинками рассыпается на куски короче фразы: на стенде минута такой речи
    /// находилась в 16 случаях из 30, семнадцать секунд — в 3; со склейкой — в 30
    /// и 26, а тишина с помехами осталась тишиной.
    static let bridge = 1

    /// Фраза — от четырёх секунд. Приступ кашля на стенде тянулся до 3,5 с,
    /// хлопок двери и вдох — до секунды. Кашель без перерыва, слипаясь со
    /// вдохами, дотягивал до 6 с — поэтому одной фразы мало, нужен ещё `sustain`.
    static let phrase: TimeInterval = 4

    /// Сколько громкого времени во фразах нужно, чтобы назвать участок потерянной
    /// речью: пять секунд. На длинном участке — `sustainShare` его длины: на
    /// пятиминутной паузе помех набирается больше, чем на минутной.
    static let sustain: TimeInterval = 5
    static let sustainShare: Double = 0.1

    struct Window: Equatable, Sendable {
        let range: ClosedRange<TimeInterval>
        /// Громкость (RMS кадра), которую держит хотя бы `heldShare` окна.
        let level: Float

        var length: TimeInterval { range.upperBound - range.lowerBound }
        var middle: TimeInterval { (range.lowerBound + range.upperBound) / 2 }
    }

    /// Что звучит в участке.
    enum Verdict: Equatable, Sendable {
        /// Речь, и где именно: переспрашивать и называть в плашке надо это место.
        case speech(ClosedRange<TimeInterval>)
        case silence
        /// Звука нет вовсе — участок за концом файла или файл не читается. Это
        /// не тишина: про участок, которого не слышали, утверждать нечего.
        case unreadable
    }

    // MARK: - Звук участка

    /// Окна по полсекунды на отрезке — с громкостью каждого. Сетка окон идёт от
    /// начала отрезка ровно через полсекунды.
    static func levels(in url: URL, range: ClosedRange<TimeInterval>) -> [Window] {
        guard range.upperBound > range.lowerBound else { return [] }
        let rate = AudioSamples.sampleRate
        let perWindow = Int(window * rate)
        // Хвост короче десятой секунды судить не по чему.
        let shortest = Int(0.1 * rate)
        let total = Int(((range.upperBound - range.lowerBound) * rate).rounded())
        var result: [Window] = []
        var pending: [Float] = []
        var head = 0
        var cut = 0
        var fetched = 0

        func emit(_ count: Int) {
            let from = range.lowerBound + Double(cut) / rate
            let to = min(range.lowerBound + Double(cut + count) / rate, range.upperBound)
            result.append(Window(range: from...max(from, to), level: level(of: pending[head..<(head + count)])))
            head += count
            cut += count
        }

        while fetched < total {
            let start = range.lowerBound + Double(fetched) / rate
            let length = min(chunk, Double(total - fetched) / rate)
            // Пустое чтение — это конец файла, а не тихое окно: слушать дальше нечего.
            guard let samples = try? AudioSamples.load(from: url, at: start, length: length),
                  !samples.isEmpty else { break }
            // `AVAudioFile` отдаёт за раз не всё, что просили: на десять секунд —
            // на 256–512 отсчётов меньше (замерено 6 октября в симуляторе и на Mac). Поэтому
            // следующее чтение начинается там, где кончилось это, а окна режутся из
            // сплошного потока — иначе на каждом стыке выпадали бы 30 мс, а сетка
            // окон уезжала бы от начала отрезка.
            let taken = min(samples.count, total - fetched)
            pending.append(contentsOf: samples[0..<taken])
            fetched += taken
            while pending.count - head >= perWindow { emit(perWindow) }
            pending.removeFirst(head)
            head = 0
        }
        if pending.count - head >= shortest { emit(pending.count - head) }
        return result
    }

    /// Громкость, которую держит хотя бы `heldShare` кадров: перцентиль энергии
    /// двадцатимиллисекундных кадров, а из неё RMS.
    static func level(of samples: ArraySlice<Float>) -> Float {
        let size = max(1, Int(frame * AudioSamples.sampleRate))
        let count = samples.count / size
        guard count > 0 else { return rms(of: samples) }
        var energies: [Float] = []
        energies.reserveCapacity(count)
        var cursor = samples.startIndex
        for _ in 0..<count {
            var sum: Float = 0
            for value in samples[cursor..<(cursor + size)] { sum += value * value }
            energies.append(sum / Float(size))
            cursor += size
        }
        return percentile(energies, 1 - heldShare).squareRoot()
    }

    // MARK: - Уровень речи

    /// Уровень речи записи: медиана громкости окон, лежащих внутри расшифрованного
    /// времени.
    ///
    /// Медиана, а не максимум: один хлопок или кашель задрал бы порог так, что
    /// тишиной оказалась бы вся запись. `nil` — мерить было нечем.
    ///
    /// Пробы — по четыре секунды вразброс по всей записи: громкость в начале и в
    /// конце разговора разная. **Проба читается и за краем реплики** — живые
    /// реплики по три–пять секунд, — но в счёт идут только окна, середина которых
    /// лежит внутри речи. Пику соседняя тишина не мешала, громкости кадров —
    /// мешает: она тянула бы уровень вниз, а за ним и порог.
    static func speechLevel(
        in url: URL,
        speech: [ClosedRange<TimeInterval>],
        probes: Int = 12,
        probe: TimeInterval = 4
    ) -> Float? {
        guard probes > 0, probe > 0 else { return nil }
        let ranges = speech
            .filter { $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        var candidates: [TimeInterval] = []
        for range in ranges {
            var start = range.lowerBound
            repeat {
                candidates.append(start)
                start += probe
            } while start < range.upperBound
        }
        guard !candidates.isEmpty else { return nil }

        let step = max(1, candidates.count / probes)
        var levels: [Float] = []
        var taken = 0
        for index in stride(from: 0, to: candidates.count, by: step) {
            guard taken < probes else { break }
            taken += 1
            let from = candidates[index]
            for window in Self.levels(in: url, range: from...(from + probe))
            where ranges.contains(where: { $0.contains(window.middle) }) {
                levels.append(window.level)
            }
        }
        guard !levels.isEmpty else { return nil }
        levels.sort()
        return levels[levels.count / 2]
    }

    // MARK: - Порог

    /// Порог, ниже которого звук считается тишиной: от уровня речи этой записи.
    static func threshold(speechLevel level: Float?) -> Float {
        max((level ?? 0) * quietShare, floor)
    }

    /// Порог для конкретного участка: от уровня речи и не ниже его собственного
    /// фона +6 dB (но не выше уровня речи −3 dB).
    ///
    /// Без уровня речи потолка нет: тогда звук ровной громкости без единой паузы
    /// речью не считается — речь без пауз не бывает.
    static func threshold(speechLevel level: Float?, background windows: [Window]) -> Float {
        let base = threshold(speechLevel: level)
        guard !windows.isEmpty else { return base }
        let noise = percentile(windows.map(\.level), noisePercentile) * aboveNoise
        guard let level else { return max(base, noise) }
        return max(base, min(noise, level * noiseCap))
    }

    // MARK: - Речь в участке

    /// Отрезок с речью среди окон, или `nil` — там нечего расшифровывать.
    ///
    /// Возвращается место, а не «да/нет»: переспрашивать надо именно его, а не
    /// весь пропуск целиком. Место — от начала первой фразы до конца последней.
    ///
    /// `sustain` — сколько громкого времени во фразах нужно; без него — пять
    /// секунд, а на длинном участке 10% его длины. На коротком отрезке требования
    /// не длиннее самого отрезка: секундный участок, звучащий целиком, — звук.
    static func sound(
        in windows: [Window],
        louderThan threshold: Float,
        sustain: TimeInterval? = nil
    ) -> ClosedRange<TimeInterval>? {
        guard let first = windows.first, let last = windows.last else { return nil }
        let length = last.range.upperBound - first.range.lowerBound
        let needPhrase = min(phrase, length)
        let needTotal = min(sustain ?? max(Self.sustain, sustainShare * length), length)
        // Окна идут подряд с шагом в полсекунды, и сравнение времени на краю не
        // должно зависеть от ошибки округления.
        let slack: TimeInterval = 0.001

        var phrases: [ClosedRange<TimeInterval>] = []
        var loudTime: TimeInterval = 0
        var index = 0
        while index < windows.count {
            guard windows[index].level >= threshold else {
                index += 1
                continue
            }
            var end = index
            var loud = windows[index].length
            var cursor = index + 1
            while cursor < windows.count {
                if windows[cursor].level >= threshold {
                    end = cursor
                    loud += windows[cursor].length
                } else if cursor - end > bridge {
                    break
                }
                cursor += 1
            }
            let span = windows[index].range.lowerBound...windows[end].range.upperBound
            if span.upperBound - span.lowerBound >= needPhrase - slack {
                phrases.append(span)
                loudTime += loud
            }
            index = end + 1
        }
        guard let opening = phrases.first, let closing = phrases.last,
              loudTime >= needTotal - slack else { return nil }
        return opening.lowerBound...closing.upperBound
    }

    /// То же по файлу, с заданным порогом: участок читается окнами и судится как
    /// есть, без поправки на фон.
    static func sound(
        in url: URL,
        range: ClosedRange<TimeInterval>,
        louderThan threshold: Float,
        sustain: TimeInterval? = nil
    ) -> ClosedRange<TimeInterval>? {
        sound(in: levels(in: url, range: range), louderThan: threshold, sustain: sustain)
    }

    /// Что звучит в участке записи — с порогом от уровня речи и фона участка.
    /// Этим судят пропуски все облачные движки и перепроверка старых плашек.
    static func verdict(
        in url: URL,
        range: ClosedRange<TimeInterval>,
        speechLevel level: Float?
    ) -> Verdict {
        let windows = levels(in: url, range: range)
        guard !windows.isEmpty else { return .unreadable }
        let threshold = threshold(speechLevel: level, background: windows)
        return sound(in: windows, louderThan: threshold).map(Verdict.speech) ?? .silence
    }

    /// Отрезок с потерянной речью внутри участка, или `nil` — там тишина или
    /// звук не читается.
    static func lostSpeech(
        in url: URL,
        range: ClosedRange<TimeInterval>,
        speechLevel level: Float?
    ) -> ClosedRange<TimeInterval>? {
        guard case let .speech(found) = verdict(in: url, range: range, speechLevel: level) else { return nil }
        return found
    }

    // MARK: - Счёт

    /// Перцентиль с линейной интерполяцией между соседями — как `numpy.percentile`
    /// на стенде, чтобы числа там и здесь были одни.
    static func percentile(_ values: [Float], _ share: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Double(sorted.count - 1) * min(1, max(0, share))
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = Float(position - Double(lower))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    private static func rms(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for value in samples { sum += value * value }
        return (sum / Float(samples.count)).squareRoot()
    }
}
