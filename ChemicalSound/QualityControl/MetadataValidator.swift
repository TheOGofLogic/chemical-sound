import Foundation

public struct MetadataValidator: Sendable {
    public init() {}

    public func validate(
        metadata: SampleMetadata,
        protocolConfiguration: ResearchProtocol
    ) -> [QualityFlag] {
        var flags: [QualityFlag] = []

        if !metadata.missingRequiredFields().isEmpty {
            flags.append(.metadataIncomplete)
        }

        if metadata.isLiquidSample && metadata.scanStage != .gate0A && metadata.sampleTemperatureC == nil {
            flags.append(.temperatureMissing)
        }

        if !metadata.positionConfirmed {
            flags.append(.positionNotConfirmed)
        }

        if let expectedForce = metadata.expectedCouplingForceSetting,
           !expectedForce.isEmpty,
           metadata.couplingForceSetting != expectedForce {
            flags.append(.fixtureForceMismatch)
        }

        if metadata.isLiquidSample {
            let foam = metadata.bubbleFoamFlag.uppercased()
            if foam == "VISIBLE_FOAM" || foam == "VISIBLE_BUBBLES" {
                flags.append(.visibleBubbles)
            }

            if metadata.scanStage != .gate0A,
               let restSec = metadata.sampleRestDurationSec,
               restSec < Double(protocolConfiguration.settleDurationSeconds) {
                flags.append(.insufficientSettleTime)
            }
        }

        return flags
    }
}
