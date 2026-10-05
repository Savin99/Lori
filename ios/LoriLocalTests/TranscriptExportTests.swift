import PDFKit
import XCTest
@testable import LoriLocal

/// Экспорт расшифровки файлом.
///
/// Регрессия, которую эти тесты держат: «Поделиться» отдавало наружу голую
/// строку — то есть сырой Markdown с решётками и звёздочками, — и получатель
/// вставлял её текстом в тело сообщения.
final class TranscriptExportTests: XCTestCase {
    /// Дата собирается по частям, а не числом секунд: в шапке проверяется
    /// именно её человеческая запись.
    private let recordedAt = Calendar(identifier: .gregorian).date(
        from: DateComponents(timeZone: .current, year: 2026, month: 8, day: 27, hour: 22, minute: 22)
    )!

    private func export(
        _ markdown: String,
        title: String = "Совещание",
        duration: TimeInterval? = 2472,
        detail: String? = nil,
        topic: String? = nil,
        names: [String: String] = [:]
    ) -> TranscriptExport {
        TranscriptExport.make(
            markdown: markdown,
            title: title,
            recordedAt: recordedAt,
            duration: duration,
            detail: detail,
            topic: topic,
            names: names
        )
    }

    func testHeaderCarriesTitleDateDurationAndTopic() {
        let text = export(
            "**[0:00–0:34]** Первая реплика.",
            duration: 2472,
            detail: "Договорились о сроках интеграции.",
            topic: "Работа"
        ).markdown

        XCTAssertTrue(text.hasPrefix("# Совещание\n"), text)
        XCTAssertTrue(text.contains("41:12"), "длительность записи: \(text)")
        XCTAssertTrue(text.contains("тема: Работа"), text)
        XCTAssertTrue(text.contains("Договорились о сроках интеграции."), text)
        // Дата абсолютная: «сегодня» и «22:22» через год ничего не скажут.
        XCTAssertTrue(text.contains("27 августа 2026, 22:22"), text)
    }

    /// Длительность знает плеер, а он не всегда загружен. Придумывать её нельзя,
    /// но последнее настоящее время в расшифровке — измеренное число.
    func testDurationFallsBackToTheLastStamp() {
        let text = export("**[0:00–0:34]** Реплика.\n\n**[10:00–10:20]** Вторая.", duration: nil).markdown

        XCTAssertTrue(text.contains("10:20"), text)
    }

    func testSpeakerLabelsBecomeNames() {
        let text = export(
            "**[0:00–0:34]** S1: Здравствуйте.\n\n**[0:35–0:40]** S2: Добрый день.",
            names: ["S1": "Аня"]
        ).markdown

        XCTAssertTrue(text.contains("Аня: Здравствуйте."), text)
        XCTAssertFalse(text.contains("S1:"), "имя дано — метки в файле быть не должно: \(text)")
        // Имени нет — остаётся метка: выдумывать второго человека нечем.
        XCTAssertTrue(text.contains("S2: Добрый день."), text)
    }

    /// В файле расшифровки стоит диапазон, и экспорт не имеет права быть беднее
    /// того файла, из которого его собрали.
    func testTimeRangeSurvives() {
        let text = export("**[1:05:20–1:05:44]** Реплика.").markdown

        XCTAssertTrue(text.contains("**[1:05:20–1:05:44]**"), text)
    }

    /// «кусок» — это границы отправленного фрагмента, а не время речи. Выдать
    /// одно за другое значит соврать.
    func testChunkBoundsStayMarkedAsChunks() {
        let text = export("**[кусок 0:00–5:00]** Реплика.").markdown

        XCTAssertTrue(text.contains("**[кусок 0:00–5:00]**"), text)
    }

    func testWarningsGoOutWithTheTranscript() {
        let text = export("""
        **[0:00–0:34]** Реплика.

        > Участок 5:00–6:00: слов сервис не дал.
        """).markdown

        XCTAssertTrue(text.contains("> Участок 5:00–6:00: слов сервис не дал."), text)
    }

    func testTextWithoutTimecodesHasNoInventedStamps() {
        let text = export("Просто текст без таймкодов.").markdown

        XCTAssertTrue(text.contains("Просто текст без таймкодов."), text)
        XCTAssertFalse(text.contains("**["), "времени не было — придумывать нечего: \(text)")
    }

    /// Имя файла видит получатель, и файловая система не примет двоеточие из
    /// «Запись 22:22» и слэш из даты.
    func testFilenameHasNoForbiddenCharacters() {
        XCTAssertEqual(
            export("Текст", title: "Запись 22:22").filename(for: .markdown),
            "Запись 22 22.md"
        )
        XCTAssertEqual(
            export("Текст", title: "Смета 03/09").filename(for: .pdf),
            "Смета 03 09.pdf"
        )
        XCTAssertEqual(export("Текст", title: "   ").filename(for: .pdf), "Расшифровка.pdf")
        // Точка первым знаком сделала бы файл скрытым.
        XCTAssertEqual(export("Текст", title: ".ssh").filename(for: .markdown), "Расшифровка.md")
    }

    func testFileLandsOutsideTheWorkspace() throws {
        let url = try TranscriptExportFile.write(Data("текст".utf8), name: "Проба.md")

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "текст")
        XCTAssertTrue(url.path.hasPrefix(FileManager.default.temporaryDirectory.path), url.path)
        XCTAssertFalse(url.path.contains("Documents/Lori"), "экспорт не место в рабочей папке: \(url.path)")
    }

    /// Папка чистится перед записью, а не после закрытия листа: иначе экспорты
    /// копились бы, а уборка «на выходе» выдёргивала бы файл из-под получателя.
    func testEachExportLeavesOneFile() throws {
        _ = try TranscriptExportFile.write(Data("раз".utf8), name: "Первый.md")
        _ = try TranscriptExportFile.write(Data("два".utf8), name: "Второй.md")

        let left = try FileManager.default.contentsOfDirectory(atPath: TranscriptExportFile.directory.path)
        XCTAssertEqual(left, ["Второй.md"])
    }
}

/// Расшифровка страницами A4. Главное здесь — русский текст, который читается
/// из готового файла: именно это и не работало у голой строки.
final class TranscriptPDFTests: XCTestCase {
    private func export(blocks: Int, warnings: [String] = []) -> TranscriptExport {
        let body = (0..<blocks).map { index in
            "**[\(index):00–\(index):40]** S1: Обсудили интеграцию с внешним сервисом и договорились о сроках."
        }.joined(separator: "\n\n")
        let tail = warnings.map { "> \($0)" }.joined(separator: "\n")
        return TranscriptExport.make(
            markdown: "# Файл\n\n_Расшифровано: GigaAM v3 CTC (int8), на этом iPhone_\n\n\(body)\n\n\(tail)",
            title: "Совещание по интеграции",
            recordedAt: Date(timeIntervalSince1970: 1_756_500_000),
            duration: 2472,
            detail: "Договорились о сроках.",
            topic: "Работа",
            names: ["S1": "Аня"]
        )
    }

    func testDataIsARealPDF() {
        let data = TranscriptPDF.data(for: export(blocks: 3))

        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(data.prefix(4), Data("%PDF".utf8))
    }

    /// Прямой тест на «кракозябры»: русский текст обязан читаться из готового
    /// файла, а не превращаться в мусор по дороге.
    func testRussianTextIsReadableBack() throws {
        let payload = export(blocks: 3)
        let document = try XCTUnwrap(PDFDocument(data: TranscriptPDF.data(for: payload)))
        let text = try XCTUnwrap(document.string)

        XCTAssertTrue(text.contains("Совещание по интеграции"), text)
        XCTAssertTrue(text.contains("Обсудили интеграцию с внешним сервисом"), text)
        XCTAssertTrue(text.contains("Аня"), "имя говорящего вместо метки: \(text)")
        XCTAssertTrue(text.contains("тема: Работа"), text)
        XCTAssertTrue(text.contains("Расшифровано: GigaAM v3 CTC (int8), на этом iPhone"), text)
    }

    func testWarningsReachThePage() throws {
        let payload = export(blocks: 2, warnings: ["Участок 5:00–6:00: слов сервис не дал."])
        let document = try XCTUnwrap(PDFDocument(data: TranscriptPDF.data(for: payload)))

        XCTAssertTrue(try XCTUnwrap(document.string).contains("слов сервис не дал"))
    }

    func testLongTranscriptGetsMorePagesAndKeepsEveryBlock() throws {
        let document = try XCTUnwrap(PDFDocument(data: TranscriptPDF.data(for: export(blocks: 120))))

        XCTAssertGreaterThan(document.pageCount, 1)
        let text = try XCTUnwrap(document.string)
        // Ни одна реплика не должна потеряться на стыке страниц.
        XCTAssertEqual(text.components(separatedBy: "Обсудили интеграцию").count - 1, 120)
        XCTAssertTrue(text.contains("стр. 1 из \(document.pageCount)"), "нумерация страниц")
    }

    /// Регрессия с живого экспорта владельца: 64 страницы, из которых первая
    /// верна, а все следующие — зеркальны по вертикали. Текст на них читается
    /// только в отражении.
    ///
    /// Проверяется геометрией, а не глазами: буквы отражены относительно своей
    /// базовой линии, поэтому краска съезжает вниз на высоту прописной. Замер:
    /// 62 точки от верха у правильной страницы против 67 у зеркальной, при
    /// верхнем поле 59,5. Запас небольшой, зато рендер детерминированный —
    /// кегли свои, системный размер текста на него не влияет.
    func testEveryPageStartsAtTheTopMargin() throws {
        let document = try XCTUnwrap(PDFDocument(data: TranscriptPDF.data(for: export(blocks: 200))))
        try XCTSkipUnless(document.pageCount >= 3, "нужны страницы после первой")

        for index in 1..<min(document.pageCount, 4) {
            let top = try inkTop(of: XCTUnwrap(document.page(at: index)))
            XCTAssertEqual(
                top,
                TranscriptPDF.verticalMargin,
                accuracy: 5,
                "страница \(index + 1): текст начинается в \(top) pt от верха вместо \(TranscriptPDF.verticalMargin)"
            )
        }
    }

    /// Сколько точек от верха страницы до первой краски.
    private func inkTop(of page: PDFPage) throws -> CGFloat {
        let scale = 2
        let size = TranscriptPDF.pageSize
        let width = Int(size.width) * scale
        let height = Int(size.height) * scale
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        defer { pixels.deallocate() }
        pixels.initialize(repeating: 255, count: width * height)

        let context = try XCTUnwrap(CGContext(
            data: pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        page.draw(with: .mediaBox, to: context)

        // Система координат у контекста своя (начало в левом нижнем углу), а
        // память лежит сверху вниз: строка 0 буфера — это **верх** страницы.
        // Спутать одно с другим значит мерить футер вместо первой строки.
        for row in 0..<height {
            for column in 0..<width where pixels[row * width + column] < 200 {
                return CGFloat(row) / CGFloat(scale)
            }
        }
        throw XCTSkip("на странице нет краски")
    }

    /// Пустая расшифровка кнопкой не отдаётся, но рендер на ней не должен
    /// падать: одна страница с шапкой честнее вылета.
    func testEmptyTranscriptStillRenders() throws {
        let payload = TranscriptExport.make(
            markdown: "# Запись",
            title: "Запись",
            recordedAt: .now
        )
        let document = try XCTUnwrap(PDFDocument(data: TranscriptPDF.data(for: payload)))

        XCTAssertEqual(document.pageCount, 1)
    }
}
