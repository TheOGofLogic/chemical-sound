# LA-V050-FUSION-PLAN-001: Multi-Modal Sensor Fusion & Guided 3-Step Cup Comparator (v0.5.0 Build 16)

- **Document ID:** `LA-V050-FUSION-PLAN-001`
- **Status:** VERIFIED ON PINNED XCODE 27.2 (Codemagic Build #18: 45/45 XCTests Passed; Bumped to Build 16 for TestFlight Ingestion)
- **Release Target:** v0.5.0 (CFBundleVersion = 16; prior Build 15 uploaded via Codemagic Build #17)
- **Frozen Pure-Acoustic Baseline:** `v0.4.1-build14-accepted` (`6d067cff97ef1641cce3772e72da0cd14ad593ca`)
- **Pinned Toolchain:** `xcode: "27.2"` (`macOS 27.2`, `Swift 6.4.2`, zero floating `latest` tags; cross-checked on `macos-15` / Xcode `16.4` / Swift `6.1.2`)
- **Related Phase R3 Hardware Spec:** [`LA-R3-SPEC-001.md`](LA-R3-SPEC-001.md) (`MODE_B` External Wall-Coupled Ultrasonic Transducer — isolated future hardware track)

---

## 1. Architectural Overview
`v0.5.0` (Build `15`) bridges the $99.94\%$ air-to-liquid acoustic reflection boundary on standalone iPhone hardware without external transducers by fusing airborne container-resonance acoustics (`MODE_A`) with illuminant-normalized camera colorimetry, turbidity, and meniscus geometry (`MODE_AF_FUSION`):

1. **[`VisionFeatureExtractor.swift`](../../LiquidAnalyzer/Consumer/VisionFeatureExtractor.swift):** Decodes captured JPEGs via `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailWithTransform: true` (honoring EXIF orientation into a normalized `128×128` 8-bit `DeviceRGB` RGBA `CGContext`, avoiding raw YUV/BGRA `CVPixelBuffer` stride hazards). Estimates ambient white-balance gains (`wbGainR ∈ [0.76, 1.28]`, `wbGainB ∈ [0.76, 1.32]`) from the neutral outer ring (`rad >= 0.66`), computes unified white-balanced `lumaWB` interior variance and rim contrast, circular-mean HSV colorimetry (`meanHueDegrees`, `meanSaturationWB`, `meanValueBrightness`), optical turbidity (`opticalTurbidity`), meniscus halo transmittance (`meniscusHaloHueDegrees`, `meniscusHaloSaturation`), and polarity-locked horizontal meniscus contact-angle geometry (`meniscusContactAngleDegrees`, `meniscusEdgeStrength`, `estimatedFillFraction`).
2. **[`MultiModalFusionClassifier.swift`](../../LiquidAnalyzer/Consumer/MultiModalFusionClassifier.swift):** 64-bit `Double` Mahalanobis distance classifier (`maximumMahalanobisDistance = 2.55`, `minimumWinningMargin = 0.18`) fusing `VisionFeatureVector` with `DifferentialBaselineVector` ($\Delta \vec{F}/\vec{F}_{\text{empty}}$, $\Delta \vec{F}/\vec{F}_{\text{water}}$, $\Delta S_{\text{HF}}$, unclamped Schroeder $\alpha$). Enforces a 2D flat-screen/photo anti-spoof gate (`spectralFlatness`, `peakProminenceDB`, and `520–5850 Hz` cavity envelope), explicit container-label fusion, chromatic/turbid/effervescent classification (`OIL_VEG`, `MILK_DAIRY`, `WINE_RED`, `COLA_CARBONATED`, `COFFEE_DARK`, `CITRUS_JUICE`, `TEA_AMBER`, `SELTZER_CARBONATED`), and `100%` pure-acoustic `MODE_A` preservation via `ConsumerInferenceMode.pureAcousticModeA`.
3. **[`LiquidComparatorWizardView.swift`](../../LiquidAnalyzer/Consumer/LiquidComparatorWizardView.swift) & [`ConsumerScanCoordinator.swift`](../../LiquidAnalyzer/Consumer/ConsumerScanCoordinator.swift):** Guided 3-Step Cup Comparator (`Step 1: Empty Cup` $\rightarrow$ `Step 2: Water Blank` $\rightarrow$ `Step 3: Test Sample`) separating clear colorless aqueous liquids (`Water` vs. `Vinegar (Acetic Acid)` vs. `Salt / Saline Water` vs. `Carbonated Seltzer`), transparent Dual-Channel Attribution cards, and 55-column Repeatability Gate R1 + v0.5.0 CSV export.

---

## 2. Stability Hardening & Production Patches on `main`
Following the initial `v0.5.0` implementation (`db000bf`, `57a40f8`), four targeted hardening commits were landed on `main` to resolve cross-toolchain compilation, `Codable`/`Equatable` safety, illuminant invariance, and EXIF alignment:

| Commit | File(s) | Hardening Summary |
| :--- | :--- | :--- |
| `8a4d43f` | `ConsumerScanCoordinator.swift` | Replaced the 55-element untyped CSV `let row = [...]` array literal in `exportRepeatabilityCSVText` with an explicitly typed incremental `[String]` builder (`reserveCapacity(55)`), eliminating the Xcode `16.4` / Swift `6.1.2` (`macos-15`) expression type-checker timeout while preserving exact 55-column CSV output. |
| `5eb0c99` | `MultiModalFusionClassifier.swift` | Converted `MultiModalAttribution.mahalanobisDistance`, `secondBestDistance`, and `winningMargin` from `Double` (previously `.nan` in `uncalibratedClearLiquidGuidance`) to `Double?` (`nil`), preventing `JSONEncoder` `EncodingError.invalidValue` failures and preserving `Equatable` reflexivity; enforced `meanValueBrightness >= 0.24` on clear-liquid guidance; added `.isFinite` filtering/guards in sorting and `confidenceFromMahalanobis`; smoothed Vinegar/Saline `zSigned` boundary transitions. |
| `3d107d6` | `VisionFeatureExtractor.swift` | Unified interior luma variance (`lumaVar`), halo brightness, and rim contrast (`rimVal`) into white-balanced `lumaWB` space (preventing false Milk variance inflation under warm/cool lighting); enabled EXIF-oriented JPEG decoding via `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceCreateThumbnailWithTransform: true`). |
| `9f45758` | `ConsumerExperienceTests.swift` | Added `testV050_StabilityGuards_AttributionCodableDarkFrameAndWarmLightingMilk` covering `MultiModalAttribution` JSON round-trip & `Equatable` reflexivity, dark-frame exclusion from clear guidance, and warm-lit Milk white-balance turbidity (`45` total XCTests). |

---

## 3. Verification & CI Status
- **Codemagic Build #18 (`a8b8168`, `Mac mini M2`):** **PASSED** all build, test, code-signing, and IPA steps on pinned `Xcode 27.2` (`27B52`) / `macOS 27.2` (`26B123`) / `Apple Swift 6.4.2`:
  - **XCTest Verification Gate (`1m 38s`):** **`45 / 45` tests passed (`0` failures, `0` unexpected) in `70.25s`**, including the new stability regression test `testV050_StabilityGuards_AttributionCodableDarkFrameAndWarmLightingMilk` (`0.009s`).
  - **Signed IPA Artifact (`40s`):** Generated `LiquidAnalyzer.ipa` (`2.07 MB`) and `chemical-sound_18_artifacts.zip` (`23.94 KB`).
  - **Publishing Note:** App Store Connect returned `HTTP 409` (`ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE`) because `CFBundleVersion = 15` was already uploaded by Build #17. `CFBundleVersion` was bumped `15 -> 16` (`LiquidAnalyzer/Info.plist` + `codemagic.yaml`) for clean TestFlight ingestion in Codemagic Build #19.
- **Baseline v0.5.0 Run #28 (`57a40f8`):** GitHub Actions `macos-26` passed (`44 / 44` XCTests + `1.5 MB` unsigned IPA); `macos-15` failed solely at `ConsumerScanCoordinator.swift:395` (remediated in `8a4d43f`). Subsequent GitHub Actions runs (`#29`–`#35`) were cancelled prior to step execution due to GitHub hosted macOS `arm64` runner capacity constraints.
