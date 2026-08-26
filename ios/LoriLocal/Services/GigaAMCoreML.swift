import CoreML
import Foundation

/// Три модели Core ML, экспортированные `design/gigaam/export_coreml.py`.
struct GigaAMModelSet {
    let encoder: URL
    let prediction: URL
    let joint: URL
    let vocabulary: URL

    /// Модели ищутся сначала в бандле приложения, потом в Application Support:
    /// 240 МБ энкодера разумнее докачивать, а не зашивать в сборку.
    static func locate(bundle: Bundle = .main, fileManager: FileManager = .default) -> GigaAMModelSet? {
        // Documents/Lori/Models видна через «Файлы», так что модель можно положить
        // и удалить руками. Список заметок её не показывает: он читает только Workspace.
        let locations = [
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appending(path: "Lori/Models", directoryHint: .isDirectory),
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appending(path: "Lori/Models", directoryHint: .isDirectory),
        ].compactMap { $0 }

        func find(_ name: String, extensions: [String]) -> URL? {
            for ext in extensions {
                if let url = bundle.url(forResource: name, withExtension: ext) { return url }
                for location in locations {
                    let candidate = location.appending(path: "\(name).\(ext)")
                    if fileManager.fileExists(atPath: candidate.path) { return candidate }
                }
            }
            return nil
        }

        guard let encoder = find("GigaAM-encoder", extensions: ["mlmodelc", "mlpackage"]),
              let prediction = find("GigaAM-prediction", extensions: ["mlmodelc", "mlpackage"]),
              let joint = find("GigaAM-joint", extensions: ["mlmodelc", "mlpackage"]),
              let vocabulary = find("vocab", extensions: ["txt"]) else {
            return nil
        }
        return GigaAMModelSet(encoder: encoder, prediction: prediction, joint: joint, vocabulary: vocabulary)
    }
}

/// Предиктор и joint RNN-T поверх Core ML.
///
/// «Нет предыдущего токена» кодируется индексом blank: в модели
/// `nn.Embedding(..., padding_idx=blank)`, и эта строка эмбеддинга всегда нулевая —
/// ровно то, что библиотека подставляет на старте.
final class GigaAMCoreMLNetwork: RNNTNetwork {
    /// Состояние хранится своими копиями, а не объектами, которые вернул Core ML:
    /// он переиспользует буферы выходов под следующий вызов, и состояние LSTM
    /// затиралось на ходу — декодер надолго уходил в blank и терял начало записи.
    struct State {
        let h: [Float]
        let c: [Float]
    }

    enum Failure: LocalizedError {
        case missingOutput(String)

        var errorDescription: String? {
            switch self {
            case let .missingOutput(name): "Модель не вернула выход «\(name)»."
            }
        }
    }

    private let prediction: MLModel
    private let joint: MLModel
    private let blankIndex: Int
    private let layers: Int
    private let hidden: Int

    init(
        prediction: MLModel,
        joint: MLModel,
        blankIndex: Int,
        layers: Int = 1,
        hidden: Int = 320
    ) {
        self.prediction = prediction
        self.joint = joint
        self.blankIndex = blankIndex
        self.layers = layers
        self.hidden = hidden
    }

    func predict(previousToken: Int?, state: State?) throws -> (embedding: [Float], state: State) {
        let token = previousToken ?? blankIndex
        let label = try MLMultiArray(shape: [1, 1], dataType: .int32)
        label[0] = NSNumber(value: token)

        let stateSize = layers * hidden
        let incoming = state ?? State(
            h: [Float](repeating: 0, count: stateSize),
            c: [Float](repeating: 0, count: stateSize)
        )
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "x": MLFeatureValue(multiArray: label),
            "hi": MLFeatureValue(multiArray: try stateArray(incoming.h)),
            "ci": MLFeatureValue(multiArray: try stateArray(incoming.c)),
        ])
        let output = try prediction.prediction(from: features)

        guard let dec = output.featureValue(for: "dec")?.multiArrayValue else {
            throw Failure.missingOutput("dec")
        }
        guard let h = output.featureValue(for: "ho")?.multiArrayValue,
              let c = output.featureValue(for: "co")?.multiArrayValue else {
            throw Failure.missingOutput("ho/co")
        }
        return (floats(from: dec), State(h: floats(from: h), c: floats(from: c)))
    }

    func joint(encoderFrame: [Float], embedding: [Float]) throws -> [Float] {
        let enc = try MLMultiArray(
            shape: [1, NSNumber(value: encoderFrame.count), 1], dataType: .float32
        )
        fill(enc, with: encoderFrame)
        let dec = try MLMultiArray(
            shape: [1, NSNumber(value: embedding.count), 1], dataType: .float32
        )
        fill(dec, with: embedding)

        let features = try MLDictionaryFeatureProvider(dictionary: [
            "enc": MLFeatureValue(multiArray: enc),
            "dec": MLFeatureValue(multiArray: dec),
        ])
        let output = try joint.prediction(from: features)
        guard let logits = output.featureValue(for: "joint")?.multiArrayValue else {
            throw Failure.missingOutput("joint")
        }
        return floats(from: logits)
    }

    private func stateArray(_ values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [NSNumber(value: layers), 1, NSNumber(value: hidden)],
            dataType: .float32
        )
        MLArrayIO.write(values, to: array)
        return array
    }

    private func fill(_ array: MLMultiArray, with values: [Float]) {
        MLArrayIO.write(values, to: array)
    }

    private func floats(from array: MLMultiArray) -> [Float] {
        MLArrayIO.read(array)
    }
}

/// Чтение и запись `MLMultiArray` по strides.
///
/// Core ML выравнивает внутреннюю размерность: у выхода на 1025 классов буфер
/// содержит 1040 значений. Читать подряд нельзя — последние 15 чисел мусорные,
/// а у многомерных выходов мусор оказывается между строками.
enum MLArrayIO {
    static func read(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let total = shape.reduce(1, *)
        guard total > 0 else { return [] }

        var result = [Float](repeating: 0, count: total)
        array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            var indices = [Int](repeating: 0, count: shape.count)
            for position in 0..<total {
                var offset = 0
                for axis in 0..<shape.count { offset += indices[axis] * strides[axis] }
                result[position] = buffer[offset]
                var axis = shape.count - 1
                while axis >= 0 {
                    indices[axis] += 1
                    if indices[axis] < shape[axis] { break }
                    indices[axis] = 0
                    axis -= 1
                }
            }
        }
        return result
    }

    static func write(_ values: [Float], to array: MLMultiArray) {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let total = min(values.count, shape.reduce(1, *))
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            var indices = [Int](repeating: 0, count: shape.count)
            for position in 0..<total {
                var offset = 0
                for axis in 0..<shape.count { offset += indices[axis] * strides[axis] }
                buffer[offset] = values[position]
                var axis = shape.count - 1
                while axis >= 0 {
                    indices[axis] += 1
                    if indices[axis] < shape[axis] { break }
                    indices[axis] = 0
                    axis -= 1
                }
            }
        }
    }
}

/// Энкодер: лог-мел признаки на входе, скрытые состояния на выходе.
///
/// Окно у модели фиксированное — в графе запечена длина последовательности, поэтому
/// признаки дополняются до окна значением тишины `log(1e-9)`, а не нулями: нуль в
/// логарифмической шкале означает мощность 1, то есть громкий шум.
struct GigaAMEncoder {
    enum Failure: LocalizedError {
        case missingOutput
        case unknownWindow
        case tooLong(frames: Int, window: Int)

        var errorDescription: String? {
            switch self {
            case .missingOutput: "Энкодер не вернул ожидаемый выход."
            case .unknownWindow: "Не удалось прочитать размер входа энкодера."
            case let .tooLong(frames, window):
                "Кусок в \(frames) кадров не влезает в окно энкодера (\(window))."
            }
        }
    }

    static let silence = logf(1e-9)

    let model: MLModel

    /// Сколько кадров признаков ждёт модель. Читается из её описания, не захардкожено.
    var window: Int? {
        model.modelDescription
            .inputDescriptionsByName["features"]?
            .multiArrayConstraint
            .map { $0.shape.count >= 3 ? $0.shape[2].intValue : 0 }
    }

    /// `features` — раскладка `[mel][frame]`, как её отдаёт `LogMelSpectrogram`.
    /// Результат приводится к `[frame][dimension]`, как его ждёт `RNNTGreedyDecoder`.
    func encode(features: [Float], melCount: Int, frames: Int) throws
        -> (encoded: [Float], frames: Int, dimension: Int, length: Int) {
        guard let window, window > 0 else { throw Failure.unknownWindow }
        guard frames <= window else { throw Failure.tooLong(frames: frames, window: window) }

        let input = try MLMultiArray(
            shape: [1, NSNumber(value: melCount), NSNumber(value: window)], dataType: .float32
        )
        var padded = [Float](repeating: Self.silence, count: melCount * window)
        for mel in 0..<melCount {
            let source = mel * frames
            let destination = mel * window
            for frame in 0..<min(frames, window) {
                padded[destination + frame] = features[source + frame]
            }
        }
        MLArrayIO.write(padded, to: input)

        // Настоящая длина обязательна: из неё строится маска паддинга. Без неё
        // Conformer считает валидной и тишину в хвосте, а внимание у него глобальное —
        // проверено, терялось первое слово записи.
        let lengths = try MLMultiArray(shape: [1], dataType: .int32)
        lengths[0] = NSNumber(value: frames)

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "features": MLFeatureValue(multiArray: input),
            "feature_lengths": MLFeatureValue(multiArray: lengths),
        ])
        let output = try model.prediction(from: provider)
        guard let encoded = output.featureValue(for: "encoded")?.multiArrayValue,
              encoded.shape.count >= 3 else {
            throw Failure.missingOutput
        }

        // Выход энкодера приходит как [1, D, T]; декодеру нужен порядок [T][D].
        let dimension = encoded.shape[1].intValue
        let encodedFrames = encoded.shape[2].intValue
        let strides = encoded.strides.map(\.intValue)
        var transposed = [Float](repeating: 0, count: dimension * encodedFrames)
        encoded.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            for channel in 0..<dimension {
                let channelOffset = channel * strides[1]
                for frame in 0..<encodedFrames {
                    transposed[frame * dimension + channel] = buffer[channelOffset + frame * strides[2]]
                }
            }
        }
        // Длина после сабсэмплинга: за ней декодер не читает.
        let encodedLength = output.featureValue(for: "encoded_lengths")?.multiArrayValue
            .map { Int(truncating: $0[0]) } ?? encodedFrames
        return (transposed, encodedFrames, dimension, min(encodedLength, encodedFrames))
    }
}
