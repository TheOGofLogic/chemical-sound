import XCTest
@testable import ChemicalSound

final class ExportBundleTests: XCTestCase {
    func testExplicitNullEncodingAndCompleteBundleExport() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CS_Export_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetsDir = repoRoot.appendingPathComponent("Assets", isDirectory: true)
        let wfRepo = WaveformRepository(assetsDirectoryURL: assetsDir)

        let store = AcquisitionStore(rootDirectoryURL: tempRoot.appendingPathComponent("Sessions"))
        let tempWav = try await store.temporaryRecordingURL(
            sessionID: "SESS_EXP_01",
            sampleID: "SMP_01",
            repetition: 1
        )
        try Data("MockLosslessWAVBytes".utf8).write(to: tempWav)

        let committed = try await store.commitRecordingFile(
            temporaryURL: tempWav,
            sessionID: "SESS_EXP_01",
            sampleID: "SMP_01",
            repetition: 1
        )

        let rec = AcquisitionRecord(
            datasetVersion: "CSRD-P1",
            protocolVersion: "CS-SPEC-P1-v1.2",
            waveformVersion: "WF-P1-v1.2.0",
            hardwareDomain: "IPHONE_NATIVE",
            studyID: "CS_TEST",
            sessionID: "SESS_EXP_01",
            operatorID: "OP_01",
            scanStage: "GATE_0B",
            sampleID: "SMP_01",
            blindCode: nil,
            isBlindedRun: false,
            liquidClass: nil,
            formulationID: "H2O_DIST",
            preparationBatchID: "B01",
            concentrationValue: nil,
            concentrationUnit: nil,
            preparationMethod: nil,
            preparationTimestamp: nil,
            fillTimestamp: nil,
            scanTimestamp: "2026-11-16T12:00:00Z",
            containerType: "PP_THIN_WALL",
            containerProductNumber: nil,
            containerLot: nil,
            containerID: "PP_01",
            isHeldOutContainer: false,
            capClosureState: "CAPPED_STOP",
            bubbleFoamFlag: "NONE",
            positionConfirmed: true,
            nominalVolumeML: 15.0,
            measuredMassG: 15.0,
            fillHeightMM: 42.0,
            headspaceHeightMM: 15.0,
            sampleTemperatureC: 22.0,
            tempMeasurementMethod: nil,
            tempMeasurementTiming: "PRE_SETTLE",
            ambientTemperatureC: nil,
            ambientHumidityPct: nil,
            sampleRestDurationSec: 180.0,
            roomIdentifier: "LAB_01",
            fixtureVersion: "MODE_B_ADJ_v01",
            fixtureMode: "MODE_B",
            couplingForceSetting: "NOMINAL",
            expectedCouplingForceSetting: "NOMINAL",
            addedDeadweightG: nil,
            deadweightAttachmentLocation: nil,
            deadweightMethod: nil,
            iphoneModel: "iPhone 15 Pro",
            hardwareModelIdentifier: "iPhone16,1",
            iosVersion: "19.0",
            appVersion: "0.1.2",
            deviceCode: "IOS_DEV_01",
            caseStatus: "NONE",
            batteryLevel: 0.9,
            chargingState: "UNPLUGGED",
            thermalState: "NOMINAL",
            deviceOrientation: "PORTRAIT",
            requestedAudioMode: "measurement",
            verifiedAudioMode: "measurement",
            requestedSampleRateHz: 48_000,
            verifiedSampleRateHz: 48_000,
            selectedInputPort: "Built-In Microphone",
            verifiedInputPort: "Built-In Microphone",
            selectedMicDatasource: "Bottom",
            verifiedMicDatasource: "Bottom",
            selectedPolarPattern: "Omnidirectional",
            verifiedPolarPattern: "Omnidirectional",
            verifiedOutputPort: "Built-In Speaker",
            inputChannelCount: 1,
            outputChannelCount: 1,
            reportedSpeakerChannelMapping: "Speaker(1ch)",
            targetHardwareVolume: 0.65,
            preScanHardwareVolume: 0.65,
            postScanHardwareVolume: 0.65,
            softwareWaveformAmplitudeDBFS: -6.0,
            inputLatencySec: 0.005,
            outputLatencySec: 0.005,
            ioBufferDurationSec: 0.005,
            routeProfileVerified: true,
            excitationSignalID: "SIG_ESS_v1",
            excitationWavSHA256: "9767b1b06b3d1ca6595eb753d615812646b2c62e903956edd89c6a7441109da4",
            recordingFormat: "WAV_IEEE_FLOAT32",
            repetitionNumber: 1,
            excitationStartHostTimeS: 10.0,
            excitationEndHostTimeS: 10.2,
            cooldownSec: 2.0,
            peakDBFS: -12.0,
            preRollRMSDBFS: -68.0,
            qualityStatus: "PROVISIONALLY_ACCEPTED",
            sessionValidityState: "SESSION_OPEN",
            finalScanValidity: "PROVISIONALLY_ACCEPTED",
            qualityFlags: [],
            rawAudioFilename: committed.filename,
            rawAudioSHA256: committed.sha256,
            featureRecordID: nil,
            calibrationID: "CAL_SESS_EXP_01",
            operatorNotes: nil
        )

        try await store.appendScanRecord(rec, sessionID: "SESS_EXP_01")
        try await store.updateSessionValidity(sessionID: "SESS_EXP_01", sessionValidityState: "SESSION_VALID")

        let sessionDir = try await store.sessionDirectory(sessionID: "SESS_EXP_01")
        let jsonlText = try String(contentsOf: sessionDir.appendingPathComponent("scans.jsonl"), encoding: .utf8)
        XCTAssertTrue(jsonlText.contains("\"blind_code\":null") || jsonlText.contains("\"blind_code\" : null"))
        XCTAssertTrue(jsonlText.contains("\"final_scan_validity\":\"FINAL_ACCEPTED\""))

        let auditURL = tempRoot.appendingPathComponent("transitions.jsonl")
        let logger = AuditLogger(logFileURL: auditURL)
        try logger.append(TransitionAuditRecord(
            timestamp: Date(),
            previousState: .unconfigured,
            nextState: .configuring,
            event: "configureRequested"
        ))

        let records = await store.records(forSession: "SESS_EXP_01")
        let exportRoot = tempRoot.appendingPathComponent("Exports", isDirectory: true)
        let bundleURL = try ExportManager().exportSessionBundle(
            studyID: "CS_TEST",
            sessionID: "SESS_EXP_01",
            sessionValidityState: "SESSION_VALID",
            protocolConfiguration: .phase1v12,
            baselineProfile: nil,
            sessionDirectoryURL: sessionDir,
            auditLogURL: auditURL,
            waveformRepository: wfRepo,
            records: records,
            exportRootURL: exportRoot
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("bundle_manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("scans.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("reference_waveforms/SIG_ESS_v1.wav").path))
    }
}
