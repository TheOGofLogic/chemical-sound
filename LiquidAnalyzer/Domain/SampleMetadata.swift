import Foundation

public enum ScanStage: String, Codable, CaseIterable, Sendable {
    case gate0A = "GATE_0A"
    case gate0B = "GATE_0B"
    case blank = "BLANK"
    case p1a = "P1A"
    case p1b = "P1B"
    case p1c = "P1C"
    case p1d = "P1D"
}

public enum ExcitationSignalChoice: String, Codable, CaseIterable, Sendable {
    case ess = "SIG_ESS_v1"
    case steppedTones = "SIG_STEP_v1"
    case silence = "SIG_SIL_v1"
}

/// Captures study, session, adjustable Mode B fixture, and sample metadata without unblinding locked runs.
public struct SampleMetadata: Codable, Sendable, Equatable {
    public var studyID: String
    public var sessionID: String
    public var operatorID: String
    public var roomIdentifier: String
    public var scanStage: ScanStage
    public var excitationSignal: ExcitationSignalChoice

    public var sampleID: String
    public var blindCode: String?
    public var isBlindedRun: Bool
    public var liquidClass: String?
    public var formulationID: String?
    public var preparationBatchID: String?
    public var concentrationValue: Double?
    public var concentrationUnit: String?
    public var preparationMethod: String?
    public var preparationTimestampISO: String?
    public var fillTimestampISO: String?

    public var containerType: String?
    public var containerProductNumber: String?
    public var containerLot: String?
    public var containerID: String?
    public var isHeldOutContainer: Bool
    public var capClosureState: String?
    public var bubbleFoamFlag: String
    public var positionConfirmed: Bool

    public var nominalVolumeML: Double?
    public var measuredMassG: Double?
    public var fillHeightMM: Double?
    public var headspaceHeightMM: Double?

    public var sampleTemperatureC: Double?
    public var tempMeasurementMethod: String?
    public var tempMeasurementTiming: String?
    public var ambientTemperatureC: Double?
    public var ambientHumidityPct: Double?
    public var sampleRestDurationSec: Double?

    /// Adjustable Milestone 3C Mode B fixture parameters
    public var fixtureVersion: String
    public var fixtureMode: String
    public var couplingForceSetting: String
    public var expectedCouplingForceSetting: String?
    public var addedDeadweightG: Double?
    public var deadweightAttachmentLocation: String?
    public var deadweightMethod: String?
    public var calibrationID: String?
    public var operatorNotes: String?

    public init(
        studyID: String,
        sessionID: String,
        operatorID: String,
        roomIdentifier: String = "LAB_BENCH_01",
        scanStage: ScanStage = .gate0A,
        excitationSignal: ExcitationSignalChoice = .ess,
        sampleID: String,
        blindCode: String? = nil,
        isBlindedRun: Bool = false,
        liquidClass: String? = nil,
        formulationID: String? = nil,
        preparationBatchID: String? = nil,
        concentrationValue: Double? = nil,
        concentrationUnit: String? = nil,
        preparationMethod: String? = nil,
        preparationTimestampISO: String? = nil,
        fillTimestampISO: String? = nil,
        containerType: String? = "PP_THIN_WALL",
        containerProductNumber: String? = nil,
        containerLot: String? = nil,
        containerID: String? = nil,
        isHeldOutContainer: Bool = false,
        capClosureState: String? = "CAPPED_STOP",
        bubbleFoamFlag: String = "NONE",
        positionConfirmed: Bool = true,
        nominalVolumeML: Double? = nil,
        measuredMassG: Double? = nil,
        fillHeightMM: Double? = nil,
        headspaceHeightMM: Double? = nil,
        sampleTemperatureC: Double? = nil,
        tempMeasurementMethod: String? = nil,
        tempMeasurementTiming: String? = "PRE_SETTLE",
        ambientTemperatureC: Double? = nil,
        ambientHumidityPct: Double? = nil,
        sampleRestDurationSec: Double? = nil,
        fixtureVersion: String = "MODE_B_ADJ_v01",
        fixtureMode: String = "MODE_B",
        couplingForceSetting: String = "NOMINAL",
        expectedCouplingForceSetting: String? = "NOMINAL",
        addedDeadweightG: Double? = nil,
        deadweightAttachmentLocation: String? = nil,
        deadweightMethod: String? = nil,
        calibrationID: String? = nil,
        operatorNotes: String? = nil
    ) {
        self.studyID = studyID
        self.sessionID = sessionID
        self.operatorID = operatorID
        self.roomIdentifier = roomIdentifier
        self.scanStage = scanStage
        self.excitationSignal = excitationSignal
        self.sampleID = sampleID
        self.blindCode = blindCode
        self.isBlindedRun = isBlindedRun
        self.liquidClass = liquidClass
        self.formulationID = formulationID
        self.preparationBatchID = preparationBatchID
        self.concentrationValue = concentrationValue
        self.concentrationUnit = concentrationUnit
        self.preparationMethod = preparationMethod
        self.preparationTimestampISO = preparationTimestampISO
        self.fillTimestampISO = fillTimestampISO
        self.containerType = containerType
        self.containerProductNumber = containerProductNumber
        self.containerLot = containerLot
        self.containerID = containerID
        self.isHeldOutContainer = isHeldOutContainer
        self.capClosureState = capClosureState
        self.bubbleFoamFlag = bubbleFoamFlag
        self.positionConfirmed = positionConfirmed
        self.nominalVolumeML = nominalVolumeML
        self.measuredMassG = measuredMassG
        self.fillHeightMM = fillHeightMM
        self.headspaceHeightMM = headspaceHeightMM
        self.sampleTemperatureC = sampleTemperatureC
        self.tempMeasurementMethod = tempMeasurementMethod
        self.tempMeasurementTiming = tempMeasurementTiming
        self.ambientTemperatureC = ambientTemperatureC
        self.ambientHumidityPct = ambientHumidityPct
        self.sampleRestDurationSec = sampleRestDurationSec
        self.fixtureVersion = fixtureVersion
        self.fixtureMode = fixtureMode
        self.couplingForceSetting = couplingForceSetting
        self.expectedCouplingForceSetting = expectedCouplingForceSetting
        self.addedDeadweightG = addedDeadweightG
        self.deadweightAttachmentLocation = deadweightAttachmentLocation
        self.deadweightMethod = deadweightMethod
        self.calibrationID = calibrationID
        self.operatorNotes = operatorNotes
    }

    public var isLiquidSample: Bool {
        scanStage != .blank && excitationSignal != .silence
    }

    public func missingRequiredFields() -> [String] {
        var missing: [String] = []
        if studyID.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("study_id") }
        if sessionID.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("session_id") }
        if operatorID.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("operator_id") }
        if sampleID.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("sample_id") }

        if isLiquidSample && scanStage != .gate0A {
            if (containerID ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                missing.append("container_id")
            }
            if nominalVolumeML == nil { missing.append("nominal_volume_ml") }
            if measuredMassG == nil { missing.append("measured_mass_g") }
            if sampleTemperatureC == nil { missing.append("sample_temperature_c") }
            if !isBlindedRun {
                if (formulationID ?? "").isEmpty { missing.append("formulation_id") }
                if (preparationBatchID ?? "").isEmpty { missing.append("preparation_batch_id") }
            }
        }
        return missing
    }
}
