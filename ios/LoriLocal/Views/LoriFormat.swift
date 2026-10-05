import Foundation

/// Форматирование для интерфейса. Локаль зафиксирована: приложение целиком
/// русскоязычное, и системная локаль телефона не должна давать «56 bytes» или «Aug 24».
enum LoriFormat {
    static let locale = Locale(identifier: "ru_RU")

    /// Подпись под заметкой: «17:42», «вчера, 09:10», «12 августа», «12 августа 2024».
    static func stamp(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "вчера, \(time.string(from: date))"
        }
        return dateFormatter(sameYearAs: now, as: date, calendar: calendar).string(from: date)
    }

    /// Заголовок группы в списке: «Сегодня», «Вчера», «12 августа».
    static func groupTitle(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Сегодня" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Вчера"
        }
        return dateFormatter(sameYearAs: now, as: date, calendar: calendar).string(from: date)
    }

    /// «3 заметки» — русские формы числительных, без сторонних библиотек.
    static func noteCount(_ count: Int) -> String {
        plural(count, one: "заметка", few: "заметки", many: "заметок")
    }

    /// Те же формы для произвольного слова: «1 файл», «2 файла», «5 файлов».
    static func plural(_ count: Int, one: String, few: String, many: String) -> String {
        let tail = count % 100
        let last = count % 10
        let word: String
        if (11...14).contains(tail) || last == 0 || (5...9).contains(last) {
            word = many
        } else if last == 1 {
            word = one
        } else {
            word = few
        }
        return "\(count) \(word)"
    }

    /// Короткая метка справа в строке истории: «сейчас», «5 мин», «2 ч», «вчера», «14 июля».
    static func relative(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "сейчас" }
        if calendar.isDate(date, inSameDayAs: now) {
            return seconds < 3_600 ? "\(Int(seconds / 60)) мин" : "\(Int(seconds / 3_600)) ч"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "вчера"
        }
        return dateFormatter(sameYearAs: now, as: date, calendar: calendar).string(from: date)
    }

    /// Длительность записи: «0:07», «12:03».
    /// Грубая оценка времени: «40 сек», «2 мин». Секундная точность в ожидании
    /// только раздражает — числа всё равно скачут.
    static func approximate(_ seconds: TimeInterval) -> String {
        let value = max(1, seconds.rounded())
        if value < 60 {
            // Ниже пяти секунд округление давало «0 сек» — оценка, которая
            // выглядит как ошибка. Пять секунд — честная нижняя граница.
            return "\(max(5, Int((value / 5).rounded() * 5))) сек"
        }
        let minutes = Int((value / 60).rounded())
        switch minutes % 10 {
        case 1 where minutes != 11: return "\(minutes) минута"
        case 2...4 where !(12...14).contains(minutes): return "\(minutes) минуты"
        default: return "\(minutes) минут"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func dateFormatter(sameYearAs now: Date, as date: Date, calendar: Calendar) -> DateFormatter {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear ? dayMonth : dayMonthYear
    }

    private static let time = formatter("HH:mm")
    private static let dayMonth = formatter("d MMMM")
    private static let dayMonthYear = formatter("d MMMM yyyy")

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = template
        return formatter
    }
}
