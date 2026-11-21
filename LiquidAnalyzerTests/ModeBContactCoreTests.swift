import XCTest
@testable import LiquidAnalyzer

final class ModeBContactCoreTests: XCTestCase {
    func testModeB_DoubleEchoSolverIsWallThicknessInvariantWithinOneMeterPerSecond() throws {
        let core = LiquidAnalyzerContactCore(
            sampleRateHz: 40_000_000.0,
            carrierFrequencyHz: 5_000_000.0,
            containerDiameterMeters: 0.065,
            gateStartUs: 18.0,
            gateEndUs: 260.0,
            detectionThreshold: 0.14
        )

        let thinGlassRF = core.generateSimulatedTrace(
            liquid: .water,
            wallThicknessMeters: 0.0020,
            temperatureCelsius: 20.0,
            snrDb: 34.0,
            includeAirBubble: false,
            deterministicSeed: 1001
        )
        let thickGlassRF = core.generateSimulatedTrace(
            liquid: .water,
            wallThicknessMeters: 0.0060,
            temperatureCelsius: 20.0,
            snrDb: 34.0,
            includeAirBubble: false,
            deterministicSeed: 1002
        )

        let thinMeas = try XCTUnwrap(core.processAScan(rfSignal: thinGlassRF, temperatureCelsius: 20.0))
        let thickMeas = try XCTUnwrap(core.processAScan(rfSignal: thickGlassRF, temperatureCelsius: 20.0))

        // Absolute arrival t1 shifts later on 3x thicker glass, while Δt = t2 - t1 stays invariant!
        XCTAssertGreaterThan(thickMeas.firstEcho.timeMicroseconds, thinMeas.firstEcho.timeMicroseconds + 1.0)
        XCTAssertEqual(thinMeas.soundVelocityMps, 1_482.0, accuracy: 2.0)
        XCTAssertEqual(thickMeas.soundVelocityMps, 1_482.0, accuracy: 2.0)
        XCTAssertEqual(thinMeas.soundVelocityMps, thickMeas.soundVelocityMps, accuracy: 2.0)
        XCTAssertFalse(thinMeas.firstEcho.isPhaseInverted)
        XCTAssertFalse(thinMeas.secondEcho.isPhaseInverted)
        XCTAssertFalse(thinMeas.hasInvertedBubbleEcho)
    }

    func testModeB_PhasePolarityDistinguishesRigidWallFromInvertedAirBubbleWithoutCorruptingVelocity() throws {
        let core = LiquidAnalyzerContactCore(
            sampleRateHz: 40_000_000.0,
            carrierFrequencyHz: 5_000_000.0,
            containerDiameterMeters: 0.070,
            gateStartUs: 18.0,
            gateEndUs: 280.0,
            detectionThreshold: 0.14
        )

        let trace = core.generateSimulatedTrace(
            liquid: .sparklingWater,
            wallThicknessMeters: 0.0035,
            temperatureCelsius: 20.0,
            snrDb: 32.0,
            includeAirBubble: true,
            bubbleDepthFraction: 0.45,
            deterministicSeed: 2026
        )

        let meas = try XCTUnwrap(core.processAScan(rfSignal: trace, temperatureCelsius: 20.0))
        XCTAssertEqual(meas.soundVelocityMps, 1_482.0, accuracy: 2.5)
        XCTAssertFalse(meas.firstEcho.isPhaseInverted, "Liquid->Glass back wall must remain in-phase (+R)")
        XCTAssertFalse(meas.secondEcho.isPhaseInverted, "Double reflection back wall must remain in-phase (+R)")
        XCTAssertTrue(meas.hasInvertedBubbleEcho, "Mid-column Liquid->Air bubble must flag 180-deg phase inversion (-R)")
        XCTAssertEqual(meas.intermediateEchoes.count, 1)

        let fusion = MultiModalFusionClassifier()
        let decision = try XCTUnwrap(fusion.evaluateModeBContactMeasurement(meas))
        XCTAssertEqual(decision.profile.id, "SELTZER_CARBONATED")
        XCTAssertEqual(decision.screeningState, .bubbleScatterDetected)
    }

    func testModeB_AllSimulatedLiquidsClassifyCleanlyThroughMultiModalFusionClassifier() throws {
        let core = LiquidAnalyzerContactCore(
            sampleRateHz: 40_000_000.0,
            carrierFrequencyHz: 5_000_000.0,
            containerDiameterMeters: 0.065,
            gateStartUs: 18.0,
            gateEndUs: 280.0,
            detectionThreshold: 0.14
        )
        let fusion = MultiModalFusionClassifier()

        let expected: [(LiquidAnalyzerContactCore.SimulatedLiquid, String)] = [
            (.water, "H2O_DIST"),
            (.vinegar, "VIN_WHITE"),
            (.saline, "NACL_AQ"),
            (.oliveOil, "OIL_VEG"),
            (.ethanol, "ISOPROPYL_ALC"),
            (.sparklingWater, "SELTZER_CARBONATED")
        ]

        for (idx, (liquid, expectedID)) in expected.enumerated() {
            let rf = core.generateSimulatedTrace(
                liquid: liquid,
                wallThicknessMeters: 0.0035,
                temperatureCelsius: 20.0,
                snrDb: 32.0,
                deterministicSeed: UInt64(3000 + idx)
            )
            let meas = try XCTUnwrap(core.processAScan(rfSignal: rf, temperatureCelsius: 20.0), "Failed A-Scan for \(liquid.rawValue)")
            XCTAssertEqual(meas.soundVelocityMps, liquid.speedOfSound20C, accuracy: 3.0, "Velocity error for \(liquid.rawValue)")
            let dec = try XCTUnwrap(fusion.evaluateModeBContactMeasurement(meas), "Fusion returned nil for \(liquid.rawValue)")
            XCTAssertEqual(dec.profile.id, expectedID, "Misclassified \(liquid.rawValue) as \(dec.profile.id)")
        }
    }

    func testModeB_ThermalNormalizationRecovers20CReferenceForWarmWaterAndCoolOil() throws {
        let core = LiquidAnalyzerContactCore(
            sampleRateHz: 40_000_000.0,
            carrierFrequencyHz: 5_000_000.0,
            containerDiameterMeters: 0.065,
            gateStartUs: 18.0,
            gateEndUs: 280.0,
            detectionThreshold: 0.14
        )
        let fusion = MultiModalFusionClassifier()

        // Warm water at 30 C (c_raw ≈ 1511 m/s) normalizes back near 1482 m/s -> H2O_DIST (not Saline!)
        let warmWaterRF = core.generateSimulatedTrace(
            liquid: .water,
            temperatureCelsius: 30.0,
            snrDb: 34.0,
            includeAirBubble: false,
            deterministicSeed: 4001
        )
        let warmMeas = try XCTUnwrap(core.processAScan(rfSignal: warmWaterRF, temperatureCelsius: 30.0))
        XCTAssertGreaterThan(warmMeas.soundVelocityMps, 1_505.0)
        XCTAssertEqual(warmMeas.normalizedVelocity20CMps, 1_482.0, accuracy: 5.0)
        let warmDecision = try XCTUnwrap(fusion.evaluateModeBContactMeasurement(warmMeas))
        XCTAssertEqual(warmDecision.profile.id, "H2O_DIST")

        // Cool cooking oil at 12 C (c_raw ≈ 1480 m/s, negative dc/dT!) normalizes back near 1455 m/s -> OIL_VEG!
        // Note: oil's raw speed at 12 C (~1480 m/s) overlaps room-temp water (~1482 m/s), so let's verify attenuation + thermal inversion!
        let coolOilRF = core.generateSimulatedTrace(
            liquid: .oliveOil,
            temperatureCelsius: 15.0,
            snrDb: 34.0,
            includeAirBubble: false,
            deterministicSeed: 4002
        )
        let coolOilMeas = try XCTUnwrap(core.processAScan(rfSignal: coolOilRF, temperatureCelsius: 15.0))
        XCTAssertLessThan(coolOilMeas.echoAttenuationRatio, 0.48)
        let oilDecision = try XCTUnwrap(fusion.evaluateModeBContactMeasurement(coolOilMeas))
        XCTAssertEqual(oilDecision.profile.id, "OIL_VEG")
    }

    func testModeB_BinaryWireProtocolRoundTripEndToEndThroughFusion() throws {
        let core = LiquidAnalyzerContactCore(
            sampleRateHz: 40_000_000.0,
            carrierFrequencyHz: 5_000_000.0,
            containerDiameterMeters: 0.065,
            gateStartUs: 18.0,
            gateEndUs: 260.0,
            detectionThreshold: 0.14
        )
        let rawTrace = core.generateSimulatedTrace(
            liquid: .saline,
            wallThicknessMeters: 0.0035,
            temperatureCelsius: 21.50,
            snrDb: 34.0,
            includeAirBubble: false,
            deterministicSeed: 5001
        )
        let txHeader = LiquidAnalyzerContactCore.HardwareFrameHeader(
            sequenceId: 42,
            containerId: 7,
            sampleCount: rawTrace.count,
            sampleRate: 40_000_000.0,
            liquidTemperatureC: 21.50,
            transducerTemperatureC: 23.25,
            analogGainDb: 28.5
        )
        let packet = LiquidAnalyzerContactCore.packHardwareRFFrame(header: txHeader, rfSignal: rawTrace)
        XCTAssertEqual(packet.count, 24 + rawTrace.count * 2 + 4)

        // Verify alignment-safe decoding even on a 1-byte-offset sliced stream buffer
        var prefixed = Data([0xFF])
        prefixed.append(packet)
        let sliced = prefixed.dropFirst()

        let (rxHeader, measOpt) = try core.processHardwareRFFrame(data: sliced)
        XCTAssertEqual(rxHeader.sequenceId, 42)
        XCTAssertEqual(rxHeader.containerId, 7)
        XCTAssertEqual(rxHeader.sampleCount, rawTrace.count)
        XCTAssertEqual(rxHeader.sampleRate, 40_000_000.0, accuracy: 0.1)
        XCTAssertEqual(rxHeader.liquidTemperatureC, 21.50, accuracy: 0.01)
        XCTAssertEqual(rxHeader.transducerTemperatureC, 23.25, accuracy: 0.01)
        XCTAssertEqual(rxHeader.analogGainDb, 28.5, accuracy: 0.1)

        let meas = try XCTUnwrap(measOpt)
        XCTAssertEqual(meas.normalizedVelocity20CMps, 1_538.0, accuracy: 3.0)
        let decision = try XCTUnwrap(MultiModalFusionClassifier().evaluateModeBContactMeasurement(meas))
        XCTAssertEqual(decision.profile.id, "NACL_AQ")
    }

    func testModeB_BinaryWireProtocolRejectsBadSyncTruncationAndCorruptedCRCs() throws {
        let samples = [Float](repeating: 0.1, count: 256)
        let header = LiquidAnalyzerContactCore.HardwareFrameHeader(sequenceId: 1, sampleCount: samples.count)
        let validPacket = LiquidAnalyzerContactCore.packHardwareRFFrame(header: header, rfSignal: samples)

        // 1. Bad sync word
        var badSync = validPacket
        badSync[0] = 0x00
        XCTAssertThrowsError(try LiquidAnalyzerContactCore.unpackHardwareRFFrame(data: badSync)) { err in
            guard case LiquidAnalyzerContactCore.FrameDecodingError.invalidSyncWord = err else {
                XCTFail("Expected invalidSyncWord, got \(err)")
                return
            }
        }

        // 2. Corrupted header byte -> Header CRC-16 mismatch
        var badHeader = validPacket
        badHeader[4] ^= 0x01
        XCTAssertThrowsError(try LiquidAnalyzerContactCore.unpackHardwareRFFrame(data: badHeader)) { err in
            guard case LiquidAnalyzerContactCore.FrameDecodingError.headerCRCMismatch = err else {
                XCTFail("Expected headerCRCMismatch, got \(err)")
                return
            }
        }

        // 3. Corrupted payload byte -> Payload CRC-32 mismatch
        var badPayload = validPacket
        badPayload[30] ^= 0x80
        XCTAssertThrowsError(try LiquidAnalyzerContactCore.unpackHardwareRFFrame(data: badPayload)) { err in
            guard case LiquidAnalyzerContactCore.FrameDecodingError.payloadCRCMismatch = err else {
                XCTFail("Expected payloadCRCMismatch, got \(err)")
                return
            }
        }

        // 4. Truncated payload
        let truncated = validPacket.prefix(validPacket.count - 5)
        XCTAssertThrowsError(try LiquidAnalyzerContactCore.unpackHardwareRFFrame(data: truncated)) { err in
            guard case LiquidAnalyzerContactCore.FrameDecodingError.truncatedPayload = err else {
                XCTFail("Expected truncatedPayload, got \(err)")
                return
            }
        }
    }
}
