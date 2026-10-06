import Foundation

/// Проверочный движок для снимков экрана в симуляторе.
///
/// Симулятор не распознаёт речь вовсе, а облачный движок без ключа останавливается
/// ещё до очереди — поэтому блок очереди, полосы, «2 из 5» и строку ошибки на
/// карточке иначе не увидеть иначе как на телефоне владельца. Заглушка считает
/// секунд двадцать с честными долями и кладёт правдоподобную расшифровку с
/// таймкодами и говорящими. Файл с «fail» в имени она роняет — так видна строка
/// ошибки с «Повторить». Текст ошибки у каждого файла свой (имя в конце): одинаковый
/// текст у нескольких записей прятал бы ошибки экрана, которые смотрят, лежит ли
/// этот текст ещё в `TranscriptionService.failed`, — так было с устаревшим алертом
/// после «Повторить» (`testRetryFromRecordScreenShowsNoStaleAlert`).
///
/// Включается только тремя условиями сразу, и ни одно из них не бывает у личного
/// приложения:
/// - сборка `DEBUG` — в Release заглушки нет в коде вовсе (`#if DEBUG` ниже);
/// - bundle ID `ru.ilyaqa.lori.local.qa` — тот же шлагбаум, что у `RecoveryProbe`;
/// - аргумент запуска `--ui-stub-engine` — его передаёт только UI-тест или `simctl launch`.
enum QAStubEngine {
    nonisolated static let argument = "--ui-stub-engine"
    /// Сколько секунд длится одна «расшифровка»: `--ui-stub-seconds 8`.
    nonisolated static let secondsArgument = "--ui-stub-seconds"
    nonisolated static let defaultSeconds: TimeInterval = 24

    /// Шлагбаум без обращения к процессу — чтобы его можно было проверить тестом.
    nonisolated static func isAllowed(bundleID: String?, arguments: [String]) -> Bool {
        RecoveryProbe.allowsDiagnostics(in: bundleID) && arguments.contains(argument)
    }

    /// Включена ли заглушка в этом запуске. В Release — всегда нет, без чтения аргументов.
    nonisolated static var enabled: Bool {
        #if DEBUG
        isAllowed(bundleID: Bundle.main.bundleIdentifier, arguments: ProcessInfo.processInfo.arguments)
        #else
        false
        #endif
    }

    /// Длительность из аргументов: число после `--ui-stub-seconds`, иначе умолчание.
    nonisolated static func seconds(in arguments: [String]) -> TimeInterval {
        guard let index = arguments.firstIndex(of: secondsArgument),
              arguments.indices.contains(index + 1),
              let value = TimeInterval(arguments[index + 1]), value > 0 else { return defaultSeconds }
        return min(value, 600)
    }
}

#if DEBUG
extension QAStubEngine {
    /// Заглушка вместо **всех** движков: какой бы ни был выбран в панели, считает она.
    /// Иначе облачный движок без ключа остановил бы пачку проверкой готовности.
    static func engines(seconds: TimeInterval) -> [TranscriptionEngineKind: any Transcribing] {
        let stub = QAStubTranscriber(seconds: seconds)
        return Dictionary(uniqueKeysWithValues: TranscriptionEngineKind.allCases.map { ($0, stub as any Transcribing) })
    }
}

/// Сама заглушка. Только DEBUG: в Release этого типа нет, и подставить его нечем.
struct QAStubTranscriber: Transcribing {
    /// Подпись в файле расшифровки. «на этом iPhone» — потому что звук и правда
    /// никуда не уходит: экран записи рисует по этой строке иконку телефона.
    let name = "Проверочный движок QA, на этом iPhone"
    let seconds: TimeInterval
    /// Сколько шагов у полосы: у долей должно быть за что зацепиться, а остаток
    /// времени появляется только после первых пяти процентов.
    var steps = 12

    func isAvailable() async -> Bool { true }

    func transcribe(audioURL: URL, progress: @Sendable (Int, Int) -> Void) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, partial: { _ in }, note: { _ in })
    }

    func transcribe(
        audioURL: URL,
        progress: @Sendable (Int, Int) -> Void,
        partial: @Sendable (Transcript) -> Void,
        note: @Sendable (String) -> Void
    ) async throws -> Transcript {
        let base = audioURL.deletingPathExtension().lastPathComponent
        let failing = base.lowercased().contains("fail")
        let result = Self.transcript(for: base)
        let pause = max(0.02, seconds / Double(steps))
        note("готовлю аудио")
        for step in 0..<steps {
            progress(step, steps)
            // `Task.sleep` бросает отмену сам: «Остановить» снимает заглушку так же,
            // как настоящий движок, — между кусками.
            try await Task.sleep(for: .seconds(pause))
            if failing, step == steps / 3 {
                throw TranscriptionError.api(Self.failure(for: base))
            }
            let ready = result.segments.prefix(result.segments.count * (step + 1) / steps)
            if !ready.isEmpty {
                partial(Transcript(text: ready.map(\.text).joined(separator: " "), segments: Array(ready)))
            }
        }
        progress(steps, steps)
        return result
    }

    /// Ошибка файла с «fail» в имени. Первая фраза — та, что встаёт на карточку, —
    /// у всех одна; имя файла в конце делает текст своим у каждой записи.
    nonisolated static func failure(for base: String) -> String {
        "Нет связи с сервисом. Проверь интернет и нажми «Повторить». Файл: \(base)."
    }

    /// Правдоподобная расшифровка: реплики двух говорящих с диапазонами времени.
    /// Какой из разговоров — решает имя файла, чтобы у разных записей в списке и
    /// заголовки, и описания были разными.
    static func transcript(for name: String) -> Transcript {
        let script = scripts[scriptIndex(for: name)]
        var segments: [TranscriptSegment] = []
        var start: TimeInterval = 0
        for (index, line) in script.enumerated() {
            // Около четырнадцати знаков в секунду — обычный темп речи.
            let length = max(2, (Double(line.count) / 14).rounded())
            let speaker = index.isMultiple(of: 2) ? "S1" : "S2"
            segments.append(TranscriptSegment(start: start, end: start + length, text: "\(speaker): \(line)"))
            start += length + 1
        }
        return Transcript(text: script.joined(separator: " "), segments: segments)
    }

    /// Разговор под имя файла: «Интервью Маши» — интервью, «Звонок поставщику» —
    /// звонок. Иначе на снимке заголовок говорил бы одно, а описание другое.
    /// Незнакомое имя — по номеру из имени.
    static func scriptIndex(for name: String) -> Int {
        let lowered = name.lowercased()
        let keywords: [(String, Int)] = [
            ("бюджет", 0), ("интервью", 1), ("поставщик", 2), ("отзыв", 3), ("планёрк", 4), ("планерк", 4), ("релиз", 4),
        ]
        for (keyword, index) in keywords where lowered.contains(keyword) { return index }
        return stableIndex(of: name, count: scripts.count)
    }

    /// Номер по сумме кодов знаков, а не `hashValue`: тот меняется от запуска к запуску.
    static func stableIndex(of name: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(name.unicodeScalars.reduce(UInt64(0)) { ($0 &* 31 &+ UInt64($1.value)) % 1_000_003 } % UInt64(count))
    }

    private static let scripts: [[String]] = [
        [
            "Обсудили бюджет на четвёртый квартал: рекламу режем на треть, найм оставляем.",
            "Тогда маркетингу нужен новый план к понедельнику, без него согласовывать нечего.",
            "Я подготовлю черновик, но цифры по найму пусть пришлёт Лёша.",
            "Договорились. Финальное решение — на планёрке в среду.",
        ],
        [
            "Маша рассказала, как пришла в аналитику из журналистики и почему осталась.",
            "Самое сложное было научиться задавать вопросы данным, а не людям.",
            "А что помогло больше всего — курсы или живые задачи?",
            "Живые задачи. Первый дашборд я переделывала четыре раза, и это лучшая школа.",
        ],
        [
            "Поставщик подтвердил отгрузку на пятницу, но цену поднимают на семь процентов.",
            "Семь процентов без предупреждения — это много, попросим зафиксировать до конца года.",
            "Попробую. Если откажут, сравним с запасным поставщиком из Казани.",
            "Хорошо, жду ответ до среды, потом решаем.",
        ],
        [
            "Разобрали отзывы за сентябрь: чаще всего просят тёмную тему и экспорт в PDF.",
            "Экспорт уже в работе, тёмную тему ставим следующим спринтом.",
            "Жалоб на скорость стало вдвое меньше после обновления.",
            "Значит, кэш сработал. Напишем об этом в заметке к релизу.",
        ],
        [
            "Планёрка по релизу: сборка готова, осталось пройти проверку на трёх телефонах.",
            "На старом айфоне падает импорт длинных файлов, это надо чинить до выпуска.",
            "Беру на себя, к вечеру будет исправление.",
            "Тогда выпускаем в четверг утром.",
        ],
    ]
}
#endif
