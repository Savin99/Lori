import AVFoundation
import Foundation

/// Тип содержимого для загрузки файла в API. Сервер по одному расширению угадывать
/// не обязан, а Gemini без `mime_type` вообще не принимает аудио.
enum AudioMIME {
    static func type(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "aac": "audio/aac"
        case "aiff", "aif": "audio/aiff"
        case "caf": "audio/x-caf"
        case "mov": "video/quicktime"
        case "flac": "audio/flac"
        default: "application/octet-stream"
        }
    }

    /// Название формата для журнала: по коду понятно, что именно записал диктофон.
    static func describe(_ identifier: AudioFormatID) -> String {
        switch identifier {
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatMPEG4AAC: "AAC"
        case kAudioFormatLinearPCM: "PCM"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatMPEGLayer3: "MP3"
        default: "формат \(identifier)"
        }
    }
}

/// Режет длинную запись на части для облачных движков: у OpenAI жёсткий лимит
/// на размер запроса, а Gemini на многочасовом аудио обрывает ответ на середине.
/// Локальные движки в этом не участвуют — у них своя нарезка по окну энкодера
/// (`AudioChunker`), она работает с отсчётами, а не с файлами.
struct AudioSplitter: Sendable {
    /// Части лежат в отдельной папке в tmp. Убирать её — забота вызывающего:
    /// `discard(_:)` вызывается в `defer`, иначе аудио копится в контейнере.
    struct Part: Sendable {
        let url: URL
        /// Сдвиг части от начала записи: без него тайминги слов во второй части
        /// начинались бы снова с нуля.
        let start: TimeInterval
        /// Длительность части. Нужна, чтобы считать покрытие: без неё непонятно,
        /// весь ли кусок расшифрован.
        let length: TimeInterval
        let isOriginal: Bool

        var end: TimeInterval { start + length }
    }

    func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return try await asset.load(.duration).seconds
    }

    func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Длина части, при которой файл влезает в лимит запроса. Битрейт берётся
    /// по факту из размера файла: у записи с диктофона он один, у импортированного
    /// mp3 — совсем другой.
    func partSeconds(for url: URL, duration: TimeInterval, maxBytes: Int) -> TimeInterval {
        let bytes = size(of: url)
        guard bytes > maxBytes, duration > 1 else { return duration }
        let bytesPerSecond = Double(bytes) / duration
        guard bytesPerSecond > 0 else { return duration }
        // 5% запаса: контейнер каждой части несёт свои заголовки.
        return max(30, Double(maxBytes) * 0.95 / bytesPerSecond)
    }

    /// Насколько части заходят друг на друга. Без перекрытия слово на стыке
    /// пропадает целиком: одна часть кончается на его середине, другая с середины
    /// начинается, и ни одна не узнаёт его. Дубликаты потом отбрасываются по времени.
    static let defaultOverlap: TimeInterval = 2

    /// Насколько граница части может уехать от целевой точки в поисках паузы.
    /// Двадцать секунд — это заведомо больше самой длинной фразы и заведомо
    /// меньше части: разрез остаётся там, где его ждали, с точностью до абзаца.
    static let silenceSearch: TimeInterval = 20

    /// Возвращает части длиной не больше `partSeconds`, с перекрытием. Если резать
    /// нечего, отдаёт исходный файл с пометкой `isOriginal` — его удалять нельзя.
    ///
    /// `alignToSilence` сажает границы на паузы. Это стоит одного чтения звука
    /// на каждый стык и нужно там, где части становятся единицей показа: у Gemini
    /// в режиме «Точность» время реплики — это и есть границы части, и разрез
    /// посреди слова человек увидит прямо в тексте.
    ///
    /// Часть при этом **никогда не становится длиннее запрошенной** — см.
    /// `alignedLength`.
    func split(
        _ url: URL,
        partSeconds: TimeInterval,
        overlapSeconds: TimeInterval = Self.defaultOverlap,
        alignToSilence: Bool = false
    ) async throws -> [Part] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw TranscriptionError.emptyResult }
        guard partSeconds > 0, duration > partSeconds + 1 else {
            return [Part(url: url, start: 0, length: duration, isOriginal: true)]
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LoriParts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Перекрытие не может съесть весь шаг, иначе нарезка не продвигается вперёд.
        let overlap = max(0, min(overlapSeconds, partSeconds / 2))
        var parts: [Part] = []
        var start: TimeInterval = 0
        var index = 0
        while start < duration - 0.1 {
            var length = min(partSeconds, duration - start)
            // Последнюю границу двигать некуда: там конец записи, а не стык.
            if alignToSilence, start + length < duration - 0.1 {
                length = alignedLength(in: url, start: start, length: length, duration: duration)
            }
            let output = directory.appending(path: String(format: "part-%03d.m4a", index))
            try await export(asset: asset, from: start, length: length, to: output)
            parts.append(Part(url: output, start: start, length: length, isOriginal: false))
            if start + length >= duration - 0.1 { break }
            start += length - overlap
            index += 1
        }
        return parts
    }

    /// Длина части с границей, сдвинутой на ближайшую паузу.
    ///
    /// Не вышло прочитать звук или найти тишину — возвращается исходная длина:
    /// нарезка по таймеру хуже нарезки по паузе, но лучше отказа расшифровать.
    func alignedLength(
        in url: URL,
        start: TimeInterval,
        length: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        // Окно поиска соразмерно части, а не постоянно: на десятиминутной части
        // двадцать секунд — это доля процента, а на десятисекундной тот же поиск
        // сдвинул бы границу куда угодно и оставил в записи дыры.
        let search = min(Self.silenceSearch, length / 4)
        guard search > 0.5 else { return length }

        // **Пауза ищется только до намеченной границы, не после.** Сдвиг вперёд
        // сделал бы часть длиннее запрошенной, а запрошенная длина у облачного
        // движка упирается в предел одного запроса: пауза на секунду позже цели
        // стоила бы отказа сервиса. Речь пауз не жалеет, и назад в двадцати
        // секундах она почти всегда есть.
        let cut = start + length
        let from = max(start + 0.5, cut - search)
        guard cut - from > 1 else { return length }
        guard let samples = try? AudioSamples.load(from: url, at: from, length: cut - from),
              !samples.isEmpty,
              // Предпочтение — конец окна: это и есть намеченная граница, и из
              // двух пауз ближе к ней та, что позже.
              let offset = AudioChunker.quietestOffset(in: samples, preferring: cut - from) else {
            Diagnostics.note("нарезка: паузу у \(Int(cut)) с не нашли, режем по таймеру")
            return length
        }
        let moved = from + offset
        Diagnostics.note("нарезка: граница \(Int(cut)) с сдвинута на паузу \(Int(moved)) с")
        return moved - start
    }

    /// Части по одной, по мере надобности.
    ///
    /// **Резать всё вперёд оказалось дорого.** На живом прогоне записи 84:06
    /// нарезка на девять частей заняла 1 минуту 32 секунды — и всё это до
    /// первого запроса. Фоновая задача в тот раз прожила 3 минуты 57 секунд,
    /// то есть 38% отпущенного окна ушло на подготовку, а расшифровка
    /// оборвалась на седьмой части из девяти.
    ///
    /// Здесь часть готовится прямо перед своим запросом: первый уходит через
    /// секунды, а не через две минуты, и оборванная работа не уносит с собой
    /// экспорт частей, до которых дело не дошло.
    struct Cutter {
        let splitter: AudioSplitter
        let url: URL
        let duration: TimeInterval
        let partSeconds: TimeInterval
        let overlapSeconds: TimeInterval
        let alignToSilence: Bool

        private var start: TimeInterval
        private var finished = false

        init(
            splitter: AudioSplitter,
            url: URL,
            duration: TimeInterval,
            partSeconds: TimeInterval,
            overlapSeconds: TimeInterval = AudioSplitter.defaultOverlap,
            alignToSilence: Bool = false,
            from cursor: TimeInterval = 0
        ) {
            self.splitter = splitter
            self.url = url
            self.duration = duration
            self.partSeconds = partSeconds
            self.overlapSeconds = overlapSeconds
            self.alignToSilence = alignToSilence
            self.start = max(0, cursor)
        }

        /// Откуда пойдёт следующая часть. Это и есть отметка для чекпоинта.
        var cursor: TimeInterval { start }

        /// Сколько частей ожидается **всего** от начала записи.
        ///
        /// Число оценочное: границы уезжают к паузам, и точное станет известно
        /// только в конце. Полосе прогресса нужна верхняя граница, а не правда —
        /// показать 100% раньше времени хуже, чем показать 90%.
        var expectedCount: Int {
            let step = max(1, partSeconds - overlapSeconds)
            return max(1, Int((duration / step).rounded(.up)))
        }

        mutating func next() async throws -> Part? {
            guard !finished, start < duration - 0.1 else { return nil }
            var length = min(partSeconds, duration - start)
            // Последнюю границу двигать некуда: там конец записи, а не стык.
            if alignToSilence, start + length < duration - 0.1 {
                length = splitter.alignedLength(in: url, start: start, length: length, duration: duration)
            }
            let part = try await splitter.part(of: url, from: start, length: length)
            if start + length >= duration - 0.1 {
                finished = true
                start = duration
            } else {
                let overlap = max(0, min(overlapSeconds, partSeconds / 2))
                start += length - overlap
            }
            return part
        }
    }

    /// Нарезка по одной части. `from` — сколько записи уже расшифровано:
    /// после обрыва работа продолжается с этой секунды, а не с нуля.
    func cutter(
        _ url: URL,
        duration: TimeInterval,
        partSeconds: TimeInterval,
        overlapSeconds: TimeInterval = Self.defaultOverlap,
        alignToSilence: Bool = false,
        from cursor: TimeInterval = 0
    ) -> Cutter {
        Cutter(
            splitter: self,
            url: url,
            duration: duration,
            partSeconds: partSeconds,
            overlapSeconds: overlapSeconds,
            alignToSilence: alignToSilence,
            from: cursor
        )
    }

    /// Отдельный кусок произвольного участка записи: нужен, чтобы переспросить
    /// сервис по месту, которое он пропустил.
    func part(of url: URL, from start: TimeInterval, length: TimeInterval) async throws -> Part {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let from = max(0, min(start, duration))
        let span = max(0.5, min(length, duration - from))
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LoriGap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "gap.m4a")
        try await export(asset: asset, from: from, length: span, to: output)
        return Part(url: output, start: from, length: span, isOriginal: false)
    }

    private func export(asset: AVURLAsset, from start: TimeInterval, length: TimeInterval, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.exportFailed
        }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: length, preferredTimescale: 600)
        )
        try await session.export(to: output, as: .m4a)
    }

    /// Удаляет папки с частями. Исходный файл не трогается никогда.
    /// Папок может быть несколько: куски по местам пропусков режутся отдельно.
    func discard(_ parts: [Part]) {
        var directories = Set<String>()
        for part in parts where !part.isOriginal {
            directories.insert(part.url.deletingLastPathComponent().path)
        }
        for path in directories {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
    }
}
