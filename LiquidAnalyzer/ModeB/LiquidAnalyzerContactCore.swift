import Accelerate
import Foundation

/// Detected ultrasonic pulse-echo arrival extracted from the analytic Hilbert envelope of an RF A-Scan.
public struct AcousticEcho: Equatable, Codable, Sendable, Identifiable {
    public var id: Int { sampleIndex }
    public let sampleIndex: Int
    public let timeMicroseconds: Double
    public let amplitude: Float
    /// `false` (+R, in-phase) indicates reflection off a higher-impedance rigid boundary (liquid -> glass wall);
    /// `true` (-R, 180-degree phase inversion) indicates reflection off a lower-impedance boundary (liquid -> air bubble).
    public let isPhaseInverted: Bool

    public init(
        sampleIndex: Int,
        timeMicroseconds: Double,
        amplitude: Float,
        isPhaseInverted: Bool
    ) {
        self.sampleIndex = sampleIndex
        self.timeMicroseconds = timeMicroseconds
        self.amplitude = amplitude
        self.isPhaseInverted = isPhaseInverted
    }
}

/// Complete wall-thickness-invariant ultrasonic pulse-echo measurement (`c_liquid = 2D / (t2 - t1)`).
public struct UltrasonicMeasurement: Equatable, Sendable {
    public let transitGapMicroseconds: Double
    public let soundVelocityMps: Double
    public let normalizedVelocity20CMps: Double
    public let echoAttenuationRatio: Double
    public let attenuationDBPerCm: Double
    public let firstEcho: AcousticEcho
    public let secondEcho: AcousticEcho
    /// Any intermediate in-liquid reflections arriving before `firstEcho` (e.g., inverted-phase air micro-bubbles or suspended particles).
    public let intermediateEchoes: [AcousticEcho]
    public let sampleRateHz: Double
    public let containerDiameterMeters: Double
    public let temperatureCelsius: Double
    public let gateStartUs: Double
    public let gateEndUs: Double
    public let rawSignal: [Float]
    public let envelopeSignal: [Float]

    public var hasInvertedBubbleEcho: Bool {
        intermediateEchoes.contains(where: \.isPhaseInverted)
    }
}

/// Phase R3 `MODE_B` Direct Wall-Coupled Ultrasonic Pulse-Echo DSP Engine & Virtual Simulator.
///
/// Implements:
/// 1. Bounds-safe radix-2 `vDSP` FFT analytic Hilbert envelope extraction (`A[n] = |x[n] + j H{x[n]}|`).
/// 2. Matched-filter RF carrier polarity check distinguishing rigid wall echoes (`R > 0`, in-phase)
///    from free-boundary / air-bubble echoes (`R < 0`, 180-degree phase inverted).
/// 3. Sub-sample parabolic lag refinement + double-reflection timing (`c = 2D / (t2 - t1)`), canceling
///    container glass wall thickness and couplant layer delay automatically.
public final class LiquidAnalyzerContactCore: @unchecked Sendable {
    public let sampleRateHz: Double
    public let carrierFrequencyHz: Double
    public let containerDiameterMeters: Double

    /// Monitor Trigger Gate bounds (microseconds) rejecting front-wall dead zone and late noise.
    public var gateStartUs: Double
    public var gateEndUs: Double
    public var detectionThreshold: Float

    public init(
        sampleRateHz: Double = 40_000_000.0,
        carrierFrequencyHz: Double = 5_000_000.0,
        containerDiameterMeters: Double = 0.065,
        gateStartUs: Double = 20.0,
        gateEndUs: Double = 320.0,
        detectionThreshold: Float = 0.14
    ) {
        self.sampleRateHz = sampleRateHz
        self.carrierFrequencyHz = carrierFrequencyHz
        self.containerDiameterMeters = containerDiameterMeters
        self.gateStartUs = gateStartUs
        self.gateEndUs = gateEndUs
        self.detectionThreshold = detectionThreshold
    }

    // MARK: - 1. Hilbert Transform Analytic Envelope Extraction

    /// Computes the positive-definite analytic envelope `A[n] = |x[n] + j * H{x[n]}|` via zero-padded radix-2 `vDSP` FFT.
    public func computeEnvelope(rfSignal: [Float]) -> [Float] {
        let n = rfSignal.count
        guard n > 0 else { return [] }

        var fftLength = 1
        while fftLength < n { fftLength <<= 1 }
        let log2n = vDSP_Length(round(log2(Double(fftLength))))

        var realParts = [Float](repeating: 0.0, count: fftLength)
        var imagParts = [Float](repeating: 0.0, count: fftLength)
        for i in 0..<n {
            realParts[i] = rfSignal[i].isFinite ? rfSignal[i] : 0.0
        }

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return rfSignal.map { abs($0) }
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        realParts.withUnsafeMutableBufferPointer { rePtr in
            imagParts.withUnsafeMutableBufferPointer { imPtr in
                guard let reBase = rePtr.baseAddress, let imBase = imPtr.baseAddress else { return }
                var splitComplex = DSPSplitComplex(realp: reBase, imagp: imBase)

                // Forward FFT
                vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                // Analytic frequency-domain mask:
                // DC (0) & Nyquist (half) = 1x; positive freqs (1..<half) = 2x; negative freqs = 0x
                let half = fftLength / 2
                for i in 1..<half {
                    reBase[i] *= 2.0
                    imBase[i] *= 2.0
                }
                for i in (half + 1)..<fftLength {
                    reBase[i] = 0.0
                    imBase[i] = 0.0
                }

                // Inverse FFT
                vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_INVERSE))
            }
        }

        let scale = 1.0 / Float(fftLength)
        var envelope = [Float](repeating: 0.0, count: n)
        for i in 0..<n {
            let r = realParts[i] * scale
            let im = imagParts[i] * scale
            envelope[i] = sqrt(r * r + im * im)
        }
        return envelope
    }

    // MARK: - 2. Pulse-Echo A-Scan Solver & Boundary Polarity Discrimination

    /// Processes a digitized RF A-Scan within `[gateStartUs, gateEndUs]`, isolates the back-wall double-reflection pair
    /// (`t1`, `t2`), detects any intermediate phase-inverted bubble/particle scatterers, and solves for wall-thickness-invariant
    /// bulk sound speed `c = 2D / (t2 - t1)`.
    public func processAScan(
        rfSignal: [Float],
        temperatureCelsius: Double = 20.0
    ) -> UltrasonicMeasurement? {
        guard rfSignal.count >= 64, sampleRateHz > 0, containerDiameterMeters > 0 else { return nil }

        let envelope = computeEnvelope(rfSignal: rfSignal)
        let samplesPerPeriod = max(4, Int(round(sampleRateHz / max(100_000.0, carrierFrequencyHz))))
        let peakHalfWindow = max(12, samplesPerPeriod * 3)

        let rawStart = max(peakHalfWindow, Int(floor((gateStartUs * 1e-6) * sampleRateHz)))
        let rawEnd = min(rfSignal.count - peakHalfWindow - 1, Int(ceil((gateEndUs * 1e-6) * sampleRateHz)))
        guard rawEnd > rawStart + 4 else { return nil }

        // 1. Detect all distinct local envelope maxima above threshold inside the monitor gate
        var detectedEchoes: [AcousticEcho] = []
        var idx = rawStart
        while idx < rawEnd {
            let val = envelope[idx]
            if val > detectionThreshold {
                var isMax = true
                for w in -peakHalfWindow...peakHalfWindow where w != 0 {
                    if envelope[idx + w] > val || (w < 0 && envelope[idx + w] >= val) {
                        isMax = false
                        break
                    }
                }
                if isMax {
                    let refinedSample = Self.parabolicPeakIndex(envelope: envelope, index: idx)
                    let timeUs = (refinedSample / sampleRateHz) * 1e6
                    let inverted = detectPhaseInversion(rfSignal: rfSignal, centerIndex: idx)
                    detectedEchoes.append(
                        AcousticEcho(
                            sampleIndex: idx,
                            timeMicroseconds: timeUs,
                            amplitude: val,
                            isPhaseInverted: inverted
                        )
                    )
                    idx += peakHalfWindow
                    continue
                }
            }
            idx += 1
        }

        guard detectedEchoes.count >= 2 else { return nil }

        // 2. Isolate the physical double-reflection back-wall pair (t1, t2):
        //    Prefer non-inverted (rigid-wall) echoes whose spacing Δt = t2 - t1 falls within physical liquid velocities
        //    [950 .. 2,100 m/s] and whose ratio t2 / t1 ≈ 2.0 (tolerant of glass wall offset).
        let minDeltaUs = ((2.0 * containerDiameterMeters) / 2_100.0) * 1e6
        let maxDeltaUs = ((2.0 * containerDiameterMeters) / 950.0) * 1e6

        let backWallCandidates = detectedEchoes.filter { !$0.isPhaseInverted }
        let searchPool = backWallCandidates.count >= 2 ? backWallCandidates : detectedEchoes

        var bestPair: (first: AcousticEcho, second: AcousticEcho, score: Double)?
        for i in 0..<searchPool.count {
            for j in (i + 1)..<searchPool.count {
                let e1 = searchPool[i]
                let e2 = searchPool[j]
                let dtUs = e2.timeMicroseconds - e1.timeMicroseconds
                guard dtUs >= minDeltaUs && dtUs <= maxDeltaUs else { continue }
                // Physical reverberation check: t1 ≈ wallDelay + dtUs and t2 ≈ wallDelay + 2*dtUs => t1/dtUs ≈ 1.0..1.30
                let ratioToDelta = e1.timeMicroseconds / max(1e-6, dtUs)
                guard ratioToDelta >= 0.65 && ratioToDelta <= 1.55 else { continue }
                let amplitudeScore = Double(e1.amplitude + e2.amplitude)
                let harmonicBonus = max(0.0, 1.0 - abs(ratioToDelta - 1.04) * 1.4)
                let score = amplitudeScore * (0.65 + 0.35 * harmonicBonus)
                if bestPair == nil || score > bestPair!.score {
                    bestPair = (e1, e2, score)
                }
            }
        }

        let echo1: AcousticEcho
        let echo2: AcousticEcho
        if let pair = bestPair {
            echo1 = pair.first
            echo2 = pair.second
        } else {
            let sorted = searchPool.sorted { $0.timeMicroseconds < $1.timeMicroseconds }
            echo1 = sorted[0]
            echo2 = sorted[1]
        }

        let deltaTUs = echo2.timeMicroseconds - echo1.timeMicroseconds
        let deltaTSec = deltaTUs * 1e-6
        guard deltaTSec > 1e-7 else { return nil }

        let velocity = (2.0 * containerDiameterMeters) / deltaTSec
        let ratioA2A1 = max(1e-5, Double(echo2.amplitude) / max(1e-5, Double(echo1.amplitude)))
        let roundTripCm = max(0.5, 2.0 * containerDiameterMeters * 100.0)
        let attenDBPerCm = max(0.0, (-20.0 * log10(ratioA2A1)) / roundTripCm)

        // Thermal normalization to 20.0 C: oils (high attenuation A2/A1 < 0.48) & alcohols (c < 1470 m/s) have negative dc/dT;
        // aqueous solutions have positive dc/dT.
        let isOrganicOrLipophilic = (velocity < 1_470.0) || (ratioA2A1 < 0.48)
        let thermalCoeff: Double = isOrganicOrLipophilic ? -3.2 : 2.7
        let c20C = velocity - thermalCoeff * (temperatureCelsius - 20.0)

        let intermediates = detectedEchoes.filter {
            $0.sampleIndex != echo1.sampleIndex
                && $0.sampleIndex != echo2.sampleIndex
                && $0.timeMicroseconds < echo1.timeMicroseconds
        }

        return UltrasonicMeasurement(
            transitGapMicroseconds: deltaTUs,
            soundVelocityMps: velocity,
            normalizedVelocity20CMps: c20C,
            echoAttenuationRatio: ratioA2A1,
            attenuationDBPerCm: attenDBPerCm,
            firstEcho: echo1,
            secondEcho: echo2,
            intermediateEchoes: intermediates,
            sampleRateHz: sampleRateHz,
            containerDiameterMeters: containerDiameterMeters,
            temperatureCelsius: temperatureCelsius,
            gateStartUs: gateStartUs,
            gateEndUs: gateEndUs,
            rawSignal: rfSignal,
            envelopeSignal: envelope
        )
    }

    /// Matched-filter carrier polarity detector anchored to the peak-magnitude RF wavefront inside the echo window
    /// (immune to envelope-top noise jitter): correlates against a zero-phase Gabor pulse `exp(-(t/sigma)^2) * cos(2*pi*f0*t)`.
    /// Negative correlation signifies 180-degree phase inversion (`R < 0`, e.g. liquid -> air bubble).
    public func detectPhaseInversion(rfSignal: [Float], centerIndex: Int) -> Bool {
        let samplesPerPeriod = max(4.0, sampleRateHz / max(100_000.0, carrierFrequencyHz))
        let searchRadius = max(6, Int(round(1.5 * samplesPerPeriod)))
        var bestIdx = max(0, min(rfSignal.count - 1, centerIndex))
        var maxAbs: Float = -1.0
        for k in -searchRadius...searchRadius {
            let idx = centerIndex + k
            guard idx >= 0 && idx < rfSignal.count else { continue }
            let a = abs(rfSignal[idx])
            if a > maxAbs {
                maxAbs = a
                bestIdx = idx
            }
        }

        let halfWidth = max(6, Int(round(2.0 * samplesPerPeriod)))
        var dot: Double = 0.0
        for k in -halfWidth...halfWidth {
            let idx = bestIdx + k
            guard idx >= 0 && idx < rfSignal.count else { continue }
            let t = Double(k) / sampleRateHz
            let env = exp(-pow(Double(k) / (samplesPerPeriod * 1.15), 2.0))
            let ref = env * cos(2.0 * .pi * carrierFrequencyHz * t)
            dot += Double(rfSignal[idx]) * ref
        }
        return dot < 0.0
    }

    private static func parabolicPeakIndex(envelope: [Float], index: Int) -> Double {
        guard index > 0, index < envelope.count - 1 else { return Double(index) }
        let y1 = Double(envelope[index - 1])
        let y2 = Double(envelope[index])
        let y3 = Double(envelope[index + 1])
        let denom = y1 - 2.0 * y2 + y3
        guard abs(denom) > 1e-12 else { return Double(index) }
        let delta = max(-0.5, min(0.5, 0.5 * (y1 - y3) / denom))
        return Double(index) + delta
    }
}

// MARK: - Double-Echo & Waveform Synthesis (Virtual NDT Bench Simulator)

extension LiquidAnalyzerContactCore {
    public enum SimulatedLiquid: String, CaseIterable, Identifiable, Sendable {
        case water = "Water (1,482 m/s)"
        case vinegar = "Vinegar 5% (1,500 m/s)"
        case saline = "Saline 5% (1,538 m/s)"
        case oliveOil = "Cooking / Veg Oil (1,455 m/s)"
        case ethanol = "Rubbing Alcohol (1,210 m/s)"
        case sparklingWater = "Sparkling Seltzer (1,482 m/s + Bubbles)"

        public var id: String { rawValue }

        public var shortLabel: String {
            switch self {
            case .water: return "Water"
            case .vinegar: return "Vinegar 5%"
            case .saline: return "Saline 5%"
            case .oliveOil: return "Cooking Oil"
            case .ethanol: return "Alcohol"
            case .sparklingWater: return "Seltzer"
            }
        }

        /// Bulk longitudinal sound speed at 20.0 °C (m/s).
        public var speedOfSound20C: Double {
            switch self {
            case .water: return 1_482.0
            case .vinegar: return 1_500.0
            case .saline: return 1_538.0
            case .oliveOil: return 1_455.0
            case .ethanol: return 1_210.0
            case .sparklingWater: return 1_482.0
            }
        }

        /// Thermal velocity coefficient dc/dT (m/(s·K)).
        public var thermalSlopeMpsPerC: Double {
            switch self {
            case .water, .sparklingWater: return 2.9
            case .vinegar: return 2.6
            case .saline: return 2.4
            case .oliveOil: return -3.2
            case .ethanol: return -3.4
            }
        }

        /// Round-trip amplitude retention factor A2 / A1 across a 65–80 mm container.
        public var attenuationFactor: Float {
            switch self {
            case .water: return 0.72
            case .vinegar: return 0.68
            case .saline: return 0.66
            case .oliveOil: return 0.36
            case .ethanol: return 0.56
            case .sparklingWater: return 0.58
            }
        }

        public var defaultHasBubbles: Bool {
            self == .sparklingWater
        }

        public func speedOfSound(atTemperatureC temperatureC: Double) -> Double {
            speedOfSound20C + thermalSlopeMpsPerC * (temperatureC - 20.0)
        }
    }

    /// Synthesizes a realistic 40 MHz RF A-Scan containing:
    /// - Initial transducer ring-down dead zone (`0 ..< 8 µs`)
    /// - Optional 180-degree phase-inverted intermediate air micro-bubble echo (`R < 0`)
    /// - Echo 1: First opposite-wall liquid-to-glass reflection (`t1 = t_wall + 2D/c`, in-phase `R > 0`)
    /// - Echo 2: Double reverberation reflection (`t2 = t_wall + 4D/c`, attenuated by `liquid.attenuationFactor`, in-phase `R > 0`)
    /// - Additive white Gaussian noise at the requested SNR (dB).
    public func generateSimulatedTrace(
        liquid: SimulatedLiquid,
        wallThicknessMeters: Double = 0.0035,
        wallVelocityMps: Double = 5_600.0,
        temperatureCelsius: Double = 20.0,
        snrDb: Float = 32.0,
        includeAirBubble: Bool? = nil,
        bubbleDepthFraction: Double = 0.45,
        deterministicSeed: UInt64? = nil
    ) -> [Float] {
        let cLiquid = max(900.0, liquid.speedOfSound(atTemperatureC: temperatureCelsius))
        let wallDelaySec = (2.0 * wallThicknessMeters) / max(1_000.0, wallVelocityMps)
        let liquidRoundTripSec = (2.0 * containerDiameterMeters) / cLiquid

        let echo1ArrivalSec = wallDelaySec + liquidRoundTripSec
        let echo2ArrivalSec = echo1ArrivalSec + liquidRoundTripSec

        let neededUs = max(240.0, ceil((echo2ArrivalSec * 1e6) + 35.0))
        let totalTimeUs = max(neededUs, gateEndUs + 15.0)
        let totalSamples = Int((totalTimeUs * 1e-6) * sampleRateHz)
        var signal = [Float](repeating: 0.0, count: totalSamples)

        let samplesPerPeriod = sampleRateHz / max(100_000.0, carrierFrequencyHz)

        func addPulse(at arrivalSec: Double, amplitude: Float, invertPhase: Bool, cycles: Double = 4.0) {
            let centerSample = arrivalSec * sampleRateHz
            let centerIdx = Int(round(centerSample))
            let halfWidth = Int(ceil(cycles * samplesPerPeriod))
            for k in -halfWidth...halfWidth {
                let idx = centerIdx + k
                guard idx >= 0 && idx < totalSamples else { continue }
                let dtSample = Double(idx) - centerSample
                let t = dtSample / sampleRateHz
                // Zero-phase Gabor wavelet: exact analytic envelope exp(-(t/sigma)^2) and unambiguous peak polarity (+R vs -R)
                let env = exp(-pow(dtSample / (samplesPerPeriod * 1.15), 2.0))
                let carrier = cos(2.0 * .pi * carrierFrequencyHz * t) * (invertPhase ? -1.0 : 1.0)
                signal[idx] += amplitude * Float(env * carrier)
            }
        }

        // Initial excitation pulse + front-wall ring-down (inside Dead Zone < 8 µs)
        addPulse(at: 1.8e-6, amplitude: 0.95, invertPhase: false, cycles: 3.0)

        // Optional suspended air micro-bubble echo inside the liquid column (180-degree phase inversion: Z_air << Z_liquid)
        let injectBubble = includeAirBubble ?? liquid.defaultHasBubbles
        if injectBubble {
            let clampedDepth = max(0.22, min(0.78, bubbleDepthFraction))
            let bubbleArrivalSec = wallDelaySec + (liquidRoundTripSec * clampedDepth)
            addPulse(at: bubbleArrivalSec, amplitude: 0.36, invertPhase: true, cycles: 3.5)
        }

        // Echo 1: First opposite liquid-to-glass wall reflection (R > 0, in-phase)
        addPulse(at: echo1ArrivalSec, amplitude: 0.85, invertPhase: false)

        // Echo 2: Second complete liquid round-trip reverberation (attenuated, in-phase)
        addPulse(at: echo2ArrivalSec, amplitude: 0.85 * liquid.attenuationFactor, invertPhase: false)

        // Additive Gaussian noise (deterministic LCG Box-Muller when seeded for unit tests)
        let noiseSigma = pow(10.0, -snrDb / 20.0)
        var rngState: UInt64 = deterministicSeed ?? UInt64.random(in: 1...UInt64.max)
        func nextUniform() -> Float {
            rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
            let val = Double((rngState >> 33) & 0x7FFF_FFFF) / Double(0x8000_0000)
            return max(Float.ulpOfOne, Float(val))
        }

        for i in 0..<totalSamples {
            let u1 = nextUniform()
            let u2 = nextUniform()
            let normalNoise = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
            signal[i] += normalNoise * noiseSigma
        }

        return signal
    }
}
