import Foundation
import MLX
import MLXLMCommon

/// Заголовок и краткое описание расшифровки, посчитанные на самом телефоне.
///
/// Модель загружается на время работы и сразу отпускается: держать два
/// гигабайта в памяти между расшифровками нельзя — предел приложения около трёх.
actor Summarizer {
    struct Summary: Equatable, Sendable {
        let title: String
        let detail: String
    }

    enum Failure: LocalizedError, Equatable {
        case notInstalled
        case notEnoughMemory
        case emptyAnswer
        case simulator

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Модель заголовков не скачана."
            case .notEnoughMemory: "Для модели заголовков сейчас мало свободной памяти."
            case .emptyAnswer: "Модель не вернула заголовок."
            case .simulator: "Заголовки считаются на графическом процессоре, а в симуляторе его нет. Нужен настоящий iPhone."
            }
        }
    }

    /// Длина заголовка и описания. Ограничения не косметические: заголовок живёт
    /// в одну строку карточки, описание — в две.
    static let titleLimit = 60
    static let detailLimit = 160

    /// Сколько текста расшифровки отдаём модели. Целая часовая встреча не нужна:
    /// тема видна по началу и концу, а память и время дороги.
    static let headCharacters = 4000
    static let tailCharacters = 1000

    private let variant: SummaryVariant
    private let directory: URL
    private let backend: Backend

    /// Откуда берётся ответ. Настоящая реализация грузит веса один раз на всю
    /// расшифровку: со второй попыткой модель на 2,3 ГБ грузилась дважды подряд,
    /// и телефон убивал приложение по памяти.
    protocol Backend: Sendable {
        func answer(instructions: String, prompt: String) async throws -> String
        func release() async
    }

    init(
        variant: SummaryVariant,
        directory: URL,
        generate: (@Sendable (String, String) async throws -> String)? = nil
    ) {
        self.variant = variant
        self.directory = directory
        self.backend = generate.map(ClosureBackend.init) ?? MLXBackend(directory: directory)
    }

    /// Подставной источник ответа для тестов.
    private struct ClosureBackend: Backend {
        let generate: @Sendable (String, String) async throws -> String

        init(_ generate: @escaping @Sendable (String, String) async throws -> String) {
            self.generate = generate
        }

        func answer(instructions: String, prompt: String) async throws -> String {
            try await generate(instructions, prompt)
        }

        func release() async {}
    }

    /// Настоящий счёт на графическом процессоре.
    private actor MLXBackend: Backend {
        private let directory: URL
        private var context: ModelContainer?

        init(directory: URL) {
            self.directory = directory
        }

        func answer(instructions: String, prompt: String) async throws -> String {
            #if targetEnvironment(simulator)
            // В симуляторе нет устройства Metal, и MLX не возвращает ошибку, а
            // гасит процесс в `mlx::core::metal::Device::Device()`.
            throw Failure.simulator
            #else
            // Загрузка весов — уже работа на графическом процессоре, и начинать
            // её на пути в фон незачем: см. отмену ниже.
            try Task.checkCancellation()
            let container = try await loaded()
            return try await container.perform { context in
            var parameters = GenerateParameters()
            // Потолок с запасом на размышления. Ждать его целиком не придётся:
            // генерация обрывается, как только ответ дописан.
            parameters.maxTokens = 1200
            parameters.temperature = 0.3
            // ChatSession этой версии создаёт внутреннюю Task без отмены потока.
            // Прекращение чтения не останавливает GPU и держит веса в памяти.
            // Считаем в текущей задаче и завершаем сам iterator на каждом токене.
            let input = try await context.processor.prepare(input: UserInput(chat: [
                .system(instructions), .user(prompt)
            ]))
            try Task.checkCancellation()
            let result: GenerateResult = try MLXLMCommon.generate(
                input: input, parameters: parameters, context: context
            ) { (tokens: [Int]) -> GenerateDisposition in
                if Task.isCancelled { return .stop }
                return Summarizer.isComplete(context.tokenizer.decode(tokens: tokens)) ? .stop : .more
            }
            try Task.checkCancellation()
            return result.output
            }
            #endif
        }

        private func loaded() async throws -> ModelContainer {
            if let context { return context }
            // Кэш буферов MLX держит память после работы: на телефоне это разница
            // между «сработало» и «система убила приложение».
            MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)
            Diagnostics.note("модель заголовков: гружу, свободно \(MemoryReport.availableBytes / 1024 / 1024) МБ")
            let context = ModelContainer(context: try await loadModel(configuration: ModelConfiguration(directory: directory)))
            self.context = context
            Diagnostics.note("модель заголовков: загружена, свободно \(MemoryReport.availableBytes / 1024 / 1024) МБ")
            return context
        }

        func release() async {
            context = nil
            #if !targetEnvironment(simulator)
            MLX.GPU.clearCache()
            #endif
            // Память возвращается не мгновенно: буферы освобождаются по мере
            // разбора ссылок. Замер сразу после выгрузки показывал меньше
            // свободного, чем было до загрузки, и выглядел как утечка.
            try? await Task.sleep(for: .seconds(2))
            #if !targetEnvironment(simulator)
            MLX.GPU.clearCache()
            #endif
            Diagnostics.note("модель заголовков: выгружена, свободно \(MemoryReport.availableBytes / 1024 / 1024) МБ")
        }
    }

    /// Запрос к модели. Рассуждать ей не запрещаем — на заголовках это заметно
    /// помогает; просто рассуждения не считаются ответом и в текст не попадают.
    ///
    /// Требование к формату повторяется после текста: с одним лишь системным
    /// указанием модель уходила писать структурированный документ с разделами
    /// вместо двух строк. Пример заполнен целиком — шаблон с угловыми скобками
    /// она копировала дословно.
    static func prompt(for transcript: String, insist: Bool = false) -> String {
        let nudge = insist
            ? "\n\nПрошлый ответ был копией задания. Напиши настоящий заголовок по этой записи."
            : ""
        return """
        Расшифровка встречи:

        \(transcript)

        Ответь ровно двумя строками и ничем больше. Никаких вступлений, \
        заголовков разделов, списков и markdown.

        Заголовок — это название, а не пересказ: три-пять слов, без глаголов, \
        без слов «обсуждали» и «разговор о». Он должен помещаться целиком.

        Пример ответа для другой записи:
        Заголовок: База знаний и оргструктура
        Описание: Обсудили структуру базы и доступ MCP к документам компании.

        Теперь так же для расшифровки выше — по её содержанию, а не по примеру.\(nudge)
        """
    }

    static let instructions = """
    Ты придумываешь названия для расшифровок встреч. Отвечаешь только по-русски и \
    только двумя строками. «Заголовок:» — короткое название из трёх-пяти слов, \
    именная фраза без глаголов. «Описание:» — одно-два предложения до 160 знаков. \
    Ничего кроме этих двух строк ты не пишешь: ни вступлений, ни разделов, ни списков. \
    Пишешь по содержанию записи, а не пересказываешь задание.
    """

    func summary(of transcript: String) async throws -> Summary {
        let source = Self.excerpt(from: transcript)
        guard !source.isEmpty else { throw Failure.emptyAnswer }

        // Освобождение завершается до следующего задания, включая путь отмены.
        do {
            let result: Summary
            if let first = try await attempt(source, insist: false) {
                result = first
            } else {
                try Task.checkCancellation()
                Diagnostics.note("заголовок: ответ похож на шаблон, повторяю запрос")
                guard let second = try await attempt(source, insist: true) else { throw Failure.emptyAnswer }
                result = second
            }
            await Task { await backend.release() }.value
            return result
        } catch {
            await Task { await backend.release() }.value
            throw error
        }
    }

    private func attempt(_ source: String, insist: Bool) async throws -> Summary? {
        let answer = try await backend.answer(
            instructions: Self.instructions,
            prompt: Self.prompt(for: source, insist: insist)
        )
        Diagnostics.note(
            "ответ модели: "
            + answer.prefix(400).replacingOccurrences(of: "\n", with: " ⏎ ")
        )
        guard let summary = Self.parse(answer), !Self.looksLikeTemplate(summary.title) else { return nil }
        return summary
    }

    /// Ответ, в котором модель повторила задание вместо содержания. На устройстве
    /// заголовком стало «<о чём разговор, до 60 знаков>» — дословная подстановка
    /// из запроса, поэтому угловые скобки и слова задания теперь запрещены.
    static func looksLikeTemplate(_ title: String) -> Bool {
        if title.contains("<"), title.contains(">") { return true }
        let lower = title.lowercased()
        let borrowed = ["до 60 знаков", "до 160 знаков", "о чём разговор", "одно-два предложения",
                        "заголовок:", "планёрка по базе знаний"]
        return borrowed.contains { lower.contains($0) }
    }

    /// Начало и конец расшифровки: середина длинного разговора для заголовка
    /// почти бесполезна, а токены стоят времени.
    static func excerpt(from text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > headCharacters + tailCharacters else { return clean }
        let head = clean.prefix(headCharacters)
        let tail = clean.suffix(tailCharacters)
        return "\(head)\n…\n\(tail)"
    }

    /// Дописан ли ответ: рассуждения закончились и обе строки на месте.
    /// По этому признаку генерация обрывается, а не досчитывается до потолка —
    /// иначе на заголовок уходили бы лишние полминуты.
    static func isComplete(_ answer: String) -> Bool {
        // Пока рассуждение не закрыто, ответа ещё нет — внутри него встречаются
        // и «Заголовок», и «Описание», но это не ответ.
        if answer.contains("<think>"), !answer.contains("</think>") { return false }
        let tail = answer.components(separatedBy: "</think>").last ?? answer
        let lines = tail
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { value(of: $0, key: "Заголовок") != nil }) else { return false }
        guard let detail = lines.first(where: { value(of: $0, key: "Описание") != nil }),
              let text = value(of: detail, key: "Описание") else { return false }
        // Описание дописано, если предложение закончено или строка закрыта.
        return ".!?…".contains(text.last ?? " ") || lines.last?.isEmpty == true
    }

    /// Убирает рассуждения модели: Qwen3 обрамляет их тегами `<think>`,
    /// и внутри может оказаться что угодно, включая слово «Заголовок».
    static func withoutThoughts(_ answer: String) -> String {
        var text = answer
        while let open = text.range(of: "<think>") {
            guard let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) else {
                text = String(text[text.startIndex..<open.lowerBound])
                break
            }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text
            .replacingOccurrences(of: "</think>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Разбор ответа. Модель иногда добавляет рассуждения или markdown —
    /// сначала берём помеченные строки, а если их нет, довольствуемся первой
    /// осмысленной: пустой заголовок хуже неидеального.
    static func parse(_ answer: String) -> Summary? {
        let cleaned = withoutThoughts(answer)
        var title: String?
        var detail: String?
        for raw in cleaned.components(separatedBy: .newlines) {
            let line = raw
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)
            if title == nil, let value = value(of: line, key: "Заголовок") { title = value }
            if detail == nil, let value = value(of: line, key: "Описание") { detail = value }
        }
        if title == nil || title?.isEmpty == true {
            // Разметки нет: модель ушла писать документ. Берём первую строку,
            // похожую на название, а не вступление вроде «Вот обобщённый текст…».
            let lines = candidates(in: cleaned)
            title = lines.first
            if detail == nil, lines.count > 1 { detail = lines[1] }
        }
        guard let title, !title.isEmpty else { return nil }
        return Summary(
            title: clamp(title, to: titleLimit),
            detail: clamp(detail ?? "", to: detailLimit)
        )
    }

    static func value(of line: String, key: String) -> String? {
        guard line.lowercased().hasPrefix(key.lowercased()) else { return nil }
        let rest = line.dropFirst(key.count).drop { $0 == ":" || $0 == " " }
        let text = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: " \"«»"))
        return text.isEmpty ? nil : text
    }

    /// Строки, которые годятся в заголовок. Отсеиваются разметка, вступления
    /// («Вот…», «Ниже…») и строки-подводки, кончающиеся двоеточием: на живом
    /// ответе модели заголовком стало «Вот обобщённый и структурированный текст».
    static func candidates(in text: String) -> [String] {
        let openers = ["вот ", "ниже ", "итак", "конечно", "хорошо,", "разумеется"]
        return text
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .replacingOccurrences(of: "#", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -—–_\"«»"))
            }
            .filter { line in
                guard line.count >= 8, line.count <= 200 else { return false }
                guard !line.hasSuffix(":") else { return false }
                let lower = line.lowercased()
                guard !openers.contains(where: { lower.hasPrefix($0) }) else { return false }
                // Речь о самой расшифровке — это разговор модели, а не название.
                let meta = ["расшифровк", "презентац", "отчёта или", "текст вашего", "документаци"]
                return !meta.contains(where: { lower.contains($0) })
            }
    }

    /// Обрезка длинного заголовка. Сначала пробуем закончить на смысловой
    /// границе — запятой или тире: «Обсуждали структуру базы знаний, оргструктуре
    /// и…» читается как обрубок, а «Структура базы знаний» — как название.
    static func clamp(_ text: String, to limit: Int) -> String {
        let clean = text.trimmingCharacters(in: .whitespaces)
        guard clean.count > limit else { return clean }
        let head = clean.prefix(limit)

        if let border = head.lastIndex(where: { ",;:—–".contains($0) }),
           head.distance(from: head.startIndex, to: border) >= limit / 3 {
            return tidy(String(head[head.startIndex..<border]))
        }
        guard let space = head.lastIndex(of: " ") else { return tidy(String(head)) + "…" }
        return tidy(String(head[head.startIndex..<space])) + "…"
    }

    /// Убирает хвост, который остался висеть после обрезки: союз или предлог
    /// в конце названия выглядит оборванным.
    ///
    /// Правило общее с заголовком из первой фразы (`TranscriptTitle.tidy`):
    /// два списка «висящих» слов однажды уже разошлись бы, и карточка резала
    /// бы по-разному в зависимости от того, кто придумал название.
    static func tidy(_ text: String) -> String {
        TranscriptTitle.tidy(text)
    }
}
