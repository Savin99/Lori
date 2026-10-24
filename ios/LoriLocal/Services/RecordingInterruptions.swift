import AVFoundation
import CallKit
import Foundation

/// Что случилось со звуком — в словах записи: поставить на паузу с причиной,
/// сказать, что продолжать уже можно, или ничего.
enum RecordingAudioEvent: Equatable, Sendable {
    case interrupted(RecordingPauseReason)
    /// Прерывание кончилось; `shouldResume` — система советует продолжить. Сама запись
    /// продолжается только после звонка, который так и не соединился (отклонён,
    /// пропущен); после разговора и всего прочего ждём «Продолжить» — меняются слова.
    case interruptionEnded(shouldResume: Bool)
    case ignore
}

/// Разбор уведомлений звуковой сессии. Чистые функции: модульные тесты подают им
/// `userInfo`, как подаёт система, и проверяют причину.
///
/// Источники — заголовки SDK 27.1 (`AVAudioSessionTypes.h`, `AVAudioSession.h`) и
/// статья Apple «Handling audio interruptions»:
/// - iOS 27 — `didBecomeInactiveNotification` с `DeactivationContext` (источник
///   `app`/`system` и `interruptionContext.reason`) и `resumptionRecommendationNotification`;
/// - iOS 18–26 — `interruptionNotification` (тип `began`/`ended`, причина — по ключу
///   `AVAudioSessionInterruptionReasonKey`); с iOS 27 он объявлен устаревшим;
/// - пропавший вход — `routeChangeNotification` с `.oldDeviceUnavailable` или
///   `.noSuitableRouteForCategory`;
/// - упавший звуковой сервер — `mediaServicesWereLost` / `mediaServicesWereReset`.
enum RecordingInterruptions {
    /// Причина паузы по причине прерывания. Звонок от другого приложения система не
    /// отличает: у обоих причина `default`. Отличает `CXCallObserver` — идёт ли сейчас
    /// звонок (`inCall`).
    static func reason(for interruption: AVAudioSession.InterruptionReason?, inCall: Bool) -> RecordingPauseReason {
        switch interruption {
        case .builtInMicMuted?, .routeDisconnected?:
            return .microphoneLost
        default:
            return inCall ? .call : .otherApp
        }
    }

    /// iOS 18–26: `AVAudioSession.interruptionNotification`.
    static func legacy(_ userInfo: [AnyHashable: Any]?, inCall: Bool) -> RecordingAudioEvent {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return .ignore }
        switch type {
        case .began:
            let cause = (userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
            return .interrupted(reason(for: cause, inCall: inCall))
        case .ended:
            let options = (userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return .ignore
        }
    }

    /// iOS 27: сессию выключили. Свою деактивацию (`source == .app`) пропускаем — это
    /// наша же пауза. Системная без `interruptionContext` («only present when the
    /// session was interrupted by another application») — не чужое приложение. Если по
    /// маршруту видно, что входа больше нет, это «микрофон отключён»; иначе — сама
    /// звуковая система: «сбой звука».
    static func deactivation(
        bySystem: Bool,
        interruption: AVAudioSession.InterruptionReason?,
        hasInterruptionContext: Bool,
        inCall: Bool,
        inputLost: Bool = false
    ) -> RecordingAudioEvent {
        guard bySystem else { return .ignore }
        guard hasInterruptionContext else { return .interrupted(inputLost ? .microphoneLost : .audioFailure) }
        return .interrupted(reason(for: interruption, inCall: inCall))
    }

    /// iOS 27: рекомендация продолжить (`ResumptionContext.recommendation`). Сам
    /// контекст создаёт только система (`init` недоступен), поэтому разбор — по уже
    /// вынутому значению: эту функцию проверяют тесты, а вынимание — только iOS 27.
    static func resumption(shouldResume: Bool) -> RecordingAudioEvent {
        .interruptionEnded(shouldResume: shouldResume)
    }

    /// Пропал ли вход: на маршруте нет входов или путь звука на вход недоступен.
    static func inputLost(currentInputs: [String], inputAvailable: Bool) -> Bool {
        currentInputs.isEmpty || !inputAvailable
    }

    /// Смена маршрута. Пауза — только когда пропал **вход**: наушники без микрофона,
    /// выдернутые из телефона, на запись не влияют.
    static func routeChange(_ userInfo: [AnyHashable: Any]?, previousInputs: [String]?, currentInputs: [String]) -> RecordingAudioEvent {
        guard let raw = userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return .ignore }
        switch reason {
        case .noSuitableRouteForCategory:
            return .interrupted(.microphoneLost)
        case .oldDeviceUnavailable:
            guard !currentInputs.isEmpty else { return .interrupted(.microphoneLost) }
            // Прежний маршрут не пришёл — считаем, что вход мог пропасть: лишняя пауза
            // дешевле записи, которая тихо пишет не тот микрофон.
            guard let previousInputs else { return .interrupted(.microphoneLost) }
            let lost = previousInputs.contains { !currentInputs.contains($0) }
            return lost ? .interrupted(.microphoneLost) : .ignore
        default:
            return .ignore
        }
    }

    /// Входы прежнего маршрута из `userInfo` смены маршрута.
    static func previousInputs(_ userInfo: [AnyHashable: Any]?) -> [String]? {
        (userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
            .inputs.map(\.uid)
    }
}

/// Перемена в звонках, как её видит запись.
struct CallChange: Equatable, Sendable {
    /// Хоть один звонок этого «эпизода» (от первого звонка до конца последнего)
    /// соединился — с человеком говорили.
    var connected: Bool
    /// Звонков больше нет.
    var allEnded: Bool
}

/// Звонки — для причины паузы и для решения, продолжать ли запись самой.
@MainActor
protocol CallMonitoring: AnyObject {
    /// Идёт ли сейчас звонок — любой: сотовый, FaceTime, мессенджер через CallKit.
    var isInCall: Bool { get }
    /// Соединялся ли звонок в текущем эпизоде, а если звонков нет — в последнем.
    var lastCallConnected: Bool { get }
    var onChange: ((CallChange) -> Void)? { get set }
}

/// `CXCallObserver` не требует ни прав, ни ключей в `Info.plist`.
///
/// Соединялся ли звонок, видно по `CXCall.hasConnected`; закончившийся звонок
/// система вскоре убирает из `calls`, поэтому ответ запоминается на весь эпизод.
@MainActor
final class CallDetector: NSObject, CallMonitoring, CXCallObserverDelegate {
    private let observer = CXCallObserver()
    private var episodeConnected = false
    private(set) var lastCallConnected = false
    var onChange: ((CallChange) -> Void)?

    override init() {
        super.init()
        // Запуск посреди разговора: эпизод уже идёт.
        episodeConnected = observer.calls.contains { $0.hasConnected && !$0.hasEnded }
        lastCallConnected = episodeConnected
        observer.setDelegate(self, queue: .main)
    }

    var isInCall: Bool { observer.calls.contains { !$0.hasEnded } }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let connected = call.hasConnected
        // `queue: .main` — делегата зовут на главном потоке.
        MainActor.assumeIsolated { self.changed(callConnected: connected) }
    }

    private func changed(callConnected: Bool) {
        if callConnected { episodeConnected = true }
        lastCallConnected = episodeConnected
        let allEnded = !isInCall
        onChange?(CallChange(connected: episodeConnected, allEnded: allEnded))
        if allEnded { episodeConnected = false }
    }
}
