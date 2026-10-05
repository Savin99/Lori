import XCTest
@testable import LoriLocal

/// Какое имя файла говорит о записи, а какое поставила программа.
final class RecordGenericNameTests: XCTestCase {
    /// Имена, которые дают диктофоны, мессенджеры, камера и сама Lori. Ни одно
    /// не должно побеждать первую фразу расшифровки.
    func testServiceNamesAreGeneric() {
        let names = [
            "Новая запись", "Новая запись 12", "Новая запись 48.m4a", "New Recording 5",
            "audio 5 2", "audio_5_2", "Вставленное 1788520000",
            "Recording-2026-09-04T22-22-10Z", "IMG_1234", "IMG_1234 2", "rec_001",
            "audio_2026-09-01_12-00-00", "audio_1@31-07-2023_21-36-43",
            "PTT-20260901-WA0001", "AUD-20260901-WA0003", "WhatsApp Audio 2026-09-01 at 12.00.00",
            "voice_message_2026-09-01", "Voice Message", "Голосовое сообщение", "Голосовое сообщение (3)",
            "20260901", "2026-09-01", "01.09.2026", "12:00", "12-00-00", "1788520000",
            "Untitled", "Untitled 2", "Без названия", "Без названия 3", "Запись 21:46",
            "Screen Recording 2026-09-01 at 12.00.00", "RPReplay_Final1693574400",
            "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "", "   ", "—",
        ]
        for name in names {
            XCTAssertTrue(RecordTitle.isGenericName(name), "«\(name)» — служебное имя")
        }
    }

    /// Имя, которое дал человек, остаётся главной приметой записи.
    func testHumanNamesAreMeaningful() {
        let names = [
            "Совещание 27.08", "Совещание 27.08.m4a", "Интервью Маши", "Планёрка", "Встреча с Анной",
            "Meeting notes", "MVP", "Звонок Маше", "Q3 итоги", "2025 Итоги года", "Лекция 5",
        ]
        for name in names {
            XCTAssertFalse(RecordTitle.isGenericName(name), "«\(name)» — имя от человека")
        }
    }

    func testGenericNameIsShownReadable() {
        XCTAssertEqual(RecordTitle.cleanedName("audio_5_2"), "audio 5 2")
        XCTAssertEqual(RecordTitle.cleanedName("Новая  запись_12 "), "Новая запись 12")
        XCTAssertEqual(RecordTitle.cleanedName("PTT-20260901-WA0001"), "PTT-20260901-WA0001", "дефисы в датах к месту")
    }
}
