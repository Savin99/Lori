import SwiftUI
import XCTest
@testable import LoriLocal

/// Кружок говорящего, время и первая строка реплики стоят на одной линии.
///
/// Владелец, 16 ноября 2026: «иконка круглая и текст невыровнены». Пока над репликой
/// стояла подпись «S1», кружок выравнивался по ней; подпись убрали, и кружок 28 pt,
/// прижатый к верху, повис ниже строки текста 16 pt. Глазом это видно, а рамкой
/// элемента — нет, поэтому строка рисуется в картинку и меряется по пикселям: середина
/// краски кружка против середины краски первой строки.
@MainActor
final class RecordingTranscriptLineAlignmentTests: XCTestCase {
    private let scale: CGFloat = 3
    private let width: CGFloat = 402
    /// Полторы точки — заметно меньше того, что видел владелец (около трёх).
    private let tolerance: CGFloat = 1.5

    func testAvatarSitsOnTheLineOfAnUnnamedSpeaker() throws {
        let bitmap = try render(line(start: nil, timeColumn: nil, label: "S2", name: "S2"))
        // Поля 12, кружок 28, шаг 12: кружок — x 12…40, текст — с 52.
        let avatar = try XCTUnwrap(bitmap.bands(points: 12..<40).first)
        let text = try XCTUnwrap(bitmap.bands(points: 52..<(width - 12)).first)
        XCTAssertEqual(avatar.center, text.center, accuracy: tolerance, "кружок \(avatar), строка \(text)")
    }

    func testTimeAvatarAndTextShareOneLine() throws {
        let bitmap = try render(line(start: 3, timeColumn: 40, label: "S2", name: "S2"))
        // Время 12…52, кружок 64…92, текст с 104.
        let time = try XCTUnwrap(bitmap.bands(points: 12..<52).first)
        let avatar = try XCTUnwrap(bitmap.bands(points: 64..<92).first)
        let text = try XCTUnwrap(bitmap.bands(points: 104..<(width - 12)).first)
        XCTAssertEqual(avatar.center, text.center, accuracy: tolerance, "кружок \(avatar), строка \(text)")
        XCTAssertEqual(time.center, text.center, accuracy: tolerance, "время \(time), строка \(text)")
    }

    /// С назначенным именем первой строкой идёт имя — кружок стоит на ней, а не на реплике.
    func testAvatarSitsOnTheNameOfANamedSpeaker() throws {
        let bitmap = try render(line(start: nil, timeColumn: nil, label: "S1", name: "Анна"))
        let avatar = try XCTUnwrap(bitmap.bands(points: 12..<40).first)
        let name = try XCTUnwrap(bitmap.bands(points: 52..<(width - 12)).first)
        XCTAssertEqual(avatar.center, name.center, accuracy: tolerance, "кружок \(avatar), имя \(name)")
    }

    // MARK: - Подготовка

    private func line(start: TimeInterval?, timeColumn: CGFloat?, label: String, name: String) -> some View {
        RecordingTranscriptLine(
            cursor: TranscriptPlaybackCursor(),
            id: 0,
            start: start,
            approximate: false,
            label: label,
            name: name,
            text: "Я вам уже отправил",
            timeColumn: timeColumn,
            canSeek: true,
            seek: { _ in },
            rename: {}
        )
        .frame(width: width)
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large)
    }

    private func render(_ view: some View) throws -> Bitmap {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage, "строка не нарисовалась")
        return Bitmap(image, scale: scale)
    }
}

/// Краска картинки по строкам пикселей. Строка 0 буфера — верх картинки.
private struct Bitmap {
    struct Band: CustomStringConvertible {
        let top: CGFloat
        let bottom: CGFloat
        var center: CGFloat { (top + bottom) / 2 }
        var description: String { String(format: "%.1f…%.1f", top, bottom) }
    }

    let width: Int
    let height: Int
    let scale: CGFloat
    private let pixels: [UInt8]

    init(_ image: CGImage, scale: CGFloat) {
        let (w, h) = (image.width, image.height)
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w
        height = h
        self.scale = scale
        pixels = buffer
    }

    /// Полосы строк с краской в столбцах `points` (в точках), сверху вниз. Фон строки
    /// прозрачный, поэтому краска — всё, что заметно непрозрачно.
    func bands(points: Range<CGFloat>) -> [Band] {
        let columns = max(0, Int(points.lowerBound * scale))..<min(width, Int(points.upperBound * scale))
        let inked = (0..<height).map { y in columns.contains { x in pixels[(y * width + x) * 4 + 3] > 80 } }
        var result: [Band] = []
        var start: Int?
        for y in 0...height {
            let ink = y < height && inked[y]
            if ink, start == nil { start = y }
            if !ink, let first = start {
                result.append(Band(top: CGFloat(first) / scale, bottom: CGFloat(y) / scale))
                start = nil
            }
        }
        return result
    }
}
