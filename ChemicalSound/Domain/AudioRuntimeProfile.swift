import Foundation

/// Captures requested vs. post-activation verified runtime hardware characteristics (Milestone 3A/3B).
public struct AudioRuntimeProfile: Codable, Sendable, Equatable {
    public let capturedAt: Date

    public let commercialModelName: String
    public let hardwareModelIdentifier: String
    public let iosVersion: String
    public let appVersion: String
    public let deviceCode: String
    public let caseStatus: String
    public let batteryLevel: Float?
    public let chargingState: String
    public let thermalState: String
    public let deviceOrientation: String

    public let requestedCategory: String
    public let actualCategory: String

    public let requestedMode: String
    public let actualMode: String

    public let requestedSampleRate: Double
    public let actualSampleRate: Double

    public let availableInputPorts: [String]
    public let availableMicDataSources: [String]
    public let availablePolarPatterns: [String]

    public let inputPortTypes: [String]
    public let outputPortTypes: [String]

    public let inputPortNames: [String]
    public let outputPortNames: [String]

    public let requestedInputDataSource: String?
    public let selectedInputDataSource: String?
    public let requestedPolarPattern: String?
    public let selectedPolarPattern: String?

    public let inputChannelCount: Int
    public let outputChannelCount: Int
    public let reportedSpeakerChannelMapping: String

    public let inputLatencySeconds: Double
    public let outputLatencySeconds: Double
    public let ioBufferDurationSeconds: Double
    public let outputVolume: Float
}
