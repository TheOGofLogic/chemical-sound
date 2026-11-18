import Foundation

public struct ResearchProtocol: Codable, Sendable, Equatable {
    public let protocolID: String
    public let specVersion: String
    public let datasetVersion: String
    public let waveformVersion: String
    public let hardwareDomain: String
    public let requestedSampleRateHz: Double
    public let requestedInputChannels: Int
    public let preferBottomSpeakerOverride: Bool
    public let targetOutputVolume: Float
    public let outputVolumeTolerance: Float
    public let softwareAmplitudeDBFS: Double
    public let preRollMs: Int
    public let postRollMs: Int
    public let cooldownMs: Int
    public let requiredAcceptedRepetitions: Int
    public let settleDurationSeconds: Int
    public let clippingCeilingDBFS: Double
    public let maxPreRollExcessDB: Double
    public let defaultMaxPreRollRMSDBFS: Double
    public let minActiveSNRDB: Double

    public init(
        protocolID: String,
        specVersion: String = "CS-SPEC-P1-v1.2",
        datasetVersion: String = "CSRD-P1",
        waveformVersion: String = "WF-P1-v1.2.0",
        hardwareDomain: String = "IPHONE_NATIVE",
        requestedSampleRateHz: Double = 48_000,
        requestedInputChannels: Int = 1,
        preferBottomSpeakerOverride: Bool = true,
        targetOutputVolume: Float = 0.65,
        outputVolumeTolerance: Float = 0.01,
        softwareAmplitudeDBFS: Double = -6.0,
        preRollMs: Int = 150,
        postRollMs: Int = 150,
        cooldownMs: Int = 2_000,
        requiredAcceptedRepetitions: Int = 5,
        settleDurationSeconds: Int = 180,
        clippingCeilingDBFS: Double = -0.5,
        maxPreRollExcessDB: Double = 6.0,
        defaultMaxPreRollRMSDBFS: Double = -50.0,
        minActiveSNRDB: Double = 12.0
    ) {
        self.protocolID = protocolID
        self.specVersion = specVersion
        self.datasetVersion = datasetVersion
        self.waveformVersion = waveformVersion
        self.hardwareDomain = hardwareDomain
        self.requestedSampleRateHz = requestedSampleRateHz
        self.requestedInputChannels = requestedInputChannels
        self.preferBottomSpeakerOverride = preferBottomSpeakerOverride
        self.targetOutputVolume = targetOutputVolume
        self.outputVolumeTolerance = outputVolumeTolerance
        self.softwareAmplitudeDBFS = softwareAmplitudeDBFS
        self.preRollMs = preRollMs
        self.postRollMs = postRollMs
        self.cooldownMs = cooldownMs
        self.requiredAcceptedRepetitions = requiredAcceptedRepetitions
        self.settleDurationSeconds = settleDurationSeconds
        self.clippingCeilingDBFS = clippingCeilingDBFS
        self.maxPreRollExcessDB = maxPreRollExcessDB
        self.defaultMaxPreRollRMSDBFS = defaultMaxPreRollRMSDBFS
        self.minActiveSNRDB = minActiveSNRDB
    }

    public static let phase1v12 = ResearchProtocol(protocolID: "CS-P1-v1.2")
}
