import Accelerate
import CoreGraphics
import CoreML
import Foundation

final class SemanticEncoder {
    enum Tower: String {
        case image
        case text
    }

    private let descriptor: SemanticModelDescriptor
    private let store: SemanticModelStore
    private let lock = NSLock()

    private var imageModel: MLModel?
    private var imageConstraint: MLImageConstraint?
    private var textModel: MLModel?
    private var tokenizer: CLIPTokenizer?

    init(descriptor: SemanticModelDescriptor, store: SemanticModelStore = .shared) {
        self.descriptor = descriptor
        self.store = store
    }

    var dimension: Int { descriptor.embeddingDimension }

    var isImageTowerLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return imageModel != nil
    }

    var isTextTowerLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return textModel != nil
    }

    private func compiledURL(for tower: Tower) -> URL {
        store.directory(for: descriptor).appendingPathComponent("\(tower.rawValue).mlmodelc")
    }

    private func packageURL(for tower: Tower) -> URL {
        tower == .image ? store.imagePackageURL(for: descriptor) : store.textPackageURL(for: descriptor)
    }

    private func loadModel(_ tower: Tower) -> MLModel? {
        let cached = compiledURL(for: tower)
        var target = cached
        if !FileManager.default.fileExists(atPath: cached.path) {
            let source = packageURL(for: tower)
            guard FileManager.default.fileExists(atPath: source.path) else {
                Log.semantic.error("model package missing tower=\(tower.rawValue, privacy: .public) path=\(source.path, privacy: .public)")
                return nil
            }
            let started = Date()
            guard let temporary = try? MLModel.compileModel(at: source) else {
                Log.semantic.error("model compile failed tower=\(tower.rawValue, privacy: .public)")
                return nil
            }
            do {
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.moveItem(at: temporary, to: cached)
                target = cached
            } catch {
                Log.semantic.error("compiled model move failed tower=\(tower.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                target = temporary
            }
            Log.semantic.info("model compiled tower=\(tower.rawValue, privacy: .public) ms=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)")
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let started = Date()
        guard let model = try? MLModel(contentsOf: target, configuration: configuration) else {
            Log.semantic.error("model load failed tower=\(tower.rawValue, privacy: .public) path=\(target.path, privacy: .public)")
            return nil
        }
        Log.semantic.info("model loaded tower=\(tower.rawValue, privacy: .public) ms=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)")
        return model
    }

    @discardableResult
    func prepareImageTower() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ensureImageTowerLocked()
    }

    @discardableResult
    func prepareTextTower() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ensureTextTowerLocked()
    }

    private func ensureImageTowerLocked() -> Bool {
        if imageModel != nil { return true }
        guard let model = loadModel(.image) else { return false }
        guard let constraint = model.modelDescription.inputDescriptionsByName[descriptor.imageInputName]?.imageConstraint else {
            Log.semantic.error("image constraint missing input=\(self.descriptor.imageInputName, privacy: .public)")
            return false
        }
        imageModel = model
        imageConstraint = constraint
        return true
    }

    private func ensureTextTowerLocked() -> Bool {
        if textModel != nil, tokenizer != nil { return true }
        if tokenizer == nil {
            let path = store.tokenizerURL(for: descriptor).path
            guard let built = CLIPTokenizer(mergesPath: path) else {
                Log.semantic.error("tokenizer load failed path=\(path, privacy: .public)")
                return false
            }
            tokenizer = built
        }
        if textModel == nil {
            guard let model = loadModel(.text) else { return false }
            textModel = model
        }
        return true
    }

    func unloadImageTower() {
        lock.lock(); defer { lock.unlock() }
        guard imageModel != nil else { return }
        imageModel = nil
        imageConstraint = nil
        Log.semantic.info("image tower unloaded")
    }

    func unloadTextTower() {
        lock.lock(); defer { lock.unlock() }
        guard textModel != nil || tokenizer != nil else { return }
        textModel = nil
        tokenizer = nil
        Log.semantic.info("text tower unloaded")
    }

    func encodeImage(_ image: CGImage) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard ensureImageTowerLocked(), let model = imageModel, let constraint = imageConstraint else { return nil }
        guard let value = try? MLFeatureValue(cgImage: image, constraint: constraint, options: nil) else {
            Log.semantic.error("image feature build failed")
            return nil
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [descriptor.imageInputName: value]) else { return nil }
        guard let output = try? model.prediction(from: provider) else {
            Log.semantic.error("image prediction failed")
            return nil
        }
        return normalizedVector(from: output)
    }

    func encodeText(_ text: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard ensureTextTowerLocked(), let model = textModel, let tokenizer else { return nil }
        let ids = tokenizer.tokenize(text)
        guard ids.count == descriptor.contextLength else {
            Log.semantic.error("token length mismatch got=\(ids.count, privacy: .public) expected=\(self.descriptor.contextLength, privacy: .public)")
            return nil
        }
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: descriptor.contextLength)], dataType: .int32) else { return nil }
        for index in 0..<descriptor.contextLength { array[index] = NSNumber(value: ids[index]) }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [descriptor.textInputName: MLFeatureValue(multiArray: array)]) else { return nil }
        guard let output = try? model.prediction(from: provider) else {
            Log.semantic.error("text prediction failed")
            return nil
        }
        return normalizedVector(from: output)
    }

    private func normalizedVector(from output: MLFeatureProvider) -> [Float]? {
        guard let array = output.featureValue(for: descriptor.outputName)?.multiArrayValue else {
            Log.semantic.error("output missing name=\(self.descriptor.outputName, privacy: .public)")
            return nil
        }
        let count = descriptor.embeddingDimension
        guard array.count >= count else {
            Log.semantic.error("output too short count=\(array.count, privacy: .public) expected=\(count, privacy: .public)")
            return nil
        }

        var vector = [Float](repeating: 0, count: count)
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            vector.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: pointer, count: count) }
        case .float16:
            let pointer = array.dataPointer.assumingMemoryBound(to: UInt16.self)
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pointer), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
            vector.withUnsafeMutableBufferPointer { buffer in
                var target = vImage_Buffer(data: buffer.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&source, &target, 0)
            }
        case .double:
            let pointer = array.dataPointer.assumingMemoryBound(to: Double.self)
            for index in 0..<count { vector[index] = Float(pointer[index]) }
        default:
            Log.semantic.error("unsupported output dtype raw=\(array.dataType.rawValue, privacy: .public)")
            return nil
        }

        var squared: Float = 0
        vDSP_svesq(vector, 1, &squared, vDSP_Length(count))
        let norm = sqrt(squared)
        guard norm > 0, norm.isFinite else {
            Log.semantic.error("degenerate embedding norm")
            return nil
        }
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &vector, 1, vDSP_Length(count))
        return vector
    }
}
