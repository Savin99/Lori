import AVFoundation
import CallKit
import Foundation

/// Что случилось со звуком — в словах записи: поставить на паузу с причиной,
/// сказать, что продолжать уже можно, или ничего.
enum RecordingAudioEvent: Equatable, Sendable {
    case interrupted(RecordingPauseReason)
    /// Прерывание кончилось. Запись при этом **не** продолжается сама — владелец
    /// решил ждать «Продолжить» (24 октября 2026), — меняются только слова в островке.
    case interruptionEnded
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
            return .interruptionEnded
        @unknown default:
            return .ignore
        }
    }

    /// iOS 27: сессию выключили. Свою деактивацию (`source == .app`) пропускаем — это
    /// наша же пауза. Системная без `interruptionContext` («only present when the
    /// session was interrupted by another application») — не чужое приложение, а сама
    /// звуковая система: «сбой звука».
    static func deactivation(bySystem: Bool, interruption: AVAudioSession.InterruptionReason?, hasInterruptionContext: Bool, inCall: Bool) -> RecordingAudioEvent {
        guard bySystem else { return .ignore }
        guard hasInterruptionContext else { return .interrupted(.audioFailure) }
        return .interrupted(reason(for: interruption, inCall: inCall))
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

/// Идёт ли сейчас звонок — любой: сотовый, FaceTime, мессенджер через CallKit.
/// `CXCallObserver` не требует ни прав, ни ключей в `Info.plist`.
@MainActor
final class CallDetector {
    private let observer = CXCallObserver()

    var isInCall: Bool { observer.calls.contains { !$0.hasEnded } }
}
