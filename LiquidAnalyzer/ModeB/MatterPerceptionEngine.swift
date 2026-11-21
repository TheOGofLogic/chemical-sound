import Accelerate
import CoreML
import Foundation

/// Output of `MatterPerceptionEngine` (`LA-ML-ARCH-001` v1.0.0) combining prototype cosine distance,
/// Open-Set Energy OOD gating, and per-modality reliability weights.
public struct MatterPrediction: Equatable, Sendable {
    public let identifier: String
    public let confidence: Float
    public let cosineDistance: Float
    public let energyScore: Float
    public let acousticReliability: Float
    public let opticalReliability: Float
    public let predictedVelocity20CMps: Float?
    public let isOutOfDistribution: Bool

    public init(
        identifier: String,
        confidence: Float,
        cosineDistance: Float,
        energyScore: Float,
        acousticReliability: Float,
        opticalReliability: Float,
        predictedVelocity20CMps: Float? = nil,
        isOutOfDistribution: Bool
    ) {
        self.identifier = identifier
        self.confidence = confidence
        self.cosineDistance = cosineDistance
        self.energyScore = energyScore
        self.acousticReliability = acousticReliability
        self.opticalReliability = opticalReliability
        self.predictedVelocity20CMps = predictedVelocity20CMps
        self.isOutOfDistribution = isOutOfDistribution
    }
}

/// On-device CoreML + Zero-Retrain Prototype Bank runtime for `MatterJEA` (`LA-ML-ARCH-001` v1.0.0).
/// Supports compiled `.mlmodelc` / `.mlpackage` ANE execution as well as standalone prototype-space inference
/// and few-shot chemical enrollment (`enrollPrototype`).
public final class MatterPerceptionEngine: @unchecked Sendable {
    public static let embeddingDimension: Int = 128

    public enum RuntimeError: Error, Equatable, Sendable {
        case modelNotLoaded
        case invalidInputLength(expected: Int, actual: Int)
        case missingModelOutput(String)
    }

    private let model: MLModel?
    private let lock = NSLock()
    private var prototypeBank: [String: [Float]]

    public var oodDistanceThreshold: Float
    public var oodEnergyThreshold: Float
    public var energyTemperature: Float
    public var minimumReliabilityFloor: Float

    /// Initializes the engine backed by a compiled CoreML model on the Apple Neural Engine (`.all`).
    public init(
        compiledModelURL: URL,
        prototypes: [String: [Float]] = [:],
        oodDistanceThreshold: Float = 0.38,
        oodEnergyThreshold: Float = -0.58,
        energyTemperature: Float = 0.15,
        minimumReliabilityFloor: Float = 0.25
    ) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        self.model = try MLModel(contentsOf: compiledModelURL, configuration: config)
        self.prototypeBank = Self.normalizedBank(prototypes)
        self.oodDistanceThreshold = oodDistanceThreshold
        self.oodEnergyThreshold = oodEnergyThreshold
        self.energyTemperature = energyTemperature
        self.minimumReliabilityFloor = minimumReliabilityFloor
    }

    /// Initializes a prototype-only engine for Sim-to-Real validation and few-shot unit testing without a bundled `.mlmodelc`.
    public init(
        prototypes: [String: [Float]] = [:],
        oodDistanceThreshold: Float = 0.38,
        oodEnergyThreshold: Float = -0.58,
        energyTemperature: Float = 0.15,
        minimumReliabilityFloor: Float = 0.25
    ) {
        self.model = nil
        self.prototypeBank = Self.normalizedBank(prototypes)
        self.oodDistanceThreshold = oodDistanceThreshold
        self.oodEnergyThreshold = oodEnergyThreshold
        self.energyTemperature = energyTemperature
        self.minimumReliabilityFloor = minimumReliabilityFloor
    }

    public var enrolledIdentifiers: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(prototypeBank.keys).sorted()
    }

    /// Loads a JSON prototype bank exported by `ml/train_matter_jea.py` (`{ "H2O_DIST": [Float * 128], ... }`).
    public func loadPrototypeBank(fromJSONData data: Data) throws {
        let decoded = try JSONDecoder().decode([String: [Float]].self, from: data)
        lock.lock()
        defer { lock.unlock() }
        for (key, vec) in decoded where vec.count == Self.embeddingDimension {
            prototypeBank[key] = Self.l2Normalized(vec)
        }
    }

    /// Zero-retrain few-shot enrollment: averages and L2-normalizes 128-D embeddings for a new chemical class.
    public func enrollPrototype(identifier: String, embeddings: [[Float]]) {
        let valid = embeddings.filter { $0.count == Self.embeddingDimension }
        guard !valid.isEmpty else { return }
        var centroid = [Float](repeating: 0.0, count: Self.embeddingDimension)
        for emb in valid {
            vDSP_vadd(centroid, 1, emb, 1, &centroid, 1, vDSP_Length(Self.embeddingDimension))
        }
        let unit = Self.l2Normalized(centroid)
        lock.lock()
        prototypeBank[identifier] = unit
        lock.unlock()
    }

    /// Executes acoustic-branch CoreML inference (`[1, 2, L]` -> `(z_a, w_a, pred_c20)`) and scores against the prototype bank.
    public func inferAcousticStream(
        rfAcoustic: [Float],
        hilbertEnvelope: [Float],
        expectedLength: Int = 8_800
    ) throws -> MatterPrediction {
        guard let model else { throw RuntimeError.modelNotLoaded }
        guard rfAcoustic.count >= expectedLength, hilbertEnvelope.count >= expectedLength else {
            throw RuntimeError.invalidInputLength(
                expected: expectedLength,
                actual: min(rfAcoustic.count, hilbertEnvelope.count)
            )
        }

        let multiArray = try MLMultiArray(
            shape: [1, 2, NSNumber(value: expectedLength)],
            dataType: .float32
        )
        let s0 = multiArray.strides[1].intValue
        let s1 = multiArray.strides[2].intValue
        let ptr = multiArray.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<expectedLength {
            ptr[i * s1] = rfAcoustic[i]
            ptr[s0 + i * s1] = hilbertEnvelope[i]
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "acoustic_stream": MLFeatureValue(multiArray: multiArray)
        ])
        let output = try model.prediction(from: provider)

        guard let zArray = output.featureValue(for: "z_a")?.multiArrayValue,
              zArray.count >= Self.embeddingDimension else {
            throw RuntimeError.missingModelOutput("z_a")
        }
        let embedding = Self.extractFloatVector(from: zArray, count: Self.embeddingDimension)
        let wA = output.featureValue(for: "w_a")?.multiArrayValue.map { Self.extractScalar(from: $0) } ?? 1.0
        let predC20 = output.featureValue(for: "pred_c20")?.multiArrayValue.map { Self.extractScalar(from: $0) }

        return classifyEmbedding(
            embedding,
            acousticReliability: wA,
            opticalReliability: 0.0,
            predictedVelocity20CMps: predC20
        )
    }

    /// Evaluates a 128-D hyperspherical embedding against all enrolled prototypes using cosine distance + OOD Energy Gate.
    public func classifyEmbedding(
        _ rawEmbedding: [Float],
        acousticReliability: Float,
        opticalReliability: Float,
        predictedVelocity20CMps: Float? = nil
    ) -> MatterPrediction {
        lock.lock()
        let bank = prototypeBank
        lock.unlock()

        guard rawEmbedding.count == Self.embeddingDimension, !bank.isEmpty else {
            return MatterPrediction(
                identifier: "Inconclusive / Unknown",
                confidence: 0.0,
                cosineDistance: 1.0,
                energyScore: 0.0,
                acousticReliability: acousticReliability,
                opticalReliability: opticalReliability,
                predictedVelocity20CMps: predictedVelocity20CMps,
                isOutOfDistribution: true
            )
        }

        let embedding = Self.l2Normalized(rawEmbedding)
        let maxReliability = max(acousticReliability, opticalReliability)

        var bestID = "Inconclusive / Unknown"
        var minDist: Float = .infinity
        var expSum: Double = 0.0
        let invT = 1.0 / Double(max(1e-4, energyTemperature))

        for (candidateID, proto) in bank where proto.count == Self.embeddingDimension {
            var dot: Float = 0.0
            vDSP_dotpr(embedding, 1, proto, 1, &dot, vDSP_Length(Self.embeddingDimension))
            let clampedDot = max(-1.0, min(1.0, dot))
            let dist = max(0.0, 1.0 - clampedDot)
            if dist < minDist {
                minDist = dist
                bestID = candidateID
            }
            expSum += exp(Double(clampedDot) * invT)
        }

        let energy = Float(-Double(energyTemperature) * log(max(1e-12, expSum)))
        let lowReliability = maxReliability < minimumReliabilityFloor
        let isOOD = lowReliability || (minDist > oodDistanceThreshold) || (energy > oodEnergyThreshold)
        let confidence: Float = isOOD
            ? 0.0
            : max(0.0, min(1.0, 1.0 - (minDist / max(1e-4, oodDistanceThreshold))))

        return MatterPrediction(
            identifier: isOOD ? "Inconclusive / Unknown" : bestID,
            confidence: confidence,
            cosineDistance: minDist,
            energyScore: energy,
            acousticReliability: acousticReliability,
            opticalReliability: opticalReliability,
            predictedVelocity20CMps: predictedVelocity20CMps,
            isOutOfDistribution: isOOD
        )
    }

    // MARK: - Helpers

    private static func normalizedBank(_ prototypes: [String: [Float]]) -> [String: [Float]] {
        var normalized: [String: [Float]] = [:]
        for (key, vec) in prototypes where vec.count == embeddingDimension {
            normalized[key] = l2Normalized(vec)
        }
        return normalized
    }

    public static func l2Normalized(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }
        var normSq: Float = 0.0
        vDSP_dotpr(vector, 1, vector, 1, &normSq, vDSP_Length(vector.count))
        let denom = sqrt(max(1e-12, normSq))
        var inv = 1.0 / denom
        var out = [Float](repeating: 0.0, count: vector.count)
        vDSP_vsmul(vector, 1, &inv, &out, 1, vDSP_Length(vector.count))
        return out
    }

    private static func extractFloatVector(from array: MLMultiArray, count: Int) -> [Float] {
        var result = [Float](repeating: 0.0, count: count)
        for i in 0..<count {
            result[i] = array[i].floatValue
        }
        return result
    }

    private static func extractScalar(from array: MLMultiArray) -> Float {
        guard array.count > 0 else { return 0.0 }
        return array[0].floatValue
    }
}
