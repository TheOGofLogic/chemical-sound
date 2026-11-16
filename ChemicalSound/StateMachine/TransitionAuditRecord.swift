import Foundation

public struct TransitionAuditRecord: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let previousState: AcquisitionState
    public let nextState: AcquisitionState
    public let event: String

    public init(
        timestamp: Date,
        previousState: AcquisitionState,
        nextState: AcquisitionState,
        event: String
    ) {
        self.timestamp = timestamp
        self.previousState = previousState
        self.nextState = nextState
        self.event = event
    }
}
