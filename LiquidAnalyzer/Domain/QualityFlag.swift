import Foundation

/// Quality-control flags harmonized with Python schema_qc.py (CS-SPEC-P1-v1.2).
public enum QualityFlag: String, Codable, CaseIterable, Sendable {
    case backgroundNoise = "BACKGROUND_NOISE"
    case clipping = "CLIPPING"
    case interruptedAudio = "INTERRUPTED_AUDIO"
    case lowSignal = "LOW_SIGNAL"
    case positionNotConfirmed = "POSITION_NOT_CONFIRMED"
    case temperatureMissing = "TEMPERATURE_MISSING"
    case protocolMismatch = "PROTOCOL_MISMATCH"
    case volumeMismatch = "VOLUME_MISMATCH"
    case audioRouteInvalid = "AUDIO_ROUTE_INVALID"
    case sampleRateMismatch = "SAMPLE_RATE_MISMATCH"
    case channelConfigurationMismatch = "CHANNEL_CONFIGURATION_MISMATCH"
    case inputDataSourceMismatch = "INPUT_DATASOURCE_MISMATCH"
    case highIntraBatchVariance = "HIGH_INTRA_BATCH_VARIANCE"
    case insufficientSettleTime = "INSUFFICIENT_SETTLE_TIME"
    case visibleBubbles = "VISIBLE_BUBBLES"
    case fixtureForceMismatch = "FIXTURE_FORCE_MISMATCH"
    case cooldownViolation = "COOLDOWN_VIOLATION"
    case calibrationDrift = "CALIBRATION_DRIFT"
    case fileWriteFailure = "FILE_WRITE_FAILURE"
    case metadataIncomplete = "METADATA_INCOMPLETE"
    case waveformIntegrityFailure = "WAVEFORM_INTEGRITY_FAILURE"
    case incompleteDuration = "INCOMPLETE_DURATION"
}
