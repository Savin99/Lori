import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Палитра берётся из LoriPalette в ContentView.swift, чтобы иконка и приложение совпадали.
let canvas = CGColor(srgbRed: 0.961, green: 0.957, blue: 0.914, alpha: 1)
let ink = CGColor(srgbRed: 0.12, green: 0.12, blue: 0.11, alpha: 1)
let lime = CGColor(srgbRed: 0.36, green: 0.47, blue: 0.0, alpha: 1)

func render(size: CGFloat, background: CGColor, glyph: CGColor, to url: URL) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fatalError("нет контекста") }

    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))

    let font = CTFontCreateWithName("Georgia" as CFString, size * 0.62, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): glyph,
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: "L", attributes: attributes)
    )
    // Центрируем по фактическим границам глифа, а не по метрикам строки:
    // иначе засечки и внутренние отступы шрифта уводят букву влево и вниз.
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.textPosition = CGPoint(
        x: (size - bounds.width) / 2 - bounds.minX,
        y: (size - bounds.height) / 2 - bounds.minY
    )
    CTLineDraw(line, context)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.png.identifier as CFString, 1, nil
          ) else { fatalError("нет PNG") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("не записалось") }
    print("готово: \(url.lastPathComponent)")
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
render(size: 1024, background: canvas, glyph: ink, to: outputDirectory.appending(path: "v1-cream-ink.png"))
render(size: 1024, background: ink, glyph: canvas, to: outputDirectory.appending(path: "v2-ink-cream.png"))
render(size: 1024, background: canvas, glyph: lime, to: outputDirectory.appending(path: "v3-cream-lime.png"))
render(size: 1024, background: lime, glyph: canvas, to: outputDirectory.appending(path: "v4-lime-cream.png"))
