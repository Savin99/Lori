import Foundation

/// Заголовок и описание записи — одни на все экраны.
///
/// Раньше каждый экран собирал их сам, и они разошлись: карточка брала имя
/// от человека или модели, а экспорт, Obsidian и правка текста — первую фразу
/// расшифровки, даже когда человек назвал запись иначе.
struct RecordTitle: Equatable, Sendable {
    /// Откуда взят заголовок — в порядке старшинства.
    enum Source: String, Equatable, Sendable {
        /// Имя дал человек. Его не переписывает ничто.
        case manual
        /// Придумала локальная модель.
        case model
        /// Осмысленное имя принесённого файла: «Совещание 27.08».
        case importedName
        /// Первая фраза расшифровки.
        case transcript
        /// Служебное имя файла («Новая запись 12», «audio_5_2») в читаемом виде —
        /// только пока расшифровка не дала заголовка.
        case genericName
        /// «Запись 21:46» — когда сказать о записи больше нечего.
        case date
    }

    let title: String
    /// Строки под заголовком: описание от модели, а без него — текст записи.
    /// Продолжение первой фразы — только когда и заголовок из неё.
    let detail: String?
    let source: Source
    /// Описание, которое придумала модель, — без подстановки текста записи.
    /// Его кладут в экспорт: там текст записи идёт следом целиком, и повторять
    /// его начало в шапке незачем.
    let generatedDetail: String?
}

// MARK: - Служебные имена файлов

extension RecordTitle {
    /// Слова служебных имён: диктофоны, мессенджеры, камера, запись экрана,
    /// буфер обмена, «Без названия». Имя, в котором есть хоть одно слово вне
    /// этого списка, — осмысленное: «Совещание 27.08», «Интервью Маши».
    private static let genericWords: Set<String> = [
        "новая", "новый", "новое", "запись", "записи", "аудио", "аудиозапись", "аудиофайл",
        "голосовое", "голосовая", "голосовой", "сообщение", "заметка", "диктофон",
        "вставленное", "без", "названия", "имени", "файл", "трек", "звук", "звукозапись",
        "копия", "звонок",
        "new", "recording", "record", "rec", "audio", "voice", "message", "memo", "memos",
        "note", "untitled", "unnamed", "track", "sound", "file", "copy", "clip", "call",
        "img", "vid", "mov", "aud", "ptt", "wa", "whatsapp", "telegram", "tg", "screen",
        "screenrecording", "rpreplay", "final", "at", "am", "pm", "dictaphone",
    ]

    /// Имя, которое ничего не говорит о записи: его дал диктофон, мессенджер или
    /// сама Lori, а не человек. «Новая запись 12», «audio 5 2», «Вставленное
    /// 1788520000», «Recording-2026-09-04T22-22-10Z», «IMG_1234»,
    /// «audio_2026-09-01_12-00-00» (Telegram), «PTT-20260901-WA0001» и «WhatsApp
    /// Audio 2026-… at 12.00.00», «Голосовое сообщение», одни цифры, даты и время,
    /// «Untitled», «Без названия».
    ///
    /// Такое имя проигрывает первой фразе расшифровки: раньше «Новая запись 12»
    /// побеждала навсегда, потому что имя принесённого файла стояло выше текста.
    /// Правило — по словам, а не по шаблонам имён: имя служебное, только если в
    /// нём нет ни одного слова вне списка, кроме чисел и коротких кодов
    /// («WA0001», «04T22»). Расширение аудио, если пришло вместе с именем, не в счёт.
    static func isGenericName(_ name: String) -> Bool {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = (base as NSString).pathExtension.lowercased()
        if !suffix.isEmpty, WorkspaceEntry.audioExtensions.contains(suffix) {
            base = (base as NSString).deletingPathExtension
        }
        // Пустое имя или одни знаки — тоже служебное: сказать им нечего.
        return base.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .allSatisfy(isFiller)
    }

    /// Кусок имени, который не несёт смысла: число, слово из списка, одна буква
    /// или код из букв вперемешку с цифрами.
    private static func isFiller(_ token: Substring) -> Bool {
        if token.allSatisfy(\.isNumber) { return true }
        if genericWords.contains(String(token)) { return true }
        let letters = token.filter(\.isLetter)
        if letters.count == token.count { return letters.count == 1 }
        // «wa0001», «img1234», «04t22», «10z», «final1693574400».
        return letters.count <= 3 || genericWords.contains(letters)
    }

    /// Служебное имя в читаемом виде: «audio_5_2» → «audio 5 2». Подчёркивания
    /// ставят программы, а не люди; дефисы остаются — в датах они к месту.
    static func cleanedName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
