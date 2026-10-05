import Foundation

/// Чем расшифровывать. Выбор явный: молча уводить аудио с телефона в облако нельзя,
/// поэтому «локально» и «через API» — это два разных пункта, а не запасной вариант.
enum TranscriptionEngineKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case gigaam
    case whisper
    case apple
    case openAI = "openai"
    case gemini
    case elevenLabs = "elevenlabs"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gigaam: "GigaAM v3 на iPhone"
        case .whisper: "Whisper large-v3 turbo на iPhone"
        case .apple: "Apple, на устройстве"
        case .openAI: "OpenAI API"
        case .gemini: "Google Gemini API"
        case .elevenLabs: "ElevenLabs Scribe API"
        }
    }

    /// Строка под названием в настройках: где считается и что уходит наружу.
    var detail: String {
        switch self {
        case .gigaam: "Считает сам телефон, аудио никуда не уходит. Модель скачивается одной кнопкой ниже."
        case .whisper: "Считает сам телефон, аудио никуда не уходит. Модель на 632 МБ кладётся руками в «Файлы» → Lori → Models."
        case .apple: "Системное распознавание iOS. Работает без ключей, но без пунктуации."
        case .openAI: "Аудио уходит в OpenAI. Нужен ключ. Модель и адрес — ниже."
        case .gemini: "Аудио уходит в Google. Нужен ключ. Имя модели — ниже."
        case .elevenLabs: "Аудио уходит в ElevenLabs — целиком, одним запросом. Нужен ключ."
        }
    }

    /// Главный факт про движок: покидает ли запись телефон.
    var leavesDevice: Bool {
        switch self {
        case .gigaam, .whisper, .apple: false
        case .openAI, .gemini, .elevenLabs: true
        }
    }

    var keychainAccount: KeychainAccount? {
        switch self {
        case .gigaam, .whisper, .apple: nil
        case .openAI: .openAI
        case .gemini: .gemini
        case .elevenLabs: .elevenLabs
        }
    }

    /// Сколько памяти нужно оставить свободной, чтобы взять **вторую** запись этим
    /// движком одновременно с первой.
    ///
    /// Это не вес модели: веса общие, их держит `EngineSessionCache`, и второй
    /// прогон их не дублирует. Здесь запас на то, что у прогона своё: мел-спектрограмма,
    /// активации энкодера и состояние декодера. Потолок у приложения жёсткий (право
    /// `increased-memory-limit` бесплатная команда разработчика не подписывает), а
    /// система убивает по памяти без предупреждения и без крэш-отчёта — так уже было.
    var deviceHeadroomBytes: UInt64 {
        switch self {
        case .gigaam: 350 * 1024 * 1024
        case .whisper: 700 * 1024 * 1024
        case .apple: 150 * 1024 * 1024
        // Облачным движкам память не нужна: у них работа в сети.
        case .openAI, .gemini, .elevenLabs: 0
        }
    }
}

/// Настройки расшифровки: выбранный движок, адреса и имена моделей.
/// Ключи здесь не живут — они только в Keychain, см. `KeychainStore`.
enum TranscriptionSettings {
    static let engineKey = "transcriptionEngine"
    static let openAIBaseURLKey = "openAIBaseURL"
    static let openAIModelKey = "openAIModel"
    static let geminiModelKey = "geminiModel"
    static let geminiBaseURLKey = "geminiBaseURL"
    /// Режим Gemini: дословный против «причёсанного» (`smart`). Таймкоды и
    /// говорящие — не режим, а отдельные переключатели, см. ниже.
    static let geminiModeKey = "geminiMode"
    static let elevenLabsBaseURLKey = "elevenLabsBaseURL"
    static let elevenLabsModelKey = "elevenLabsModel"
    /// Режим ElevenLabs: дословно, со звуками или причёсанный текст.
    static let elevenLabsModeKey = "elevenLabsMode"
    /// Какой вариант GigaAM использовать: RNN-T или CTC.
    static let gigaAMVariantKey = "gigaamVariant"
    /// Расшифровывать сразу после остановки диктофона. Импорта не касается:
    /// принесённый файл всегда проходит через подтверждение в панели.
    static let autoTranscribeKey = "autoTranscribe"
    /// Свой словарь: имена, названия и термины, которые модель обычно перевирает.
    static let vocabularyKey = "transcriptionVocabulary"
    /// Язык записи: пусто — пусть сервис определяет сам.
    static let languageKey = "transcriptionLanguage"
    /// Просить разделение по говорящим, где сервис это умеет.
    static let speakerLabelsKey = "transcriptionSpeakerLabels"
    /// Просить таймкоды реплик там, где они не приходят сами.
    static let timecodesKey = "transcriptionTimecodes"
    /// Сколько записей считать одновременно. По умолчанию одна: остальные ждут в очереди.
    static let concurrencyKey = "transcriptionConcurrency"
    /// Длина части, которой запись уходит в Gemini, в минутах.
    static let geminiPartKey = "geminiPartMinutes"

    static let defaultOpenAIBaseURL = "https://api.openai.com/v1"
    static let defaultOpenAIModel = "whisper-1"
    /// Модель Gemini по умолчанию — специализированная на речи `gemini-3.5-transcribe`
    /// (вышла 26 августа 2026). Полный список приложение забирает у сервиса: зашивать
    /// его в код бессмысленно, линейка меняется чаще сборок.
    static let defaultGeminiModel = "gemini-3.5-transcribe"

    static let defaultElevenLabsBaseURL = "https://api.elevenlabs.io/v1"
    /// `scribe_v2` — та модель, которую документация называет основной для
    /// файлов. Остальная линейка (`scribe_v2_realtime…`) существует ради
    /// потокового распознавания через WebSocket, а файл ей отправлять незачем.
    static let defaultElevenLabsModel = "scribe_v2"

    /// Язык записи. Пустая строка означает «определяй сам»: у OpenAI тогда не уходит
    /// поле `language`, у Gemini — указание языка в подсказке.
    static let defaultLanguage = "ru"

    static var language: String {
        guard let stored = setting(forKey: languageKey) else { return defaultLanguage }
        return stored.trimmingCharacters(in: .whitespaces)
    }

    static var detectsLanguage: Bool { language.isEmpty }

    /// Говорящие и таймкоды: у Gemini это поля `diarization_mode` и
    /// `timestamp_granularities`, у OpenAI говорящих дают только diarize-модели,
    /// у whisper тайминги приходят сами. Где движок не умеет — переключатель
    /// в интерфейсе выключен с пояснением, а не молча игнорируется.
    static var speakerLabels: Bool {
        setting(forKey: speakerLabelsKey).map { $0 == "1" || $0 == "true" } ?? false
    }

    static var timecodes: Bool {
        setting(forKey: timecodesKey).map { $0 == "1" || $0 == "true" } ?? true
    }

    /// Сколько записей идёт одновременно. **По умолчанию одна** — остальные ждут в
    /// очереди, как и было. Владелец попробовал две и вернулся к очереди: выигрыша по
    /// времени параллель локальным движкам не даёт (они делят один процессор), а
    /// понять по двум ползущим полосам, сколько ещё ждать, труднее, чем по одной.
    ///
    /// Настройка осталась: планировщик её держит, и поднять до трёх — одна строка на
    /// экране «Расшифровка». Две записи безопасны по памяти только потому, что веса
    /// модели у них общие (`EngineSessionCache`).
    static let concurrencyRange = 1...3
    static let defaultConcurrency = 1

    static var concurrency: Int {
        let stored = UserDefaults.standard.integer(forKey: concurrencyKey)
        guard concurrencyRange.contains(stored) else { return defaultConcurrency }
        return stored
    }

    static var engine: TranscriptionEngineKind {
        let raw = setting(forKey: engineKey) ?? ""
        return TranscriptionEngineKind(rawValue: raw) ?? .gigaam
    }

    static var openAIBaseURL: URL {
        url(from: setting(forKey: openAIBaseURLKey) ?? "")
            ?? URL(string: defaultOpenAIBaseURL)!
    }

    static var openAIModel: String {
        value(forKey: openAIModelKey, fallback: defaultOpenAIModel)
    }

    static var geminiMode: GeminiMode {
        // Старое значение «timecodes» — это ровно нынешний `speakers`. Сырое
        // значение может прийти и в обход миграции — аргументом запуска.
        let raw = setting(forKey: geminiModeKey) ?? ""
        if raw == "timecodes" { return .speakers }
        return GeminiMode(rawValue: raw) ?? .accuracy
    }

    /// Что реально просим у Gemini: `smart` несовместим с таймкодами и говорящими,
    /// поэтому при нём переключатели не действуют — и интерфейс это говорит.
    /// Что уходит в запрос, решает режим — и только он. Пара «режим плюс
    /// независимые тумблеры» позволяла собрать «Точность» с таймкодами, то есть
    /// состояние, которого у сервиса не бывает.
    static var geminiWantsWordTimestamps: Bool { geminiMode == .speakers }
    static var geminiWantsDiarization: Bool { geminiMode == .speakers }

    /// Сколько аудио сервис берёт одним запросом: час, а с таймкодами слов
    /// или разделением говорящих — 30 минут (документация Google).
    static var geminiMaxSeconds: TimeInterval {
        geminiWantsWordTimestamps || geminiWantsDiarization ? 30 * 60 : 60 * 60
    }

    static let geminiPartRange = 5...60
    /// Что предлагается в настройках. Свободный ввод здесь ни к чему: разница
    /// между девятью и десятью минутами не значит ничего.
    static let geminiPartOptions = [5, 10, 15, 20, 30, 60]
    /// Десять минут. Меньше — больше стыков, а каждый стык это шанс потерять
    /// слово; больше — реже отметки времени и крупнее потеря, когда модель
    /// сорвётся в повтор.
    static let defaultGeminiPart = 10

    /// Длина части в минутах, как её видит человек в настройках.
    static var geminiPartMinutes: Int {
        let stored = Int(setting(forKey: geminiPartKey) ?? "") ?? 0
        guard geminiPartRange.contains(stored) else { return defaultGeminiPart }
        return stored
    }

    /// Каким куском запись уходит в Gemini.
    ///
    /// В «Точности» сервис времени не отдаёт вовсе: `timestamp_granularities`
    /// документированы только как `["word"]`, они несовместимы со словарём и,
    /// прямая цитата из документации Google, «degrade transcription accuracy».
    /// Значит время может взяться только из границ того, что мы сами отправили —
    /// и длина части определяет, как часто в расшифровке стоит отметка времени.
    ///
    /// Больше предела сервиса не отдаём никогда: там начинается его собственная
    /// нарезка, и она уже не про читаемость.
    static var geminiPartSeconds: TimeInterval {
        min(TimeInterval(geminiPartMinutes) * 60, geminiMaxSeconds)
    }

    /// Режим Gemini прошёл круг: сначала «Спикеры и таймкоды» были режимом,
    /// потом их растворили в независимых тумблерах, теперь они снова режим —
    /// потому что тумблеры поверх режима давали противоречивые состояния.
    ///
    /// Приводится только однозначная прошлая форма: значение `timecodes` — это
    /// ровно нынешний `speakers`.
    ///
    /// Вторая прошлая форма — «точность с включёнными тумблерами» — приводилась
    /// здесь же и оказалась вредной. Отличить её от осознанно выбранной
    /// «Точности» нечем: старый тумблер говорящих остаётся включённым в
    /// настройках навсегда (у Gemini он теперь индикатор, и погасить его
    /// нечем), а вызов идёт на **каждом** запуске приложения. Владелец выбирал
    /// «Точность» на главной, а после выхода получал обратно «Спикеры» — выбор
    /// режима выглядел как несохраняющийся. Эпоха тумблеров закончилась
    /// 29 августа 2026, и приводить с неё уже нечего.
    static func migrateLegacyGeminiMode() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: geminiModeKey) == "timecodes" else { return }
        defaults.set(GeminiMode.speakers.rawValue, forKey: geminiModeKey)
    }

    static var geminiModel: String {
        value(forKey: geminiModelKey, fallback: defaultGeminiModel)
    }

    static var elevenLabsModel: String {
        value(forKey: elevenLabsModelKey, fallback: defaultElevenLabsModel)
    }

    static var elevenLabsMode: ElevenLabsMode {
        let raw = setting(forKey: elevenLabsModeKey) ?? ""
        return ElevenLabsMode(rawValue: raw) ?? .verbatim
    }

    static var elevenLabsBaseURL: URL {
        url(from: setting(forKey: elevenLabsBaseURLKey) ?? "")
            ?? URL(string: defaultElevenLabsBaseURL)!
    }

    static var elevenLabsTranscriptionsURL: URL {
        elevenLabsBaseURL.appending(path: "speech-to-text")
    }

    /// Проверка ключа. Списка моделей распознавания у сервиса нет: `GET /v1/models`
    /// отвечает голосами синтеза, и признака «умеет распознавать» там не бывает.
    static var elevenLabsUserURL: URL {
        elevenLabsBaseURL.appending(path: "user")
    }

    /// Словарь как список слов. Хранится обычным текстом — по строке или через
    /// запятую, как человеку удобнее, — а движкам нужен именно список.
    ///
    /// Ограничение не выдумано: у whisper подсказка живёт в тех же 224 токенах,
    /// что и текст, и слишком длинный словарь начинает вытеснять расшифровку.
    static let vocabularyLimit = 700

    static var vocabulary: [String] {
        terms(from: setting(forKey: vocabularyKey) ?? "")
    }

    /// Зеркало словаря в рабочей папке.
    ///
    /// Владелец потерял словарь: было 52 слова, стало 0. Проверка показала, что
    /// файл настроек пуст, пока приложение работает, и наполняется при уходе в
    /// фон, — значит настройка, сделанная перед жёстким завершением процесса
    /// (свайп из переключателя задач, падение, истёкший профиль и переустановка),
    /// пропадает целиком. Искать сломанную миграцию было незачем: её нет.
    ///
    /// Словарь — единственное, что человек набирает руками и не может
    /// восстановить по памяти, поэтому он дублируется в файл рядом с записями.
    /// Файл переживает переустановку и забирается с Mac вместе с папкой.
    static var vocabularyMirror: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Lori", directoryHint: .isDirectory)
            .appending(path: "vocabulary.txt")
    }

    static func mirrorVocabulary(_ text: String) {
        try? FileManager.default.createDirectory(
            at: vocabularyMirror.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(text.utf8).write(to: vocabularyMirror, options: .atomic)
    }

    /// Восстановление при запуске: только если настройка пуста, а зеркало нет.
    /// Обратное направление опаснее — вернуть удалённые слова человеку, который
    /// их удалил, значит спорить с ним.
    static func restoreVocabularyIfLost() {
        let stored = (setting(forKey: vocabularyKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored.isEmpty,
              let mirrored = try? String(contentsOf: vocabularyMirror, encoding: .utf8),
              !mirrored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UserDefaults.standard.set(mirrored, forKey: vocabularyKey)
        Diagnostics.note("словарь восстановлен из файла: \(terms(from: mirrored).count) слов")
    }

    static func terms(from raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var length = 0
        for piece in raw.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" }) {
            let term = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            length += term.count + 2
            guard length <= vocabularyLimit else { break }
            result.append(term)
        }
        return result
    }

    /// Одна строка для подсказки модели. Пусто — значит подсказку не передаём вовсе.
    static var vocabularyHint: String {
        vocabulary.joined(separator: ", ")
    }

    static var gigaAMVariant: GigaAMVariant {
        let raw = setting(forKey: gigaAMVariantKey) ?? ""
        return GigaAMVariant(rawValue: raw) ?? .rnnt
    }

    static var openAITranscriptionsURL: URL {
        openAIBaseURL.appending(path: "audio/transcriptions")
    }

    static var openAIModelsURL: URL {
        openAIBaseURL.appending(path: "models")
    }

    static let defaultGeminiHost = "https://generativelanguage.googleapis.com"

    /// Куда идут запросы к Gemini. По умолчанию — к Google, но Google отвечает
    /// «User location is not supported for the API use» из ряда стран, и тогда
    /// единственный работающий путь — свой прокси в поддерживаемом регионе.
    static var geminiHost: URL {
        url(from: setting(forKey: geminiBaseURLKey) ?? "")
            ?? URL(string: defaultGeminiHost)!
    }

    /// Работаем ли через свой адрес: от этого зависит, можно ли доверять
    /// ссылке на загрузку, которую вернул сервис.
    static var geminiUsesCustomHost: Bool {
        geminiHost.absoluteString != defaultGeminiHost
    }

    static var geminiInteractionsURL: URL { geminiHost.appending(path: "v1beta/interactions") }
    static var geminiFilesUploadURL: URL { geminiHost.appending(path: "upload/v1beta/files") }
    static var geminiModelsURL: URL { geminiHost.appending(path: "v1beta/models") }

    /// Только http и https, только с хостом. `URL(string:)` принимает почти любую
    /// строку, поэтому проверки обязательны: иначе запрос уйдёт в никуда.
    static func url(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    /// Человекочитаемая строка для настроек и карточки записи.
    /// Режим выбранного движка. Хранится в тех же ключах, что и раньше: у
    /// GigaAM это вариант модели, у Gemini — режим расшифровки, у OpenAI режим
    /// выводится из выбранной модели. Поэтому переключение движка туда и обратно
    /// возвращает прежний режим само собой — отдельной памяти не требуется.
    static func mode(for kind: TranscriptionEngineKind) -> TranscriptionMode? {
        let modes = EngineCatalog.descriptor(for: kind).modes
        guard !modes.isEmpty else { return nil }
        let current: String?
        switch kind {
        case .gigaam: current = gigaAMVariant.rawValue
        case .gemini: current = geminiMode.rawValue
        case .openAI: current = OpenAIMode.of(openAIModel)?.rawValue
        case .elevenLabs: current = elevenLabsMode.rawValue
        case .whisper, .apple: current = nil
        }
        return modes.first { $0.id == current } ?? modes.first
    }

    /// Своя модель в настройках — это не режим: чип показывает её как есть.
    static func hasCustomModel(for kind: TranscriptionEngineKind) -> Bool {
        kind == .openAI && OpenAIMode.of(openAIModel) == nil
    }

    static func setMode(_ mode: TranscriptionMode, for kind: TranscriptionEngineKind) {
        switch kind {
        case .gigaam:
            UserDefaults.standard.set(mode.id, forKey: gigaAMVariantKey)
        case .gemini:
            UserDefaults.standard.set(mode.id, forKey: geminiModeKey)
        case .openAI:
            // Режим OpenAI — это пресет над моделью: он её и выставляет.
            guard let preset = OpenAIMode(rawValue: mode.id) else { return }
            UserDefaults.standard.set(preset.model, forKey: openAIModelKey)
        case .elevenLabs:
            UserDefaults.standard.set(mode.id, forKey: elevenLabsModeKey)
        case .whisper, .apple:
            break
        }
    }

    static func describedTarget(for engine: TranscriptionEngineKind) -> String {
        switch engine {
        case .gigaam: gigaAMVariant.title
        case .whisper, .apple: engine.title
        case .openAI: "\(openAIBaseURL.host() ?? "OpenAI") · \(openAIModel)"
        case .gemini: "\(geminiHost.host() ?? "Gemini") · \(geminiModel)"
        case .elevenLabs: "\(elevenLabsBaseURL.host() ?? "ElevenLabs") · \(elevenLabsModel)"
        }
    }

    private static func setting(forKey key: String) -> String? {
        if let job = TranscriptionJob.current { return job.values[key] }
        return UserDefaults.standard.object(forKey: key).map { String(describing: $0) }
    }

    private static func value(forKey key: String, fallback: String) -> String {
        let stored = (setting(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? fallback : stored
    }
}


/// Два режима работы Gemini: дословный и «причёсанный».
///
/// Режим — единственное, что решает, что уйдёт в запрос.
///
/// Раньше таймкоды и говорящие были независимыми переключателями поверх режима,
/// и приложение могло сказать две противоположные вещи разом: режим «Точность»
/// с подписью «без таймкодов» — и тут же включённый тумблер «Таймкоды реплик».
/// Теперь выбор один, и он же виден в чипе панели: три режима, три исхода.
/// Документация Google (27 августа 2026): `smart` с таймкодами несовместим.
enum GeminiMode: String, CaseIterable, Identifiable, Sendable {
    /// Дословно, без таймкодов и говорящих: `{"type": "verbatim"}` без подполей.
    case accuracy
    /// Дословно плюс `timestamp_granularities` и `diarization_mode`. Говорящие
    /// приходят только вместе с таймингами слов — проверено на живом API.
    case speakers
    /// Режим `smart` из документации: сервис сам убирает слова-паразиты,
    /// запинки и повторы и расставляет форматирование.
    case smart

    var id: String { rawValue }

    /// Порядок один и тот же везде, где режимы показываются.
    static let ordered: [GeminiMode] = [.accuracy, .speakers, .smart]

    var title: String {
        switch self {
        case .accuracy: "Точность"
        case .speakers: "Спикеры и таймкоды"
        case .smart: "Причёсанный текст"
        }
    }

    /// Короткое имя для чипа в панели.
    var short: String {
        switch self {
        case .accuracy: "Точность"
        case .speakers: "Спикеры"
        case .smart: "Причёсанный"
        }
    }

    var detail: String {
        switch self {
        case .accuracy:
            "Дословная расшифровка без таймкодов и говорящих. Час записи одним запросом."
        case .speakers:
            "Дословно, со временем каждой реплики и разделением говорящих. Предел одного запроса — 30 минут."
        case .smart:
            "Сервис сам убирает слова-паразиты, запинки и повторы и расставляет абзацы. Дословности не будет, таймкодов и говорящих тоже — зато текст сразу читаемый."
        }
    }
}
