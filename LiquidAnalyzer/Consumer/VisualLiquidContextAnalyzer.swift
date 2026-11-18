import CoreGraphics
import Foundation
import ImageIO
import Vision

/// High-level visual context category extracted on-device from the targeting reticle thumbnail.
/// Provides container presence and optical context alongside the acoustic echo measurement.
public enum VisualLiquidHint: String, Equatable, Sendable {
    case audioOnly              // No camera frame provided (e.g., headless unit test)
    case noContainerOrLiquid    // Blank wall, floor, countertop shadow, or non-vessel object
    case clearAqueous           // Clear/colorless water or aqueous solution in cup, glass, bowl, or bottle
    case milkOpaqueWhite        // Opaque white dairy/plant milk inside vessel
    case darkBeverage           // Coffee, espresso, cola, or dark tea inside vessel
    case citrusOrAmberJuice     // Vivid orange/yellow/berry turbid juice or beverage
    case goldenOil              // High-chroma translucent golden cooking/vegetable oil
    case coloredPackagedLiquid  // Dyed blue/green/purple bottled liquid or household solution
    case labeledWater           // Bottle label explicitly indicates water
    case labeledSaline          // Label indicates saline / electrolyte / sodium chloride
    case labeledVinegar         // Label indicates vinegar / acetic acid
    case labeledOil             // Label indicates cooking / olive / vegetable / canola oil
    case labeledMilk            // Label indicates milk / cream
    case labeledJuice           // Label indicates juice / citrus
    case labeledCoffeeOrCola    // Label indicates coffee / tea / cola / soda
    case labeledAlcohol         // Label indicates isopropyl / rubbing alcohol / ethanol
    case labeledSurfactant      // Label indicates mouthwash / soap / cleaner / detergent
}

public struct VisualContextSummary: Equatable, Sendable {
    public let hint: VisualLiquidHint
    public let vesselDetected: Bool
    public let hasBarcode: Bool
    public let centerSaturationWB: Double
    public let centerHueDegrees: Double
    public let centerBrightness: Double

    public static let audioOnlyDefault = VisualContextSummary(
        hint: .audioOnly,
        vesselDetected: true,
        hasBarcode: false,
        centerSaturationWB: 0.0,
        centerHueDegrees: 0.0,
        centerBrightness: 0.5
    )
}

public struct VisualLiquidContextAnalyzer: Sendable {
    public init() {}

    public func analyze(jpegData: Data?) -> VisualContextSummary {
        guard let jpegData,
              !jpegData.isEmpty,
              let imgSource = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSource, 0, nil) else {
            return .audioOnlyDefault
        }

        // 1. White-balance-normalized reticle pixel optics
        let optics = Self.extractNormalizedOptics(from: cgImage)

        // 2. On-device Vision scene taxonomy, label text, and barcode check
        var recognizedWords = ""
        var hasBarcode = false
        var vesselScore = 0.0
        var nonVesselSurfaceScore = 0.0

        let classifyReq = VNClassifyImageRequest()
        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .fast
        textReq.usesLanguageCorrection = false
        let barcodeReq = VNDetectBarcodesRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([classifyReq, textReq, barcodeReq])

        if let textObs = textReq.results {
            let lines = textObs.compactMap { $0.topCandidates(1).first?.string.lowercased() }
            recognizedWords = lines.joined(separator: " ")
        }

        if let barcodes = barcodeReq.results, !barcodes.isEmpty {
            hasBarcode = true
        }

        if let sceneObs = classifyReq.results {
            let vesselKeywords = [
                "cup", "mug", "glass", "beaker", "bottle", "jar", "bowl", "pitcher",
                "wine", "liquid", "water", "beverage", "drink", "coffee", "tea",
                "milk", "juice", "soda", "beer", "cocktail", "soup", "sink", "basin",
                "tub", "bucket", "vase", "container", "tableware", "dish", "pot", "toilet"
            ]
            let blankSurfaceKeywords = [
                "wall", "ceiling", "floor", "carpet", "curtain", "laptop", "keyboard",
                "monitor", "television", "bed", "couch", "pillow", "clothing", "shoe", "door"
            ]

            for obs in sceneObs where obs.confidence >= 0.03 {
                let id = obs.identifier.lowercased()
                if vesselKeywords.contains(where: { id.contains($0) }) {
                    vesselScore = max(vesselScore, Double(obs.confidence))
                }
                if blankSurfaceKeywords.contains(where: { id.contains($0) }) {
                    nonVesselSurfaceScore = max(nonVesselSurfaceScore, Double(obs.confidence))
                }
            }
        }

        // 3. Explicit label keyword match (when scanning a labeled bottle or carton)
        if !recognizedWords.isEmpty {
            if Self.containsAny(recognizedWords, ["vinegar", "acetic"]) {
                return summary(.labeledVinegar, vessel: true, barcode: hasBarcode, optics: optics)
            }
            if Self.containsAny(recognizedWords, ["olive oil", "vegetable oil", "canola", "cooking oil", "avocado oil", "sesame oil"]) {
                return summary(.labeledOil, vessel: true, barcode: hasBarcode, optics: optics)
            }
            if Self.containsAny(recognizedWords, ["isopropyl", "rubbing alcohol", "ethanol", "antiseptic alcohol"]) {
                return summary(.labeledAlcohol, vessel: true, barcode: hasBarcode, optics: optics)
            }
            if Self.containsAny(recognizedWords, ["saline", "sodium chloride", "electrolyte", "pedialyte"]) {
                return summary(.labeledSaline, vessel: true, barcode: hasBarcode, optics: optics)
            }
            if Self.containsAny(recognizedWords, ["mouthwash", "listerine", "detergent", "dish soap", "hand soap", "cleaner", "shampoo", "bleach", "lotion", "wash"]) {
                return summary(.labeledSurfactant, vessel: true, barcode: hasBarcode, optics: optics)
            }
            if Self.containsAny(recognizedWords, ["milk", "cream", "dairy"]) {
                return summary(.labeledMilk, vessel: true, barcode: hasBarcode, optics: optics)
            }
            if Self.containsAny(recognizedWords, ["orange juice", "apple juice", "lemon juice", "fruit juice", "lemonade"]) {
                return summary(.labeledJuice, vessel: true, barcode: hasBarcode, optics: optics)
            }
            if Self.containsAny(recognizedWords, ["coffee", "espresso", "cola", "pepsi", "coca-cola", "iced tea"]) {
                return summary(.labeledCoffeeOrCola, vessel: true, barcode: hasBarcode, optics: optics)
            }
            if Self.containsAny(recognizedWords, ["purified water", "distilled water", "spring water", "drinking water", "mineral water", "smartwater", "dasani", "aquafina", "fiji", "evian"]) {
                return summary(.labeledWater, vessel: true, barcode: hasBarcode, optics: optics)
            }
        }

        // 4. Non-Liquid / Blank Wall / Covered Lens Rejection
        // Calibrated against real iPhone close-ups so close-in bowls/cups of water (rimEdgeContrast ~0.014) pass,
        // while covered lenses, blank walls, floors, keyboards, or flat shadow-only walls are rejected.
        let isCoveredOrUniformBlank = optics.centerBrightness < 0.05 ||
            (optics.rimEdgeContrast < 0.008 && optics.specularGlintFraction < 0.002 && vesselScore < 0.03 && !hasBarcode)
        let isFlatWallShadowWithoutVessel = vesselScore < 0.03 && !hasBarcode && recognizedWords.isEmpty &&
            optics.centerSaturationWB < 0.022 && optics.rimEdgeContrast < 0.013 && optics.vividCoolColorFraction < 0.02
        let isRecognizedNonVesselObject = nonVesselSurfaceScore >= 0.24 && vesselScore < 0.05 && !hasBarcode && recognizedWords.isEmpty

        if isCoveredOrUniformBlank || isFlatWallShadowWithoutVessel || isRecognizedNonVesselObject {
            return summary(.noContainerOrLiquid, vessel: false, barcode: hasBarcode, optics: optics)
        }

        // 5. Optical Colorimetry & Meniscus Regime (White-Balance-Normalized)
        let sat = optics.centerSaturationWB
        let hue = optics.centerHueDegrees
        let val = optics.centerBrightness

        // Blue / Cyan / Teal / Green / Violet dyed liquid or bottle (even when a barcode label sits near center)
        if optics.vividCoolColorFraction >= 0.14 ||
            (sat >= 0.22 && hue >= 150.0 && hue <= 315.0) ||
            (hasBarcode && (optics.vividCoolColorFraction >= 0.08 || sat >= 0.18)) {
            return summary(.coloredPackagedLiquid, vessel: true, barcode: hasBarcode, optics: optics)
        }

        // Red / Berry / Pink beverage or packaged liquid
        if sat >= 0.32 && (hue < 14.0 || hue > 330.0) {
            return summary(.citrusOrAmberJuice, vessel: true, barcode: hasBarcode, optics: optics)
        }

        // Dark Coffee / Cola / Espresso inside a cup/glass (dark core surrounded by brighter rim)
        if val < 0.25 && (optics.outerBrightness - val) > 0.12 {
            return summary(.darkBeverage, vessel: true, barcode: hasBarcode, optics: optics)
        }

        // Vivid Orange / Citrus Juice (hue 14° - 40°, strong WB-corrected saturation)
        if sat >= 0.36 && hue >= 14.0 && hue < 40.0 {
            return summary(.citrusOrAmberJuice, vessel: true, barcode: hasBarcode, optics: optics)
        }

        // Golden Cooking / Vegetable Oil: requires STRONG white-balance-normalized yellow-gold chroma (sat >= 0.42)
        // so warm 2700K indoor lighting on clear water in a ceramic cup/bowl (satWB ~0.12) is NEVER mistaken for oil!
        if sat >= 0.42 && hue >= 40.0 && hue <= 68.0 && val >= 0.32 {
            return summary(.goldenOil, vessel: true, barcode: hasBarcode, optics: optics)
        }

        // Opaque Milk: uniform bright white core with very high brightness and low interior variance
        if sat < 0.08 && val > 0.82 && optics.interiorVariance < 0.003 && optics.rimEdgeContrast >= 0.018 && !hasBarcode {
            return summary(.milkOpaqueWhite, vessel: true, barcode: hasBarcode, optics: optics)
        }

        // Default validated container holding clear / neutral / lightly tinted liquid -> Clear Aqueous (Water)
        return summary(.clearAqueous, vessel: true, barcode: hasBarcode, optics: optics)
    }

    private func summary(
        _ hint: VisualLiquidHint,
        vessel: Bool,
        barcode: Bool,
        optics: NormalizedOptics
    ) -> VisualContextSummary {
        VisualContextSummary(
            hint: hint,
            vesselDetected: vessel,
            barcode: barcode,
            optics: optics
        )
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    // MARK: - Illuminant-Normalized Reticle Pixel Analysis

    fileprivate struct NormalizedOptics {
        let centerSaturationWB: Double
        let centerHueDegrees: Double
        let centerBrightness: Double
        let outerBrightness: Double
        let specularGlintFraction: Double
        let rimEdgeContrast: Double
        let interiorVariance: Double
        let vividCoolColorFraction: Double
    }

    private static func extractNormalizedOptics(from cgImage: CGImage) -> NormalizedOptics {
        let gridSize = 48
        var pixels = [UInt8](repeating: 0, count: gridSize * gridSize * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: gridSize,
            height: gridSize,
            bitsPerComponent: 8,
            bytesPerRow: gridSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NormalizedOptics(
                centerSaturationWB: 0.0,
                centerHueDegrees: 0.0,
                centerBrightness: 0.5,
                outerBrightness: 0.5,
                specularGlintFraction: 0.01,
                rimEdgeContrast: 0.05,
                interiorVariance: 0.01,
                vividCoolColorFraction: 0.0
            )
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: gridSize, height: gridSize))

        // Estimate scene illuminant white point from neutral/bright outer-ring pixels (cancels warm 2700K indoor bulbs)
        var outerRSum = 0.0
        var outerGSum = 0.0
        var outerBSum = 0.0
        var outerCount = 0.0
        var outerLumaSum = 0.0
        var outerTotalCount = 0.0

        var lumaGrid = [Double](repeating: 0.0, count: gridSize * gridSize)

        for y in 0..<gridSize {
            for x in 0..<gridSize {
                let idx = (y * gridSize + x) * 4
                let r = Double(pixels[idx]) / 255.0
                let g = Double(pixels[idx + 1]) / 255.0
                let b = Double(pixels[idx + 2]) / 255.0
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                lumaGrid[y * gridSize + x] = luma

                let dx = (Double(x) - 23.5) / 24.0
                let dy = (Double(y) - 23.5) / 24.0
                let rad = sqrt(dx * dx + dy * dy)
                if rad >= 0.55 {
                    outerLumaSum += luma
                    outerTotalCount += 1.0
                    let maxC = max(r, max(g, b))
                    let minC = min(r, min(g, b))
                    let rawSat = maxC > 0.05 ? (maxC - minC) / maxC : 0.0
                    if luma > 0.20 && rawSat < 0.40 {
                        outerRSum += r
                        outerGSum += g
                        outerBSum += b
                        outerCount += 1.0
                    }
                }
            }
        }

        let wbGainR: Double
        let wbGainB: Double
        if outerCount >= 20 && outerGSum > 1.0 {
            let avgR = outerRSum / outerCount
            let avgG = outerGSum / outerCount
            let avgB = outerBSum / outerCount
            wbGainR = min(1.28, max(0.76, avgG / max(0.05, avgR)))
            wbGainB = min(1.32, max(0.76, avgG / max(0.05, avgB)))
        } else {
            wbGainR = 1.0
            wbGainB = 1.0
        }

        // Measure inner liquid core (radius <= 0.38) and broader reticle color occupancy (middle 83%)
        var cRSum = 0.0
        var cGSum = 0.0
        var cBSum = 0.0
        var cLumaSum = 0.0
        var cLumaSqSum = 0.0
        var cCount = 0.0
        var glintCount = 0.0
        var coolColorCount = 0.0
        var roiCount = 0.0

        for y in 4..<(gridSize - 4) {
            for x in 4..<(gridSize - 4) {
                let idx = (y * gridSize + x) * 4
                let rRaw = Double(pixels[idx]) / 255.0
                let gRaw = Double(pixels[idx + 1]) / 255.0
                let bRaw = Double(pixels[idx + 2]) / 255.0

                let r = min(1.0, rRaw * wbGainR)
                let g = gRaw
                let b = min(1.0, bRaw * wbGainB)

                let pxMax = max(r, max(g, b))
                let pxMin = min(r, min(g, b))
                let pxDelta = pxMax - pxMin
                let pxSat = pxMax > 0.08 ? (pxDelta / pxMax) : 0.0
                if pxSat >= 0.28 && pxDelta > 0.01 {
                    var pxHue = 0.0
                    if pxMax == r {
                        pxHue = 60.0 * (((g - b) / pxDelta).truncatingRemainder(dividingBy: 6.0))
                    } else if pxMax == g {
                        pxHue = 60.0 * (((b - r) / pxDelta) + 2.0)
                    } else {
                        pxHue = 60.0 * (((r - g) / pxDelta) + 4.0)
                    }
                    if pxHue < 0.0 { pxHue += 360.0 }
                    if pxHue >= 145.0 && pxHue <= 320.0 {
                        coolColorCount += 1.0
                    }
                }
                roiCount += 1.0

                let dx = (Double(x) - 23.5) / 24.0
                let dy = (Double(y) - 23.5) / 24.0
                let rad = sqrt(dx * dx + dy * dy)
                guard rad <= 0.38 else { continue }

                let luma = lumaGrid[y * gridSize + x]
                cRSum += r
                cGSum += g
                cBSum += b
                cLumaSum += luma
                cLumaSqSum += luma * luma
                cCount += 1.0

                let maxRaw = max(rRaw, max(gRaw, bRaw))
                let minRaw = min(rRaw, min(gRaw, bRaw))
                if maxRaw > 0.88 && (maxRaw - minRaw) < 0.14 {
                    glintCount += 1.0
                }
            }
        }

        let meanR = cCount > 0 ? cRSum / cCount : 0.5
        let meanG = cCount > 0 ? cGSum / cCount : 0.5
        let meanB = cCount > 0 ? cBSum / cCount : 0.5
        let meanLuma = cCount > 0 ? cLumaSum / cCount : 0.5
        let variance = cCount > 0 ? max(0.0, (cLumaSqSum / cCount) - (meanLuma * meanLuma)) : 0.0

        let maxC = max(meanR, max(meanG, meanB))
        let minC = min(meanR, min(meanG, meanB))
        let delta = maxC - minC
        let satWB = maxC > 0.04 ? (delta / maxC) : 0.0

        var hueDeg = 0.0
        if delta > 0.005 {
            if maxC == meanR {
                hueDeg = 60.0 * (((meanG - meanB) / delta).truncatingRemainder(dividingBy: 6.0))
            } else if maxC == meanG {
                hueDeg = 60.0 * (((meanB - meanR) / delta) + 2.0)
            } else {
                hueDeg = 60.0 * (((meanR - meanG) / delta) + 4.0)
            }
            if hueDeg < 0.0 { hueDeg += 360.0 }
        }

        // Compute rim/container edge gradient across the middle 75% of the frame
        var gradSum = 0.0
        var gradCount = 0.0
        for y in 6..<(gridSize - 7) {
            for x in 6..<(gridSize - 7) {
                let c = lumaGrid[y * gridSize + x]
                let gx = abs(lumaGrid[y * gridSize + x + 1] - c)
                let gy = abs(lumaGrid[(y + 1) * gridSize + x] - c)
                gradSum += (gx + gy)
                gradCount += 2.0
            }
        }

        return NormalizedOptics(
            centerSaturationWB: satWB,
            centerHueDegrees: hueDeg,
            centerBrightness: meanLuma,
            outerBrightness: outerTotalCount > 0 ? outerLumaSum / outerTotalCount : meanLuma,
            specularGlintFraction: cCount > 0 ? glintCount / cCount : 0.0,
            rimEdgeContrast: gradCount > 0 ? gradSum / gradCount : 0.0,
            interiorVariance: variance,
            vividCoolColorFraction: roiCount > 0 ? coolColorCount / roiCount : 0.0
        )
    }
}

extension VisualContextSummary {
    fileprivate init(
        hint: VisualLiquidHint,
        vesselDetected: Bool,
        barcode: Bool,
        optics: VisualLiquidContextAnalyzer.NormalizedOptics
    ) {
        self.hint = hint
        self.vesselDetected = vesselDetected
        self.hasBarcode = barcode
        self.centerSaturationWB = optics.centerSaturationWB
        self.centerHueDegrees = optics.centerHueDegrees
        self.centerBrightness = optics.centerBrightness
    }
}
