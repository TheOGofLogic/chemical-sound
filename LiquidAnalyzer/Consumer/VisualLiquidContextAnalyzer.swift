import CoreGraphics
import Foundation
import ImageIO
import Vision

/// High-level visual context category extracted on-device from the camera frame.
/// Requires positive container/liquid evidence so solid walls or non-liquid objects never default to H₂O.
public enum VisualLiquidHint: String, Equatable, Sendable {
    case audioOnly                   // No camera frame provided (headless acoustic unit test)
    case solidOrNonLiquid            // Wall, desk, floor, furniture, hand, electronics, or flat non-vessel surface
    case openVesselAqueousOrGeneral  // Validated cup, mug, glass, or bowl (clear OR opaque) — acoustic features decide
    case milkOpaqueWhite             // Homogeneous bright opaque white liquid inside vessel
    case darkBeverage                // Deep dark coffee/cola pool inside brighter vessel rim
    case citrusOrAmberJuice          // Vivid orange/berry liquid pool inside vessel
    case goldenOil                   // High-chroma translucent golden cooking/vegetable oil
    case brownPeroxideBottle         // Dark amber/brown topical peroxide bottle
    case coloredPackagedBottle       // Dyed blue/green/purple commercial packaged bottle
    case labeledWater                // Label explicitly indicates water
    case labeledSaline               // Label indicates saline / salt / sodium chloride / electrolyte
    case labeledPeroxide             // Label indicates hydrogen peroxide / H₂O₂ / topical antiseptic
    case labeledVinegar              // Label indicates vinegar / acetic acid
    case labeledOil                  // Label indicates cooking / olive / vegetable / canola oil
    case labeledMilk                 // Label indicates milk / cream
    case labeledJuice                // Label indicates juice / citrus / lemonade
    case labeledCoffeeOrCola         // Label indicates coffee / tea / cola / soda
    case labeledAlcohol              // Label indicates isopropyl / rubbing alcohol / ethanol
    case labeledSurfactant           // Label indicates mouthwash / soap / cleaner / detergent
}

public struct VisualContextSummary: Equatable, Sendable {
    public let hint: VisualLiquidHint
    public let vesselDetected: Bool
    public let vesselConfidence: Double
    public let solidSurfaceConfidence: Double
    public let hasBarcode: Bool
    public let innerSaturationWB: Double
    public let innerHueDegrees: Double
    public let innerBrightness: Double
    public let innerSpatialContrast: Double
    public let rimContrast: Double

    public static let audioOnlyDefault = VisualContextSummary(
        hint: .audioOnly,
        vesselDetected: true,
        vesselConfidence: 1.0,
        solidSurfaceConfidence: 0.0,
        hasBarcode: false,
        innerSaturationWB: 0.0,
        innerHueDegrees: 0.0,
        innerBrightness: 0.5,
        innerSpatialContrast: 0.02,
        rimContrast: 0.04
    )
}

public struct VisualLiquidContextAnalyzer: Sendable {
    public init() {}

    public func analyze(jpegData: Data?, sceneContextJPEGData: Data? = nil) -> VisualContextSummary {
        let primaryData = jpegData ?? sceneContextJPEGData
        guard let primaryData,
              !primaryData.isEmpty,
              let thumbSource = CGImageSourceCreateWithData(primaryData as CFData, nil),
              let thumbCG = CGImageSourceCreateImageAtIndex(thumbSource, 0, nil) else {
            return .audioOnlyDefault
        }

        let fullSceneCG: CGImage
        if let sceneContextJPEGData,
           !sceneContextJPEGData.isEmpty,
           let fullSource = CGImageSourceCreateWithData(sceneContextJPEGData as CFData, nil),
           let decodedFull = CGImageSourceCreateImageAtIndex(fullSource, 0, nil) {
            fullSceneCG = decodedFull
        } else {
            fullSceneCG = thumbCG
        }

        // 1. White-balance-normalized inner-meniscus vs. container-rim optics & 4-quadrant closed rim geometry
        let reticleOptics = Self.extractNormalizedOptics(from: thumbCG)
        let fullOptics = (fullSceneCG === thumbCG) ? reticleOptics : Self.extractNormalizedOptics(from: fullSceneCG)
        let bestAnnularRim = max(reticleOptics.annularRimThirdQuadrant, fullOptics.annularRimThirdQuadrant)

        // 2. Full-FOV Vision taxonomy, OCR label text, and barcode detection
        var recognizedWords = ""
        var hasBarcode = false
        var vesselScore = 0.0
        var solidSurfaceScore = 0.0

        let classifyReq = VNClassifyImageRequest()
        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .fast
        textReq.usesLanguageCorrection = false
        let barcodeReq = VNDetectBarcodesRequest()

        let handler = VNImageRequestHandler(cgImage: fullSceneCG, options: [:])
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
                "liquid", "water", "fluid", "beverage", "drink", "cup", "mug", "teacup",
                "glass", "goblet", "tumbler", "wine", "chalice", "bottle", "flask", "vial",
                "beaker", "jar", "jug", "pitcher", "carafe", "bowl", "basin", "sink",
                "tub", "toilet", "bucket", "pail", "pot", "pan", "kettle", "teapot",
                "can", "carton", "tableware", "dishware", "crockery", "porcelain", "ceramic",
                "coffee", "espresso", "latte", "tea", "milk", "cream", "juice", "lemonade",
                "soda", "cola", "beer", "cocktail", "liquor", "soup", "broth", "sauce",
                "syrup", "oil", "vinegar", "condiment", "soap", "detergent", "lotion",
                "shampoo", "cosmetics", "medicine", "toiletry"
            ]
            let solidKeywords = [
                "wall", "drywall", "plaster", "paint", "brick", "concrete", "cement", "masonry",
                "ceiling", "roof", "floor", "flooring", "hardwood", "wood", "lumber", "plywood",
                "plank", "carpet", "rug", "mat", "door", "window", "blinds", "curtain", "drapery",
                "room", "interior", "hallway", "corridor", "stair", "architecture", "building",
                "furniture", "couch", "sofa", "chair", "bed", "mattress", "pillow", "blanket",
                "cabinet", "cupboard", "drawer", "shelf", "bookcase", "closet", "desk", "office",
                "computer", "laptop", "keyboard", "mouse", "monitor", "display", "screen",
                "television", "electronics", "cable", "outlet", "switch", "lamp", "person",
                "human", "face", "hand", "finger", "arm", "leg", "foot", "skin", "clothing",
                "shirt", "pants", "shoe", "bag", "backpack", "paper", "book", "notebook",
                "document", "cardboard", "box", "fabric", "textile", "cloth", "towel", "plant",
                "leaf", "tree", "grass", "rock", "stone", "road", "sidewalk", "sky"
            ]

            for obs in sceneObs where obs.confidence >= 0.03 {
                let id = obs.identifier.lowercased()
                if vesselKeywords.contains(where: { id.contains($0) }) {
                    vesselScore = max(vesselScore, Double(obs.confidence))
                }
                if solidKeywords.contains(where: { id.contains($0) }) {
                    solidSurfaceScore = max(solidSurfaceScore, Double(obs.confidence))
                }
            }
        }

        // 3. Explicit label keyword match (bottle / carton OCR)
        if !recognizedWords.isEmpty {
            if Self.containsAny(recognizedWords, ["peroxide", "h2o2", "h₂o₂", "antiseptic", "topical solution"]) {
                return makeSummary(.labeledPeroxide, vessel: true, vScore: max(vesselScore, 0.9), sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
            }
            if Self.containsAny(recognizedWords, ["vinegar", "acetic"]) {
                return makeSummary(.labeledVinegar, vessel: true, vScore: max(vesselScore, 0.9), sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
            }
            if Self.containsAny(recognizedWords, ["olive oil", "vegetable oil", "canola", "cooking oil", "avocado oil", "sesame oil"]) {
                return makeSummary(.labeledOil, vessel: true, vScore: max(vesselScore, 0.9), sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
            }
            if Self.containsAny(recognizedWords, ["isopropyl", "rubbing alcohol", "ethanol"]) {
                return makeSummary(.labeledAlcohol, vessel: true, vScore: max(vesselScore, 0.9), sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
            }
            if Self.containsAny(recognizedWords, ["saline", "sodium chloride", "salt water", "electrolyte", "pedialyte"]) {
                return makeSummary(.labeledSaline, vessel: true, vScore: max(vesselScore, 0.9), sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
            }
            if Self.containsAny(recognizedWords, ["mouthwash", "listerine", "detergent", "dish soap", "hand soap", "cleaner", "shampoo", "bleach", "lotion", "body wash"]) {
                return makeSummary(.labeledSurfactant, vessel: true, vScore: max(vesselScore, 0.9), sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
            }
            if Self.containsAny(recognizedWords, ["milk", "cream", "dairy"]) {
                return makeSummary(.labeledMilk, vessel: true, vScore: max(vesselScore, 0.9), sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
            }
            if Self.containsAny(recognizedWords, ["orange juice", "apple juice", "lemon juice", "fruit juice", "lemonade"]) {
                return makeSummary(.labeledJuice, vessel: true, vScore: max(vesselScore, 0.9), sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
            }
            if Self.containsAny(recognizedWords, ["coffee", "espresso", "cola", "pepsi", "coca-cola", "iced tea"]) {
                return makeSummary(.labeledCoffeeOrCola, vessel: true, vScore: max(vesselScore, 0.9), sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
            }
            if Self.containsAny(recognizedWords, ["purified water", "distilled water", "spring water", "drinking water", "mineral water", "smartwater", "dasani", "aquafina", "fiji", "evian"]) {
                return makeSummary(.labeledWater, vessel: true, vScore: max(vesselScore, 0.9), sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
            }
        }

        // 4. Positive Container / Liquid Evidence Gate — Rejects Walls, Furniture, Floors, & Non-Liquids!
        // Never defaults unknown scenes or painted walls to H₂O.
        let isDarkOrCovered = reticleOptics.innerBrightness < 0.05
        let hasIsoluminantChromaticPool = (reticleOptics.innerSaturationWB - reticleOptics.rimSaturationWB) >= 0.26
            && bestAnnularRim >= 0.010
        let isSolidDominated = solidSurfaceScore >= 0.12
            && vesselScore < max(0.08, solidSurfaceScore * 0.65)
            && !hasBarcode
            && !hasIsoluminantChromaticPool
        let lacksAnyContainerEvidence = vesselScore < 0.045
            && !hasBarcode
            && bestAnnularRim < 0.022
            && !hasIsoluminantChromaticPool

        if isDarkOrCovered || isSolidDominated || lacksAnyContainerEvidence {
            return makeSummary(
                .solidOrNonLiquid,
                vessel: false,
                vScore: vesselScore,
                sScore: max(solidSurfaceScore, isDarkOrCovered ? 0.8 : 0.4),
                barcode: hasBarcode,
                optics: reticleOptics
            )
        }

        // 5. Interior Meniscus vs. Container-Wall Optical Analysis
        // Only looks at the inner pool (rad <= 0.24) relative to the rim (0.36..0.64) so opaque colored
        // mugs or bowls holding water/salt water/peroxide are NEVER misclassified by their mug color!
        let innerSat = reticleOptics.innerSaturationWB
        let rimSat = reticleOptics.rimSaturationWB
        let innerHue = reticleOptics.innerHueDegrees
        let innerVal = reticleOptics.innerBrightness
        let rimVal = reticleOptics.rimBrightness

        // Classic dark brown opaque Hydrogen Peroxide bottle (with barcode or bottle silhouette)
        if hasBarcode && innerVal >= 0.10 && innerVal <= 0.36 && innerHue >= 14.0 && innerHue <= 42.0 && innerSat >= 0.24 {
            return makeSummary(.brownPeroxideBottle, vessel: true, vScore: vesselScore, sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
        }

        // Commercial barcoded dyed bottle OR uniform full-bottle vivid cool color (both rim & interior are vivid blue/green/violet)
        if (hasBarcode && (reticleOptics.vividCoolColorFraction >= 0.10 || innerSat >= 0.22)) ||
            (innerSat >= 0.45 && rimSat >= 0.45 && innerHue >= 150.0 && innerHue <= 315.0) {
            return makeSummary(.coloredPackagedBottle, vessel: true, vScore: vesselScore, sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
        }

        // Golden Cooking / Vegetable Oil: strong WB-normalized yellow-gold chroma in inner liquid core
        // AND higher saturation inside the liquid than on the container rim!
        if innerSat >= 0.42 && innerSat >= (rimSat + 0.12) && innerHue >= 40.0 && innerHue <= 68.0 && innerVal >= 0.32 {
            return makeSummary(.goldenOil, vessel: true, vScore: vesselScore, sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
        }

        // Vivid Orange / Citrus / Berry Juice: inner liquid pool itself is strongly chromatic (more than rim)
        if innerSat >= 0.42 && innerSat >= (rimSat + 0.10) && ((innerHue >= 12.0 && innerHue < 40.0) || innerHue < 12.0 || innerHue > 332.0) {
            return makeSummary(.citrusOrAmberJuice, vessel: true, vScore: vesselScore, sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
        }

        // Deep Dark Coffee / Cola inside a brighter cup/glass rim
        if innerVal < 0.18 && (rimVal - innerVal) > 0.22 {
            return makeSummary(.darkBeverage, vessel: true, vScore: vesselScore, sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
        }

        // Opaque Pure White Milk inside a darker/contrasting rim
        if innerSat < 0.07 && innerVal > 0.84 && reticleOptics.innerVariance < 0.0025 && (innerVal - rimVal) > 0.10 && !hasBarcode {
            return makeSummary(.milkOpaqueWhite, vessel: true, vScore: vesselScore, sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
        }

        // Validated open cup, mug, glass, bowl, or clear bottle — let 5D acoustic features classify fairly!
        return makeSummary(.openVesselAqueousOrGeneral, vessel: true, vScore: vesselScore, sScore: solidSurfaceScore, barcode: hasBarcode, optics: reticleOptics)
    }

    private func makeSummary(
        _ hint: VisualLiquidHint,
        vessel: Bool,
        vScore: Double,
        sScore: Double,
        barcode: Bool,
        optics: NormalizedOptics
    ) -> VisualContextSummary {
        VisualContextSummary(
            hint: hint,
            vesselDetected: vessel,
            vesselConfidence: vScore,
            solidSurfaceConfidence: sScore,
            hasBarcode: barcode,
            innerSaturationWB: optics.innerSaturationWB,
            innerHueDegrees: optics.innerHueDegrees,
            innerBrightness: optics.innerBrightness,
            innerSpatialContrast: sqrt(optics.innerVariance),
            rimContrast: optics.annularRimThirdQuadrant
        )
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    // MARK: - Illuminant-Normalized Inner-Meniscus vs. Container-Rim Pixel & Geometry Analysis

    fileprivate struct NormalizedOptics {
        let innerSaturationWB: Double
        let innerHueDegrees: Double
        let innerBrightness: Double
        let rimSaturationWB: Double
        let rimBrightness: Double
        let innerVariance: Double
        let vividCoolColorFraction: Double
        let annularRimThirdQuadrant: Double
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
                innerSaturationWB: 0.0,
                innerHueDegrees: 0.0,
                innerBrightness: 0.5,
                rimSaturationWB: 0.0,
                rimBrightness: 0.5,
                innerVariance: 0.01,
                vividCoolColorFraction: 0.0,
                annularRimThirdQuadrant: 0.0
            )
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: gridSize, height: gridSize))

        // 1. Estimate scene illuminant white point from neutral outer background ring (rad >= 0.66)
        var bgRSum = 0.0
        var bgGSum = 0.0
        var bgBSum = 0.0
        var bgCount = 0.0
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
                if rad >= 0.66 {
                    let maxC = max(r, max(g, b))
                    let minC = min(r, min(g, b))
                    let rawSat = maxC > 0.05 ? (maxC - minC) / maxC : 0.0
                    if luma > 0.18 && rawSat < 0.38 {
                        bgRSum += r
                        bgGSum += g
                        bgBSum += b
                        bgCount += 1.0
                    }
                }
            }
        }

        let wbGainR: Double
        let wbGainB: Double
        if bgCount >= 16 && bgGSum > 0.8 {
            let avgR = bgRSum / bgCount
            let avgG = bgGSum / bgCount
            let avgB = bgBSum / bgCount
            wbGainR = min(1.28, max(0.76, avgG / max(0.05, avgR)))
            wbGainB = min(1.32, max(0.76, avgG / max(0.05, avgB)))
        } else {
            wbGainR = 1.0
            wbGainB = 1.0
        }

        // 2. Separate inner liquid core (rad <= 0.25) from container rim/wall zone (0.38 <= rad <= 0.64)
        var inR = 0.0, inG = 0.0, inB = 0.0, inLuma = 0.0, inLumaSq = 0.0, inCnt = 0.0
        var rimR = 0.0, rimG = 0.0, rimB = 0.0, rimLuma = 0.0, rimCnt = 0.0
        var coolCount = 0.0, roiCount = 0.0

        for y in 3..<(gridSize - 3) {
            for x in 3..<(gridSize - 3) {
                let idx = (y * gridSize + x) * 4
                let r = min(1.0, (Double(pixels[idx]) / 255.0) * wbGainR)
                let g = Double(pixels[idx + 1]) / 255.0
                let b = min(1.0, (Double(pixels[idx + 2]) / 255.0) * wbGainB)
                let luma = lumaGrid[y * gridSize + x]

                let pxMax = max(r, max(g, b))
                let pxMin = min(r, min(g, b))
                let pxDelta = pxMax - pxMin
                let pxSat = pxMax > 0.08 ? (pxDelta / pxMax) : 0.0
                if pxSat >= 0.28 && pxDelta > 0.01 {
                    let h = Self.rgbToHueDegrees(r: r, g: g, b: b, maxC: pxMax, delta: pxDelta)
                    if h >= 145.0 && h <= 320.0 { coolCount += 1.0 }
                }
                roiCount += 1.0

                let dx = (Double(x) - 23.5) / 24.0
                let dy = (Double(y) - 23.5) / 24.0
                let rad = sqrt(dx * dx + dy * dy)

                if rad <= 0.25 {
                    inR += r; inG += g; inB += b
                    inLuma += luma; inLumaSq += luma * luma
                    inCnt += 1.0
                } else if rad >= 0.38 && rad <= 0.64 {
                    rimR += r; rimG += g; rimB += b
                    rimLuma += luma
                    rimCnt += 1.0
                }
            }
        }

        let meanInR = inCnt > 0 ? inR / inCnt : 0.5
        let meanInG = inCnt > 0 ? inG / inCnt : 0.5
        let meanInB = inCnt > 0 ? inB / inCnt : 0.5
        let meanInLuma = inCnt > 0 ? inLuma / inCnt : 0.5
        let inVar = inCnt > 0 ? max(0.0, (inLumaSq / inCnt) - (meanInLuma * meanInLuma)) : 0.0

        let inMax = max(meanInR, max(meanInG, meanInB))
        let inMin = min(meanInR, min(meanInG, meanInB))
        let inDelta = inMax - inMin
        let inSatWB = inMax > 0.04 ? (inDelta / inMax) : 0.0
        let inHue = Self.rgbToHueDegrees(r: meanInR, g: meanInG, b: meanInB, maxC: inMax, delta: inDelta)

        let meanRimR = rimCnt > 0 ? rimR / rimCnt : meanInR
        let meanRimG = rimCnt > 0 ? rimG / rimCnt : meanInG
        let meanRimB = rimCnt > 0 ? rimB / rimCnt : meanInB
        let meanRimLuma = rimCnt > 0 ? rimLuma / rimCnt : meanInLuma
        let rimMax = max(meanRimR, max(meanRimG, meanRimB))
        let rimMin = min(meanRimR, min(meanRimG, meanRimB))
        let rimSatWB = rimMax > 0.04 ? ((rimMax - rimMin) / rimMax) : 0.0

        // 3. 4-Quadrant Annular Rim Symmetry (rejects flat walls & 1D straight shadows while accepting closed rims)
        var quadGradSum = [Double](repeating: 0.0, count: 4)
        var quadGradCnt = [Double](repeating: 0.0, count: 4)
        for y in 2..<(gridSize - 3) {
            for x in 2..<(gridSize - 3) {
                let dx = (Double(x) - 23.5) / 24.0
                let dy = (Double(y) - 23.5) / 24.0
                let rad = sqrt(dx * dx + dy * dy)
                guard rad >= 0.26 && rad <= 0.72 else { continue }

                let c = lumaGrid[y * gridSize + x]
                let g = abs(lumaGrid[y * gridSize + x + 1] - c) + abs(lumaGrid[(y + 1) * gridSize + x] - c)
                let q = (y >= 24 ? 2 : 0) + (x >= 24 ? 1 : 0)
                quadGradSum[q] += g
                quadGradCnt[q] += 2.0
            }
        }
        let quadMeans = (0..<4).map { q in quadGradCnt[q] > 0 ? quadGradSum[q] / quadGradCnt[q] : 0.0 }.sorted()
        // Require at least 3 of 4 quadrants to exhibit rim gradient (index 1 in ascending sorted 4-element array)
        let thirdBestQuadrantRim = quadMeans[1]

        return NormalizedOptics(
            innerSaturationWB: inSatWB,
            innerHueDegrees: inHue,
            innerBrightness: meanInLuma,
            rimSaturationWB: rimSatWB,
            rimBrightness: meanRimLuma,
            innerVariance: inVar,
            vividCoolColorFraction: roiCount > 0 ? coolCount / roiCount : 0.0,
            annularRimThirdQuadrant: thirdBestQuadrantRim
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
