import SwiftUI
import UIKit

/// Системный лист «Поделиться».
///
/// `ShareLink` внутри свайпа по строке списка ведёт себя непредсказуемо, а файл
/// экспорта готовится только в момент нажатия — поэтому обычный лист с обёрткой.
///
/// Наружу уходит **файл**, а не строка. Голая строка вставлялась получателю
/// текстом в тело сообщения вместе со всей разметкой, и «Поделиться» не давало
/// того, за чем к нему идут: документа, который можно переслать и открыть.
struct ShareSheet: UIViewControllerRepresentable {
    let payload: SharePayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [ExportActivityItem(url: payload.url, subject: payload.subject)],
            applicationActivities: nil
        )
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Обёртка, чтобы файл можно было передать через `.sheet(item:)`.
struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
    /// Заголовок записи: он же тема письма, если делятся через Почту.
    let subject: String
}

/// Файл и тема письма.
///
/// Без `UIActivityItemSource` лист не может подсказать тему, и письмо с
/// расшифровкой уходило бы без темы вовсе — приложение знает заголовок записи,
/// а человек его повторял руками.
/// Класс нарочно без `@MainActor`: `UIActivityItemSource` изоляции не объявляет,
/// и главный актор здесь дал бы ошибку о пересечении границы. Внутри только
/// неизменяемые значения, гонке нечего портить.
private final class ExportActivityItem: NSObject, UIActivityItemSource {
    private let url: URL
    private let subject: String

    init(url: URL, subject: String) {
        self.url = url
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

    func activityViewController(
        _ controller: UIActivityViewController,
        itemForActivityType type: UIActivity.ActivityType?
    ) -> Any? { url }

    func activityViewController(
        _ controller: UIActivityViewController,
        subjectForActivityType type: UIActivity.ActivityType?
    ) -> String { subject }
}
