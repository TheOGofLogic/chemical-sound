import Foundation

public struct QualityEvaluationResult: Sendable, Equatable {
    public let qualityStatus: String  // PROVISIONALLY_ACCEPTED | REJECTED | INTERRUPTED | INCOMPLETE
    public let flags: [QualityFlag]
    public let peakDBFS: Double
    public let preRollRMSDBFS: Double
    public let clippedSampleCount: Int
    public let totalFrames: Int
}

public struct QualityControlEngine: Sendable {
    private let metadataValidator = MetadataValidator()
    private let routeValidator = AudioRouteValidator()
    private let audioAnalyzer = ImmediateAudioAnalyzer()

    public init() {}

    public func evaluate(
        recordingURL: URL,
        metadata: SampleMetadata,
        preProfile: AudioRuntimeProfile,
        postProfile: AudioRuntimeProfile,
        activeExcitationDurationMs: Int,
        protocolConfiguration: ResearchProtocol,
        silenceBaselineRMSDBFS: Double? = nil,
        previousExcitationEndUptime: Double? = nil,
        currentExcitationStartUptime: Double? = nil,
        frameTolerance: Int = 4_800
    ) throws -> QualityEvaluationResult {
        var flags: [QualityFlag] = []
        let isSilence = metadata.excitationSignal == .silence

        // 1. Metadata & physical preparation checks
        flags.append(contentsOf: metadataValidator.validate(
            metadata: metadata,
            protocolConfiguration: protocolConfiguration
        ))

        // 2. Pre/post runtime route, rate, channel & volume checks
        flags.append(contentsOf: routeValidator.qualityFlags(
            preProfile: preProfile,
            postProfile: postProfile,
            protocolConfiguration: protocolConfiguration,
            isSilenceControl: isSilence
        ))

        // 3. Inter-excitation cooldown invariant check
        if let prevEnd = previousExcitationEndUptime,
           let curStart = currentExcitationStartUptime {
            let minCooldownSec = Double(protocolConfiguration.cooldownMs) / 1_000.0
            if (curStart - prevEnd) < (minCooldownSec - 1e-4) {
                flags.append(.cooldownViolation)
            }
        }

        // 4. Lossless PCM signal checks
        let sr = protocolConfiguration.requestedSampleRateHz
        let preFrames = Int(round(Double(protocolConfiguration.preRollMs) * sr / 1_000.0))
        let actFrames = Int(round(Double(activeExcitationDurationMs) * sr / 1_000.0))
        let postFrames = Int(round(Double(protocolConfiguration.postRollMs) * sr / 1_000.0))
        let expectedTotalFrames = preFrames + actFrames + postFrames

        let metrics = try audioAnalyzer.analyze(
            recordingURL: recordingURL,
            preRollFrames: preFrames,
            activeFrames: actFrames,
            clippingCeilingDBFS: protocolConfiguration.clippingCeilingDBFS
        )

        if metrics.hasNonFiniteValues {
            flags.append(.fileWriteFailure)
        }

        if abs(metrics.sampleRateHz - sr) >= 0.5 && !flags.contains(.sampleRateMismatch) {
            flags.append(.sampleRateMismatch)
        }

        if metrics.channelCount != protocolConfiguration.requestedInputChannels &&
            !flags.contains(.channelConfigurationMismatch) {
            flags.append(.channelConfigurationMismatch)
        }

        if metrics.totalFrames < (preFrames + actFrames) ||
            abs(metrics.totalFrames - expectedTotalFrames) > frameTolerance {
            flags.append(.incompleteDuration)
        }

        if metrics.clippedSampleCount > 0 || metrics.peakDBFS >= protocolConfiguration.clippingCeilingDBFS {
            flags.append(.clipping)
        }

        if !isSilence {
            let noiseLimit: Double
            if let base = silenceBaselineRMSDBFS, base > -95.0 {
                noiseLimit = base + protocolConfiguration.maxPreRollExcessDB
            } else {
                noiseLimit = protocolConfiguration.defaultMaxPreRollRMSDBFS
            }
            if metrics.preRollRMSDBFS > noiseLimit {
                flags.append(.backgroundNoise)
            }

            if (metrics.activeRMSDBFS - metrics.preRollRMSDBFS) < protocolConfiguration.minActiveSNRDB {
                flags.append(.lowSignal)
            }
        }

        // Deduplicate while preserving deterministic order
        var uniqueFlags: [QualityFlag] = []
        for f in flags where !uniqueFlags.contains(f) {
            uniqueFlags.append(f)
        }

        let status: String
        if uniqueFlags.isEmpty {
            status = "PROVISIONALLY_ACCEPTED"
        } else if uniqueFlags.contains(.interruptedAudio) {
            status = "INTERRUPTED"
        } else if Set(uniqueFlags).isSubset(of: [.metadataIncomplete, .temperatureMissing, .fileWriteFailure]) {
            status = "INCOMPLETE"
        } else {
            status = "REJECTED"
        }

        return QualityEvaluationResult(
            qualityStatus: status,
            flags: uniqueFlags,
            peakDBFS: (metrics.peakDBFS * 1_000.0).rounded() / 1_000.0,
            preRollRMSDBFS: (metrics.preRollRMSDBFS * 1_000.0).rounded() / 1_000.0,
            clippedSampleCount: metrics.clippedSampleCount,
            totalFrames: metrics.totalFrames
        )
    }
}
