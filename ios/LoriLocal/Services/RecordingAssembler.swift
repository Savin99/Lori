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
/// **Сквозной экспорт — в контейнер MPEG-4, а не M4A.** Замер 24 октября 2026
/// (симулятор iOS 26.5): для композиции из кусков AAC `compatibility(ofExportPreset:
/// Passthrough, outputFileType: .m4a)` — `false`, экспорт в `.m4a` падает с -11838
/// «Операция остановлена» (внутри -16976); `.mp4` — `true`, и выходит файл с той же
/// дорожкой `aac`, длиной ровно в сумму кусков (1,5 + 2,0 = 3,5 с по `AVURLAsset`).
/// Файл всё равно называется `.m4a`: M4A — это тот же MPEG-4 с одной звуковой
/// дорожкой, отличается только бренд в `ftyp` (`mp42` вместо `M4A `), а по расширению
/// запись опознают и список, и «Поделиться».
///
/// Длительность итога проверяется по самому файлу: экспорт, отдавший «успех» и
/// половину звука, хуже честной ошибки — куски к тому моменту уже были бы удалены.
enum RecordingAssembler {
    /// Префикс временного файла склейки: недоделанный файл убирается при следующем запуске.
    static let temporaryPrefix = ".assembling-"

    /// Кусок для склейки: файл и повтор в его начале (`RecordingSession.Chunk.trimStart`).
    struct Piece: Equatable, Sendable {
        var url: URL
        var trimStart: TimeInterval = 0
    }

    struct Outcome: Equatable, Sendable {
        /// Длительность готового файла.
        var duration: TimeInterval
        /// Куски, которые не прочитались (или в них нет звуковой дорожки) и в запись не
        /// вошли. Вызывающий откладывает их в корзину — молча стереть нельзя.
        var unreadable: [URL]
        /// Собрано перекодированием, а не сквозным экспортом.
        var reencoded: Bool
        /// Сколько повторов на стыках отрезано, в секундах.
        var trimmed: TimeInterval

        var skipped: Int { unreadable.count }
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
        try await assemble(chunks.map { Piece(url: $0) }, into: destination, workDirectory: workDirectory)
    }

    /// Повтор в начале куска отрезается, только если предыдущий кусок в запись вошёл:
    /// пропал предыдущий — повтор и есть единственная копия этого звука.
    static func assemble(_ pieces: [Piece], into destination: URL, workDirectory: URL) async throws -> Outcome {
        struct Included {
            var url: URL
            /// Ассет держится здесь до конца склейки: дорожка ссылается на него слабо, и
            /// без него `insertTimeRange` падает с -11800 / -12780 (так и упало 24 октября).
            var asset: AVURLAsset
            var track: AVAssetTrack
            var range: CMTimeRange
        }
        var included: [Included] = []
        var unreadable: [URL] = []
        var trimmed: TimeInterval = 0
        var previousIncluded = false
        for piece in pieces {
            // Кусок короче 50 мс — это старт, который тут же прервали: в нём нет звука.
            guard let length = RecordingAudio.duration(of: piece.url) else {
                unreadable.append(piece.url)
                previousIncluded = false
                continue
            }
            guard length > 0.05 else {
                previousIncluded = false
                continue
            }
            let asset = AVURLAsset(url: piece.url)
            guard let duration = try? await asset.load(.duration),
                  let source = try? await asset.loadTracks(withMediaType: .audio).first else {
                unreadable.append(piece.url)
                previousIncluded = false
                continue
            }
            var start = CMTime.zero
            if previousIncluded, piece.trimStart > 0 {
                let trim = min(piece.trimStart, max(0, duration.seconds - 0.05))
                start = CMTime(seconds: trim, preferredTimescale: 44_100)
                trimmed += trim
            }
            included.append(Included(url: piece.url, asset: asset, track: source, range: CMTimeRange(start: start, end: duration)))
            previousIncluded = true
        }
        guard !included.isEmpty else { throw Failure.nothingToSave }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if included.count == 1, included[0].range.start == .zero {
            try FileManager.default.moveItem(at: included[0].url, to: destination)
            let duration = RecordingAudio.duration(of: destination) ?? included[0].range.duration.seconds
            return Outcome(duration: duration, unreadable: unreadable, reencoded: false, trimmed: 0)
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw Failure.exportFailed("нет звуковой дорожки") }
        var cursor = CMTime.zero
        for piece in included {
            try track.insertTimeRange(piece.range, of: piece.track, at: cursor)
            cursor = cursor + piece.range.duration
        }
        let expected = cursor.seconds

        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let temporary = workDirectory.appending(path: "\(temporaryPrefix)\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }

        var reencoded = false
        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, as: .mp4, to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            reencoded = true
            try await export(composition, preset: AVAssetExportPresetAppleM4A, as: .m4a, to: temporary)
        }

        let actual = try await AVURLAsset(url: temporary).load(.duration).seconds
        guard abs(actual - expected) <= tolerance(for: expected, parts: included.count) else {
            throw Failure.lengthMismatch(expected: expected, actual: actual)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return Outcome(duration: actual, unreadable: unreadable, reencoded: reencoded, trimmed: trimmed)
    }

    private static func export(_ composition: AVComposition, preset: String, as type: AVFileType, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw Failure.exportFailed("экспорт \(preset) недоступен")
        }
        do {
            try await session.export(to: output, as: type)
        } catch {
            throw Failure.exportFailed(error.localizedDescription)
        }
    }
}
