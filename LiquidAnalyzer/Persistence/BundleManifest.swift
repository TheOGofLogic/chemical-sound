import Foundation

public struct BundleManifest: Codable, Sendable, Equatable {
    public let bundleVersion: String
    public let createdAtISO: String
    public let datasetVersion: String
    public let specVersion: String
    public let protocolConfiguration: ResearchProtocol
    public let studyID: String
    public let sessionID: String
    public let sessionValidityState: String
    public let appVersion: String
    public let operatingSystemVersion: String
    public let baselineRuntimeProfile: AudioRuntimeProfile?
    public let totalRecordedScans: Int
    public let provisionallyAcceptedScans: Int
    public let rejectedOrInvalidScans: Int
    public let fileChecksumsSHA256: [String: String]

    enum CodingKeys: String, CodingKey {
        case bundleVersion = "bundle_version"
        case createdAtISO = "created_at_iso"
        case datasetVersion = "dataset_version"
        case specVersion = "spec_version"
        case protocolConfiguration = "protocol_configuration"
        case studyID = "study_id"
        case sessionID = "session_id"
        case sessionValidityState = "session_validity_state"
        case appVersion = "app_version"
        case operatingSystemVersion = "operating_system_version"
        case baselineRuntimeProfile = "baseline_runtime_profile"
        case totalRecordedScans = "total_recorded_scans"
        case provisionallyAcceptedScans = "provisionally_accepted_scans"
        case rejectedOrInvalidScans = "rejected_or_invalid_scans"
        case fileChecksumsSHA256 = "file_checksums_sha256"
    }
}
