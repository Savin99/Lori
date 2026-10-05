import SwiftUI
import UIKit

@main
struct LoriLocalApp: App {
    @UIApplicationDelegateAdaptor(LoriBackgroundDelegate.self) private var backgroundDelegate
    @StateObject private var workspace = WorkspaceStore()
    @StateObject private var summaries = SummaryStore()
    @StateObject private var summaryModels = SummaryModelStore()
    @StateObject private var summaryRunner: SummaryRunner
    /// Расшифровка живёт на уровне приложения, а не экрана: её очередь переживает
    /// уходы с главного экрана, а фоновая задача приходит от системы и не должна
    /// зависеть от того, построен ли уже `ContentView`.
    @StateObject private var transcription: TranscriptionService
    @StateObject private var runway: TranscriptionRunway

    init() {
        let workspace = WorkspaceStore(rootURL: RecoveryProbe.enabled ? RecoveryProbe.root : nil)
        _workspace = StateObject(wrappedValue: workspace)
        // Самой первой строкой — какая сборка работает. Дальше по журналу
        // разбирают поведение на телефоне, и начинать разбор надо с этого.
        Journal.noteLaunch()

        // Бегунок зависит от двух хранилищ, поэтому собирается здесь: так у
        // списка и у экрана записи один и тот же, а не по своему на экран.
        let summaries = SummaryStore(url: RecoveryProbe.enabled ? RecoveryProbe.summaries : nil)
        let models = SummaryModelStore()
        _summaries = StateObject(wrappedValue: summaries)
        _summaryModels = StateObject(wrappedValue: models)
        let runner = SummaryRunner(models: models, store: summaries)
        _summaryRunner = StateObject(wrappedValue: runner)

        // Сервис и его фоновое сопровождение знают друг о друге: `unowned` в одну
        // сторону, `weak` в другую — цикла нет, а собрать их можно только здесь.
        let transcription = TranscriptionService(interruptedStore: RecoveryProbe.enabled ? RecoveryProbe.queue : InterruptedRecords.url)
        let runway = TranscriptionRunway(service: transcription)
        transcription.runway = runway
        runner.connect(to: workspace, transcription: transcription)
        transcription.didSaveTranscript = { [weak runner] path, text in runner?.summarize(path: path, text: text) }
        transcription.willStart = { [weak runner] in await runner?.prepareForTranscription() }
        transcription.didDrain = { [weak runner] in runner?.applicationDidBecomeActive() }
        _transcription = StateObject(wrappedValue: transcription)
        _runway = StateObject(wrappedValue: runway)
        // Обработчик регистрируется до конца запуска и ровно один раз: на второй
        // регистрации того же идентификатора система убивает приложение.
        TranscriptionRunway.register()

        UserDefaults.standard.register(defaults: [
            TranscriptionSettings.engineKey: (KeychainStore.hasBundledKey(for: .elevenLabs)
                ? TranscriptionEngineKind.elevenLabs : .gigaam).rawValue,
            TranscriptionSettings.autoTranscribeKey: true,
        ])
        TranscriptionSettings.migrateLegacyGeminiMode()
        TranscriptionSettings.restoreVocabularyIfLost()
        if ImportInbox.isResetRequested { ImportInbox.forgetEverything() }
    }

    /// Unit-host не запускает задания пользовательского архива параллельно тестам.
    private var isUnitTestHost: Bool { NSClassFromString("XCTestCase") != nil }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspace)
                .environmentObject(summaries)
                .environmentObject(summaryModels)
                .environmentObject(summaryRunner)
                .environmentObject(transcription)
                .environmentObject(runway)
                // Акцент задаётся на уровне окна, а не экрана: у листа выбора
                // файлов и у шита «Поделиться» свой UIKit-мир, и `.tint`,
                // поставленный внутри `ContentView`, туда не доходил — кнопки
                // там оставались системными синими.
                .tint(LoriPalette.lime)
                // Отложенная заявка на фон подаётся, когда приложение стало активным:
                // на запуске `resumeInterrupted` дёргает очередь раньше этого момента.
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                ) { _ in
                    guard !isUnitTestHost else { return }
                    RecoveryProbe.note("didBecomeActive")
                    runway.applicationDidBecomeActive()
                    // Прерванное восстанавливается при **каждом** возвращении, а не
                    // только при холодном запуске: систему задача перестаёт устраивать,
                    // пока приложение в фоне, и процесс к этому моменту чаще всего жив —
                    // тогда `task` экрана больше не сработает, и запись так и осталась
                    // бы висеть «Прервано» до перезапуска.
                    transcription.applicationDidBecomeActive(in: workspace)
                    // Заголовки, отложенные на время фона, считаются здесь: в фоне
                    // графического процессора нет, и модель там убивает процесс.
                    summaryRunner.applicationDidBecomeActive()
                }
                // Уход в фон обрывает счёт заголовка до того, как система заберёт
                // графический процессор. `willResignActive`, а не
                // `didEnterBackground`: он приходит раньше, пока доступ ещё есть.
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
                ) { _ in
                    RecoveryProbe.note("willResignActive")
                    summaryRunner.applicationWillResignActive()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    RecoveryProbe.note("didEnterBackground")
                    transcription.applicationDidEnterBackground()
                    runway.applicationDidEnterBackground()
                }
                .task {
                    workspace.start()
                    guard !isUnitTestHost else { return }
                    // Заброшенные черновики частей: запись удалили, движок сменили —
                    // файл под отпечаток, который больше не совпадёт, лежал бы вечно.
                    TranscriptCheckpoint.prune()
                    // Прерванное системой в прошлый раз считается заново — но не
                    // обязательно с нуля: у облачной расшифровки готовые части
                    // сохранены черновиком, и спрашивается только остаток.
                    if UIApplication.shared.applicationState == .active {
                        transcription.applicationDidBecomeActive(in: workspace)
                    } else {
                        transcription.applicationDidEnterBackground()
                    }
                    // Самопроверка движка на устройстве: включается только переменной
                    // окружения, обычный запуск её не касается. См. `SelfTest`.
                    if RecoveryProbe.enabled {
                        await RecoveryProbe.run(workspace: workspace, service: transcription, summaries: summaries, runner: summaryRunner, runway: runway)
                    } else if SelfTest.isRequested { await SelfTest.run(in: workspace) }
                }
        }
    }
}
