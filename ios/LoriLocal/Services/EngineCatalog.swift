import Combine
import Foundation

/// Где считается расшифровка. Иконка в интерфейсе кодирует именно это, а не
/// бренд: человеку важно, уходит ли запись с телефона.
enum EngineLocality: Sendable {
    case onDevice
    case cloud

    var symbol: String {
        switch self {
        case .onDevice: "iphone"
        case .cloud: "cloud"
        }
    }
}

/// Готов ли движок к работе прямо сейчас.
enum EngineReadiness: Equatable, Sendable {
    case ready
    case needsKey
    case needsDownload
    case unavailable(String)

    /// Короткая пометка для чипа и шита. У готового движка пометки нет.
    var badge: String? {
        switch self {
        case .ready: nil
        case .needsKey: "Нет ключа"
        case .needsDownload: "Скачать модель"
        case let .unavailable(reason): reason
        }
    }
}

/// Режим — то, что человек выбирает осознанно. Под ним лежит модель и набор
/// полей запроса, но в интерфейсе виден только смысл: «точнее» или «быстрее».
struct TranscriptionMode: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// Короткое имя для чипа: «Максимальная точность» вытесняла из панели
    /// название самого движка.
    let short: String
    let detail: String

    init(id: String, title: String, short: String? = nil, detail: String) {
        self.id = id
        self.title = title
        self.short = short ?? title
        self.detail = detail
    }
}

/// Описание движка для интерфейса. Появление нового движка не должно требовать
/// правок в самих экранах — они читают только этот список.
struct EngineDescriptor: Identifiable, Sendable {
    let kind: TranscriptionEngineKind
    let displayName: String
    let subtitle: String
    let locality: EngineLocality
    let modes: [TranscriptionMode]

    var id: String { kind.rawValue }
    var defaultMode: TranscriptionMode? { modes.first }
}

/// Каталог движков и их режимов.
enum EngineCatalog {
    /// Список строится при каждом обращении: подпись облачного движка — это
    /// выбранная модель, а она меняется в настройках.
    static var all: [EngineDescriptor] {[
        EngineDescriptor(
            kind: .gigaam,
            displayName: "GigaAM v3",
            subtitle: "Русский, таймкоды слов",
            locality: .onDevice,
            modes: GigaAMVariant.allCases.map {
                TranscriptionMode(id: $0.rawValue, title: $0.modeTitle, detail: $0.detail)
            }
        ),
        EngineDescriptor(
            kind: .whisper,
            displayName: "Whisper turbo",
            subtitle: "Многоязычный, пунктуация, таймкоды слов",
            locality: .onDevice,
            modes: []
        ),
        EngineDescriptor(
            kind: .apple,
            displayName: "Движок Apple",
            subtitle: "Без словаря, быстрый",
            locality: .onDevice,
            modes: []
        ),
        EngineDescriptor(
            kind: .openAI,
            displayName: "OpenAI",
            subtitle: TranscriptionSettings.openAIModel,
            locality: .cloud,
            modes: OpenAIMode.allCases.map {
                TranscriptionMode(id: $0.rawValue, title: $0.title, short: $0.short, detail: $0.detail)
            }
        ),
        EngineDescriptor(
            kind: .gemini,
            displayName: "Gemini",
            subtitle: TranscriptionSettings.geminiModel,
            locality: .cloud,
            modes: GeminiMode.ordered.map {
                TranscriptionMode(id: $0.rawValue, title: $0.title, short: $0.short, detail: $0.detail)
            }
        ),
        EngineDescriptor(
            kind: .elevenLabs,
            // Только бренд: в чипе панели «ElevenLabs Scribe» не влезает и режется
            // до «Eleven…», а модель и так стоит подписью ниже — как у OpenAI и Gemini.
            displayName: "ElevenLabs",
            subtitle: TranscriptionSettings.elevenLabsModel,
            locality: .cloud,
            modes: ElevenLabsMode.ordered.map {
                TranscriptionMode(id: $0.rawValue, title: $0.title, short: $0.short, detail: $0.detail)
            }
        ),
    ]}

    static func descriptor(for kind: TranscriptionEngineKind) -> EngineDescriptor {
        all.first { $0.kind == kind } ?? all[0]
    }

    static func onDevice() -> [EngineDescriptor] { all.filter { $0.locality == .onDevice } }
    static func cloud() -> [EngineDescriptor] { all.filter { $0.locality == .cloud } }
}

/// Режимы OpenAI. Своего понятия режима у сервиса нет: выбор человека
/// раскрывается в модель и поля запроса, а ручной выбор модели в настройках
/// остаётся переопределением.
enum OpenAIMode: String, CaseIterable, Identifiable, Sendable {
    case fast
    case words
    case speakers

    var id: String { rawValue }

    /// Модель, которой соответствует режим.
    var model: String {
        switch self {
        case .fast: "gpt-transcribe"
        case .words: "whisper-1"
        case .speakers: "gpt-4o-transcribe-diarize"
        }
    }

    var title: String {
        switch self {
        case .fast: "Быстрый текст"
        case .words: "Таймкоды слов"
        case .speakers: "Говорящие"
        }
    }

    /// Для чипа в панели, где рядом стоит название движка.
    var short: String {
        switch self {
        case .fast: "Быстро"
        case .words: "Таймкоды"
        case .speakers: "Говорящие"
        }
    }

    var detail: String {
        switch self {
        case .fast: "Основная модель расшифровки: текст без таймкодов."
        case .words: "whisper-1 — единственная модель с таймингами каждого слова."
        case .speakers: "Реплики с метками говорящих; подсказку со словарём эта модель не принимает."
        }
    }

    /// Режим по выбранной модели. Своя модель в настройках — это не режим.
    static func of(_ model: String) -> OpenAIMode? {
        allCases.first { $0.model.caseInsensitiveCompare(model) == .orderedSame }
    }
}

/// Режимы ElevenLabs Scribe.
///
/// Таймкоды и говорящих здесь просить не нужно режимом: у сервиса это отдельные
/// поля (`timestamps_granularity` и `diarize`), и они ложатся ровно на два общих
/// переключателя «Расшифровки» — это единственный движок, где оба работают
/// по-настоящему и независимо. Режиму остаётся один вопрос: что делать с тем,
/// что словами не является.
enum ElevenLabsMode: String, CaseIterable, Identifiable, Sendable {
    /// Как сказано, без пометок. `tag_audio_events: false` отправляется явно:
    /// у сервиса это поле по умолчанию **включено**.
    case verbatim
    /// `tag_audio_events: true` — смех, аплодисменты, музыка попадают в текст
    /// отдельными пометками со своим временем.
    case events
    /// `no_verbatim: true` — сервис сам убирает слова-паразиты, запинки и
    /// фальстарты. Поддерживается только моделью `scribe_v2`.
    case clean

    var id: String { rawValue }

    /// Порядок один и тот же везде, где режимы показываются.
    static let ordered: [ElevenLabsMode] = [.verbatim, .events, .clean]

    var title: String {
        switch self {
        case .verbatim: "Дословно"
        case .events: "Со звуками"
        case .clean: "Причёсанный текст"
        }
    }

    /// Для чипа в панели, где рядом стоит название движка.
    var short: String {
        switch self {
        case .verbatim: "Дословно"
        case .events: "Со звуками"
        case .clean: "Причёсанный"
        }
    }

    var detail: String {
        switch self {
        case .verbatim:
            "Дословная расшифровка. Таймкоды и говорящих включают переключатели «Расшифровки» — здесь работают оба."
        case .events:
            "То же дословно, но смех, аплодисменты и музыка попадают в текст пометками со своим временем."
        case .clean:
            "Сервис сам убирает слова-паразиты, запинки и фальстарты. Дословности не будет; работает только на scribe_v2."
        }
    }
}

/// Что переключатель «Расшифровки» значит для выбранного движка и модели.
/// Где возможности нет, переключатель не притворяется работающим — он выключен
/// и объясняет почему. Молча игнорировать настройку нельзя: человек включил
/// «Разделять говорящих» и вправе ждать говорящих или объяснения.
enum ToggleSupport: Equatable, Sendable {
    /// Реально управляет запросом или файлом расшифровки.
    case active
    /// У этой модели всегда включено, выключить нельзя.
    case fixedOn(String)
    /// Движок не умеет; в скобках — почему и где искать альтернативу.
    case unavailable(String)

    var explanation: String? {
        switch self {
        case .active: nil
        case let .fixedOn(reason), let .unavailable(reason): reason
        }
    }
}

/// Пара переключателей для текущего движка. Считается на месте — зависит от
/// выбранной модели OpenAI и режима Gemini, а они меняются в настройках.
struct EngineToggles: Equatable, Sendable {
    let timecodes: ToggleSupport
    let speakers: ToggleSupport

    static func current(for kind: TranscriptionEngineKind) -> EngineToggles {
        switch kind {
        case .gigaam:
            return EngineToggles(
                timecodes: .active,
                speakers: .unavailable("GigaAM не различает говорящих.")
            )
        case .whisper:
            return EngineToggles(
                timecodes: .active,
                speakers: .unavailable("Whisper не различает говорящих.")
            )
        case .apple:
            return EngineToggles(
                timecodes: .unavailable("Движок Apple отдаёт только текст — без таймкодов и говорящих."),
                speakers: .unavailable("Движок Apple отдаёт только текст — без таймкодов и говорящих.")
            )
        case .openAI:
            switch OpenAITranscriber.Family.of(TranscriptionSettings.openAIModel) {
            case .whisper:
                return EngineToggles(
                    timecodes: .active,
                    speakers: .unavailable("Говорящих различает режим «Говорящие» (gpt-4o-transcribe-diarize).")
                )
            case .diarization:
                return EngineToggles(
                    timecodes: .active,
                    speakers: .fixedOn("Эта модель всегда различает говорящих.")
                )
            case .plain:
                return EngineToggles(
                    timecodes: .unavailable("Эта модель отдаёт только текст; таймкоды слов — у режима «Таймкоды слов» (whisper-1)."),
                    speakers: .unavailable("Говорящих различает режим «Говорящие» (gpt-4o-transcribe-diarize).")
                )
            }
        case .elevenLabs:
            // Единственный движок, где оба переключателя настоящие: тайминги
            // слов приходят нативно на всю запись, говорящие — отдельным полем
            // `diarize`, и одно другого не требует.
            return EngineToggles(timecodes: .active, speakers: .active)
        case .gemini:
            switch TranscriptionSettings.geminiMode {
            case .speakers:
                let reason = "Режим «Спикеры и таймкоды» включает и то и другое."
                return EngineToggles(timecodes: .fixedOn(reason), speakers: .fixedOn(reason))
            case .accuracy:
                let reason = "Режим «Точность» отдаёт дословный текст без времени и говорящих — их даёт режим «Спикеры и таймкоды»."
                return EngineToggles(timecodes: .unavailable(reason), speakers: .unavailable(reason))
            case .smart:
                let reason = "Режим «Причёсанный текст» несовместим с таймкодами и говорящими."
                return EngineToggles(timecodes: .unavailable(reason), speakers: .unavailable(reason))
            }
        }
    }
}

/// Готовность движков для интерфейса. Чипу нужен ответ сразу, а проверка
/// `unavailability(of:)` в сервисе асинхронная — поэтому здесь дешёвые
/// синхронные признаки: есть ли ключ, скачана ли модель.
@MainActor
final class EngineDirectory: ObservableObject {
    @Published private(set) var readiness: [String: EngineReadiness] = [:]

    private let hasKey: @Sendable (KeychainAccount) -> Bool
    private let hasModel: @Sendable (GigaAMVariant) -> Bool
    private let hasWhisperModel: @Sendable () -> Bool

    init(
        hasKey: @escaping @Sendable (KeychainAccount) -> Bool = { KeychainStore.hasKey(for: $0) },
        hasModel: @escaping @Sendable (GigaAMVariant) -> Bool = { GigaAMModelSet.locate($0) != nil },
        hasWhisperModel: @escaping @Sendable () -> Bool = { WhisperModelSet.locate() != nil }
    ) {
        self.hasKey = hasKey
        self.hasModel = hasModel
        self.hasWhisperModel = hasWhisperModel
        refresh()
    }

    func refresh() {
        var found: [String: EngineReadiness] = [:]
        for engine in EngineCatalog.all {
            found[engine.id] = state(of: engine.kind)
        }
        readiness = found
    }

    func readiness(of kind: TranscriptionEngineKind) -> EngineReadiness {
        readiness[kind.rawValue] ?? .ready
    }

    private func state(of kind: TranscriptionEngineKind) -> EngineReadiness {
        if let account = kind.keychainAccount {
            return hasKey(account) ? .ready : .needsKey
        }
        if kind == .gigaam {
            return hasModel(TranscriptionSettings.gigaAMVariant) ? .ready : .needsDownload
        }
        // У Whisper пометка не «Скачать модель»: кнопки скачивания нет и не будет —
        // 632 МБ приложение само не тянет, папку приносят через «Файлы».
        if kind == .whisper {
            return hasWhisperModel() ? .ready : .unavailable("Нет модели")
        }
        return .ready
    }
}
