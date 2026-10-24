import AVFoundation
import Foundation

/// Склейка кусков записи в один файл.
///
/// Один кусок — просто переносится: перекладывать байты незачем. Несколько — без
/// перекодирования: `AVMutableComposition` с кусками подряд и экспорт
/// `AVAssetExportPresetPassthrough`. Куски пишет один и тот же рекордер с одними
/// настройками (AAC 44,1 кГц моно), поэтому пакеты AAC переезжают как есть — качество
/// не теряется, а часовая запись собирается за секунды, а не за минуты кодирования.
/// Не вышел сквозной экспорт — запасной путь с перекодированием (`AppleM4A`):
/// записать хоть так лучше, чем не записать.
///
/// Длительность итога проверяется по самому файлу: экспорт, отдавший «успех» и
/// половину звука, хуже честной ошибки — куски к тому моменту уже были бы удалены.
enum RecordingAssembler {
    /// Префикс временного файла склейки: недоделанный файл убирается при следующем запуске.
    static let temporaryPrefix = ".assembling-"

    struct Outcome: Equatable, Sendable {
        /// Длительность готового файла.
        var duration: TimeInterval
        /// Сколько кусков не прочиталось и в запись не вошло.
        var skipped: Int
        /// Собрано перекодированием, а не сквозным экспортом.
        var reencoded: Bool
    }

    enum Failure: LocalizedError, Equatable {
        /// Ни один кусок не читается или в них нет звука.
        case nothingToSave
        case exportFailed(String)
        case lengthMismatch(expected: TimeInterval, actual: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .nothingToSave:
                "В записи нет звука — сохранять нечего."
            case let .exportFailed(reason):
                "Не получилось собрать запись: \(reason)"
            case let .lengthMismatch(expected, actual):
                "Не получилось собрать запись: вышло \(Int(actual)) с вместо \(Int(expected)) с. Куски записи на месте — попробуй ещё раз."
            }
        }
    }

    /// Допуск на стык: у каждого куска AAC свой «разгон» кодировщика, и сумма длин
    /// по файлам и длина склейки расходятся на доли секунды.
    static func tolerance(for expected: TimeInterval, parts: Int) -> TimeInterval {
        max(0.5, 0.05 * Double(parts), expected * 0.005)
    }

    /// Склеивает куски по порядку в `destination` (файла там быть не должно).
    /// Единственный кусок переезжает (часовая запись не должна на время лежать
    /// дважды); несколько — остаются на месте, их убирает вызывающий, когда итог
    /// уже в списке.
    static func assemble(_ chunks: [URL], into destination: URL, workDirectory: URL) async throws -> Outcome {
        var readable: [(url: URL, duration: TimeInterval)] = []
        for url in chunks {
            // Кусок короче 50 мс — это старт, который тут же прервали: в нём нет звука.
            if let duration = RecordingAudio.duration(of: url), duration > 0.05 {
                readable.append((url, duration))
            }
        }
        let skipped = chunks.count - readable.count
        guard !readable.isEmpty else { throw Failure.nothingToSave }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if readable.count == 1 {
            try FileManager.default.moveItem(at: readable[0].url, to: destination)
            return Outcome(duration: readable[0].duration, skipped: skipped, reencoded: false)
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw Failure.exportFailed("нет звуковой дорожки") }
        var cursor = CMTime.zero
        for chunk in readable {
            let asset = AVURLAsset(url: chunk.url)
            let duration = try await asset.load(.duration)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = cursor + duration
        }
        let expected = cursor.seconds

        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let temporary = workDirectory.appending(path: "\(temporaryPrefix)\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }

        var reencoded = false
        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            reencoded = true
            try await export(composition, preset: AVAssetExportPresetAppleM4A, to: temporary)
        }

        let actual = try await AVURLAsset(url: temporary).load(.duration).seconds
        guard abs(actual - expected) <= tolerance(for: expected, parts: readable.count) else {
            throw Failure.lengthMismatch(expected: expected, actual: actual)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return Outcome(duration: actual, skipped: skipped, reencoded: reencoded)
    }

    private static func export(_ composition: AVComposition, preset: String, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw Failure.exportFailed("экспорт \(preset) недоступен")
        }
        do {
            try await session.export(to: output, as: .m4a)
        } catch {
            throw Failure.exportFailed(error.localizedDescription)
        }
    }
}
