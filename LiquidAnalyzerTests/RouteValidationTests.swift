import XCTest
@testable import LiquidAnalyzer

final class RouteValidationTests: XCTestCase {
    private func validProfile(
        sampleRate: Double = 48_000,
        outputPortType: String = "Speaker",
        outputPortName: String = "Built-In Speaker",
        volume: Float = 0.65
    ) -> AudioRuntimeProfile {
        AudioRuntimeProfile(
            capturedAt: Date(),
            commercialModelName: "iPhone 15 Pro",
            hardwareModelIdentifier: "iPhone16,1",
            iosVersion: "19.0",
            appVersion: "0.1.2",
            deviceCode: "IOS_DEV_TEST01",
            caseStatus: "NONE",
            batteryLevel: 0.85,
            chargingState: "UNPLUGGED",
            thermalState: "NOMINAL",
            deviceOrientation: "PORTRAIT",
            requestedCategory: "AVAudioSessionCategoryPlayAndRecord",
            actualCategory: "AVAudioSessionCategoryPlayAndRecord",
            requestedMode: "AVAudioSessionModeMeasurement",
            actualMode: "AVAudioSessionModeMeasurement",
            requestedSampleRate: 48_000,
            actualSampleRate: sampleRate,
            availableInputPorts: ["MicrophoneBuiltIn"],
            availableMicDataSources: ["Bottom"],
            availablePolarPatterns: ["Omnidirectional"],
            inputPortTypes: ["MicrophoneBuiltIn"],
            outputPortTypes: [outputPortType],
            inputPortNames: ["Built-In Microphone"],
            outputPortNames: [outputPortName],
            requestedInputDataSource: "Bottom",
            selectedInputDataSource: "Bottom",
            requestedPolarPattern: "Omnidirectional",
            selectedPolarPattern: "Omnidirectional",
            inputChannelCount: 1,
            outputChannelCount: 1,
            reportedSpeakerChannelMapping: "Speaker(1ch)",
            inputLatencySeconds: 0.005,
            outputLatencySeconds: 0.005,
            ioBufferDurationSeconds: 0.0053,
            outputVolume: volume
        )
    }

    func testValidBuiltInMeasurementRoutePasses() throws {
        let validator = AudioRouteValidator()
        let profile = validProfile()
        XCTAssertNoThrow(try validator.validateConfiguration(profile: profile, protocolConfiguration: .phase1v12))
        XCTAssertNoThrow(try validator.validateOutputVolume(actualVolume: profile.outputVolume, protocolConfiguration: .phase1v12))
    }

    func testBluetoothAirPodsRouteIsRejected() {
        let validator = AudioRouteValidator()
        let btProfile = validProfile(
            outputPortType: "BluetoothA2DPOutput",
            outputPortName: "AirPods Pro"
        )
        XCTAssertThrowsError(
            try validator.validateConfiguration(profile: btProfile, protocolConfiguration: .phase1v12)
        )
    }

    func testSampleRateAndVolumeMismatchesAreFlagged() {
        let validator = AudioRouteValidator()
        let badRate = validProfile(sampleRate: 44_100)
        XCTAssertThrowsError(
            try validator.validateConfiguration(profile: badRate, protocolConfiguration: .phase1v12)
        )

        let badVol = validProfile(volume: 0.75)
        XCTAssertThrowsError(
            try validator.validateOutputVolume(actualVolume: badVol.outputVolume, protocolConfiguration: .phase1v12)
        )

        let flags = validator.qualityFlags(
            preProfile: validProfile(),
            postProfile: badVol,
            protocolConfiguration: .phase1v12,
            isSilenceControl: false
        )
        XCTAssertTrue(flags.contains(.volumeMismatch))
    }
}
