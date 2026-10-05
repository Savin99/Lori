import Foundation

/// Одна расшифровка как источник для ассистента.
///
/// Файлы читает интерфейс (`WorkspaceStore` живёт на главном потоке), а движок
/// получает уже прочитанный текст: так он остаётся `Sendable` и проверяется
/// тестами без рабочей папки.
struct AssistantSource: Sendable, Equatable {
    /// `WorkspaceEntry.relativePath` записи — по нему интерфейс её и открывает.
    let path: String
    let title: String
    let date: Date
    /// Содержимое `Transcripts/<имя>.md`.
    let markdown: String
    /// Описание от модели заголовков, если оно посчитано. Идёт в оглавление;
    /// без него оглавление берёт первые фразы самой расшифровки.
    let detail: String?
    /// Тема записи, если назначена.
    let topic: String?

    init(
        path: String,
        title: String,
        date: Date,
        markdown: String,
        detail: String? = nil,
        topic: String? = nil
    ) {
        self.path = path
        self.title = title
        self.date = date
        self.markdown = markdown
        self.detail = detail
        self.topic = topic
    }
}

/// Отбор кусков расшифровок под вопрос.
///
/// Никакого нового ML: эмбеддинги потребовали бы своей модели, своего хранилища
/// и переиндексации при каждой правке текста. Здесь совпадение по словам — оно
/// дёшево, объяснимо и работает ровно там, где человек спрашивает своими
/// словами о том, что в записи и было сказано.
enum AssistantRetrieval {
    /// Кусок расшифровки с якорем для ссылки.
    struct Chunk: Sendable, Equatable {
        /// Индекс источника в переданном массиве.
        let sourceIndex: Int
        /// Порядковый номер куска внутри записи — им же задаётся порядок чтения.
        let position: Int
        /// Время первой реплики куска. nil — у движка расшифровки таймкодов нет.
        let start: TimeInterval?
        /// Время последней реплики куска.
        let end: TimeInterval?
        /// Начала всех реплик куска. По ним проверяется секунда, которую модель
        /// вернула в ссылке: диапазон «от и до» пропускает любое число внутри,
        /// а такой секунды в записи может не быть вовсе.
        let starts: [TimeInterval]
        let text: String
    }

    struct Selection: Sendable, Equatable {
        let chunks: [Chunk]
        let usedCharacters: Int
        /// Охват вошёл целиком. Ложь означает, что тексты отбирались под вопрос,
        /// и «в записях этого нет» тогда нельзя читать как факт про архив.
        let whole: Bool
    }

    /// Целевой размер куска. Меньше — и реплика теряет контекст соседних;
    /// больше — и в бюджет влезает слишком мало разных мест архива.
    static let targetChunkCharacters = 1200

    /// Разбор расшифровки в куски. Служебные строки (заголовок файла, подпись
    /// движка, предупреждения о пропусках) отбрасывает сам `TranscriptDocument`.
    static func chunks(of source: AssistantSource, index: Int, target: Int = targetChunkCharacters) -> [Chunk] {
        chunks(of: TranscriptDocument.parse(source.markdown), index: index, target: target)
    }

    /// То же по уже разобранному файлу: снимок разбирает каждую расшифровку один
    /// раз — и на куски, и на строку оглавления.
    static func chunks(of document: TranscriptDocument, index: Int, target: Int = targetChunkCharacters) -> [Chunk] {
        var result: [Chunk] = []
        var buffer: [String] = []
        var bufferStart: TimeInterval?
        var bufferEnd: TimeInterval?
        var starts: [TimeInterval] = []
        var length = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(Chunk(
                sourceIndex: index,
                position: result.count,
                start: bufferStart,
                end: bufferEnd,
                starts: starts,
                text: buffer.joined(separator: "\n")
            ))
            buffer = []
            bufferStart = nil
            bufferEnd = nil
            starts = []
            length = 0
        }

        for line in document.lines {
            if buffer.isEmpty { bufferStart = line.start }
            if let start = line.start {
                bufferEnd = start
                starts.append(start)
            }
            // Секунда в начале строки — это то, что модель потом вернёт в
            // ссылке. Без неё она может указать только начало всего фрагмента,
            // а пилюля «Интеграция · 0:38» должна вести именно в ту минуту,
            // о которой речь, а не в начало пятиминутного куска.
            let text = line.start.map { "\(Int($0))| \(line.text)" } ?? line.text
            buffer.append(text)
            length += text.count + 1
            if length >= target { flush() }
        }
        flush()
        return result
    }

    /// Что отдать модели. Помещается целиком — отдаём целиком: отбор на том,
    /// что и так влезает, только вредит, а модель сама найдёт нужное место.
    static func select(
        question: String,
        sources: [AssistantSource],
        documents: [TranscriptDocument] = [],
        budget: Int = AssistantSettings.contextCharacters,
        vocabulary: [String] = TranscriptionSettings.vocabulary
    ) -> Selection {
        let parsed = documents.count == sources.count
            ? documents
            : sources.map { TranscriptDocument.parse($0.markdown) }
        let all = parsed.enumerated().flatMap { chunks(of: $1, index: $0) }
        let total = all.reduce(0) { $0 + $1.text.count }
        guard total > budget else {
            return Selection(chunks: all, usedCharacters: total, whole: true)
        }

        let wanted = terms(in: question)
        let boosted = Set(vocabulary.flatMap(terms(in:)))
        let scored = all.map { chunk -> (chunk: Chunk, score: Int) in
            let hits = wanted.intersection(terms(in: chunk.text))
            return (chunk, hits.reduce(0) { $0 + (boosted.contains($1) ? 2 : 1) })
        }
        let order = scored
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.chunk.sourceIndex != rhs.chunk.sourceIndex { return lhs.chunk.sourceIndex < rhs.chunk.sourceIndex }
                return lhs.chunk.position < rhs.chunk.position
            }
            .map(\.chunk)

        var taken: [Chunk] = []
        var keys = Set<String>()
        var used = 0

        func add(_ chunk: Chunk) {
            let key = "\(chunk.sourceIndex)/\(chunk.position)"
            guard !keys.contains(key), used + chunk.text.count <= budget else { return }
            keys.insert(key)
            taken.append(chunk)
            used += chunk.text.count
        }

        for chunk in order { add(chunk) }
        // Соседи попавшего куска. Разговор режется по объёму, а не по смыслу:
        // упоминание оказывается в одном куске, а разговор о нём — в следующем.
        // Без соседей ответ выходит «есть только упоминание, больше ничего».
        for chunk in order {
            for neighbour in all where neighbour.sourceIndex == chunk.sourceIndex
                && abs(neighbour.position - chunk.position) == 1 {
                add(neighbour)
            }
        }
        // Остаток бюджета добивается подряд, от свежих записей к старым
        // (интерфейс отдаёт их именно в этом порядке). Оплаченный, но пустой
        // контекст — это молча выброшенные знаки, а не осторожность.
        for chunk in all { add(chunk) }

        // Порядок чтения возвращаем: подряд идущие куски одной записи модель
        // понимает как разговор, а перемешанные по весу — как обрывки.
        taken.sort { lhs, rhs in
            lhs.sourceIndex == rhs.sourceIndex
                ? lhs.position < rhs.position
                : lhs.sourceIndex < rhs.sourceIndex
        }
        return Selection(chunks: taken, usedCharacters: used, whole: false)
    }

    /// Слова как ключи сравнения. Русский язык склоняет всё подряд, поэтому
    /// слово режется до шести знаков: «договор», «договора» и «договоре»
    /// становятся одним ключом. Настоящий стеммер тут был бы точнее, но он
    /// стоит зависимости, а ошибка обрезки — это лишний кусок в контексте.
    static func terms(in text: String) -> Set<String> {
        var result: Set<String> = []
        for piece in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            guard piece.count >= 3, !stopWords.contains(String(piece)) else { continue }
            result.insert(String(piece.prefix(6)))
        }
        return result
    }

    /// Слова, которые есть в каждой второй реплике: они не отбирают, а шумят.
    private static let stopWords: Set<String> = [
        "что", "как", "это", "вот", "так", "там", "тут", "или", "если", "чтобы",
        "был", "была", "были", "было", "есть", "для", "про", "над", "под", "при",
        "они", "она", "оно", "мы", "вы", "его", "её", "их", "мне", "нам", "вам",
        "уже", "ещё", "еще", "все", "всё", "тоже", "только", "очень", "потом",
        "когда", "где", "куда", "кто", "чем", "том", "тем", "нет", "да",
    ]
}
