# LA-V050-FUSION-PLAN-001: Multi-Modal Sensor Fusion & Guided 3-Step Cup Comparator (`v0.5.0` Build `15`)

- **Document ID:** `LA-V050-FUSION-PLAN-001`
- **Release Target:** `v0.5.0` (`CFBundleVersion = 15`)
- **Frozen Pure-Acoustic Baseline:** `v0.4.1-build14-accepted` (`6d067cff97ef1641cce3772e72da0cd14ad593ca`)
- **Pinned Toolchain:** `xcode: "27.2"` (`macOS 27.2`, `Swift 6.4.2`, zero floating `latest` tags)

---

## 1. Architectural Overview
`v0.5.0` (Build `15`) bridges the $99.94\%$ air-to-liquid acoustic reflection boundary on standalone iPhone hardware without external transducers by combining:
1. **[`VisionFeatureExtractor.swift`](../../LiquidAnalyzer/Consumer/VisionFeatureExtractor.swift):** Illuminant-white-balanced `128×128` ROI extractor computing circular-mean HSV colorimetry (`meanHueDegrees`, `meanSaturationWB`, `meanValueBrightness`), optical turbidity/opacity (`opticalTurbidity`), meniscus halo transmittance (`meniscusHaloHueDegrees`, `meniscusHaloSaturation`), and horizontal liquid-boundary meniscus contact-angle geometry (`meniscusContactAngleDegrees`, `estimatedFillFraction`).
2. **[`MultiModalFusionClassifier.swift`](../../LiquidAnalyzer/Consumer/MultiModalFusionClassifier.swift):** Covariance-weighted Mahalanobis classifier with strict distance and winning-margin gates fusing `VisionFeatureVector` with `DifferentialBaselineVector` ($\Delta \vec{F}/\vec{F}_{\text{empty}}$, $\Delta \vec{F}/\vec{F}_{\text{water}}$, $\Delta S_{\text{HF}}$, unclamped Schroeder $\alpha$), while enforcing 2D flat-spoof rejection (`REJECTED_NON_LIQUID_ACOUSTIC_FLATNESS`) and preserving `100%` of pure-acoustic `MODE_A` via `ConsumerInferenceMode.pureAcousticModeA`.
3. **[`LiquidComparatorWizardView.swift`](../../LiquidAnalyzer/Consumer/LiquidComparatorWizardView.swift):** Guided 3-Step Cup Comparator (`Step 1: Empty Cup` $\rightarrow$ `Step 2: Water Blank` $\rightarrow$ `Step 3: Test Sample`) separating clear colorless liquids (`Water` vs. `Vinegar (Acetic Acid)` vs. `Salt / Saline Water` vs. `Carbonated Seltzer`) plus transparent Dual-Channel Attribution cards on Result screens.
