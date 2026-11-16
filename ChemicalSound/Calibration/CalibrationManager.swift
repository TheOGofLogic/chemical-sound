import Combine
import Foundation

public enum CalibrationStepKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case silenceControl = "CAL_START_SILENCE"
    case fixtureOnly = "CAL_START_FIXTURE_ONLY"
    case emptyContainer = "CAL_START_EMPTY_CONTAINER"
    case distilledWaterStart = "CAL_START_DISTILLED_WATER"
    case periodicWaterCheck = "CAL_PERIODIC_WATER"
    case distilledWaterEnd = "CAL_END_DISTILLED_WATER"
    case emptyContainerEnd = "CAL_END_EMPTY_CONTAINER"

    public var id: String { rawValue }

    public static let requiredStartSteps: [CalibrationStepKind] = [
        .silenceControl,
        .fixtureOnly,
        .emptyContainer,
        .distilledWaterStart
    ]

    public static let requiredEndSteps: [CalibrationStepKind] = [
        .distilledWaterEnd,
        .emptyContainerEnd
    ]
}

@MainActor
public final class CalibrationManager: ObservableObject {
    @Published public private(set) var completedSteps: Set<CalibrationStepKind> = []
    @Published public private(set) var silenceBaselineRMSDBFS: Double?
    @Published public private(set) var startWaterActiveRMSDBFS: Double?
    @Published public private(set) var endWaterActiveRMSDBFS: Double?
    @Published public private(set) var sessionValidityState: String = "SESSION_OPEN"
    @Published public private(set) var activeCalibrationID: String

    public init(sessionID: String = "SESS_01") {
        self.activeCalibrationID = "CAL_\(sessionID)"
    }

    public var hasPassedInitialCalibration: Bool {
        Set(CalibrationStepKind.requiredStartSteps).isSubset(of: completedSteps)
    }

    public var hasCompletedFinalCalibration: Bool {
        Set(CalibrationStepKind.requiredEndSteps).isSubset(of: completedSteps)
    }

    public func reset(sessionID: String) {
        completedSteps.removeAll()
        silenceBaselineRMSDBFS = nil
        startWaterActiveRMSDBFS = nil
        endWaterActiveRMSDBFS = nil
        sessionValidityState = "SESSION_OPEN"
        activeCalibrationID = "CAL_\(sessionID)"
    }

    public func recordAcceptedStep(
        _ step: CalibrationStepKind,
        preRollRMSDBFS: Double,
        peakDBFS: Double,
        maxBroadbandDriftDB: Double = 2.0
    ) -> Bool {
        completedSteps.insert(step)
        switch step {
        case .silenceControl:
            silenceBaselineRMSDBFS = preRollRMSDBFS
        case .distilledWaterStart:
            startWaterActiveRMSDBFS = peakDBFS
        case .distilledWaterEnd:
            endWaterActiveRMSDBFS = peakDBFS
        default:
            break
        }

        if hasCompletedFinalCalibration,
           let startW = startWaterActiveRMSDBFS,
           let endW = endWaterActiveRMSDBFS {
            if abs(endW - startW) <= maxBroadbandDriftDB {
                sessionValidityState = "SESSION_VALID"
                return true
            } else {
                sessionValidityState = "SESSION_DRIFT_INVALIDATED"
                return false
            }
        }
        return true
    }
}
