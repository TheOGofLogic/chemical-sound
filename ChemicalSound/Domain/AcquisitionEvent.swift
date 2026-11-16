import Foundation

public enum AcquisitionEvent: Sendable, Equatable {
    case configureRequested
    case configurationSucceeded
    case configurationFailed(AcquisitionFailure)

    case calibrationRequested
    case calibrationSucceeded
    case calibrationFailed(AcquisitionFailure)
    case calibrationAcknowledged

    case sampleMetadataAccepted
    case settlingStarted
    case settlingCompleted

    case armRequested
    case armSucceeded
    case armFailed(AcquisitionFailure)

    case preRollStarted
    case excitationStarted
    case excitationCompleted
    case postRollCompleted
    case cooldownCompleted

    case qualityControlPassed
    case qualityControlFailed([QualityFlag])

    case nextRepetitionRequested
    case requiredRepetitionsCompleted

    case saveRequested
    case saveSucceeded
    case saveFailed(AcquisitionFailure)

    case resetCalibrationRequested
    case resetSampleRequested

    case audioInterrupted
    case routeChanged
    case appBackgrounded
    case recoverRequested
    case recoverySucceeded
    case recoveryFailed(AcquisitionFailure)

    case fatal(AcquisitionFailure)
}
