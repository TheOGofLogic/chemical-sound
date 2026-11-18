import AVFAudio
import Foundation
#if canImport(UIKit)
import UIKit
#endif

public actor AudioSessionController {
    private let routeValidator = AudioRouteValidator()
    private let persistentDeviceCode: String

    public init() {
        let primaryKey = "liquid_analyzer.research_device_code"
        if let existing = UserDefaults.standard.string(forKey: primaryKey) {
            self.persistentDeviceCode = existing
        } else {
            let generated = "IOS_DEV_" + UUID().uuidString.prefix(8).uppercased()
            UserDefaults.standard.set(generated, forKey: primaryKey)
            self.persistentDeviceCode = generated
        }
    }

    public func requestMicrophonePermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        return true
        #endif
    }

    public func configure(
        protocol configuration: ResearchProtocol,
        caseStatus: String = "NONE"
    ) async throws -> AudioRuntimeProfile {
        let granted = await requestMicrophonePermission()
        guard granted else {
            throw AcquisitionFailure.microphonePermissionDenied
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()

        // Deactivate non-fatally if previously active
        try? session.setActive(false)

        // 1. Set .playAndRecord + .measurement (fall back cleanly if iOS rejects .defaultToSpeaker with .measurement -> OSStatus -50)
        do {
            if configuration.preferBottomSpeakerOverride {
                do {
                    try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
                } catch {
                    try session.setCategory(.playAndRecord, mode: .measurement, options: [])
                }
            } else {
                try session.setCategory(.playAndRecord, mode: .measurement, options: [])
            }
        } catch {
            throw AcquisitionFailure.audioEngineFailure("AVAudioSession setCategory(.measurement) failed: \(error)")
        }

        // 2. Request preferred sample rate prior to activation (negotiated preference)
        try? session.setPreferredSampleRate(configuration.requestedSampleRateHz)

        // 3. Activate session BEFORE querying/setting input ports, data sources, or channel counts (avoids OSStatus -50 on iPhone15,3)
        do {
            try session.setActive(true)
        } catch {
            throw AcquisitionFailure.audioEngineFailure("AVAudioSession setActive(true) failed: \(error)")
        }

        if configuration.preferBottomSpeakerOverride {
            try? session.overrideOutputAudioPort(.speaker)
        }

        guard let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            throw AcquisitionFailure.unsupportedAudioRoute("Built-in microphone unavailable.")
        }

        var requestedDataSourceName: String?
        var requestedPolarPatternName: String?

        // 4. Negotiate preferred built-in mic, data source, polar pattern, and mono channel counts post-activation
        try? session.setPreferredInput(builtInMic)
        if let dataSources = builtInMic.dataSources,
           let selected = preferredDataSource(from: dataSources) {
            requestedDataSourceName = selected.dataSourceName
            if selected.supportedPolarPatterns?.contains(.omnidirectional) == true {
                try? selected.setPreferredPolarPattern(.omnidirectional)
                requestedPolarPatternName = AVAudioSession.PolarPattern.omnidirectional.rawValue
            } else {
                try? selected.setPreferredPolarPattern(nil)
            }
            try? builtInMic.setPreferredDataSource(selected)
        }

        if session.maximumInputNumberOfChannels >= configuration.requestedInputChannels {
            try? session.setPreferredInputNumberOfChannels(configuration.requestedInputChannels)
        }
        if session.maximumOutputNumberOfChannels >= 1 {
            try? session.setPreferredOutputNumberOfChannels(1)
        }

        let profile = await makeRuntimeProfile(
            configuration,
            caseStatus: caseStatus,
            requestedDataSourceName: requestedDataSourceName,
            requestedPolarPatternName: requestedPolarPatternName
        )
        try routeValidator.validateConfiguration(profile: profile, protocolConfiguration: configuration)
        return profile
        #else
        let profile = makeSimulatedHostProfile(configuration, caseStatus: caseStatus)
        try routeValidator.validateConfiguration(profile: profile, protocolConfiguration: configuration)
        return profile
        #endif
    }

    /// Deterministic measurement-mode audio configuration using built-in bottom speaker + omnidirectional mic.
    /// Uses `.measurement` mode to disable iOS adaptive AGC, voice echo cancellation, and multi-mic beamforming
    /// so repeated scans of the same container produce repeatable physical waveforms.
    public func configureForConsumerScan() async throws -> (sampleRateHz: Double, outputVolume: Float) {
        let granted = await requestMicrophonePermission()
        guard granted else {
            throw AcquisitionFailure.microphonePermissionDenied
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()

        do {
            do {
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            } catch {
                try session.setCategory(.playAndRecord, mode: .measurement, options: [])
            }
            try? session.setPreferredSampleRate(48_000.0)
            try? session.setPreferredIOBufferDuration(0.010)
            try session.setActive(true)
        } catch {
            throw AcquisitionFailure.audioEngineFailure("Unable to activate measurement audio session: \(error)")
        }

        // Reject external headphones/Bluetooth so speaker-to-mic acoustic sweep uses built-in transducers
        let route = session.currentRoute
        let portNamesAndTypes = route.outputs.map { $0.portType.rawValue + " " + $0.portName }
            + route.inputs.map { $0.portType.rawValue + " " + $0.portName }
        for portDesc in portNamesAndTypes {
            let lower = portDesc.lowercased()
            if AudioRouteValidator.prohibitedPortSubstrings.contains(where: { lower.contains($0) }) {
                throw AcquisitionFailure.externalAudioRoute(portDesc)
            }
        }

        try? session.overrideOutputAudioPort(.speaker)
        if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtInMic)
            if let dataSources = builtInMic.dataSources,
               let bottomOmni = preferredDataSource(from: dataSources) {
                if bottomOmni.supportedPolarPatterns?.contains(.omnidirectional) == true {
                    try? bottomOmni.setPreferredPolarPattern(.omnidirectional)
                }
                try? builtInMic.setPreferredDataSource(bottomOmni)
            }
        }

        // Allow CoreAudio measurement route & fixed hardware gain to settle before starting AVAudioEngine
        try? await Task.sleep(for: .milliseconds(100))

        let rate = session.sampleRate > 0 ? session.sampleRate : 48_000.0
        return (rate, session.outputVolume)
        #else
        return (48_000.0, 0.65)
        #endif
    }

    public func deactivate() throws {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    public func currentOutputVolume() -> Float {
        #if os(iOS)
        return AVAudioSession.sharedInstance().outputVolume
        #else
        return 0.65
        #endif
    }

    public func currentRuntimeProfile(
        protocol configuration: ResearchProtocol,
        caseStatus: String = "NONE"
    ) async -> AudioRuntimeProfile {
        #if os(iOS)
        return await makeRuntimeProfile(
            configuration,
            caseStatus: caseStatus,
            requestedDataSourceName: nil,
            requestedPolarPatternName: nil
        )
        #else
        return makeSimulatedHostProfile(configuration, caseStatus: caseStatus)
        #endif
    }

    #if os(iOS)
    private func preferredDataSource(
        from sources: [AVAudioSessionDataSourceDescription]
    ) -> AVAudioSessionDataSourceDescription? {
        sources.first {
            $0.dataSourceName.lowercased().contains("bottom") &&
            ($0.supportedPolarPatterns?.contains(.omnidirectional) ?? true)
        } ?? sources.first {
            $0.supportedPolarPatterns?.contains(.omnidirectional) == true
        } ?? sources.first
    }

    private func makeRuntimeProfile(
        _ configuration: ResearchProtocol,
        caseStatus: String,
        requestedDataSourceName: String?,
        requestedPolarPatternName: String?
    ) async -> AudioRuntimeProfile {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let allInputs = session.availableInputs ?? []
        let builtInMic = allInputs.first(where: { $0.portType == .builtInMic })
        let micSources = builtInMic?.dataSources ?? []
        let polars = session.inputDataSource?.supportedPolarPatterns?.map(\.rawValue) ?? []

        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.2"
        let thermal = Self.describeThermalState(ProcessInfo.processInfo.thermalState)

        var modelName = "iPhone"
        var osVer = ProcessInfo.processInfo.operatingSystemVersionString
        var battLevel: Float?
        var chargeStr = "UNKNOWN"
        var orientStr = "UNKNOWN"

        #if canImport(UIKit)
        let uiSnapshot = await MainActor.run { () -> (String, String, Float?, String, String) in
            UIDevice.current.isBatteryMonitoringEnabled = true
            let name = UIDevice.current.name
            let ver = UIDevice.current.systemVersion
            let rawBatt = UIDevice.current.batteryLevel
            let batt: Float? = rawBatt >= 0 ? rawBatt : nil
            let charge: String
            switch UIDevice.current.batteryState {
            case .unplugged: charge = "UNPLUGGED"
            case .charging: charge = "CHARGING"
            case .full: charge = "FULL"
            default: charge = "UNKNOWN"
            }
            let orient = String(describing: UIDevice.current.orientation.rawValue)
            return (name, ver, batt, charge, orient)
        }
        modelName = uiSnapshot.0
        osVer = uiSnapshot.1
        battLevel = uiSnapshot.2
        chargeStr = uiSnapshot.3
        orientStr = uiSnapshot.4
        #endif

        return AudioRuntimeProfile(
            capturedAt: Date(),
            commercialModelName: modelName,
            hardwareModelIdentifier: Self.hardwareMachineIdentifier(),
            iosVersion: osVer,
            appVersion: appVer,
            deviceCode: persistentDeviceCode,
            caseStatus: caseStatus,
            batteryLevel: battLevel,
            chargingState: chargeStr,
            thermalState: thermal,
            deviceOrientation: orientStr,
            requestedCategory: AVAudioSession.Category.playAndRecord.rawValue,
            actualCategory: session.category.rawValue,
            requestedMode: AVAudioSession.Mode.measurement.rawValue,
            actualMode: session.mode.rawValue,
            requestedSampleRate: configuration.requestedSampleRateHz,
            actualSampleRate: session.sampleRate,
            availableInputPorts: allInputs.map { "\($0.portType.rawValue):\($0.portName)" },
            availableMicDataSources: micSources.map(\.dataSourceName),
            availablePolarPatterns: polars,
            inputPortTypes: route.inputs.map(\.portType.rawValue),
            outputPortTypes: route.outputs.map(\.portType.rawValue),
            inputPortNames: route.inputs.map(\.portName),
            outputPortNames: route.outputs.map(\.portName),
            requestedInputDataSource: requestedDataSourceName ?? session.inputDataSource?.dataSourceName,
            selectedInputDataSource: session.inputDataSource?.dataSourceName,
            requestedPolarPattern: requestedPolarPatternName,
            selectedPolarPattern: session.inputDataSource?.selectedPolarPattern?.rawValue,
            inputChannelCount: session.inputNumberOfChannels,
            outputChannelCount: session.outputNumberOfChannels,
            reportedSpeakerChannelMapping: route.outputs.map { "\($0.portType.rawValue)(\($0.channels?.count ?? 1)ch)" }.joined(separator: "+"),
            inputLatencySeconds: session.inputLatency,
            outputLatencySeconds: session.outputLatency,
            ioBufferDurationSeconds: session.ioBufferDuration,
            outputVolume: session.outputVolume
        )
    }
    #endif

    private func makeSimulatedHostProfile(
        _ configuration: ResearchProtocol,
        caseStatus: String
    ) -> AudioRuntimeProfile {
        AudioRuntimeProfile(
            capturedAt: Date(),
            commercialModelName: "macOS-Host-Simulator",
            hardwareModelIdentifier: Self.hardwareMachineIdentifier(),
            iosVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: "0.1.2",
            deviceCode: persistentDeviceCode,
            caseStatus: caseStatus,
            batteryLevel: nil,
            chargingState: "UNPLUGGED",
            thermalState: Self.describeThermalState(ProcessInfo.processInfo.thermalState),
            deviceOrientation: "PORTRAIT",
            requestedCategory: "AVAudioSessionCategoryPlayAndRecord",
            actualCategory: "AVAudioSessionCategoryPlayAndRecord",
            requestedMode: "AVAudioSessionModeMeasurement",
            actualMode: "AVAudioSessionModeMeasurement",
            requestedSampleRate: configuration.requestedSampleRateHz,
            actualSampleRate: configuration.requestedSampleRateHz,
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
            ioBufferDurationSeconds: 0.00533,
            outputVolume: configuration.targetOutputVolume
        )
    }

    private static func hardwareMachineIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "UnknownDevice"
            }
        }
    }

    private static func describeThermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "NOMINAL"
        case .fair: return "FAIR"
        case .serious: return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "UNKNOWN"
        }
    }
}
