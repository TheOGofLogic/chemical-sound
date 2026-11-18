import Foundation

public enum AcquisitionFailure: Error, Codable, Sendable, Equatable, LocalizedError {
    case microphonePermissionDenied
    case protocolInvalid(String)
    case manifestInvalid(String)
    case waveformMissing(String)
    case checksumMismatch(assetID: String)
    case externalAudioRoute(String)
    case unsupportedAudioRoute(String)
    case sampleRateMismatch(expected: Double, actual: Double)
    case channelConfigurationMismatch(expected: Int, actual: Int)
    case inputDataSourceMismatch(expected: String, actual: String?)
    case volumeMismatch(expected: Float, actual: Float)
    case cooldownViolation(remainingMs: Int)
    case calibrationUnavailable
    case calibrationDrift(String)
    case metadataIncomplete([String])
    case audioEngineFailure(String)
    case fileWriteFailure(String)
    case insufficientStorage
    case interrupted(String)
    case integrityFailure(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission was denied."
        case .protocolInvalid(let msg):
            return "Protocol invalid: \(msg)"
        case .manifestInvalid(let msg):
            return "Waveform manifest invalid: \(msg)"
        case .waveformMissing(let name):
            return "Missing bundled waveform file: \(name)"
        case .checksumMismatch(let assetID):
            return "SHA-256 checksum mismatch for waveform asset: \(assetID)"
        case .externalAudioRoute(let port):
            return "Prohibited external audio route active: \(port)"
        case .unsupportedAudioRoute(let detail):
            return "Unsupported audio route: \(detail)"
        case .sampleRateMismatch(let expected, let actual):
            return "Sample rate mismatch (expected \(Int(expected)) Hz, actual \(Int(actual)) Hz)."
        case .channelConfigurationMismatch(let expected, let actual):
            return "Input channel mismatch (expected \(expected), actual \(actual))."
        case .inputDataSourceMismatch(let expected, let actual):
            return "Microphone data source mismatch (expected \(expected), actual \(actual ?? "nil"))."
        case .volumeMismatch(let expected, let actual):
            return String(format: "Hardware output volume %.2f outside target %.2f.", actual, expected)
        case .cooldownViolation(let remainingMs):
            return "Inter-excitation cooldown active (\(remainingMs) ms remaining)."
        case .calibrationUnavailable:
            return "Required session calibration has not passed."
        case .calibrationDrift(let msg):
            return "Session calibration drift exceeded limit: \(msg)"
        case .metadataIncomplete(let fields):
            return "Required metadata incomplete: \(fields.joined(separator: ", "))"
        case .audioEngineFailure(let msg):
            return "AVAudioEngine failure: \(msg)"
        case .fileWriteFailure(let msg):
            return "Lossless audio write failure: \(msg)"
        case .insufficientStorage:
            return "Insufficient local storage to begin acquisition."
        case .interrupted(let reason):
            return "Acquisition interrupted: \(reason)"
        case .integrityFailure(let detail):
            return "Integrity failure: \(detail)"
        }
    }
}
