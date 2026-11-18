import Foundation

/// Pure validator for requested-vs-verified audio routes, sample rate, channels, and volume.
public struct AudioRouteValidator: Sendable {
    public static let prohibitedPortSubstrings: [String] = [
        "bluetooth",
        "airpods",
        "headphone",
        "headset",
        "usb",
        "carplay",
        "airplay",
        "hdmi",
        "lineout"
    ]

    public init() {}

    public func validateConfiguration(
        profile: AudioRuntimeProfile,
        protocolConfiguration: ResearchProtocol
    ) throws {
        // 1. Reject any prohibited external route on input or output
        for port in (profile.inputPortTypes + profile.outputPortTypes + profile.inputPortNames + profile.outputPortNames) {
            let lower = port.lowercased()
            if Self.prohibitedPortSubstrings.contains(where: { lower.contains($0) }) {
                throw AcquisitionFailure.externalAudioRoute(port)
            }
        }

        // 2. Require built-in microphone input and built-in speaker/receiver output
        let hasBuiltInInput = !profile.inputPortTypes.isEmpty && profile.inputPortTypes.allSatisfy {
            let lower = $0.lowercased()
            return lower.contains("microphonebuiltin") || lower.contains("builtinmic") || lower.contains("built-in")
        }
        let hasBuiltInOutput = !profile.outputPortTypes.isEmpty && profile.outputPortTypes.allSatisfy {
            let lower = $0.lowercased()
            return lower.contains("speaker") || lower.contains("receiver") || lower.contains("built-in")
        }

        guard hasBuiltInInput && hasBuiltInOutput else {
            throw AcquisitionFailure.unsupportedAudioRoute(
                "in=\(profile.inputPortTypes.joined(separator: ",")), out=\(profile.outputPortTypes.joined(separator: ","))"
            )
        }

        // 3. Verify negotiated mode includes measurement
        guard profile.actualMode.lowercased().contains("measurement") else {
            throw AcquisitionFailure.unsupportedAudioRoute("Expected measurement mode, got \(profile.actualMode)")
        }

        // 4. Verify negotiated sample rate == 48,000 Hz
        guard abs(profile.actualSampleRate - protocolConfiguration.requestedSampleRateHz) < 0.5 else {
            throw AcquisitionFailure.sampleRateMismatch(
                expected: protocolConfiguration.requestedSampleRateHz,
                actual: profile.actualSampleRate
            )
        }

        // 5. Verify positive channel counts
        guard profile.inputChannelCount >= 1 else {
            throw AcquisitionFailure.channelConfigurationMismatch(
                expected: protocolConfiguration.requestedInputChannels,
                actual: profile.inputChannelCount
            )
        }
        guard profile.outputChannelCount >= 1 else {
            throw AcquisitionFailure.unsupportedAudioRoute("Zero output channels reported.")
        }
    }

    public func validateOutputVolume(
        actualVolume: Float,
        protocolConfiguration: ResearchProtocol
    ) throws {
        let diff = abs(actualVolume - protocolConfiguration.targetOutputVolume)
        guard diff <= protocolConfiguration.outputVolumeTolerance else {
            throw AcquisitionFailure.volumeMismatch(
                expected: protocolConfiguration.targetOutputVolume,
                actual: actualVolume
            )
        }
    }

    public func qualityFlags(
        preProfile: AudioRuntimeProfile,
        postProfile: AudioRuntimeProfile,
        protocolConfiguration: ResearchProtocol,
        isSilenceControl: Bool
    ) -> [QualityFlag] {
        var flags: [QualityFlag] = []

        do {
            try validateConfiguration(profile: preProfile, protocolConfiguration: protocolConfiguration)
            try validateConfiguration(profile: postProfile, protocolConfiguration: protocolConfiguration)
        } catch AcquisitionFailure.sampleRateMismatch {
            flags.append(.sampleRateMismatch)
        } catch AcquisitionFailure.channelConfigurationMismatch {
            flags.append(.channelConfigurationMismatch)
        } catch {
            flags.append(.audioRouteInvalid)
        }

        if let reqDS = preProfile.requestedInputDataSource,
           let actDS = postProfile.selectedInputDataSource,
           reqDS != actDS {
            flags.append(.inputDataSourceMismatch)
        }

        if !isSilenceControl {
            let preDiff = abs(preProfile.outputVolume - protocolConfiguration.targetOutputVolume)
            let postDiff = abs(postProfile.outputVolume - protocolConfiguration.targetOutputVolume)
            if preDiff > protocolConfiguration.outputVolumeTolerance ||
               postDiff > protocolConfiguration.outputVolumeTolerance {
                flags.append(.volumeMismatch)
            }
        }

        return flags
    }
}
