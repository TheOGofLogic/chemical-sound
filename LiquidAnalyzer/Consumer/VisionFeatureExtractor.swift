import CoreGraphics
import Foundation
import ImageIO

/// Quantitative optical feature vector extracted from the camera targeting ROI for v0.5.0 Multi-Modal Sensor Fusion.
public struct VisionFeatureVector: Codable, Equatable, Sendable {
    public let hasCameraFrame: Bool
    public let meanHueDegrees: Double
    public let meanSaturationWB: Double
    public let meanValueBrightness: Double
    public let rimSaturationWB: Double
    public let rimValueBrightness: Double
    public let opticalTurbidity: Double
    public let meniscusContactAngleDegrees: Double
    public let meniscusCurvatureRatio: Double
    public let meniscusEdgeStrength: Double
    public let meniscusHaloHueDegrees: Double
    public let meniscusHaloSaturation: Double
    public let estimatedFillFraction: Double?

    public init(
        hasCameraFrame: Bool,
        meanHueDegrees: Double,
        meanSaturationWB: Double,
        meanValueBrightness: Double,
        rimSaturationWB: Double = 0.0,
        rimValueBrightness: Double = 0.5,
        opticalTurbidity: Double,
        meniscusContactAngleDegrees: Double,
        meniscusCurvatureRatio: Double = 0.0,
        meniscusEdgeStrength: Double = 0.0,
        meniscusHaloHueDegrees: Double = 0.0,
        meniscusHaloSaturation: Double = 0.0,
        estimatedFillFraction: Double? = nil
    ) {
        self.hasCameraFrame = hasCameraFrame
        self.meanHueDegrees = meanHueDegrees
        self.meanSaturationWB = meanSaturationWB
        self.meanValueBrightness = meanValueBrightness
        self.rimSaturationWB = rimSaturationWB
        self.rimValueBrightness = rimValueBrightness
        self.opticalTurbidity = opticalTurbidity
        self.meniscusContactAngleDegrees = meniscusContactAngleDegrees
        self.meniscusCurvatureRatio = meniscusCurvatureRatio
        self.meniscusEdgeStrength = meniscusEdgeStrength
        self.meniscusHaloHueDegrees = meniscusHaloHueDegrees
        self.meniscusHaloSaturation = meniscusHaloSaturation
        self.estimatedFillFraction = estimatedFillFraction
    }

    public static let audioOnlyEmpty = VisionFeatureVector(
        hasCameraFrame: false,
        meanHueDegrees: 0.0,
        meanSaturationWB: 0.0,
        meanValueBrightness: 0.5,
        rimSaturationWB: 0.0,
        rimValueBrightness: 0.5,
        opticalTurbidity: 0.0,
        meniscusContactAngleDegrees: 35.0,
        meniscusCurvatureRatio: 0.0,
        meniscusEdgeStrength: 0.0,
        meniscusHaloHueDegrees: 0.0,
        meniscusHaloSaturation: 0.0,
        estimatedFillFraction: nil
    )
}

/// Extracts illuminant-normalized HSV colorimetry, optical turbidity/opacity, meniscus halo transmittance,
/// and horizontal liquid-boundary meniscus contact-angle geometry from the 128x128 aiming ROI.
public struct VisionFeatureExtractor: Sendable {
    public init() {}

    public func extract(jpegData: Data?, sceneContextJPEGData: Data? = nil) -> VisionFeatureVector {
        let primaryData = jpegData ?? sceneContextJPEGData
        guard let primaryData,
              !primaryData.isEmpty,
              let src = CGImageSourceCreateWithData(primaryData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return .audioOnlyEmpty
        }
        return Self.extractFromCGImage(cgImage)
    }

    public static func extractFromCGImage(_ cgImage: CGImage) -> VisionFeatureVector {
        let grid = 128
        var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: grid,
            height: grid,
            bitsPerComponent: 8,
            bytesPerRow: grid * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .audioOnlyEmpty
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: grid, height: grid))

        let half = Double(grid - 1) * 0.5
        let invHalf = 1.0 / Double(grid / 2)
        var lumaGrid = [Double](repeating: 0.0, count: grid * grid)

        // 1. Estimate ambient illuminant white point from neutral outer background ring (rad >= 0.66)
        var bgR = 0.0, bgG = 0.0, bgB = 0.0, bgCount = 0.0
        for y in 0..<grid {
            for x in 0..<grid {
                let idx = (y * grid + x) * 4
                let r = Double(pixels[idx]) / 255.0
                let g = Double(pixels[idx + 1]) / 255.0
                let b = Double(pixels[idx + 2]) / 255.0
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                lumaGrid[y * grid + x] = luma

                let dx = (Double(x) - half) * invHalf
                let dy = (Double(y) - half) * invHalf
                let rad = sqrt(dx * dx + dy * dy)
                if rad >= 0.66 {
                    let maxC = max(r, max(g, b))
                    let minC = min(r, min(g, b))
                    let rawSat = maxC > 0.05 ? (maxC - minC) / maxC : 0.0
                    if luma > 0.16 && rawSat < 0.38 {
                        bgR += r
                        bgG += g
                        bgB += b
                        bgCount += 1.0
                    }
                }
            }
        }

        let wbGainR: Double
        let wbGainB: Double
        if bgCount >= 64 && bgG > 4.0 {
            let avgR = bgR / bgCount
            let avgG = bgG / bgCount
            let avgB = bgB / bgCount
            wbGainR = min(1.28, max(0.76, avgG / max(0.05, avgR)))
            wbGainB = min(1.32, max(0.76, avgG / max(0.05, avgB)))
        } else {
            wbGainR = 1.0
            wbGainB = 1.0
        }

        // 2. Extract interior liquid core (rad <= 0.28), transition halo (0.24..0.37), and rim (0.38..0.62)
        var inRSum = 0.0, inGSum = 0.0, inBSum = 0.0
        var inValSum = 0.0, inValSqSum = 0.0, inCnt = 0.0
        var hueSinSum = 0.0, hueCosSum = 0.0, hueWeightSum = 0.0
        var inGradSum = 0.0, inGradCnt = 0.0

        var rimRSum = 0.0, rimGSum = 0.0, rimBSum = 0.0, rimValSum = 0.0, rimCnt = 0.0
        var haloSinSum = 0.0, haloCosSum = 0.0, haloSatSum = 0.0, haloCnt = 0.0

        for y in 2..<(grid - 2) {
            for x in 2..<(grid - 2) {
                let idx = (y * grid + x) * 4
                let r = min(1.0, (Double(pixels[idx]) / 255.0) * wbGainR)
                let g = Double(pixels[idx + 1]) / 255.0
                let b = min(1.0, (Double(pixels[idx + 2]) / 255.0) * wbGainB)

                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let delta = maxC - minC
                let sat = maxC > 0.04 ? (delta / maxC) : 0.0
                let luma = lumaGrid[y * grid + x]

                let dx = (Double(x) - half) * invHalf
                let dy = (Double(y) - half) * invHalf
                let rad = sqrt(dx * dx + dy * dy)

                if rad <= 0.23 {
                    inRSum += r
                    inGSum += g
                    inBSum += b
                    inValSum += maxC
                    inValSqSum += luma * luma
                    inCnt += 1.0

                    if delta > 0.008 {
                        let hDeg = Self.rgbToHueDegrees(r: r, g: g, b: b, maxC: maxC, delta: delta)
                        let hRad = hDeg * Double.pi / 180.0
                        hueSinSum += sin(hRad) * delta
                        hueCosSum += cos(hRad) * delta
                        hueWeightSum += delta
                    }

                    let gx = abs(lumaGrid[y * grid + x + 1] - lumaGrid[y * grid + x - 1])
                    let gy = abs(lumaGrid[(y + 1) * grid + x] - lumaGrid[(y - 1) * grid + x])
                    inGradSum += 0.5 * (gx + gy)
                    inGradCnt += 1.0
                }

                if rad >= 0.24 && rad <= 0.37 && luma >= 0.10 && luma <= 0.72 && delta > 0.015 {
                    let hDeg = Self.rgbToHueDegrees(r: r, g: g, b: b, maxC: maxC, delta: delta)
                    let hRad = hDeg * Double.pi / 180.0
                    haloSinSum += sin(hRad) * sat
                    haloCosSum += cos(hRad) * sat
                    haloSatSum += sat
                    haloCnt += 1.0
                }

                if rad >= 0.38 && rad <= 0.62 {
                    rimRSum += r
                    rimGSum += g
                    rimBSum += b
                    rimValSum += luma
                    rimCnt += 1.0
                }
            }
        }

        let meanR = inCnt > 0 ? inRSum / inCnt : 0.5
        let meanG = inCnt > 0 ? inGSum / inCnt : 0.5
        let meanB = inCnt > 0 ? inBSum / inCnt : 0.5
        let inMax = max(meanR, max(meanG, meanB))
        let inMin = min(meanR, min(meanG, meanB))
        let inDelta = inMax - inMin
        let meanSatWB = inMax > 0.04 ? (inDelta / inMax) : 0.0
        let meanVal = inCnt > 0 ? (inValSum / inCnt) : 0.5

        let meanHueDeg: Double
        if hueWeightSum > 1e-4 {
            var deg = atan2(hueSinSum, hueCosSum) * 180.0 / Double.pi
            if deg < 0.0 { deg += 360.0 }
            meanHueDeg = deg
        } else {
            meanHueDeg = Self.rgbToHueDegrees(r: meanR, g: meanG, b: meanB, maxC: inMax, delta: inDelta)
        }

        let rimR = rimCnt > 0 ? rimRSum / rimCnt : meanR
        let rimG = rimCnt > 0 ? rimGSum / rimCnt : meanG
        let rimB = rimCnt > 0 ? rimBSum / rimCnt : meanB
        let rimMax = max(rimR, max(rimG, rimB))
        let rimMin = min(rimR, min(rimG, rimB))
        let rimSatWB = rimMax > 0.04 ? ((rimMax - rimMin) / rimMax) : 0.0
        let rimVal = rimCnt > 0 ? (rimValSum / rimCnt) : meanVal

        let haloSat = haloCnt > 0 ? (haloSatSum / haloCnt) : 0.0
        let haloHueDeg: Double = {
            guard haloCnt > 0, (abs(haloSinSum) + abs(haloCosSum)) > 1e-5 else { return meanHueDeg }
            var deg = atan2(haloSinSum, haloCosSum) * 180.0 / Double.pi
            if deg < 0.0 { deg += 360.0 }
            return deg
        }()

        // 3. Optical Turbidity / Opacity Estimation (0 = crystal-clear/translucent, 1 = opaque colloidal emulsion)
        let meanLumaApprox = 0.299 * meanR + 0.587 * meanG + 0.114 * meanB
        let lumaVar = inCnt > 0 ? max(0.0, (inValSqSum / inCnt) - (meanLumaApprox * meanLumaApprox)) : 0.0
        let interiorEdgeDensity = inGradCnt > 0 ? (inGradSum / inGradCnt) : 0.02

        let opticalTurbidity: Double = {
            // High-albedo opaque white colloidal scatter (Milk / Cream: luma > 0.85, near-zero chroma)
            if meanLumaApprox > 0.85 && meanSatWB < 0.08 && lumaVar < 0.004 && (meanLumaApprox - rimVal) > 0.08 {
                return min(0.98, 0.85 + 0.13 * min(1.0, (meanLumaApprox - 0.85) / 0.12))
            }
            // Deep optical absorption (Coffee / Cola / Red Wine)
            if meanVal < 0.22 && (rimVal - meanLumaApprox) > 0.16 {
                return min(0.82, 0.58 + (0.22 - meanVal))
            }
            // Translucent golden cooking oil (high yellow-gold chroma with specular clarity, low diffuse scatter)
            if meanHueDeg >= 38.0 && meanHueDeg <= 68.0 && meanSatWB >= 0.36 {
                let edgeSuppression = max(0.0, 0.032 - interiorEdgeDensity) / 0.032
                return min(0.34, 0.10 + 0.18 * edgeSuppression)
            }
            // Cloudy chromatic juice / emulsion vs. clear aqueous pool
            if meanSatWB >= 0.36 && (meanHueDeg < 38.0 || meanHueDeg > 325.0) {
                let scatterTerm = max(0.0, 0.045 - interiorEdgeDensity) / 0.045
                return min(0.84, max(0.42, 0.44 + 0.32 * scatterTerm))
            }
            // Clear neutral / slightly tinted aqueous solution
            let baseClear = min(0.32, max(0.04, 0.08 + 0.20 * max(0.0, 0.018 - interiorEdgeDensity) / 0.018))
            return baseClear
        }()

        // 4. Horizontal Meniscus Surface Boundary Profile & Contact-Angle Estimation
        // Uses polarity-consistent vertical gradients (headspace -> liquid step sign) so curved top container rims
        // (dark rim -> bright headspace, opposite polarity) never masquerade as capillary wall rise.
        let yTop = Int(Double(grid) * 0.24)
        let yBot = Int(Double(grid) * 0.76)
        let xLeftRange = Int(Double(grid) * 0.34)...Int(Double(grid) * 0.41)
        let xCenterRange = Int(Double(grid) * 0.45)...Int(Double(grid) * 0.55)
        let xRightRange = Int(Double(grid) * 0.59)...Int(Double(grid) * 0.66)

        func signedVerticalStepAt(y: Int, xRange: ClosedRange<Int>) -> Double {
            var sum = 0.0
            var cnt = 0.0
            for x in xRange {
                // Positive when upper row (y - 1) is brighter than lower row (y + 1)
                let step = lumaGrid[(y - 1) * grid + x] - lumaGrid[(y + 1) * grid + x]
                sum += step
                cnt += 1.0
            }
            return cnt > 0 ? sum / cnt : 0.0
        }

        var bestCenterY = (yTop + yBot) / 2
        var bestCenterSigned = 0.0
        var bestCenterGrad = 0.0
        for y in (yTop + 4)..<(yBot - 4) {
            let sCenter = signedVerticalStepAt(y: y, xRange: xCenterRange)
            let gCenter = abs(sCenter)
            if gCenter > bestCenterGrad {
                bestCenterGrad = gCenter
                bestCenterSigned = sCenter
                bestCenterY = y
            }
        }

        let meniscusDetected = bestCenterGrad >= 0.028
        var curvatureRatio = 0.0
        var contactAngleDeg = 35.0
        var fillFrac: Double? = nil

        if meniscusDetected {
            let polaritySign: Double = bestCenterSigned >= 0.0 ? 1.0 : -1.0
            let searchMinY = max(yTop + 1, bestCenterY - 9)
            let searchMaxY = min(yBot - 1, bestCenterY + 4)

            var bestLeftY = bestCenterY
            var maxLeftG = -1.0
            var bestRightY = bestCenterY
            var maxRightG = -1.0

            for y in searchMinY...searchMaxY {
                let gl = signedVerticalStepAt(y: y, xRange: xLeftRange) * polaritySign
                if gl > maxLeftG {
                    maxLeftG = gl
                    bestLeftY = y
                }
                let gr = signedVerticalStepAt(y: y, xRange: xRightRange) * polaritySign
                if gr > maxRightG {
                    maxRightG = gr
                    bestRightY = y
                }
            }

            if maxLeftG >= 0.020 && maxRightG >= 0.020 {
                let avgWallY = 0.5 * Double(bestLeftY + bestRightY)
                // Positive risePixels means concave upward capillary wetting at container walls (smaller y = higher in image)
                let risePixels = Double(bestCenterY) - avgWallY
                let halfSpanPx = Double(grid) * 0.135
                curvatureRatio = risePixels / max(1.0, halfSpanPx)
                contactAngleDeg = min(78.0, max(14.0, 46.0 - 145.0 * curvatureRatio))
            }

            let span = Double(max(1, yBot - yTop))
            fillFrac = min(0.98, max(0.05, 1.0 - (Double(bestCenterY - yTop) / span)))
        }

        return VisionFeatureVector(
            hasCameraFrame: true,
            meanHueDegrees: meanHueDeg,
            meanSaturationWB: meanSatWB,
            meanValueBrightness: meanVal,
            rimSaturationWB: rimSatWB,
            rimValueBrightness: rimVal,
            opticalTurbidity: opticalTurbidity,
            meniscusContactAngleDegrees: contactAngleDeg,
            meniscusCurvatureRatio: curvatureRatio,
            meniscusEdgeStrength: bestCenterGrad,
            meniscusHaloHueDegrees: haloHueDeg,
            meniscusHaloSaturation: haloSat,
            estimatedFillFraction: fillFrac
        )
    }

    private static func rgbToHueDegrees(r: Double, g: Double, b: Double, maxC: Double, delta: Double) -> Double {
        guard delta > 0.005 else { return 0.0 }
        var hueDeg: Double
        if maxC == r {
            hueDeg = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6.0))
        } else if maxC == g {
            hueDeg = 60.0 * (((b - r) / delta) + 2.0)
        } else {
            hueDeg = 60.0 * (((r - g) / delta) + 4.0)
        }
        if hueDeg < 0.0 { hueDeg += 360.0 }
        return hueDeg
    }
}
