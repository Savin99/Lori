import Foundation
import OnnxRuntimeBindings

/// Среда ORT одна на приложение: она держит логгер и пул потоков,
/// создавать её на каждую расшифровку — платить за это каждый раз.
enum OnnxRuntime {
    /// `ORTEnv` по документации ORT потокобезопасен, но `Sendable` у него нет:
    /// отсюда явное «unsafe» вместо обёртки, которая ничего бы не добавила.
    nonisolated(unsafe) static let shared: ORTEnv? = try? ORTEnv(loggingLevel: ORTLoggingLevel.warning)
}

enum OnnxFailure: LocalizedError, Equatable {
    case unavailable
    case missingOutput(String)
    case badShape(String, [Int])

    var errorDescription: String? {
        switch self {
        case .unavailable: "Не удалось запустить ONNX Runtime на этом устройстве."
        case let .missingOutput(name): "Модель не вернула выход «\(name)»."
        case let .badShape(name, shape): "Неожиданная форма выхода «\(name)»: \(shape)."
        }
    }
}

/// Одна модель ONNX и всё, что нужно, чтобы её позвать.
final class OnnxSession {
    struct Tensor {
        let shape: [Int]
        let elementType: ORTTensorElementDataType
        let data: Data

        var count: Int { shape.reduce(1, *) }

        var floats: [Float] {
            data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }

        /// Длины энкодер отдаёт целыми, и тип у разных сборок графа разный.
        var integers: [Int] {
            switch elementType {
            case .int32: data.withUnsafeBytes { $0.bindMemory(to: Int32.self).map(Int.init) }
            case .int64: data.withUnsafeBytes { $0.bindMemory(to: Int64.self).map(Int.init) }
            default: []
            }
        }
    }

    private let session: ORTSession
    /// У экспортов GigaAM длины и метки объявлены как int64, но встречаются сборки с int32.
    /// Тип запоминается после первой удачной попытки, чтобы не гадать на каждом кадре.
    private var integerType: ORTTensorElementDataType = .int64

    init(url: URL) throws {
        guard let env = OnnxRuntime.shared else { throw OnnxFailure.unavailable }
        let options = try ORTSessionOptions()

        // Память — главное ограничение на телефоне: у энкодера 225 МБ веса, и любая
        // лишняя их копия стоит столько же. Поэтому:
        //  * оптимизации только базовые — расширенные переставляют слои и на время
        //    держат в памяти обе раскладки весов;
        //  * prepacking отключён — он дублирует веса матричных умножений;
        //  * инициализаторы читаются аллокатором устройства, без промежуточной копии;
        //  * потоков два, а не по числу ядер: каждый несёт свои буферы активаций.
        try options.setGraphOptimizationLevel(ORTGraphOptimizationLevel.basic)
        try? options.addConfigEntry(withKey: "session.disable_prepacking", value: "1")
        try? options.addConfigEntry(withKey: "session.use_device_allocator_for_initializers", value: "1")
        try? options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
        try? options.setIntraOpNumThreads(2)

        // Core ML EP не подключается сознательно: на квантованном графе он всё равно
        // почти всё отдаёт обратно на CPU, зато на этапе компиляции модели удваивает
        // расход памяти. В симуляторе этого не видно — провайдера там просто нет,
        // и приложение падало только на телефоне.
        Diagnostics.log.notice("ONNX: загружаю \(url.lastPathComponent, privacy: .public)")
        session = try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
        Diagnostics.log.notice("ONNX: загрузил \(url.lastPathComponent, privacy: .public)")
    }

    func run(
        floats: [String: (values: [Float], shape: [Int])],
        integers: [String: (values: [Int], shape: [Int])] = [:],
        outputs: [String]
    ) throws -> [String: Tensor] {
        do {
            return try execute(floats: floats, integers: integers, outputs: outputs, integerType: integerType)
        } catch {
            guard !integers.isEmpty else { throw error }
            let other: ORTTensorElementDataType = integerType == .int64 ? .int32 : .int64
            let result = try execute(floats: floats, integers: integers, outputs: outputs, integerType: other)
            integerType = other
            return result
        }
    }

    private func execute(
        floats: [String: (values: [Float], shape: [Int])],
        integers: [String: (values: [Int], shape: [Int])],
        outputs: [String],
        integerType: ORTTensorElementDataType
    ) throws -> [String: Tensor] {
        var inputs: [String: ORTValue] = [:]
        for (name, input) in floats {
            inputs[name] = try value(input.values, shape: input.shape)
        }
        for (name, input) in integers {
            inputs[name] = try value(input.values, shape: input.shape, type: integerType)
        }

        let raw = try session.run(withInputs: inputs, outputNames: Set(outputs), runOptions: nil)
        var result: [String: Tensor] = [:]
        for name in outputs {
            guard let output = raw[name] else { throw OnnxFailure.missingOutput(name) }
            let info = try output.tensorTypeAndShapeInfo()
            // Копия снимается сразу: буфер выхода принадлежит ORT и переиспользуется
            // следующим вызовом — на Core ML на этом уже наступали.
            result[name] = Tensor(
                shape: info.shape.map(\.intValue),
                elementType: info.elementType,
                data: Data(try output.tensorData() as Data)
            )
        }
        return result
    }

    private func value(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer {
            NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.size)
        }
        return try ORTValue(
            tensorData: data,
            elementType: ORTTensorElementDataType.float,
            shape: shape.map { NSNumber(value: $0) }
        )
    }

    private func value(_ values: [Int], shape: [Int], type: ORTTensorElementDataType) throws -> ORTValue {
        let data: NSMutableData
        if type == .int32 {
            let narrow = values.map(Int32.init)
            data = narrow.withUnsafeBufferPointer {
                NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Int32>.size)
            }
        } else {
            let wide = values.map(Int64.init)
            data = wide.withUnsafeBufferPointer {
                NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Int64>.size)
            }
        }
        return try ORTValue(tensorData: data, elementType: type, shape: shape.map { NSNumber(value: $0) })
    }
}

/// Энкодер: лог-мел признаки на входе, скрытые состояния на выходе.
///
/// В отличие от Core ML-экспорта окно здесь не запечено в граф — длина входа
/// динамическая, поэтому дополнять признаки тишиной не нужно. Куски всё равно
/// режутся по 20 секунд: внимание в Conformer глобальное, и память растёт квадратично.
struct GigaAMOnnxEncoder {
    let session: OnnxSession
    let featuresName: String
    let lengthName: String

    /// `features` — раскладка `[mel][frame]`, как её отдаёт `LogMelSpectrogram`.
    /// Результат приводится к `[frame][dimension]`, как его ждёт `RNNTGreedyDecoder`.
    func encode(features: [Float], melCount: Int, frames: Int) throws
        -> (encoded: [Float], frames: Int, dimension: Int, length: Int) {
        let output = try session.run(
            floats: [featuresName: (features, [1, melCount, frames])],
            // Настоящая длина обязательна: из неё строится маска паддинга.
            integers: [lengthName: ([frames], [1])],
            outputs: ["encoded", "encoded_len"]
        )
        guard let encoded = output["encoded"], encoded.shape.count == 3 else {
            throw OnnxFailure.badShape("encoded", output["encoded"]?.shape ?? [])
        }

        // Выход энкодера приходит как [1, D, T]; декодеру нужен порядок [T][D].
        let dimension = encoded.shape[1]
        let encodedFrames = encoded.shape[2]
        let values = encoded.floats
        var transposed = [Float](repeating: 0, count: dimension * encodedFrames)
        for channel in 0..<dimension {
            let offset = channel * encodedFrames
            for frame in 0..<encodedFrames {
                transposed[frame * dimension + channel] = values[offset + frame]
            }
        }
        let length = output["encoded_len"]?.integers.first ?? encodedFrames
        return (transposed, encodedFrames, dimension, min(max(length, 0), encodedFrames))
    }
}

/// Предиктор и joint RNN-T поверх ONNX Runtime.
///
/// «Нет предыдущего токена» кодируется индексом blank: в модели
/// `nn.Embedding(..., padding_idx=blank)`, и эта строка эмбеддинга всегда нулевая —
/// ровно то, что подставляет библиотека на старте.
final class GigaAMOnnxNetwork: RNNTNetwork {
    struct State {
        let h: [Float]
        let c: [Float]
    }

    private let decoder: OnnxSession
    private let joint: OnnxSession
    private let blankIndex: Int
    private let layers: Int
    private let hidden: Int

    init(decoder: OnnxSession, joint: OnnxSession, blankIndex: Int, layers: Int = 1, hidden: Int = 320) {
        self.decoder = decoder
        self.joint = joint
        self.blankIndex = blankIndex
        self.layers = layers
        self.hidden = hidden
    }

    func predict(previousToken: Int?, state: State?) throws -> (embedding: [Float], state: State) {
        let zeros = [Float](repeating: 0, count: layers * hidden)
        let incoming = state ?? State(h: zeros, c: zeros)
        let output = try decoder.run(
            floats: [
                "h.1": (incoming.h, [layers, 1, hidden]),
                "c.1": (incoming.c, [layers, 1, hidden]),
            ],
            integers: ["x": ([previousToken ?? blankIndex], [1, 1])],
            outputs: ["dec", "h", "c"]
        )
        guard let dec = output["dec"], let h = output["h"], let c = output["c"] else {
            throw OnnxFailure.missingOutput("dec/h/c")
        }
        return (dec.floats, State(h: h.floats, c: c.floats))
    }

    func joint(encoderFrame: [Float], embedding: [Float]) throws -> [Float] {
        let output = try joint.run(
            floats: [
                "enc": (encoderFrame, [1, encoderFrame.count, 1]),
                "dec": (embedding, [1, embedding.count, 1]),
            ],
            outputs: ["joint"]
        )
        guard let logits = output["joint"] else { throw OnnxFailure.missingOutput("joint") }
        return logits.floats
    }
}

/// Модель CTC: одна сессия, на выходе логиты по классам для каждого кадра.
struct GigaAMOnnxCTC {
    let session: OnnxSession

    /// Возвращает логиты в раскладке `[frame][class]` — именно её ждёт `CTCGreedyDecoder`.
    func logProbabilities(features: [Float], melCount: Int, frames: Int, classes: Int) throws
        -> (logits: [Float], frames: Int) {
        let output = try session.run(
            floats: ["features": (features, [1, melCount, frames])],
            integers: ["feature_lengths": ([frames], [1])],
            outputs: ["log_probs"]
        )
        guard let logits = output["log_probs"], logits.shape.count == 3 else {
            throw OnnxFailure.badShape("log_probs", output["log_probs"]?.shape ?? [])
        }

        let values = logits.floats
        // Порядок осей у экспорта проверяется по числу классов, а не берётся на веру:
        // [1, T, C] и [1, C, T] отличаются только этим, а перепутать — получить кашу.
        if logits.shape[2] == classes {
            return (values, logits.shape[1])
        }
        guard logits.shape[1] == classes else {
            throw OnnxFailure.badShape("log_probs", logits.shape)
        }
        let encodedFrames = logits.shape[2]
        var transposed = [Float](repeating: 0, count: classes * encodedFrames)
        for klass in 0..<classes {
            let offset = klass * encodedFrames
            for frame in 0..<encodedFrames {
                transposed[frame * classes + klass] = values[offset + frame]
            }
        }
        return (transposed, encodedFrames)
    }
}
