import Combine
import Foundation

@MainActor
public final class RepetitionManager: ObservableObject {
    @Published public private(set) var attemptedRepetitions: Int = 0
    @Published public private(set) var acceptedRepetitions: Int = 0
    @Published public private(set) var sampleRecords: [AcquisitionRecord] = []

    public init() {}

    public func nextAttemptNumber() -> Int {
        attemptedRepetitions += 1
        return attemptedRepetitions
    }

    public func recordOutcome(_ record: AcquisitionRecord) {
        sampleRecords.append(record)
        if record.qualityStatus == "PROVISIONALLY_ACCEPTED" {
            acceptedRepetitions += 1
        }
    }

    public func hasReachedTarget(_ requiredAccepted: Int) -> Bool {
        acceptedRepetitions >= requiredAccepted
    }

    public func resetForNewSample() {
        attemptedRepetitions = 0
        acceptedRepetitions = 0
        sampleRecords.removeAll()
    }
}
