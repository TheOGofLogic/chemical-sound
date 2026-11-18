import AVFAudio
import XCTest
@testable import LiquidAnalyzer

final class QualityControlTests: XCTestCase {
    private func writeTestWAV(
        to url: URL,
        preRollAmp: Float = 0.0004,
        activeAmp: Float = 0.15,
        postRollAmp: Float = 0.001,
        injectClip: Bool = false
    ) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let totalFrames: AVAudioFrameCount = 24_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)!
        buffer.frameLength = totalFrames
        let ptr = buffer.floatChannelData![0]

        for i in 0..<Int(totalFrames) {
            let phase = Float(2.0 * Double.pi * 1_000.0 * Double(i) / 48_000.0)
            if i < 7_200 {
                ptr[i] = preRollAmp * sin(phase)
            } else if i < 16_800 {
                ptr[i] = activeAmp * sin(phase)
            } else {
                ptr[i] = postRollAmp * sin(phase)
            }
        }
        if injectClip {
            ptr[9_000] = 0.99
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func baseRuntimeProfile(volume: Float = 0.65) -> AudioRuntimeProfile {
        AudioRuntimeProfile(
            capturedAt: Date(),
            commercialModelName: "iPhone 15 Pro",
            hardwareModelIdentifier: "iPhone16,1",
            iosVersion: "19.0",
            appVersion: "0.1.2",
            deviceCode: "IOS_DEV_01",
            caseStatus: "NONE",
            batteryLevel: 0.9,
            chargingState: "UNPLUGGED",
            thermalState: "NOMINAL",
            deviceOrientation: "PORTRAIT",
            requestedCategory: "AVAudioSessionCategoryPlayAndRecord",
            actualCategory: "AVAudioSessionCategoryPlayAndRecord",
            requestedMode: "AVAudioSessionModeMeasurement",
            actualMode: "AVAudioSessionModeMeasurement",
            requestedSampleRate: 48_000,
            actualSampleRate: 48_000,
            availableInputPorts: ["MicrophoneBuiltIn"],
            availableMicDataSources: ["Bottom"],
            availablePolarPatterns: ["Omnidirectional"],
            inputPortTypes: ["MicrophoneBuiltIn"],
            outputPortTypes: ["Speaker"],
            inputPortNames: ["Built-In Microphone"],
            outputPortNames: ["Built-In Speaker"],
            requestedInputDataSource: "Bottom",
            selectedInputDataSource: "Bottom",
            requestedPolarPattern: "Omnidirectional",
            selectedPolarPattern: "Omnidirectional",
            inputChannelCount: 1,
            outputChannelCount: 1,
            reportedSpeakerChannelMapping: "Speaker(1ch)",
            inputLatencySeconds: 0.005,
            outputLatencySeconds: 0.005,
            ioBufferDurationSeconds: 0.005,
            outputVolume: volume
        )
    }

    private func validSampleMetadata() -> SampleMetadata {
        SampleMetadata(
            studyID: "CS_TEST",
            sessionID: "SESS_01",
            operatorID: "OP_01",
            scanStage: .gate0B,
            excitationSignal: .ess,
            sampleID: "SMP_01",
            formulationID: "H2O_DIST",
            preparationBatchID: "B01",
            containerID: "PP_01",
            bubbleFoamFlag: "NONE",
            positionConfirmed: true,
            nominalVolumeML: 15.0,
            measuredMassG: 15.0,
            sampleTemperatureC: 22.0,
            sampleRestDurationSec: 185.0
        )
    }

    func testCleanRecordingIsProvisionallyAccepted() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CS_QC_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("clean.wav")
        try writeTestWAV(to: wavURL)

        let qc = QualityControlEngine()
        let prof = baseRuntimeProfile()
        let res = try qc.evaluate(
            recordingURL: wavURL,
            metadata: validSampleMetadata(),
            preProfile: prof,
            postProfile: prof,
            activeExcitationDurationMs: 200,
            protocolConfiguration: .phase1v12,
            previousExcitationEndUptime: 10.0,
            currentExcitationStartUptime: 12.5
        )
        XCTAssertEqual(res.qualityStatus, "PROVISIONALLY_ACCEPTED")
        XCTAssertTrue(res.flags.isEmpty)
    }

    func testClippingAndCooldownViolationAreRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CS_QCClip_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("clipped.wav")
        try writeTestWAV(to: wavURL, injectClip: true)

        let qc = QualityControlEngine()
        let prof = baseRuntimeProfile()
        let res = try qc.evaluate(
            recordingURL: wavURL,
            metadata: validSampleMetadata(),
            preProfile: prof,
            postProfile: prof,
            activeExcitationDurationMs: 200,
            protocolConfiguration: .phase1v12,
            previousExcitationEndUptime: 10.0,
            currentExcitationStartUptime: 10.8  // < 2.0 s cooldown!
        )
        XCTAssertEqual(res.qualityStatus, "REJECTED")
        XCTAssertTrue(res.flags.contains(.clipping))
        XCTAssertTrue(res.flags.contains(.cooldownViolation))
    }
}
