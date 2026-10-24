import Foundation

/// Подписи главного экрана. Отдельно от `LoriFormat`, потому что правила здесь
/// свои: дата живёт только в заголовке дня, а карточка говорит одно время.
enum HomeFormat {
    /// «14:20» — время записи без даты: день уже назван заголовком группы.
    /// `LoriFormat.stamp` для вчерашней записи дал бы «вчера, 14:20» — второй
    /// раз то, что написано над карточкой.
    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// Длительность «24:10», а дольше часа — «1:41:12». `LoriFormat.duration`
    /// считает только минуты и показал бы «101:12»: такое число надо пересчитывать в уме.
    static func clock(_ seconds: TimeInterval) -> String {
        TranscriptSegment.stamp(seconds)
    }

    /// «ещё ~2 мин»: оценка остатка, а не обещание. Секунды показываются только
    /// в последнюю минуту — раньше они скачут и только раздражают.
    static func remaining(_ seconds: TimeInterval) -> String {
        let value = max(1, seconds.rounded())
        if value < 60 {
            return "ещё ~\(max(5, Int((value / 5).rounded()) * 5)) сек"
        }
        let minutes = max(1, Int((value / 60).rounded()))
        guard minutes >= 60 else { return "ещё ~\(minutes) мин" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "ещё ~\(hours) ч" : "ещё ~\(hours) ч \(rest) мин"
    }

    /// «Запись 5 октября 2026, 09:10» — имя файла и заметки для записи без
    /// заголовка. Не «Запись вчера, 09:10»: файл переживёт этот день, и через
    /// неделю «вчера» указывало бы не туда.
    static func absoluteTitle(_ date: Date) -> String {
        "Запись \(absoluteFormatter.string(from: date))"
    }

    /// «3-я» — место в очереди. Запись — женского рода, и окончание у порядкового
    /// числительного одно на все номера.
    static func ordinal(_ position: Int) -> String {
        "\(max(1, position))-я"
    }

    /// «5 записей» — для «Добавляю 5 записей…».
    static func records(_ count: Int) -> String {
        LoriFormat.plural(count, one: "запись", few: "записи", many: "записей")
    }

    /// «5 файлов» — для панели с прикреплёнными файлами.
    static func files(_ count: Int) -> String {
        LoriFormat.plural(count, one: "файл", few: "файла", many: "файлов")
    }

    private static let timeFormatter = formatter("HH:mm")
    private static let absoluteFormatter = formatter("d MMMM yyyy, HH:mm")

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = LoriFormat.locale
        formatter.dateFormat = template
        return formatter
    }
}

// MARK: - Состояние карточки

/// Строка состояния карточки — только когда записи есть что сказать.
///
/// Готовая запись строки не получает вовсе: список — библиотека, а не пульт, и цвет
/// в нём появляется только там, где состояние требует внимания.
struct RecordStatus: Equatable, Sendable {
    /// Чем окрашена строка. Палитра та же, что везде: идёт работа — приглушённый
    /// оливковый, ждёт — тёплый, сорвалось — красный, спокойное — серый.
    enum Tone: Equatable, Sendable {
        case working
        case waiting
        case failure
        case quiet
    }

    /// Действие прямо на карточке. Название одно и то же везде — в карточке, в
    /// меню долгого нажатия и в подсказке VoiceOver.
    enum Action: Equatable, Sendable {
        case transcribe
        case retry
        case resume

        var title: String {
            switch self {
            case .transcribe: "Расшифровать"
            case .retry: "Повторить"
            case .resume: "Продолжить"
            }
        }
    }

    var text: String
    var tone: Tone
    var symbol: String?
    var action: Action?
    /// Тонкая полоса под строкой — пока запись считается.
    var showsBar: Bool
    /// Доля для полосы; nil — работа идёт, но доли нет (облачный запрос одним куском).
    var fraction: Double?

    /// Состояние из сервиса одним значением (`TranscriptionService.state(for:)`).
    ///
    /// «Без расшифровки» — только у записи, которая ни в работе, ни в очереди:
    /// раньше карточка между «вышла из очереди» и «вошла в работу» мигала этой
    /// строкой. Об этом заботится сам `TranscriptionRecordState.starting`.
    static func make(
        state: TranscriptionRecordState,
        hasTranscript: Bool,
        fraction: Double?,
        remaining: TimeInterval?
    ) -> RecordStatus? {
        switch state {
        case let .queued(position, waitsForMemory):
            var text = "В очереди · \(HomeFormat.ordinal(position))"
            // «Жду память» — не то же, что «в очереди»: первое может и не пройти,
            // если телефону и правда тесно, и человек вправе видеть разницу.
            if waitsForMemory { text += " · жду память" }
            return RecordStatus(text: text, tone: .waiting, symbol: "clock", action: nil, showsBar: false, fraction: nil)
        case .starting:
            return RecordStatus(text: "Расшифровываю", tone: .working, symbol: nil, action: nil, showsBar: true, fraction: nil)
        case .running:
            var parts = ["Расшифровываю"]
            if let fraction { parts.append(percent(fraction)) }
            if let remaining { parts.append(HomeFormat.remaining(remaining)) }
            return RecordStatus(
                text: parts.joined(separator: " · "),
                tone: .working,
                symbol: nil,
                action: nil,
                showsBar: true,
                fraction: fraction
            )
        case let .sending(share):
            // Доля отправленного тела, а не расшифровки — поэтому и слово другое: «100%»
            // при «Расшифровываю» в конце загрузки читалось бы как готовая запись.
            var text = "Отправляю"
            if let share { text += " · \(percent(share))" }
            return RecordStatus(text: text, tone: .working, symbol: nil, action: nil, showsBar: true, fraction: share)
        case .awaitingService:
            // Тело у сервиса, ответа ещё нет: сколько ждать, не знает никто, поэтому
            // полоса — бегущий отрезок, а не выдуманная доля.
            return RecordStatus(text: "Жду ответ сервиса", tone: .working, symbol: nil, action: nil, showsBar: true, fraction: nil)
        case .interrupted:
            return RecordStatus(text: "Прервано", tone: .waiting, symbol: "pause.circle", action: .resume, showsBar: false, fraction: nil)
        case let .failed(message):
            return RecordStatus(
                text: shortReason(message),
                tone: .failure,
                symbol: "exclamationmark.triangle",
                action: .retry,
                showsBar: false,
                fraction: nil
            )
        case .idle:
            guard !hasTranscript else { return nil }
            return RecordStatus(text: "Без расшифровки", tone: .quiet, symbol: nil, action: .transcribe, showsBar: false, fraction: nil)
        }
    }

    /// Каким движком ставить запись по кнопке на карточке. «Продолжить» — тем же,
    /// что считал до обрыва: у старых прерванных записей нет снимка задания, и без
    /// движка сервис взял бы выбранный сейчас в настройках — запись, прерванная на
    /// OpenAI, молча ушла бы в ElevenLabs. «Расшифровать» и «Повторить» — тем, что
    /// выбран сейчас: после ошибки человек мог сменить движок именно затем.
    static func engine(for action: Action, interrupted: TranscriptionEngineKind?) -> TranscriptionEngineKind? {
        switch action {
        case .resume: interrupted
        case .transcribe, .retry: nil
        }
    }

    /// «63%» — по сделанному, без округления вверх: сотня появляется только с концом
    /// работы, иначе «100%» стояло бы на последнем куске (см. `TranscriptionService.fraction`).
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded(.down)))%"
    }

    /// Первая фраза ошибки — для карточки. Полный текст с тем, что делать, — на экране
    /// записи: «Ключ ElevenLabs не сохранён. Настройки → …» в две строки карточки
    /// не влезает, а «Ключ ElevenLabs не сохранён» — влезает и уже говорит главное.
    static func shortReason(_ message: String) -> String {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Не получилось" }
        let firstLine = clean.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? clean
        var cut = firstLine
        for marker in [". ", "! ", "? "] {
            if let range = firstLine.range(of: marker), firstLine.distance(from: firstLine.startIndex, to: range.lowerBound) >= 8 {
                let candidate = String(firstLine[..<range.lowerBound])
                if candidate.count < cut.count { cut = candidate }
            }
        }
        while cut.hasSuffix(".") { cut.removeLast() }
        return cut.isEmpty ? firstLine : cut
    }
}

// MARK: - Блок очереди

/// Что показать в блоке очереди над списком. Считается из сервиса один раз на
/// перерисовку; функция чистая, поэтому порядок «текущая — дальше — ещё N»
/// проверяется тестом, а не глазами.
struct QueueSummary: Equatable {
    /// «2 из 5» — только когда в пачке больше одной записи: «1 из 1» ничего не говорит.
    var counter: String?
    /// Запись, о которой блок говорит: та, что считается, а если ещё ни одна не
    /// пошла — первая в очереди. Тап по блоку открывает её.
    var focusPath: String
    var title: String
    /// Ни одна запись ещё не считается — блок говорит о первой ждущей.
    var isWaiting: Bool
    var fraction: Double?
    var remaining: TimeInterval?
    /// Чем занят движок, пока процентов нет: «отправляю запись», «жду ответ сервиса».
    var note: String?
    /// «Дальше: Интервью Маши, ещё 2».
    var next: String?
    /// Хоть одна ждущая запись упёрлась в память.
    var waitsForMemory: Bool
    /// Кто идёт вместе с ней, когда расшифровка параллельная (2–3 записи):
    /// «Ещё идёт: Интервью Маши», «Ещё идут: 2 записи». nil — идёт одна.
    var alongside: String? = nil

    static func make(
        current: String?,
        queued: [String],
        batchDone: Int,
        batchTotal: Int,
        fraction: Double?,
        remaining: TimeInterval?,
        note: String?,
        waitingForMemory: Set<String>,
        alsoRunning: [String] = [],
        title: (String) -> String
    ) -> QueueSummary? {
        guard let focus = current ?? queued.first else { return nil }
        // «Дальше» — только ждущие: идущие вместе с текущей сюда не попадают, о них
        // говорит `alongside`.
        let rest = current == nil ? Array(queued.dropFirst()) : queued
        var next: String?
        if let first = rest.first {
            next = "Дальше: \(title(first))"
            if rest.count > 1 { next? += ", ещё \(rest.count - 1)" }
        }
        let running = current != nil
        let others = running ? alsoRunning.filter { $0 != focus } : []
        var alongside: String?
        switch others.count {
        case 0: alongside = nil
        case 1: alongside = "Ещё идёт: \(title(others[0]))"
        default: alongside = "Ещё идут: \(HomeFormat.records(others.count))"
        }
        return QueueSummary(
            counter: batchTotal > 1 ? Self.counter(done: batchDone, total: batchTotal, running: 1 + others.count) : nil,
            focusPath: focus,
            title: title(focus),
            isWaiting: !running,
            fraction: running ? fraction : nil,
            remaining: running ? remaining : nil,
            note: running && fraction == nil ? note.flatMap { $0.isEmpty ? nil : $0 } : nil,
            next: next,
            waitsForMemory: !waitingForMemory.isEmpty,
            alongside: alongside
        )
    }

    /// «2 из 5», а когда идут сразу несколько — «2–3 из 5». Номер одной записи при
    /// двух идущих читался бы так, будто вторая ещё ждёт. С одной — тот же текст,
    /// что в Dynamic Island (`TranscriptionService.counter`).
    static func counter(done: Int, total: Int, running: Int) -> String {
        guard running > 1 else { return TranscriptionService.counter(done: done, total: total) }
        let total = max(total, 1)
        let first = min(max(done, 0) + 1, total)
        let last = min(max(done, 0) + running, total)
        return first == last ? "\(first) из \(total)" : "\(first)–\(last) из \(total)"
    }
}

/// Вопрос перед «Остановить» в блоке очереди. `cancelAll` снимает и прерванные
/// записи — иначе они поднялись бы сами при ближайшем возвращении в приложение, —
/// и когда такие есть, вопрос говорит и о них: молча снятая прерванная запись
/// выглядела бы потерянной.
enum StopQueueCopy {
    static let title = "Остановить расшифровку?"

    static func message(interrupted: Int) -> String {
        let keep = "Записи останутся — расшифровку можно запустить снова."
        switch interrupted {
        case ...0: return keep
        case 1: return "Прерванная запись тоже снимется: сама она уже не продолжится. \(keep)"
        default: return "Прерванные записи (\(interrupted)) тоже снимутся: сами они уже не продолжатся. \(keep)"
        }
    }
}

// MARK: - Сообщения о приёме файлов

/// Тексты о том, что не вошло, — одним сообщением на всё действие.
///
/// Пять файлов, из которых два не подошли, — это одно событие, и человеку нужен один
/// ответ с обеими причинами, а не два алерта подряд. Причины от сервисов уже
/// содержат имя файла и что делать, поэтому здесь они только собираются вместе.
enum ImportNotice {
    struct Message: Equatable {
        let title: String
        let text: String
    }

    /// Выбор в «Файлах» или «Поделиться» → Lori: часть файлов не взяли.
    static func rejected(_ messages: [String]) -> Message? {
        guard !messages.isEmpty else { return nil }
        if messages.count == 1 {
            return Message(title: "Файл не добавлен", text: messages[0])
        }
        return Message(
            title: "Не добавлено: \(HomeFormat.files(messages.count))",
            text: messages.joined(separator: "\n\n")
        )
    }

    /// Вставка из буфера: что-то забрали, что-то нет.
    static func pasteSkipped(_ messages: [String], taken: Int) -> Message? {
        guard !messages.isEmpty else { return nil }
        let title = taken > 0
            ? "Вставлено не всё: \(taken) из \(taken + messages.count)"
            : "Из буфера ничего не вставлено"
        return Message(title: title, text: messages.joined(separator: "\n\n"))
    }

    /// «Расшифровать» на прикреплённых: движок не готов — не сделано ничего.
    static func blocked(_ problem: String) -> Message {
        Message(title: "Расшифровка не началась", text: "\(problem)\n\nФайлы остались в панели.")
    }

    /// Часть файлов ушла в очередь, часть нет. Оставшиеся — в панели, и это
    /// говорится прямо: иначе неясно, повторять ли что-то.
    static func partial(_ messages: [String], imported: Int) -> Message? {
        guard !messages.isEmpty else { return nil }
        let total = imported + messages.count
        let lead = imported > 0
            ? "В расшифровку ушло \(imported) из \(total). Остальные остались в панели."
            : "Ни один файл не ушёл в расшифровку. Они остались в панели."
        return Message(
            title: "Не все файлы добавлены",
            text: ([lead] + messages).joined(separator: "\n\n")
        )
    }
}

// MARK: - Удаление и переименование — одними словами везде

/// Подтверждение удаления: одни и те же слова в списке и на экране записи. Два
/// входа в одно действие не должны называть его по-разному.
enum DeleteRecordCopy {
    static let title = "Удалить запись?"

    /// Идущая расшифровка останавливается — об этом говорится до нажатия.
    static func message(active: Bool) -> String {
        active
            ? "Аудио и расшифровка переедут в корзину Lori. Расшифровка этой записи остановится."
            : "Аудио и расшифровка переедут в корзину Lori."
    }
}

/// Переименовать можно только запись, с которой ничего не происходит.
///
/// У идущей, ждущей и запускающейся задание держит старый путь: движок не найдёт
/// звук или сохранит текст под старым именем, рядом с переименованной записью.
/// У прерванной задание сохранено и поднимется само (возвращение в приложение,
/// повтор по сети) или ждёт «Продолжить», а переименование через `forget` сняло бы
/// его вместе со снимком — продолжать стало бы нечего. Ошибка прошлой попытки
/// не мешает: задания за ней нет.
extension TranscriptionRecordState {
    var allowsRename: Bool {
        switch self {
        case .idle, .failed: true
        case .queued, .starting, .running, .sending, .awaitingService, .interrupted: false
        }
    }
}

/// Запись стала занятой, пока было открыто окно переименования.
enum RenameRefusal: LocalizedError, Equatable {
    case busy

    var errorDescription: String? {
        "Сначала дождись окончания расшифровки или останови её."
    }
}

/// Что сказать, когда переименовать не вышло: что случилось и что сделать.
enum RenameFailure {
    static func message(for error: Error) -> String {
        if let refusal = error as? RenameRefusal { return refusal.errorDescription ?? "" }
        return switch error as? WorkspaceError {
        case .nameTaken:
            "Запись с таким названием уже есть. Выбери другое."
        case .invalidName:
            "Из этого названия не получается имя файла. Добавь буквы или цифры."
        default:
            "Не получилось переименовать: \(error.localizedDescription)"
        }
    }
}
