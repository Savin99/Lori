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

// MARK: - Старшинство источников

extension RecordTitle {
    /// Заголовок и описание записи по тому, что о ней известно.
    ///
    /// Старшинство:
    /// 1. имя от человека — его не переписывает ничто;
    /// 2. заголовок модели — он может заменить имя принесённого файла: такое имя
    ///    временное (`SummaryStore.setImported`);
    /// 3. осмысленное имя принесённого файла — «Совещание 27.08»: человек уже
    ///    назвал запись, и подменять это первой фразой значит терять примету;
    /// 4. первая фраза расшифровки;
    /// 5. служебное имя файла в читаемом виде — «audio 5 2», только пока
    ///    расшифровка не дала заголовка;
    /// 6. «Запись 21:46».
    ///
    /// Под заголовком — описание модели, а без него текст записи: продолжение
    /// первой фразы, только когда и заголовок из неё, иначе начало текста —
    /// отрезать «ушедшее в заголовок» не от чего, сниппет начинался бы с
    /// середины фразы.
    ///
    /// Функция чистая и дешёвая: два словарных поиска в хранилищах, без чтения
    /// файлов, — её можно звать прямо из `body`.
    static func resolve(
        summary: SummaryStore.Entry?,
        preview: TranscriptPreviews.Preview?,
        recordedAt: Date,
        now: Date = .now
    ) -> RecordTitle {
        let generated = summary.flatMap { $0.detail.isEmpty ? nil : $0.detail }
        func named(_ title: String, _ source: Source) -> RecordTitle {
            RecordTitle(title: title, detail: generated ?? preview?.head, source: source, generatedDetail: generated)
        }

        if let summary, !summary.title.isEmpty {
            switch summary.origin {
            case .manual:
                return named(summary.title, .manual)
            case .generated:
                return named(summary.title, .model)
            case .imported:
                if !isGenericName(summary.title) { return named(summary.title, .importedName) }
            }
        }
        if let title = preview?.title, !title.isEmpty {
            return RecordTitle(
                title: title,
                detail: generated ?? preview?.snippet,
                source: .transcript,
                generatedDetail: generated
            )
        }
        if let summary, summary.origin == .imported, !summary.title.isEmpty {
            return named(cleanedName(summary.title), .genericName)
        }
        return named("Запись \(LoriFormat.stamp(recordedAt, now: now))", .date)
    }

    /// То же по хранилищам приложения. Вид, который зовёт это из `body`, обязан
    /// наблюдать оба хранилища — тогда он перерисуется, когда придёт заголовок
    /// модели или дочитается расшифровка.
    @MainActor
    static func resolve(_ entry: WorkspaceEntry, summaries: SummaryStore, previews: TranscriptPreviews) -> RecordTitle {
        resolve(path: entry.relativePath, recordedAt: entry.modifiedAt, summaries: summaries, previews: previews)
    }

    @MainActor
    static func resolve(path: String, recordedAt: Date, summaries: SummaryStore, previews: TranscriptPreviews) -> RecordTitle {
        resolve(summary: summaries.entry(for: path), preview: previews.preview(for: path), recordedAt: recordedAt)
    }

    /// Где лежит расшифровка записи: `Transcripts/<имя аудио без расширения>.md` —
    /// то же правило, что у `WorkspaceStore.existingTranscript` и `saveTranscript`.
    static func transcriptPath(forAudio path: String) -> String {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return "Transcripts/\(base).md"
    }
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
