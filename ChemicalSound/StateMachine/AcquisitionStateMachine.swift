import Combine
import Foundation

@MainActor
public final class AcquisitionStateMachine: ObservableObject {
    @Published public private(set) var state: AcquisitionState = .unconfigured
    @Published public private(set) var lastFailure: AcquisitionFailure?
    @Published public private(set) var activeQualityFlags: Set<QualityFlag> = []

    private let auditLogger: AuditLogger

    public init(auditLogger: AuditLogger) {
        self.auditLogger = auditLogger
    }

    public func handle(_ event: AcquisitionEvent) throws {
        let previous = state
        let outcome = try TransitionRule.evaluate(from: state, event: event)

        state = outcome.nextState
        switch outcome.failureUpdate {
        case .keep:
            break
        case .clear:
            lastFailure = nil
        case .set(let failure):
            lastFailure = failure
        }

        if let flags = outcome.qualityFlagsUpdate {
            activeQualityFlags = flags
        }

        let record = TransitionAuditRecord(
            timestamp: Date(),
            previousState: previous,
            nextState: outcome.nextState,
            event: String(describing: event)
        )
        try auditLogger.append(record)
    }
}
