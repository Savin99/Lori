import ActivityKit
import Foundation

/// Live Activity записи: островок Dynamic Island и экран блокировки.
///
/// Файл общий для приложения и расширения. Расширение видит только то, что лежит
/// здесь и в `ContentState`: своего доступа к файлам приложения у него нет (App
/// Group бесплатная команда не подписывает, а Live Activity и так живёт в своей
/// песочнице без сети). Поэтому всё, что нужно нарисовать, — уже готовые слова.
///
/// Активность есть только у записи. Расшифровку в островке рисует системная полоса
/// `BGContinuedProcessingTask` — вторая своя полоса рядом с ней не нужна.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            /// Микрофон пишет, таймер идёт сам.
            case recording
            /// Кусок закрыт, ждём «Продолжить» или «Расшифровать».
            case paused
            /// Куски склеиваются в одну запись: таймер стоит, кнопок нет — нажимать
            /// пока нечего.
            case saving
            /// Запись собрана и ушла в список — короткое прощание перед уходом.
            case finished
        }

        var phase: Phase
        /// Точка отсчёта таймера: «момент обновления минус уже записанное». Пока идёт
        /// запись, `Text(timerInterval:)` считает от неё сам — без обновлений раз в
        /// секунду, которых система активности не даёт.
        var timerStart: Date
        /// Сколько записано к моменту паузы или конца — на этом значении таймер стоит.
        var recorded: TimeInterval
        /// Почему пауза, одним-двумя словами: «звонок», «микрофон отключён». `nil` —
        /// паузу поставил человек, и объяснять нечего.
        var reason: String?
        /// «Расшифровать» открывает Lori, а не работает в фоне: у движка на телефоне
        /// заявку на фоновую расшифровку iOS примет только от приложения на виду.
        var finishOpensApp: Bool
        /// «Расшифровать» или «Сохранить» — смотря по «Расшифровывать запись сразу».
        var finishTitle: String
        /// Запись поднята после перезапуска Lori: предлагаем и «Удалить».
        var canDiscard: Bool
        /// Строка прощания: «Отправлено на расшифровку».
        var note: String?

        /// Таймер стоит на `recorded`, пока запись не идёт.
        var pauseTime: Date? {
            phase == .recording ? nil : timerStart.addingTimeInterval(max(0, recorded))
        }

        /// Диапазон для `Text(timerInterval:)`: открытый вперёд на сутки. Записи
        /// дольше восьми часов у Live Activity не бывает — система снимает её сама.
        var timerRange: ClosedRange<Date> {
            timerStart...timerStart.addingTimeInterval(max(recorded, 0) + 24 * 3600)
        }

        /// Таймер перевалил за час — в строке появляется третья группа цифр.
        var showsHours: Bool { recorded >= 3600 }

        /// Кнопки есть, пока запись можно поставить на паузу, продолжить или закончить.
        var showsButtons: Bool { phase == .recording || phase == .paused }
    }

    /// Ссылка, по которой Lori открывается и заканчивает запись. Схема — bundle ID
    /// приложения: у Lori и Lori QA она своя, и чужую сборку ссылка не откроет.
    var finishURL: URL
}

/// Слова Live Activity — одни на островок, экран блокировки и тесты приложения.
enum RecordingActivityCopy {
    /// «Lori», «Пауза», «Пауза · звонок», «Отправлено на расшифровку».
    ///
    /// Слова «Запись» здесь нет нарочно (владелец, 24 октября 2026): островок должен
    /// быть незаметным — видно, что Lori занята, а не что идёт запись разговора.
    static func headline(_ state: RecordingActivityAttributes.ContentState) -> String {
        switch state.phase {
        case .recording: "Lori"
        case .paused: state.reason.map { "Пауза · \($0)" } ?? "Пауза"
        case .saving: "Сохраняю…"
        case .finished: state.note ?? "Lori"
        }
    }

    /// Строка для VoiceOver про всю активность сразу.
    static func accessibilitySummary(_ state: RecordingActivityAttributes.ContentState, stale: Bool) -> String {
        if stale, state.phase == .recording { return staleLine }
        switch state.phase {
        case .recording: return "Lori пишет звук"
        case .paused: return state.reason.map { "Lori на паузе: \($0)" } ?? "Lori на паузе"
        case .saving: return "Lori сохраняет запись"
        case .finished: return state.note ?? "Lori"
        }
    }

    /// Активность давно не обновлялась, а таймер всё идёт: процесс Lori мог умереть.
    /// Честнее сказать это, чем тикать дальше.
    static let staleLine = "Lori не отвечает — открой её"

    static let pause = "Пауза"
    static let resume = "Продолжить"
    static let discard = "Удалить"

    static let pauseHint = "Поставить запись на паузу"
    static let resumeHint = "Продолжить запись"
    static let discardHint = "Удалить запись в корзину Lori"

    static func finishHint(_ state: RecordingActivityAttributes.ContentState) -> String {
        state.finishTitle == "Сохранить" ? "Остановить и сохранить запись" : "Остановить и расшифровать запись"
    }
}
