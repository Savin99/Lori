import CoreText
import UIKit

/// Расшифровка страницами A4.
///
/// PDF — это то, что откроется у любого получателя без вопросов о формате;
/// поэтому он и стоит первым в меню «Поделиться». Вёрстка повторяет экспорт
/// веб-интерфейса Lori (поля 21/18 мм, заголовок Georgia): продукт один, и
/// лист, присланный с телефона, не должен выглядеть чужим рядом с листом с Мака.
enum TranscriptPDF {
    /// A4 в точках.
    static let pageSize = CGSize(width: 595.28, height: 841.89)
    /// 18 мм по бокам, 21 мм сверху и снизу — как в вебе.
    static let sideMargin: CGFloat = 51
    static let verticalMargin: CGFloat = 59.5
    /// Воздух между шапкой, линией под ней и текстом.
    static let ruleGap: CGFloat = 12

    // MARK: - Цвета
    //
    // Палитра приложения динамическая: `LoriPalette.ink` в тёмной теме почти
    // белый. Внутри рендера тема телефона никак не связана с бумагой, и лист,
    // сделанный вечером, вышел бы белым по белому. Поэтому здесь свои цвета,
    // и страница белая, а не кремовая: кремовый холст — язык экрана, на печати
    // он съедает тонер. Оливковая линия под шапкой — единственный акцент.

    private static let ink = UIColor(red: 0.12, green: 0.12, blue: 0.11, alpha: 1)
    private static let muted = UIColor(red: 0.44, green: 0.44, blue: 0.41, alpha: 1)
    private static let lime = UIColor(red: 0.36, green: 0.47, blue: 0, alpha: 1)
    private static let warn = UIColor(red: 0.62, green: 0.44, blue: 0.05, alpha: 1)

    static func data(for export: TranscriptExport) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: export.title,
            kCGPDFContextCreator as String: "Lori",
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize),
            format: format
        )

        let header = header(for: export)
        let body = body(for: export)
        let contentWidth = pageSize.width - sideMargin * 2
        let headerHeight = ceil(header.boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)

        // Шапка живёт вне текстового потока: только так под ней можно провести
        // линию, не угадывая, где именно поток кончился.
        func column(page: Int) -> CGRect {
            let top = page == 0 ? verticalMargin + headerHeight + ruleGap * 2 : verticalMargin
            return CGRect(
                x: sideMargin,
                y: top,
                width: contentWidth,
                height: pageSize.height - verticalMargin - top
            )
        }

        let framesetter = CTFramesetterCreateWithAttributedString(body)
        let pages = pageRanges(framesetter, length: body.length, column: column)

        return renderer.pdfData { context in
            for (index, range) in pages.enumerated() {
                context.beginPage()
                if index == 0 {
                    header.draw(
                        with: CGRect(
                            x: sideMargin,
                            y: verticalMargin,
                            width: contentWidth,
                            height: headerHeight
                        ),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        context: nil
                    )
                    let line = CGRect(
                        x: sideMargin,
                        y: verticalMargin + headerHeight + ruleGap,
                        width: contentWidth,
                        height: 0.8
                    )
                    lime.setFill()
                    context.cgContext.fill(line)
                }
                if range.length > 0 {
                    let cg = context.cgContext
                    cg.saveGState()
                    // CoreText считает от левого нижнего угла, UIKit — от левого
                    // верхнего. Без переворота текст встаёт зеркально.
                    cg.translateBy(x: 0, y: pageSize.height)
                    cg.scaleBy(x: 1, y: -1)
                    // Текстовая матрица **не входит в графическое состояние**:
                    // `saveGState`/`restoreGState` её не возвращают, и та,
                    // которую оставил после себя `CTFrameDraw`, доставалась
                    // следующей странице. Отсюда живой отчёт с телефона: первая
                    // страница верна, а все следующие зеркальны.
                    cg.textMatrix = .identity
                    let frame = CTFramesetterCreateFrame(framesetter, range, path(for: column(page: index)), nil)
                    CTFrameDraw(frame, cg)
                    cg.restoreGState()
                }
                if pages.count > 1 { drawFooter(page: index + 1, of: pages.count) }
            }
        }
    }

    // MARK: - Разбивка на страницы

    /// Куски текста по страницам считаются заранее — иначе в подписи не написать
    /// «из пяти», а «стр. 3» без общего числа не говорит, кончился ли документ.
    private static func pageRanges(
        _ framesetter: CTFramesetter,
        length: Int,
        column: (Int) -> CGRect
    ) -> [CFRange] {
        guard length > 0 else { return [CFRange(location: 0, length: 0)] }
        var ranges: [CFRange] = []
        var start = 0
        while start < length {
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: start, length: 0),
                path(for: column(ranges.count)),
                nil
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            // Ноль означал бы вечный цикл: страница, на которую ничего не влезло.
            let taken = max(Int(visible.length), 1)
            ranges.append(CFRange(location: start, length: taken))
            start += taken
        }
        return ranges
    }

    private static func path(for rect: CGRect) -> CGPath {
        let flipped = CGRect(
            x: rect.minX,
            y: pageSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let path = CGMutablePath()
        path.addRect(flipped)
        return path
    }

    private static func drawFooter(page: Int, of total: Int) {
        let text = NSAttributedString(
            string: "стр. \(page) из \(total)",
            attributes: [
                .font: UIFont.systemFont(ofSize: 8.5),
                .foregroundColor: muted,
            ]
        )
        let size = text.size()
        text.draw(at: CGPoint(
            x: (pageSize.width - size.width) / 2,
            y: pageSize.height - verticalMargin + ruleGap
        ))
    }

    // MARK: - Текст

    private static func header(for export: TranscriptExport) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: export.title + "\n",
            // Georgia стоит в системе, отдельный файл шрифта не нужен.
            attributes: attributes(
                font: UIFont(name: "Georgia", size: 25) ?? .systemFont(ofSize: 25, weight: .semibold),
                color: ink,
                style: style(spacingAfter: 6)
            )
        ))
        result.append(NSAttributedString(
            string: export.meta + "\n",
            attributes: attributes(
                font: .systemFont(ofSize: 9.5),
                color: muted,
                style: style(spacingAfter: export.detail == nil ? 4 : 8)
            )
        ))
        if let detail = export.detail, !detail.isEmpty {
            result.append(NSAttributedString(
                string: detail + "\n",
                attributes: attributes(
                    font: .systemFont(ofSize: 10.5),
                    color: ink,
                    style: style(lineSpacing: 3, spacingAfter: 6)
                )
            ))
        }
        if let engine = export.engine, !engine.isEmpty {
            result.append(NSAttributedString(
                string: "Расшифровано: \(engine)" + (export.mode.map { " · \($0)" } ?? "") + "\n",
                attributes: attributes(
                    font: .systemFont(ofSize: 9.5),
                    color: muted,
                    style: style(spacingAfter: export.warnings.isEmpty ? 0 : 8)
                )
            ))
        }
        // Замечания стоят в шапке, а не в конце: это свойство всей расшифровки,
        // и человек, получивший файл, должен знать о дырах до того, как начнёт
        // читать, а не после.
        for (offset, warning) in export.warnings.enumerated() {
            result.append(NSAttributedString(
                string: warning + (offset == export.warnings.count - 1 ? "" : "\n"),
                attributes: attributes(
                    font: .systemFont(ofSize: 9.5),
                    color: warn,
                    style: style(lineSpacing: 2, spacingAfter: 2)
                )
            ))
        }
        return result
    }

    private static func body(for export: TranscriptExport) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = style(lineSpacing: 6, spacingAfter: 9)
        for (offset, block) in export.blocks.enumerated() {
            if let range = block.markedRange {
                result.append(NSAttributedString(
                    string: range + "  ",
                    // Моноширинные цифры: иначе колонка времени пляшет.
                    attributes: attributes(
                        font: .monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                        color: muted,
                        style: paragraph
                    )
                ))
            }
            if let speaker = block.speaker {
                result.append(NSAttributedString(
                    string: speaker + ": ",
                    attributes: attributes(
                        font: .systemFont(ofSize: 11, weight: .semibold),
                        color: ink,
                        style: paragraph
                    )
                ))
            }
            result.append(NSAttributedString(
                string: block.text + (offset == export.blocks.count - 1 ? "" : "\n"),
                attributes: attributes(font: .systemFont(ofSize: 11), color: ink, style: paragraph)
            ))
        }
        return result
    }

    /// Цвет проставляется двумя ключами. Шапку рисует UIKit и читает
    /// `.foregroundColor`, а текст — CoreText, и у него для цвета свой ключ с
    /// `CGColor`. С одним ключом половина документа выходила бы чёрной по
    /// умолчанию, независимо от задуманного цвета.
    private static func attributes(
        font: UIFont,
        color: UIColor,
        style: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            .paragraphStyle: style,
        ]
    }

    private static func style(lineSpacing: CGFloat = 0, spacingAfter: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = spacingAfter
        return style
    }
}
