import AVFoundation
import Foundation

/// Длительности записей для списка.
///
/// Читать их при каждом обновлении списка нельзя — это обращение к файлу на каждую
/// строку. Поэтому значение считается один раз и запоминается, а строка до этого
/// показывает время без длительности.
@MainActor
final class RecordingDurations: ObservableObject {
    @Published private(set) var seconds: [String: TimeInterval] = [:]
    private var loading = Set<String>()

    func duration(for relativePath: String) -> TimeInterval? {
        seconds[relativePath]
    }

    func load(_ relativePath: String, url: URL) {
        guard seconds[relativePath] == nil, !loading.contains(relativePath) else { return }
        loading.insert(relativePath)
        Task { [weak self] in
            let value = try? await AVURLAsset(url: url).load(.duration).seconds
            guard let self else { return }
            loading.remove(relativePath)
            guard let value, value.isFinite, value > 0 else { return }
            seconds[relativePath] = value
        }
    }
}
