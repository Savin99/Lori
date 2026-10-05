import Foundation
import WhisperKit

/// Загруженные модели локальных движков, общие на всю пачку записей.
///
/// Раньше каждый вызов `transcribe()` собирал модель заново: `WhisperKit` — это 618 МБ
/// весов Core ML, GigaAM — три сессии ONNX на 225 МБ. На пяти записях подряд это пять
/// загрузок, и они же были главной причиной, почему две записи сразу считать было
/// нельзя: вторая копия весов упирается в потолок памяти приложения (право
/// `increased-memory-limit` бесплатная команда разработчика не подписывает).
///
/// Здесь модель одна на всех, и это решает обе задачи разом: пачка не платит за
/// повторные загрузки, а две записи делят одни веса вместо того, чтобы их удваивать.
///
/// **Сам счёт сериализован, и это сознательно.** У `OnnxSession` есть изменяемое поле
/// (`integerType`), а буфер выхода ORT переиспользуется следующим вызовом — два
/// одновременных `run` на одной сессии испортили бы друг другу данные. У `WhisperKit`
/// одновременный `transcribe` на одном экземпляре тоже нигде не обещан. Поэтому куски
/// разных записей идут через модель **по очереди**, чередуясь: обе записи двигаются,
/// обе карточки живые, памяти — как на одну. Настоящая параллель дала бы вторую копию
/// весов и не дала бы скорости: локальные движки и так делят один процессор.
actor EngineSessionCache {
    static let shared = EngineSessionCache()

    // MARK: - GigaAM

    /// `@unchecked Sendable` — не по недосмотру: к содержимому обращаются только изнутри
    /// этого актора, и только из синхронных тел, то есть строго по одному вызову за раз.
    final class GigaAMSession: @unchecked Sendable {
        enum Graph {
            case rnnt(encoder: GigaAMOnnxEncoder, network: GigaAMOnnxNetwork)
            case ctc(GigaAMOnnxCTC)
        }

        let vocabulary: SentencePieceVocabulary
        let spectrogram: LogMelSpectrogram
        let graph: Graph

        init(vocabulary: SentencePieceVocabulary, spectrogram: LogMelSpectrogram, graph: Graph) {
            self.vocabulary = vocabulary
            self.spectrogram = spectrogram
            self.graph = graph
        }
    }

    private var gigaam: [String: GigaAMSession] = [:]
    private var gigaamUsers: [String: Int] = [:]

    /// Отдаёт загруженную модель, поднимая счётчик пользователей. Вызывать ровно один
    /// раз на запись, парой к `releaseGigaAM`.
    func leaseGigaAM(_ models: GigaAMModelSet) throws -> GigaAMSession {
        let key = models.variant.rawValue
        gigaamUsers[key, default: 0] += 1
        if let ready = gigaam[key] { return ready }
        do {
            let session = try Self.loadGigaAM(models)
            gigaam[key] = session
            return session
        } catch {
            // Не загрузилась — счётчик обязан вернуться назад, иначе модель, которой нет,
            // навсегда останется «занятой» и следующая пачка её не выгрузит.
            gigaamUsers[key, default: 1] -= 1
            throw error
        }
    }

    func releaseGigaAM(_ variant: GigaAMVariant) {
        let key = variant.rawValue
        gigaamUsers[key] = max(0, (gigaamUsers[key] ?? 1) - 1)
    }

    /// Модель на всё время одной записи. `defer` внутри актора освобождает счётчик
    /// детерминированно — «отпустить потом отдельной задачей» оставило бы модель
    /// навсегда занятой, если бы выгрузка успела пройти раньше.
    func withGigaAM<T: Sendable>(
        _ models: GigaAMModelSet,
        _ body: sending (GigaAMSession) async throws -> T
    ) async throws -> T {
        let session = try leaseGigaAM(models)
        defer { releaseGigaAM(models.variant) }
        return try await body(session)
    }

    /// Один вызов модели. Тело **синхронное**, и это и есть шлюз: пока оно работает,
    /// актор занят, и второй записи приходится дождаться своей очереди.
    func compute<T: Sendable>(
        gigaam session: GigaAMSession,
        _ body: @Sendable (GigaAMSession) throws -> T
    ) throws -> T {
        try body(session)
    }

    private static func loadGigaAM(_ models: GigaAMModelSet) throws -> GigaAMSession {
        let vocabulary = try SentencePieceVocabulary(tableAt: models.vocabulary)
        let spectrogram = try LogMelSpectrogram()
        let graph: GigaAMSession.Graph
        switch models.variant {
        case .rnnt:
            graph = .rnnt(
                encoder: GigaAMOnnxEncoder(
                    session: try OnnxSession(url: models.url("v3_e2e_rnnt_encoder.int8.onnx")),
                    featuresName: "audio_signal",
                    lengthName: "length"
                ),
                network: GigaAMOnnxNetwork(
                    decoder: try OnnxSession(url: models.url("v3_e2e_rnnt_decoder.int8.onnx")),
                    joint: try OnnxSession(url: models.url("v3_e2e_rnnt_joint.int8.onnx")),
                    blankIndex: vocabulary.blankIndex
                )
            )
        case .ctc:
            graph = .ctc(GigaAMOnnxCTC(session: try OnnxSession(url: models.url("v3_e2e_ctc.int8.onnx"))))
        }
        return GigaAMSession(vocabulary: vocabulary, spectrogram: spectrogram, graph: graph)
    }

    // MARK: - Whisper

    final class WhisperSession: @unchecked Sendable {
        let pipe: WhisperKit

        init(pipe: WhisperKit) { self.pipe = pipe }
    }

    private var whisper: [String: WhisperSession] = [:]
    private var whisperUsers: [String: Int] = [:]
    /// Шлюз для Whisper заводится отдельно: его вызов асинхронный, а асинхронное тело
    /// актор отпускает на время ожидания — сериализации самим актором тут не выходит.
    private var whisperBusy: Set<String> = []
    private var whisperWaiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func leaseWhisper(_ models: WhisperModelSet) async throws -> WhisperSession {
        let key = models.folder.path
        whisperUsers[key, default: 0] += 1
        if let ready = whisper[key] { return ready }
        do {
            // `download: false` — единственная защита от похода в сеть за 618 МБ.
            let pipe = try await WhisperKit(WhisperKitConfig(
                modelFolder: models.folder.path,
                verbose: false,
                load: true,
                download: false
            ))
            // Пока грузили, другая запись могла успеть загрузить ту же модель.
            if let ready = whisper[key] { return ready }
            let session = WhisperSession(pipe: pipe)
            whisper[key] = session
            return session
        } catch {
            whisperUsers[key, default: 1] -= 1
            throw error
        }
    }

    func releaseWhisper(_ models: WhisperModelSet) {
        let key = models.folder.path
        whisperUsers[key] = max(0, (whisperUsers[key] ?? 1) - 1)
    }

    /// Модель на всё время одной записи, парой к счётчику пользователей.
    func withWhisperModel<T: Sendable>(
        _ models: WhisperModelSet,
        _ body: sending (WhisperSession) async throws -> T
    ) async throws -> T {
        let session = try await leaseWhisper(models)
        defer { releaseWhisper(models) }
        return try await body(session)
    }

    /// Один кусок через Whisper, строго по одному за раз.
    func withWhisper<T: Sendable>(
        _ session: WhisperSession,
        _ body: sending (WhisperKit) async throws -> T
    ) async throws -> T {
        let key = ObjectIdentifier(session).debugDescription
        while whisperBusy.contains(key) {
            await withCheckedContinuation { continuation in
                whisperWaiting[key, default: []].append(continuation)
            }
        }
        whisperBusy.insert(key)
        defer { openWhisperGate(key) }
        return try await body(session.pipe)
    }

    private func openWhisperGate(_ key: String) {
        whisperBusy.remove(key)
        guard var queue = whisperWaiting[key], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        whisperWaiting[key] = queue.isEmpty ? nil : queue
        next.resume()
    }

    // MARK: - Выгрузка

    /// Выгружает всё, чем никто не пользуется. Зовётся, когда очередь опустела: держать
    /// 618 МБ весов после последней записи незачем, а следующая пачка загрузит заново.
    func dropIdle() {
        for (key, count) in gigaamUsers where count == 0 {
            gigaam[key] = nil
            gigaamUsers[key] = nil
        }
        for (key, count) in whisperUsers where count == 0 {
            whisper[key] = nil
            whisperUsers[key] = nil
        }
    }

    /// Системе не хватает памяти. Занятое не трогаем — прогон всё равно рухнет без
    /// своей модели, и лучше отдать то, что точно никому не нужно.
    func dropUnderPressure() {
        dropIdle()
    }

    /// Для тестов: сколько сейчас загружено моделей и сколько у них пользователей.
    func inventory() -> (loaded: Int, users: Int) {
        (
            gigaam.count + whisper.count,
            gigaamUsers.values.reduce(0, +) + whisperUsers.values.reduce(0, +)
        )
    }
}
