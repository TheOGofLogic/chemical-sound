import AVFAudio
import Foundation

/// Extracted acoustic features from a 48 kHz ESS liquid scan.
public struct ExtractedConsumerFeatures: Equatable, Sendable {
    public let activeSNRDB: Double
    public let peakDBFS: Double
    public let clippedSamples: Int
    public let dominantPeakHz: Double
    public let spectralCentroidHz: Double
    public let midToHighBandDB: Double
    public let decaySlopeDBPerSec: Double
}

/// Layer 2 on-device acoustic feature analyzer and 3-state experimental reference matcher.
/// Never fabricates unvalidated percentage purity claims; enforces `INVALID_MEASUREMENT`,
/// `NO_VALIDATED_MATCH`, and `REFERENCE_MATCH` with explicit experimental labeling.
public struct OnDeviceAcousticClassifier: Sendable {
    public let referenceLibrary: [ReferenceLiquidProfile]
    public let distanceThreshold: Double
    public let minimumSNRDB: Double

    public init(
        referenceLibrary: [ReferenceLiquidProfile] = ReferenceLiquidProfile.provisionalLibrary,
        distanceThreshold: Double = 3.10,
        minimumSNRDB: Double = 1.8
    ) {
        self.referenceLibrary = referenceLibrary
        self.distanceThreshold = distanceThreshold
        self.minimumSNRDB = minimumSNRDB
    }

    public func analyzeAndClassify(
        recordingURL: URL,
        inverseFilterURL: URL?,
        preRollFrames: Int = 7_200,
        activeFrames: Int = 9_600,
        clippingCeilingDBFS: Double = -0.5,
        thumbnailJPEGData: Data? = nil
    ) throws -> ConsumerScanItem {
        let (samples, actualSR) = try Self.readMonoFloatSamplesAndRate(from: recordingURL)
        let inverse = inverseFilterURL.flatMap { try? Self.readMonoFloatSamplesAndRate(from: $0).samples }
        return classifySamples(
            samples: samples,
            inverseFilter: inverse,
            sampleRateHz: actualSR,
            preRollFrames: preRollFrames,
            activeFrames: activeFrames,
            clippingCeilingDBFS: clippingCeilingDBFS,
            thumbnailJPEGData: thumbnailJPEGData
        )
    }

    public func classifySamples(
        samples: [Float],
        inverseFilter: [Float]?,
        sampleRateHz: Double = 48_000.0,
        preRollFrames: Int = 7_200,
        activeFrames: Int = 9_600,
        clippingCeilingDBFS: Double = -0.5,
        thumbnailJPEGData: Data? = nil
    ) -> ConsumerScanItem {
        let features = extractFeatures(
            samples: samples,
            inverseFilter: inverseFilter,
            sampleRateHz: sampleRateHz,
            preRollFrames: preRollFrames,
            activeFrames: activeFrames,
            clippingCeilingDBFS: clippingCeilingDBFS
        )

        // 1. Signal Quality Verification (`INVALID_MEASUREMENT`)
        if samples.count < (preRollFrames + activeFrames / 2) ||
            features.clippedSamples > 8 ||
            features.activeSNRDB < minimumSNRDB {
            let reasonNote: String
            if features.clippedSamples > 8 {
                reasonNote = "The sound reflection was too loud or clipped. Lower your volume slightly and try again."
            } else {
                reasonNote = "Ambient noise was too close to the acoustic test wave. Move to a quieter spot, hold steady near the container, and scan again."
            }
            return ConsumerScanItem(
                status: .unclearScan,
                title: "Scan Unclear",
                formulaDisplay: "Signal Check",
                statusBadgeText: "Rescan Needed",
                confidencePercent: nil,
                scientificNote: reasonNote,
                constituents: [],
                tuneProfile: Self.buildAcousticSignatureTune(features: features, formula: "Signal Echo"),
                measuredPeakHz: features.dominantPeakHz,
                measuredCentroidHz: features.spectralCentroidHz,
                measuredDecayDBPerSec: features.decaySlopeDBPerSec,
                thumbnailJPEGData: thumbnailJPEGData
            )
        }

        // 2. Standardized distance comparison against calibrated/provisional reference profiles
        let scored: [(profile: ReferenceLiquidProfile, distance: Double)] = referenceLibrary.map { prof in
            let dPeak = (features.dominantPeakHz - prof.expectedPeakHz) / 550.0
            let dCent = (features.spectralCentroidHz - prof.expectedCentroidHz) / 620.0
            let dBand = (features.midToHighBandDB - prof.expectedMidToHighDB) / 3.8
            let dDecay = (features.decaySlopeDBPerSec - prof.expectedDecayDBPerSec) / 42.0
            let dist = sqrt(0.35 * dPeak * dPeak + 0.30 * dCent * dCent + 0.20 * dBand * dBand + 0.15 * dDecay * dDecay)
            return (prof, dist)
        }.sorted { $0.distance < $1.distance }

        guard let best = scored.first else {
            return buildUnmatchedItem(features: features, thumbnailJPEGData: thumbnailJPEGData)
        }

        let secondDistance = scored.count > 1 ? scored[1].distance : (best.distance + 1.0)
        let margin = secondDistance - best.distance

        // 3. Open-Set Unknown Rejection (`NO_VALIDATED_MATCH`)
        if best.distance > distanceThreshold || margin < 0.08 {
            return buildUnmatchedItem(features: features, thumbnailJPEGData: thumbnailJPEGData)
        }

        // 4. Experimental Reference Match (`REFERENCE_MATCH`) — bounded experimental confidence (never 99.9%)
        let rawSimilarity = exp(-0.48 * best.distance) * (0.78 + 0.22 * min(1.0, margin / 0.45))
        let snrFactor = min(1.0, max(0.75, features.activeSNRDB / 26.0))
        let boundedConfidence = min(92, max(58, Int(round(rawSimilarity * snrFactor * 94.0))))

        return ConsumerScanItem(
            status: .referenceMatch,
            title: best.profile.displayName,
            formulaDisplay: best.profile.formulaDisplay,
            statusBadgeText: "Experimental Reference Match • \(boundedConfidence)% Similarity",
            confidencePercent: boundedConfidence,
            scientificNote: "Estimated from acoustic resonance similarity to the \(best.profile.displayName.lowercased()) reference profile. Experimental research result—not a laboratory chemical or safety test.",
            constituents: best.profile.constituents,
            tuneProfile: best.profile.tuneProfile,
            measuredPeakHz: features.dominantPeakHz,
            measuredCentroidHz: features.spectralCentroidHz,
            measuredDecayDBPerSec: features.decaySlopeDBPerSec,
            thumbnailJPEGData: thumbnailJPEGData
        )
    }

    public func extractFeatures(
        samples: [Float],
        inverseFilter: [Float]?,
        sampleRateHz: Double = 48_000.0,
        preRollFrames: Int = 7_200,
        activeFrames: Int = 9_600,
        clippingCeilingDBFS: Double = -0.5
    ) -> ExtractedConsumerFeatures {
        guard !samples.isEmpty else {
            return ExtractedConsumerFeatures(
                activeSNRDB: 0.0,
                peakDBFS: -120.0,
                clippedSamples: 0,
                dominantPeakHz: 1_800.0,
                spectralCentroidHz: 2_000.0,
                midToHighBandDB: 4.0,
                decaySlopeDBPerSec: 100.0
            )
        }

        let clipLin = pow(10.0, clippingCeilingDBFS / 20.0)
        var peakLin = 0.0
        var clipped = 0
        for s in samples where s.isFinite {
            let a = abs(Double(s))
            if a > peakLin { peakLin = a }
            if a >= clipLin { clipped += 1 }
        }

        let preEnd = max(1, min(samples.count, preRollFrames))
        let actStart = min(samples.count, preRollFrames)
        let actEnd = min(samples.count, preRollFrames + max(1, activeFrames))

        let preRMS = Self.segmentRMS(samples, start: 0, end: preEnd)
        let actRMS = actEnd > actStart ? Self.segmentRMS(samples, start: actStart, end: actEnd) : 0.0
        let preDB = ImmediateAudioAnalyzer.linearToDBFS(preRMS)
        let actDB = ImmediateAudioAnalyzer.linearToDBFS(actRMS)
        let snrDB = max(0.0, actDB - preDB)

        // Deconvolve with matched inverse filter if available; otherwise analyze active + post-roll response window
        let analysisSignal: [Double]
        if let inv = inverseFilter, !inv.isEmpty, samples.count > actStart + 512 {
            let responseSlice = Array(samples[actStart..<samples.count]).map { $0.isFinite ? Double($0) : 0.0 }
            let invDouble = inv.map { $0.isFinite ? Double($0) : 0.0 }
            let ir = Self.fastLinearConvolve(responseSlice, invDouble)
            var peakIdx = 0
            var maxAbs = 0.0
            for (idx, val) in ir.enumerated() {
                let a = abs(val)
                if a > maxAbs {
                    maxAbs = a
                    peakIdx = idx
                }
            }
            // Extract causal resonance tail window (+1.2 ms to +42 ms after impulse arrival t0)
            let tailStart = min(ir.count, peakIdx + Int(0.0012 * sampleRateHz))
            let tailEnd = min(ir.count, peakIdx + Int(0.0420 * sampleRateHz))
            if tailEnd - tailStart >= 256 {
                analysisSignal = Array(ir[tailStart..<tailEnd])
            } else {
                analysisSignal = Array(samples[actStart..<actEnd]).map { Double($0) }
            }
        } else {
            analysisSignal = Array(samples[actStart..<max(actStart + 1, actEnd)]).map { $0.isFinite ? Double($0) : 0.0 }
        }

        // Compute Hann-windowed power spectrum over 450 Hz - 12 kHz
        let nFFT = 4_096
        var real = [Double](repeating: 0.0, count: nFFT)
        var imag = [Double](repeating: 0.0, count: nFFT)
        let copyCount = min(analysisSignal.count, nFFT)
        if copyCount > 1 {
            for i in 0..<copyCount {
                let w = 0.5 * (1.0 - cos(2.0 * Double.pi * Double(i) / Double(copyCount - 1)))
                real[i] = analysisSignal[i] * w
            }
        }
        Self.fftRadix2(real: &real, imag: &imag, inverse: false)

        let binHz = sampleRateHz / Double(nFFT)
        let minBin = max(1, Int(ceil(450.0 / binHz)))
        let maxBin = min(nFFT / 2 - 1, Int(floor(12_000.0 / binHz)))

        var weightedFreqSum = 0.0
        var powerSum = 1e-15
        var maxBinPower = -1.0
        var dominantFreq = 2_000.0
        var midBandPower = 1e-15
        var highBandPower = 1e-15

        if maxBin > minBin {
            for b in minBin...maxBin {
                let p = real[b] * real[b] + imag[b] * imag[b]
                let f = Double(b) * binHz
                weightedFreqSum += f * p
                powerSum += p
                if p > maxBinPower {
                    maxBinPower = p
                    dominantFreq = f
                }
                if f >= 900.0 && f < 3_600.0 {
                    midBandPower += p
                } else if f >= 3_600.0 && f <= 10_500.0 {
                    highBandPower += p
                }
            }
        }

        let centroidHz = weightedFreqSum / powerSum
        let midToHighDB = 10.0 * log10(midBandPower / highBandPower)

        // Estimate envelope decay rate (dB/s) across first vs. second half of resonance window
        let half = analysisSignal.count / 2
        let decayDBPerSec: Double
        if half >= 64 {
            let earlyE = analysisSignal[0..<half].reduce(1e-15) { $0 + $1 * $1 } / Double(half)
            let lateE = analysisSignal[half..<analysisSignal.count].reduce(1e-15) { $0 + $1 * $1 } / Double(analysisSignal.count - half)
            let dropDB = max(1.5, 10.0 * log10(earlyE / max(lateE, 1e-15)))
            let dtSec = max(0.005, Double(half) / sampleRateHz)
            decayDBPerSec = min(260.0, max(30.0, dropDB / dtSec))
        } else {
            decayDBPerSec = 95.0
        }

        return ExtractedConsumerFeatures(
            activeSNRDB: snrDB,
            peakDBFS: ImmediateAudioAnalyzer.linearToDBFS(peakLin),
            clippedSamples: clipped,
            dominantPeakHz: dominantFreq,
            spectralCentroidHz: centroidHz,
            midToHighBandDB: midToHighDB,
            decaySlopeDBPerSec: decayDBPerSec
        )
    }

    private func buildUnmatchedItem(
        features: ExtractedConsumerFeatures,
        thumbnailJPEGData: Data?
    ) -> ConsumerScanItem {
        ConsumerScanItem(
            status: .unmatchedSignature,
            title: "Unmatched Liquid",
            formulaDisplay: "Acoustic Profile",
            statusBadgeText: "Experimental • Outside Current Reference Library",
            confidencePercent: nil,
            scientificNote: "A clean acoustic response was captured, but its resonance pattern did not closely match a calibrated reference liquid yet. You can still listen to its mapped acoustic tune.",
            constituents: [
                ReferenceConstituent(
                    symbol: "≈ \(Int(round(features.dominantPeakHz))) Hz",
                    name: "Measured Resonance Peak",
                    roleDescription: "Unclassified liquid signature (no reference claim)"
                )
            ],
            tuneProfile: Self.buildAcousticSignatureTune(features: features, formula: "Acoustic Signature"),
            measuredPeakHz: features.dominantPeakHz,
            measuredCentroidHz: features.spectralCentroidHz,
            measuredDecayDBPerSec: features.decaySlopeDBPerSec,
            thumbnailJPEGData: thumbnailJPEGData
        )
    }

    private static func buildAcousticSignatureTune(
        features: ExtractedConsumerFeatures,
        formula: String
    ) -> ChemicalTuneProfile {
        // Quantize measured dominant peak into a pleasant D-major pentatonic harmonic chord
        let pentatonicBase: [Double] = [293.66, 329.63, 369.99, 440.00, 493.88, 587.33, 659.25, 739.99, 880.00]
        let normalizedIdx = max(0, min(pentatonicBase.count - 4, Int((features.dominantPeakHz - 900.0) / 550.0)))
        let chord = [
            pentatonicBase[normalizedIdx],
            pentatonicBase[min(pentatonicBase.count - 1, normalizedIdx + 1)],
            pentatonicBase[min(pentatonicBase.count - 1, normalizedIdx + 2)],
            pentatonicBase[min(pentatonicBase.count - 1, normalizedIdx + 3)]
        ]
        return ChemicalTuneProfile(
            formulaDisplay: formula,
            mappingSummary: "Mapped musical representation derived directly from the liquid's measured acoustic resonance frequencies.",
            baseFrequenciesHz: chord,
            shimmerMultiplier: max(0.75, min(1.30, features.spectralCentroidHz / 2_400.0)),
            warmthDecayPerSec: max(1.3, min(2.4, features.decaySlopeDBPerSec / 65.0))
        )
    }

    // MARK: - Pure Swift Audio & FFT Utilities

    private static func readMonoFloatSamplesAndRate(from url: URL) throws -> (samples: [Float], sampleRateHz: Double) {
        let file = try AVAudioFile(forReading: url)
        let sr = file.processingFormat.sampleRate > 0 ? file.processingFormat.sampleRate : 48_000.0
        let count = Int(file.length)
        guard count > 0,
              let buf = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(count)
              ) else {
            return ([], sr)
        }
        try file.read(into: buf)
        guard let ptr = buf.floatChannelData?[0] else { return ([], sr) }
        let n = Int(buf.frameLength)
        return (Array(UnsafeBufferPointer(start: ptr, count: n)), sr)
    }

    private static func segmentRMS(_ samples: [Float], start: Int, end: Int) -> Double {
        let n = end - start
        guard n > 0 else { return 0.0 }
        var sum = 0.0
        for i in start..<end {
            let v = Double(samples[i])
            if v.isFinite { sum += v }
        }
        let mean = sum / Double(n)
        var sq = 0.0
        for i in start..<end {
            let v = Double(samples[i])
            if v.isFinite {
                let d = v - mean
                sq += d * d
            }
        }
        return sqrt(sq / Double(n))
    }

    private static func fastLinearConvolve(_ a: [Double], _ b: [Double]) -> [Double] {
        let total = a.count + b.count - 1
        var nFFT = 1
        while nFFT < total { nFFT <<= 1 }

        var ar = [Double](repeating: 0.0, count: nFFT)
        var ai = [Double](repeating: 0.0, count: nFFT)
        var br = [Double](repeating: 0.0, count: nFFT)
        var bi = [Double](repeating: 0.0, count: nFFT)

        for i in 0..<a.count { ar[i] = a[i] }
        for i in 0..<b.count { br[i] = b[i] }

        fftRadix2(real: &ar, imag: &ai, inverse: false)
        fftRadix2(real: &br, imag: &bi, inverse: false)

        for i in 0..<nFFT {
            let rr = ar[i] * br[i] - ai[i] * bi[i]
            let ii = ar[i] * bi[i] + ai[i] * br[i]
            ar[i] = rr
            ai[i] = ii
        }

        fftRadix2(real: &ar, imag: &ai, inverse: true)
        return Array(ar.prefix(total))
    }

    public static func fftRadix2(real: inout [Double], imag: inout [Double], inverse: Bool) {
        let n = real.count
        guard n > 1 && (n & (n - 1)) == 0 else { return }

        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while (j & bit) != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                real.swapAt(i, j)
                imag.swapAt(i, j)
            }
        }

        var len = 2
        let sign = inverse ? 1.0 : -1.0
        while len <= n {
            let ang = sign * 2.0 * Double.pi / Double(len)
            let wlenR = cos(ang)
            let wlenI = sin(ang)
            let half = len >> 1
            var i = 0
            while i < n {
                var wR = 1.0
                var wI = 0.0
                for k in 0..<half {
                    let uR = real[i + k]
                    let uI = imag[i + k]
                    let vR = real[i + k + half] * wR - imag[i + k + half] * wI
                    let vI = real[i + k + half] * wI + imag[i + k + half] * wR
                    real[i + k] = uR + vR
                    imag[i + k] = uI + vI
                    real[i + k + half] = uR - vR
                    imag[i + k + half] = uI - vI
                    let nextWR = wR * wlenR - wI * wlenI
                    wI = wR * wlenI + wI * wlenR
                    wR = nextWR
                }
                i += len
            }
            len <<= 1
        }

        if inverse {
            let scale = 1.0 / Double(n)
            for i in 0..<n {
                real[i] *= scale
                imag[i] *= scale
            }
        }
    }
}
