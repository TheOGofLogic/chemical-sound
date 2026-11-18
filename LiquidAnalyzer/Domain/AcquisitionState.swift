import Foundation

/// Canonical 22-state acquisition machine for Liquid Analyzer Milestone 3A (CS-SPEC-P1-v1.2).
public enum AcquisitionState: String, Codable, CaseIterable, Sendable {
    case unconfigured
    case configuring
    case configurationFailed
    case readyForCalibration
    case calibrating
    case calibrationPassed
    case calibrationFailed
    case readyForSample
    case settling
    case armed
    case recordingPreRoll
    case playingExcitation
    case recordingPostRoll
    case coolingDown
    case evaluatingQC
    case repetitionAccepted
    case repetitionRejected
    case batchComplete
    case saving
    case exportReady
    case interrupted
    case fatalError

    public var isActivelyAcquiring: Bool {
        switch self {
        case .recordingPreRoll,
             .playingExcitation,
             .recordingPostRoll:
            return true
        default:
            return false
        }
    }

    public var permitsAudioSessionReconfiguration: Bool {
        !isActivelyAcquiring
    }

    public var isTerminalForCurrentRun: Bool {
        switch self {
        case .exportReady, .fatalError:
            return true
        default:
            return false
        }
    }
}
