import Foundation

/// Готовые ONNX-модели GigaAM v3, которые приложение качает само.
///
/// Адрес зашит в код намеренно: вписывать его руками — не дело человека, а Core ML-экспорта
/// GigaAM никто не публикует (на HuggingFace лежат ONNX, MLX и GGUF). Взят открытый
/// репозиторий `istupakov/gigaam-v3-onnx` — без ключей и регистрации. Файлы качаются по
/// одному: это обычные файлы, а не архив, и распаковывать на телефоне нечего.
enum GigaAMVariant: String, CaseIterable, Identifiable, Sendable {
    /// e2e RNN-T: рабочая модель GigaAM, с пунктуацией и таймингами слов.
    case rnnt
    /// e2e CTC: одна модель вместо трёх, считает заметно быстрее.
    case ctc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rnnt: "GigaAM v3 RNN-T (int8)"
        case .ctc: "GigaAM v3 CTC (int8)"
        }
    }

    /// Название для чипа режима: техническое имя модели живёт в настройках.
    var modeTitle: String {
        switch self {
        case .rnnt: "Точный"
        case .ctc: "Быстрый"
        }
    }

    var detail: String {
        switch self {
        case .rnnt: "Основная модель: пунктуация и тайминги слов. Считает медленнее CTC."
        case .ctc: "Быстрее и проще: одна модель вместо трёх, пунктуация тоже есть."
        }
    }

    /// Папка внутри `Lori/Models`: у вариантов свои файлы, и рядом они не мешают друг другу.
    var directory: String {
        switch self {
        case .rnnt: "GigaAM-v3-rnnt"
        case .ctc: "GigaAM-v3-ctc"
        }
    }

    /// Размеры и контрольные суммы взяты из HuggingFace (у LFS-файла oid — это sha256).
    /// У маленьких текстовых файлов LFS-хеша нет, для них сверяется только размер.
    var files: [GigaAMFile] {
        switch self {
        case .rnnt:
            [
                GigaAMFile(
                    name: "v3_e2e_rnnt_encoder.int8.onnx",
                    bytes: 224_570_477,
                    sha256: "4e0e076a6076cd110277e529b8ac8f32cd5297f7fbebad5341ae8ddb7d00817b"
                ),
                GigaAMFile(
                    name: "v3_e2e_rnnt_decoder.int8.onnx",
                    bytes: 1_159_170,
                    sha256: "89014e134865615b91e037157e46e389b1271e6072460efc010ea08e61e23146"
                ),
                GigaAMFile(
                    name: "v3_e2e_rnnt_joint.int8.onnx",
                    bytes: 687_791,
                    sha256: "ade116563dbf66e503b0994efab6b5861412743e52bf31c39fc3fffa3783d5d1"
                ),
                GigaAMFile(name: "v3_e2e_rnnt_vocab.txt", bytes: 13_354, sha256: nil),
            ]
        case .ctc:
            [
                GigaAMFile(
                    name: "v3_e2e_ctc.int8.onnx",
                    bytes: 224_893_347,
                    sha256: "2e3fcb7a7b66030336fd10c2fcfb033bd1dc7e1bf238fe5cfd83b1d0cfc9d28e"
                ),
                GigaAMFile(name: "v3_e2e_ctc_vocab.txt", bytes: 2_007, sha256: nil),
            ]
        }
    }

    var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }

    /// «226 МБ» для кнопки скачивания: человек должен видеть цену нажатия заранее.
    var sizeText: String {
        String(format: "%.0f МБ", Double(totalBytes) / 1024 / 1024)
    }

    static let source = URL(string: "https://huggingface.co/istupakov/gigaam-v3-onnx/resolve/main")!

    func url(for file: GigaAMFile) -> URL {
        Self.source.appending(path: file.name)
    }
}

struct GigaAMFile: Sendable, Equatable {
    let name: String
    let bytes: Int
    let sha256: String?
}

/// Где лежат скачанные файлы варианта и все ли они на месте.
struct GigaAMModelSet: Sendable {
    let variant: GigaAMVariant
    let directory: URL

    /// Порядок файлов тот же, что в каталоге: энкодер, декодер, joint, словарь.
    func url(_ name: String) -> URL { directory.appending(path: name) }

    var vocabulary: URL {
        url(variant == .rnnt ? "v3_e2e_rnnt_vocab.txt" : "v3_e2e_ctc_vocab.txt")
    }

    /// Модели ищутся в Application Support (туда качает приложение) и в Documents —
    /// второе на случай, когда файлы положили руками через «Файлы».
    static func locate(
        _ variant: GigaAMVariant,
        fileManager: FileManager = .default,
        roots: [URL]? = nil
    ) -> GigaAMModelSet? {
        for root in roots ?? defaultRoots(fileManager: fileManager) {
            let directory = root.appending(path: variant.directory, directoryHint: .isDirectory)
            let complete = variant.files.allSatisfy {
                fileManager.fileExists(atPath: directory.appending(path: $0.name).path)
            }
            if complete { return GigaAMModelSet(variant: variant, directory: directory) }
        }
        return nil
    }

    static func defaultRoots(fileManager: FileManager = .default) -> [URL] {
        [
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
        ]
        .compactMap { $0?.appending(path: "Lori/Models", directoryHint: .isDirectory) }
    }
}
