import Foundation

/// Заголовок и сниппет карточки из самой расшифровки.
///
/// «Новая запись 48» не говорит ни о чём: чтобы вспомнить запись, приходится её
/// открывать. Название берётся из первых слов текста, а под ним — первые фразы,
/// как в списке писем.
enum TranscriptTitle {
    static let titleLimit = 42
    static let snippetLimit = 120
    /// Граница мысли раньше этого числа знаков дала бы заголовок из пары слов
    /// («Ок.», «Так.»), поэтому тогда берётся следующая граница.
    static let minimumTitle = 12

    /// Текст расшифровки без служебной обвязки: заголовка файла, подписи движка,
    /// строки режима, предупреждений о пропусках, таймкодов и меток говорящих.
    ///
    /// Разбор один на всё приложение — `TranscriptDocument.parse`, тот же, что у
    /// экрана записи и экспорта. Здесь раньше жил свой построчный разбор, и он
    /// отстал от формата: `Transcript.markdown` пишет строку `_Режим: …_` для
    /// каждого движка с режимом, а этот код знал только `#`, `>` и
    /// `_Расшифровано:` — карточка называлась «_Режим: Быстрый текст_ Обсудили
    /// переезд». Метки «S1:» снимает тот же разбор: заголовок «S1: Здравствуйте»
    /// читается как мусор, а сниппету важны слова, а не кто их сказал.
    static func plain(from markdown: String) -> String {
        text(of: TranscriptDocument.parse(markdown))
    }

    /// То же для уже разобранного документа: экран записи держит его в памяти,
    /// и читать файл второй раз ради заголовка незачем.
    static func text(of document: TranscriptDocument) -> String {
        // Абзацы и реплики склеиваются в одну строку: карточке нужен текст
        // подряд, а двойные пробелы из ответа движка в ней только мешают.
        document.lines
            .map(\.text)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Всё, что карточке нужно от текста, — одним разбором: заголовок,
    /// продолжение под ним и начало текста для чужого заголовка.
    struct Parts: Equatable, Sendable {
        let title: String?
        /// Продолжение текста после того, что ушло в заголовок.
        let snippet: String?
        /// Текст с самого начала.
        let head: String?
    }

    /// Части карточки из уже очищенного текста (`plain`, `text(of:)`).
    static func parts(of text: String) -> Parts {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return Parts(title: nil, snippet: nil, head: nil) }
        let head = shortened(clean, limit: snippetLimit, ellipsis: true)
        guard let split = split(clean) else { return Parts(title: nil, snippet: head, head: head) }
        // Вся расшифровка уместилась в заголовок — продолжать нечем, и лучше
        // показать текст ещё раз, чем пустоту.
        let snippet = shortened(split.rest.isEmpty ? clean : split.rest, limit: snippetLimit, ellipsis: true)
        return Parts(title: split.title, snippet: snippet, head: head)
    }

    /// Название: первая фраза, обрезанная по слову. Точка в конце не нужна —
    /// это заголовок, а не предложение.
    static func title(from markdown: String) -> String? {
        parts(of: plain(from: markdown)).title
    }

    /// Сниппет: продолжение текста под названием, одна-две строки.
    ///
    /// Именно продолжение, а не начало. Заголовок карточки — это первая фраза
    /// расшифровки, и сниппет, начинающийся оттуда же, дублировал её слово в
    /// слово: «То есть именно така…» сверху и «То есть именно такая внутренняя…»
    /// строкой ниже. Две строки на карточке — слишком дорогое место, чтобы
    /// тратить их на повтор.
    static func snippet(from markdown: String) -> String? {
        parts(of: plain(from: markdown)).snippet
    }

    /// Текст с начала — для карточек, у которых заголовок не из расшифровки.
    static func head(from markdown: String) -> String? {
        parts(of: plain(from: markdown)).head
    }

    /// Текст после того, что ушло в заголовок. Принимает очищенный текст.
    static func continuation(of text: String) -> String {
        split(text)?.rest ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Заголовок и остаток текста после него — одним проходом, чтобы сниппет
    /// начинался ровно там, где кончился заголовок.
    ///
    /// Заголовок — первая **содержательная** фраза среди первых `leadSentences`
    /// (`lead(in:)`): диалог начинается репликами вроде «Что хотел? Не. Да.», и
    /// карточка владельца называлась «Что хотел? Не». Короткие реплики в заголовок
    /// не идут и в сниппет тоже — он продолжает текст после выбранной фразы.
    /// Содержательной нет — прежнее правило с начала текста.
    static func split(_ text: String) -> (title: String, rest: String)? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let lead = lead(in: clean)
        let body = clean[(lead?.lowerBound ?? clean.startIndex)...]
        var end = boundary(in: String(body)).map { body.index(body.startIndex, offsetBy: $0) } ?? body.endIndex
        // Заголовок не выходит за выбранную фразу: граница «не раньше двенадцати
        // знаков» иначе приклеила бы к короткой фразе следующую реплику.
        if let lead, end > lead.upperBound { end = lead.upperBound }
        var title = shortened(String(body[..<end]), limit: titleLimit)
        // Короткая запись целиком уходит в заголовок вместе со своей точкой.
        while title.hasSuffix(".") { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }

        guard let range = clean.range(of: title, range: body.startIndex..<clean.endIndex) else { return (title, clean) }
        var rest = clean[range.upperBound...]
        // Заголовок обрывается на границе мысли, и продолжение начинается с
        // её знака: «. Дальше…» читается как ошибка вёрстки.
        while let first = rest.first, ".!?…:—,;".contains(first) || first.isWhitespace {
            rest.removeFirst()
        }
        return (title, String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Граница первой фразы

    /// Знаки конца предложения. Идущие подряд («...», «?!») считаются одной
    /// границей — по первому знаку серии.
    private static let enders: Set<Character> = [".", "!", "?", "…"]
    /// Конец мысли внутри предложения: «Значит, по корпусу Славы: сначала…»
    /// даёт заголовок до двоеточия.
    private static let pauses: Set<Character> = [":", "—"]
    /// После точки может стоять закрывающая кавычка или скобка — граница всё равно есть.
    private static let closers: Set<Character> = ["»", "\"", "”", "’", ")", "]"]
    /// Сокращения, после которых точка — не конец фразы. Расшифровка их почти не
    /// пишет, но «т.е.» и «г.» встречаются, и «Мы решили, т» — хуже, чем ничего.
    private static let abbreviations: Set<String> = [
        "т", "е", "д", "п", "н", "г", "гг", "в", "вв", "др", "пр", "см", "им", "ул",
        "тыс", "млн", "млрд", "руб", "коп", "напр", "проф",
    ]

    /// Смещение (в знаках) первой границы мысли, после которой заголовок уже не
    /// из пары слов, или nil, если в пределах заголовка её нет.
    ///
    /// Граница — только знак, за которым пробел или конец текста. Так дата
    /// «27.08», версия «3.5» и время «12:30» фразу не рвут: раньше считался любой
    /// знак, и заголовок выходил «Совещание 27». Слишком ранняя граница («Ок.»)
    /// уступает следующей, а не отменяет поиск. Дальше `titleLimit` смотреть
    /// незачем: такой кусок всё равно режется по длине, как и текст без границ.
    static func boundary(in text: String) -> Int? {
        let window = Array(text.prefix(titleLimit + 2))
        for index in window.indices where index <= titleLimit {
            let mark = window[index]
            let next: Character? = index + 1 < window.count ? window[index + 1] : nil
            let breaks = next.map { $0.isWhitespace || closers.contains($0) } ?? true

            if enders.contains(mark) {
                // Середина серии «...» — граница будет на её последнем знаке.
                if let next, enders.contains(next) { continue }
                guard breaks else { continue }
                var start = index
                while start > 0, enders.contains(window[start - 1]) { start -= 1 }
                if mark == ".", start == index, isAbbreviation(before: index, in: window) { continue }
                if start >= minimumTitle { return start }
            } else if pauses.contains(mark) {
                if mark == ":" {
                    guard breaks else { continue }
                } else {
                    // Тире без пробелов — диапазон «Москва—Петербург», а не пауза.
                    let previous: Character? = index > 0 ? window[index - 1] : nil
                    guard previous?.isWhitespace ?? true || next?.isWhitespace ?? true else { continue }
                }
                if index >= minimumTitle { return index }
            }
        }
        return nil
    }

    // MARK: - Короткие реплики в начале диалога

    /// Сколько первых предложений смотреть в поисках содержательного. В диалоге,
    /// который прислал владелец, оно шестое: «Что хотел? Не. Да. Сегодня справка.
    /// По чем? По затратам на эксплуатацию…».
    static let leadSentences = 8
    /// Дальше этого числа знаков предложения не ищутся: восемь коротких реплик
    /// укладываются в пару сотен знаков, а часовую расшифровку целиком в массив
    /// знаков ради заголовка превращать незачем.
    static let leadWindow = 600

    /// Содержательная фраза — от трёх слов или от пятнадцати букв, не считая
    /// слов-откликов. «Сегодня справка» (два слова, четырнадцать букв) ещё нет,
    /// «По затратам на эксплуатацию» — уже да.
    static let substantialWords = 3
    static let substantialLetters = 15

    /// Слова-отклики и междометия: «Да.», «Не.», «Ага.», «Так.» о записи ничего
    /// не говорят. Только они — не приветствия и не служебные слова: «Здравствуйте,
    /// давайте начнём встречу» — заголовок, а «Да, хорошо, ладно» — нет.
    static let fillers: Set<String> = [
        "да", "нет", "не", "ага", "угу", "ну", "так", "ок", "окей", "ладно", "хорошо", "понятно", "ясно",
        "вот", "а", "э", "ээ", "эээ", "эм", "мм", "ммм", "хм", "ой", "ах", "алло", "ало", "алле", "слушаю",
        "да-да", "ага-ага", "угу-угу", "так-так", "нет-нет", "ну-ну", "ок-ок",
    ]

    /// Первая содержательная фраза среди первых `leadSentences` — от её начала до
    /// знака конца без самого знака. nil — содержательной нет.
    static func lead(in text: String) -> Range<String.Index>? {
        sentences(in: text, limit: leadSentences).first { isSubstantial(text[$0]) }
    }

    /// Слов без откликов не меньше `substantialWords` или букв в них не меньше
    /// `substantialLetters`. Числа — тоже слова: «27.08 планёрка по релизу».
    static func isSubstantial(_ sentence: Substring) -> Bool {
        let words = sentence
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)) }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
        let meaningful = words.filter { !fillers.contains($0.lowercased().replacingOccurrences(of: "ё", with: "е")) }
        let letters = meaningful.reduce(0) { $0 + $1.filter(\.isLetter).count }
        return meaningful.count >= substantialWords || letters >= substantialLetters
    }

    /// Первые предложения текста — от начала до знака конца, без самого знака.
    ///
    /// Граница — по тем же правилам, что у `boundary`: знак, за которым пробел или
    /// конец текста; инициалы, сокращения и «27.08» границей не считаются; серия
    /// «?!» или «...» — одна граница. Хвост без знака — тоже предложение.
    static func sentences(in text: String, limit: Int) -> [Range<String.Index>] {
        let characters = Array(text.prefix(leadWindow))
        var offsets: [(start: Int, end: Int)] = []
        var start = 0
        var index = 0
        while index < characters.count, offsets.count < limit {
            guard enders.contains(characters[index]) else {
                index += 1
                continue
            }
            var last = index
            while last + 1 < characters.count, enders.contains(characters[last + 1]) { last += 1 }
            let next: Character? = last + 1 < characters.count ? characters[last + 1] : nil
            let breaks = next.map { $0.isWhitespace || closers.contains($0) } ?? true
            let abbreviation = characters[index] == "." && last == index && isAbbreviation(before: index, in: characters)
            guard breaks, !abbreviation else {
                index = last + 1
                continue
            }
            if index > start { offsets.append((start, index)) }
            var cursor = last + 1
            while cursor < characters.count, characters[cursor].isWhitespace || closers.contains(characters[cursor]) {
                cursor += 1
            }
            start = cursor
            index = cursor
        }
        if offsets.count < limit, start < characters.count { offsets.append((start, characters.count)) }
        return offsets.map { offset in
            let from = text.index(text.startIndex, offsetBy: offset.start)
            return from..<text.index(from, offsetBy: offset.end - offset.start)
        }
    }

    /// Точка после инициала («А. С. Петров»), сокращения или слова с точкой
    /// внутри («т.е.»).
    private static func isAbbreviation(before index: Int, in window: [Character]) -> Bool {
        var word = ""
        var cursor = index - 1
        while cursor >= 0, window[cursor].isLetter || window[cursor] == "." {
            word.insert(window[cursor], at: word.startIndex)
            cursor -= 1
        }
        guard !word.isEmpty else { return false }
        if word.count == 1, word.first?.isUppercase == true { return true }
        if word.contains(".") { return true }
        return abbreviations.contains(word.lowercased())
    }

    // MARK: - Обрезка

    /// Обрезка по границе слова: «Планы по RAG для ОВи…» читается хуже, чем
    /// «Планы по RAG для…». Висящий в конце предлог или союз снимается
    /// (`tidy`) — то же правило, что у заголовков модели.
    static func shortened(_ text: String, limit: Int, ellipsis: Bool = false) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean.trimmingCharacters(in: edges) }
        let end = clean.index(clean.startIndex, offsetBy: limit)
        let cut = clean[..<end]
        let words: Substring
        if clean[end].isWhitespace {
            // Обрезка пришлась ровно на конец слова — его не теряем.
            words = cut
        } else if let space = cut.lastIndex(where: \.isWhitespace) {
            words = cut[..<space]
        } else {
            words = cut
        }
        let trimmed = tidy(String(words))
        return ellipsis ? trimmed + "…" : trimmed
    }

    /// Знаки, которым не место на краю заголовка.
    private static let edges = CharacterSet(charactersIn: " ,;:—–-")

    /// Слова, после которых фраза явно продолжается. В конце обрезанного
    /// названия они выглядят обрубком: «…базы знаний вместе с».
    static let danglingWords: Set<String> = [
        "и", "или", "а", "но", "в", "во", "на", "с", "со", "к", "ко", "по", "о", "об", "обо",
        "у", "за", "до", "для", "из", "от", "при", "про", "без", "над", "под", "через",
        "что", "чтобы", "как", "если", "не", "ни",
    ]

    /// Убирает хвост, который остался висеть после обрезки: союз или предлог
    /// в конце названия, а за ним и запятую перед ним — «Отчёт по продажам, и».
    static func tidy(_ text: String) -> String {
        var words = text
            .trimmingCharacters(in: edges)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
        while words.count > 1, let last = words.last?.lowercased(), danglingWords.contains(last) {
            words.removeLast()
            while let tail = words.last, let mark = tail.last, ",;:—–-".contains(mark) {
                words[words.count - 1] = String(tail.dropLast())
                if words[words.count - 1].isEmpty { words.removeLast() }
            }
        }
        return words.joined(separator: " ").trimmingCharacters(in: edges)
    }
}
