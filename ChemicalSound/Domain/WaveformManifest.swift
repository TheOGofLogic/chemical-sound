import Foundation

public struct WaveformManifest: Codable, Sendable, Equatable {
    public let manifestVersion: String
    public let protocolID: String
    public let specVersion: String?
    public let waveformVersion: String?
    public let sampleRateHz: Double
    public let assets: [WaveformAsset]

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case protocolID = "protocol_id"
        case specVersion = "spec_version"
        case waveformVersion = "waveform_version"
        case sampleRateHz = "sample_rate_hz"
        case assets
    }

    public func asset(withID assetID: String) -> WaveformAsset? {
        assets.first { $0.assetID == assetID }
    }
}

public struct WaveformAsset: Codable, Identifiable, Sendable, Equatable {
    public let assetID: String
    public let role: String
    public let filename: String
    public let sha256: String
    public let durationMs: Int
    public let numFrames: Int?
    public let channels: Int
    public let format: String

    public var id: String { assetID }

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case role
        case filename
        case sha256
        case durationMs = "duration_ms"
        case numFrames = "num_frames"
        case channels
        case format
    }
}
