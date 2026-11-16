import Foundation

public enum StateTransitionError: Error, Equatable, LocalizedError {
    case invalidTransition(from: AcquisitionState, eventDescription: String)

    public var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let eventDescription):
            return "Invalid state transition from '\(from.rawValue)' via event '\(eventDescription)'."
        }
    }
}

public struct TransitionOutcome: Sendable, Equatable {
    public let nextState: AcquisitionState
    public let failureUpdate: FailureUpdate
    public let qualityFlagsUpdate: Set<QualityFlag>?

    public enum FailureUpdate: Sendable, Equatable {
        case keep
        case clear
        case set(AcquisitionFailure)
    }
}

/// Pure, unit-testable transition table for the 22-state Chemical Sound acquisition machine.
public enum TransitionRule {
    public static func evaluate(
        from current: AcquisitionState,
        event: AcquisitionEvent
    ) throws -> TransitionOutcome {
        switch (current, event) {
        case (.unconfigured, .configureRequested),
             (.configurationFailed, .configureRequested):
            return TransitionOutcome(nextState: .configuring, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.configuring, .configurationSucceeded),
             (.configuring, .recoverySucceeded):
            return TransitionOutcome(nextState: .readyForCalibration, failureUpdate: .clear, qualityFlagsUpdate: [])

        case (.configuring, .configurationFailed(let failure)),
             (.configuring, .recoveryFailed(let failure)):
            return TransitionOutcome(nextState: .configurationFailed, failureUpdate: .set(failure), qualityFlagsUpdate: nil)

        case (.readyForCalibration, .calibrationRequested),
             (.calibrationFailed, .calibrationRequested):
            return TransitionOutcome(nextState: .calibrating, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.calibrating, .calibrationSucceeded):
            return TransitionOutcome(nextState: .calibrationPassed, failureUpdate: .clear, qualityFlagsUpdate: [])

        case (.calibrating, .calibrationFailed(let failure)):
            return TransitionOutcome(nextState: .calibrationFailed, failureUpdate: .set(failure), qualityFlagsUpdate: nil)

        case (.calibrationPassed, .calibrationAcknowledged):
            return TransitionOutcome(nextState: .readyForSample, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.readyForSample, .sampleMetadataAccepted):
            return TransitionOutcome(nextState: .settling, failureUpdate: .clear, qualityFlagsUpdate: [])

        case (.settling, .settlingStarted):
            return TransitionOutcome(nextState: .settling, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.settling, .settlingCompleted):
            return TransitionOutcome(nextState: .armed, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.armed, .armRequested):
            return TransitionOutcome(nextState: .armed, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.armed, .armSucceeded):
            return TransitionOutcome(nextState: .recordingPreRoll, failureUpdate: .clear, qualityFlagsUpdate: nil)

        case (.armed, .armFailed(let failure)):
            return TransitionOutcome(nextState: .repetitionRejected, failureUpdate: .set(failure), qualityFlagsUpdate: nil)

        case (.recordingPreRoll, .preRollStarted):
            return TransitionOutcome(nextState: .recordingPreRoll, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.recordingPreRoll, .excitationStarted):
            return TransitionOutcome(nextState: .playingExcitation, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.playingExcitation, .excitationCompleted):
            return TransitionOutcome(nextState: .recordingPostRoll, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.recordingPostRoll, .postRollCompleted):
            return TransitionOutcome(nextState: .coolingDown, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.coolingDown, .cooldownCompleted):
            return TransitionOutcome(nextState: .evaluatingQC, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.evaluatingQC, .qualityControlPassed):
            return TransitionOutcome(nextState: .repetitionAccepted, failureUpdate: .clear, qualityFlagsUpdate: [])

        case (.evaluatingQC, .qualityControlFailed(let flags)):
            return TransitionOutcome(nextState: .repetitionRejected, failureUpdate: .keep, qualityFlagsUpdate: Set(flags))

        case (.repetitionAccepted, .nextRepetitionRequested),
             (.repetitionRejected, .nextRepetitionRequested):
            return TransitionOutcome(nextState: .armed, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.repetitionAccepted, .requiredRepetitionsCompleted):
            return TransitionOutcome(nextState: .batchComplete, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.batchComplete, .saveRequested),
             (.readyForSample, .saveRequested):
            return TransitionOutcome(nextState: .saving, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.saving, .saveSucceeded):
            return TransitionOutcome(nextState: .exportReady, failureUpdate: .clear, qualityFlagsUpdate: nil)

        case (.saving, .saveFailed(let failure)):
            return TransitionOutcome(nextState: .fatalError, failureUpdate: .set(failure), qualityFlagsUpdate: nil)

        case (.calibrationPassed, .resetCalibrationRequested),
             (.readyForSample, .resetCalibrationRequested),
             (.armed, .resetCalibrationRequested),
             (.batchComplete, .resetCalibrationRequested),
             (.exportReady, .resetCalibrationRequested):
            return TransitionOutcome(nextState: .readyForCalibration, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (.readyForSample, .resetSampleRequested),
             (.settling, .resetSampleRequested),
             (.armed, .resetSampleRequested),
             (.repetitionAccepted, .resetSampleRequested),
             (.repetitionRejected, .resetSampleRequested),
             (.batchComplete, .resetSampleRequested),
             (.exportReady, .resetSampleRequested):
            return TransitionOutcome(nextState: .readyForSample, failureUpdate: .keep, qualityFlagsUpdate: [])

        case let (state, .audioInterrupted) where state.isActivelyAcquiring:
            return TransitionOutcome(
                nextState: .interrupted,
                failureUpdate: .set(.interrupted("Audio-session interruption")),
                qualityFlagsUpdate: [.interruptedAudio]
            )

        case let (state, .routeChanged) where state.isActivelyAcquiring:
            return TransitionOutcome(
                nextState: .interrupted,
                failureUpdate: .set(.interrupted("Audio route changed")),
                qualityFlagsUpdate: [.audioRouteInvalid, .interruptedAudio]
            )

        case let (state, .appBackgrounded) where state.isActivelyAcquiring:
            return TransitionOutcome(
                nextState: .interrupted,
                failureUpdate: .set(.interrupted("Application entered background")),
                qualityFlagsUpdate: [.interruptedAudio]
            )

        case (.interrupted, .recoverRequested):
            return TransitionOutcome(nextState: .configuring, failureUpdate: .keep, qualityFlagsUpdate: nil)

        case (_, .fatal(let failure)):
            return TransitionOutcome(nextState: .fatalError, failureUpdate: .set(failure), qualityFlagsUpdate: nil)

        default:
            throw StateTransitionError.invalidTransition(
                from: current,
                eventDescription: String(describing: event)
            )
        }
    }
}
