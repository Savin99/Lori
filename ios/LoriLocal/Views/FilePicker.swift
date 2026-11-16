import UIKit
import UniformTypeIdentifiers

/// Выбор аудио в «Файлах» — копией, а не «на месте».
///
/// `.fileImporter` открывает файл на месте: Lori получает закладку на чужой файл и должна
/// разрешить её сама. На телефоне владельца (iOS 27.2.1, файл из iCloud Drive → «Загрузки»)
/// разрешение не проходило — `Could not resolve bookmark`, NSCocoaError 257, — система
/// отдавала пустой список, и окно выбора просто оставалось открытым после «Открыть», без
/// ошибки и без вызова обработчика. В режиме копии файл копирует само окно выбора, у
/// которого доступ есть, и права на чужую папку Lori больше не нужны. Копию Lori сделала бы
/// и так: `ImportInbox.stage` снимает её сразу, до нажатия «Расшифровать».
///
/// UIKit, а не `.sheet` с обёрткой: окно выбора закрывается само после выбора, и лист
/// SwiftUI вокруг него остался бы висеть пустым.
@MainActor
enum FilePicker {
    /// Живёт, пока окно открыто: `delegate` у окна выбора слабый.
    private static var current: Delegate?

    static func present(types: [UTType], onPick: @escaping ([URL]) -> Void) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else {
            Diagnostics.note("импорт: окно выбора не открыто — нет активного окна приложения")
            return
        }
        while let next = top.presentedViewController { top = next }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        let delegate = Delegate(onPick: onPick)
        picker.delegate = delegate
        current = delegate
        top.present(picker, animated: true)
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            FilePicker.current = nil
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            FilePicker.current = nil
        }
    }
}
