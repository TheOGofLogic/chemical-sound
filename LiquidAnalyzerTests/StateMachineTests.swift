import XCTest
@testable import LiquidAnalyzer

@MainActor
final class StateMachineTests: XCTestCase {
    private func makeMachine() throws -> (AcquisitionStateMachine, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CS_StateTests_\(UUID().uuidString)", isDirectory: true)
        let logURL = dir.appendingPathComponent("transitions.jsonl")
        let logger = AuditLogger(logFileURL: logURL)
        return (AcquisitionStateMachine(auditLogger: logger), dir)
    }

    func testTwentyTwoStatesEnumerated() {
        XCTAssertEqual(AcquisitionState.allCases.count, 22)
    }

    func testCannotBypassCalibrationDirectlyToArmed() throws {
        let (machine, dir) = try makeMachine()
        defer { try? FileManager.default.removeItem(at: dir) }

        try machine.handle(.configureRequested)
        try machine.handle(.configurationSucceeded)
        XCTAssertEqual(machine.state, .readyForCalibration)

        XCTAssertThrowsError(try machine.handle(.sampleMetadataAccepted))
        XCTAssertThrowsError(try machine.handle(.armSucceeded))
    }

    func testFullNominalAcquisitionAndExportLifecycle() throws {
        let (machine, dir) = try makeMachine()
        defer { try? FileManager.default.removeItem(at: dir) }

        try machine.handle(.configureRequested)
        try machine.handle(.configurationSucceeded)
        try machine.handle(.calibrationRequested)
        try machine.handle(.calibrationSucceeded)
        try machine.handle(.calibrationAcknowledged)
        XCTAssertEqual(machine.state, .readyForSample)

        try machine.handle(.sampleMetadataAccepted)
        try machine.handle(.settlingStarted)
        try machine.handle(.settlingCompleted)
        XCTAssertEqual(machine.state, .armed)

        try machine.handle(.armSucceeded)
        try machine.handle(.preRollStarted)
        XCTAssertTrue(machine.state.isActivelyAcquiring)

        try machine.handle(.excitationStarted)
        XCTAssertTrue(machine.state.isActivelyAcquiring)

        try machine.handle(.excitationCompleted)
        XCTAssertEqual(machine.state, .recordingPostRoll)
        XCTAssertTrue(machine.state.isActivelyAcquiring)

        try machine.handle(.postRollCompleted)
        XCTAssertEqual(machine.state, .coolingDown)
        XCTAssertFalse(machine.state.isActivelyAcquiring)

        try machine.handle(.cooldownCompleted)
        XCTAssertEqual(machine.state, .evaluatingQC)

        try machine.handle(.qualityControlPassed)
        XCTAssertEqual(machine.state, .repetitionAccepted)

        try machine.handle(.requiredRepetitionsCompleted)
        XCTAssertEqual(machine.state, .batchComplete)

        try machine.handle(.saveRequested)
        try machine.handle(.saveSucceeded)
        XCTAssertEqual(machine.state, .exportReady)
    }

    func testRouteChangeDuringActiveCaptureTransitionsToInterruptedAndRecovers() throws {
        let (machine, dir) = try makeMachine()
        defer { try? FileManager.default.removeItem(at: dir) }

        try machine.handle(.configureRequested)
        try machine.handle(.configurationSucceeded)
        try machine.handle(.calibrationRequested)
        try machine.handle(.calibrationSucceeded)
        try machine.handle(.calibrationAcknowledged)
        try machine.handle(.sampleMetadataAccepted)
        try machine.handle(.settlingCompleted)
        try machine.handle(.armSucceeded)
        try machine.handle(.excitationStarted)

        try machine.handle(.routeChanged)
        XCTAssertEqual(machine.state, .interrupted)
        XCTAssertTrue(machine.activeQualityFlags.contains(.audioRouteInvalid))

        try machine.handle(.recoverRequested)
        XCTAssertEqual(machine.state, .configuring)
        try machine.handle(.recoverySucceeded)
        XCTAssertEqual(machine.state, .readyForCalibration)
    }
}
