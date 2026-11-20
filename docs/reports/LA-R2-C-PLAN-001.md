# LA-R2-C-PLAN-001: Phase R2-C (`v0.4.1` Build `14`) Calibration Workflow & Field Edge-Case Remediation Plan

**Status:** EXECUTED & VERIFIED ([LA-R2-C-VERIFICATION-REPORT-001.md](LA-R2-C-VERIFICATION-REPORT-001.md))  
**Governing Baselines:** [LA-R2-A-SANDBOX-REPORT-001.md](LA-R2-A-SANDBOX-REPORT-001.md), [LA-R2-B-FIELD-AUDIT-001.md](LA-R2-B-FIELD-AUDIT-001.md)  
**Target Release:** `v0.4.1` (`CFBundleVersion = 14`), `MODE_A` Airborne Screening Only  
**Pinned CI Toolchain:** `xcode: "27.2"` (`macOS 27.2` / `iphoneos27.2`, zero `latest` tags)

---

## 1. Objective & Scope
Live field verification of `v0.4.0` (Build `13`) across `7` stationary `20x` bursts (`Scans 192–331`, `140` scans) on the **iPhone Duo** confirmed `0 / 140` `145.0 dB/s` clamp saturation, `0%` inter-sweep ring-down bleed under `K_cond = 2` and the `900 ms` settle gap, and `100%` truth-in-labeling (`0 / 140` false chemical claims on uncalibrated runs).

Phase R2-C (`v0.4.1` Build `14`) closes the calibration loop and resolves all three field edge cases exposed by the elevated glass-on-book setup without introducing `MODE_B` or ungrounded airborne viscosity claims.

---

## 2. Architectural Specifications

### 2.1 Upgrade A — `20x` Steady-State (`Sweeps 3–20`) Baseline Action & History Reconciliation
* **Mechanism**: Add `teachCalibratedBatchBaseline(items:targetID:)` in [ConsumerScanCoordinator.swift](../../LiquidAnalyzer/Consumer/ConsumerScanCoordinator.swift) and expose a dedicated **"Save Steady-State (Sweeps 3–20) as Baseline"** menu on both:
  1. `RepeatabilityGateSummaryCard` in [ConsumerTabsView.swift](../../LiquidAnalyzer/Consumer/ConsumerTabsView.swift) (`History` tab cohort summary), and
  2. Batch result cards in [ConsumerScanFlowView.swift](../../LiquidAnalyzer/Consumer/ConsumerScanFlowView.swift).
* **Supported Baseline Targets**:
  * `EMPTY_CONTAINER` ($\vec{F}_{\text{empty}}, \vec{Q}_{\text{empty}}, \vec{\alpha}_{\text{empty}}, S_{\text{HF, empty}}$)
  * `H2O_DIST` (`WATER_REFERENCE`: $\vec{F}_{\text{water}}, \vec{Q}_{\text{water}}, \vec{\alpha}_{\text{water}}, S_{\text{HF, water}}$)
  * `SOLID_SURFACE` ($\vec{F}_{\text{solid}}$)
  * Reference liquid standards (`NACL_AQ`, `VIN_WHITE`, `OIL_VEG`, `H2O2_AQ`, etc.) for controlled bench calibration.
* **Steady-State Aggregation Rule**:
  1. Purge conditioning sweeps (`isConditioningCycle == true`, i.e., `Sweeps 1–2` where $K_{\text{cond}} = 2$) and quality-rejected `.unclearScan` rows.
  2. Compute component-wise steady-state medians across `Sweeps 3–20` for all scalar and 6-subband features, and attach the Hungarian-tracked 4-mode vector via `BatchModalVectorTracker.aggregateSteadyStateModalVector(items:purgeConditioningK2: true)` (preserving `nil` / `NaN` for absent modes).
  3. Persist `geometryCondition` on `CalibratedAcousticPrototype` (backward-compatible optional `Codable` field) and replace any stale prototype sharing the same `(targetID, geometryCondition)` so container re-calibration cleanly updates the active setup.
  4. Immediately reconcile matching-geometry items in `history` so existing uncalibrated cohorts populate $\Delta \vec{X}_{\text{empty}}$, $\Delta \vec{X}_{\text{water}}$, and calibrated `MODE_A` screening states without altering immutable raw acoustic measurements.

---

### 2.2 Upgrade B — Bubble Scatter Floor Removal & Differential Baseline Normalization ($\Delta S_{\text{HF}}$)
* **1. Strip High-Frequency Artificial Floor**:
  In [OnDeviceAcousticClassifier.swift](../../LiquidAnalyzer/Consumer/OnDeviceAcousticClassifier.swift), set the spectral residual floor strictly to `0.0` for all bins $f_b \ge 5.2\text{ kHz}$:
  $$P_{\text{clean}}(b) = \begin{cases} \max\big(0.0,\ P_{\text{unit}}(b) - 1.45 \cdot N_{\text{pre}}(b)\big) \cdot W, & f_b \ge 5.2\text{ kHz} \\ \max\big(0.04 \cdot P_{\text{unit}}(b),\ P_{\text{unit}}(b) - 1.45 \cdot N_{\text{pre}}(b)\big) \cdot W, & f_b < 5.2\text{ kHz} \end{cases}$$
* **2. Differential Scatter Gate ($\Delta S_{\text{HF}}$) + Pre-Roll Acoustic Fizz**:
  Define baseline high-frequency scatter from compatible calibrated `EMPTY_CONTAINER` and/or `H2O_DIST` standards:
  $$S_{\text{HF, ref}} = \max\big(S_{\text{HF, empty}},\ S_{\text{HF, water}}\big), \qquad \Delta S_{\text{HF}} = S_{\text{HF, sample}} - S_{\text{HF, ref}}$$
  Assert `BUBBLE_SCATTER_DETECTED` only when:
  1. **Calibrated setup** ($S_{\text{HF, ref}}$ available): $\Delta S_{\text{HF}} \ge +2.5\text{ dB}$ **and** `preRollExcessHFDB > 0.0` (genuine positive pre-roll high-frequency fizz above $0.85 \cdot P_{\text{pre, mid}}$).
  2. **Uncalibrated setup** ($S_{\text{HF, ref}}$ absent): `highFreqBubbleScatterDB >= -3.0` **and** `preRollExcessHFDB > 0.0` (preventing quiet-room empty containers, saline, vinegar, and oil from ever false-triggering `BUBBLE_SCATTER_DETECTED`).

---

### 2.3 Upgrade C — Log-Ratio Decay Normalization in Diagnostic Candidate Scoring
* **Formulation**: Align `computeFrozenCandidateDistances` in [OnDeviceAcousticClassifier.swift](../../LiquidAnalyzer/Consumer/OnDeviceAcousticClassifier.swift) with the log-ratio scale validated in `calibratedScatteringDistance`:
  $$d_{\text{decay}} = \frac{\left|\ln\!\left(\dfrac{\max(1.0,\ \alpha_{\text{dB/s}})}{\max(1.0,\ \alpha_{\text{prior, dB/s}})}\right)\right|}{0.42}$$
  This preserves `100%` of headless synthetic XCTest margins (`Water d=0.688, margin=+0.158`; `Salt d=0.487, margin=+0.592`; `Peroxide d=0.241, margin=+0.769`) while bounding diagnostic distances on `900–3,000 dB/s` real container echoes to `1.45–4.52` instead of `8.7–118.1`.

---

### 2.4 Upgrade D — Camera Stale-Thumbnail & `isCameraLive` Race Fix
* **Remediation**:
  1. In [CameraTargetingService.swift](../../LiquidAnalyzer/Consumer/CameraTargetingService.swift): set `isCameraLive = false` synchronously in `stopCamera()`, add `clearCachedFrames()` (`cachedThumbnailJPEG = nil`, `cachedSceneContextJPEG = nil`, `lastThumbnailUptime = 0`), and invoke it on both `start(...)` and `stopCamera()`.
  2. In `ConsumerScanCoordinator.startRepeatabilityGateR1Batch` (and `beginScan`): if `!cameraService.isCameraLive`, call `cameraService.clearCachedFrames()` and `cameraService.startCamera(graceDelaySeconds: 0.0)`, polling up to `900 ms` for a fresh live frame from the active session so an un-aimed launch safely passes `nil` rather than any prior run's image.

---

## 3. Verification & Release Checklist (`v0.4.1` Build `14`)
1. Applied Swift updates across [ConsumerModels.swift](../../LiquidAnalyzer/Consumer/ConsumerModels.swift), [CameraTargetingService.swift](../../LiquidAnalyzer/Consumer/CameraTargetingService.swift), [OnDeviceAcousticClassifier.swift](../../LiquidAnalyzer/Consumer/OnDeviceAcousticClassifier.swift), [ConsumerScanCoordinator.swift](../../LiquidAnalyzer/Consumer/ConsumerScanCoordinator.swift), [ConsumerTabsView.swift](../../LiquidAnalyzer/Consumer/ConsumerTabsView.swift), and [ConsumerScanFlowView.swift](../../LiquidAnalyzer/Consumer/ConsumerScanFlowView.swift).
2. Added Phase R2-C XCTests in [ConsumerExperienceTests.swift](../../LiquidAnalyzerTests/ConsumerExperienceTests.swift) (`39 / 39` XCTests passing).
3. Bumped version metadata to `0.4.1` (`Build 14`) in [Info.plist](../../LiquidAnalyzer/Info.plist), [ConsumerTabsView.swift](../../LiquidAnalyzer/Consumer/ConsumerTabsView.swift), [ExportManager.swift](../../LiquidAnalyzer/Persistence/ExportManager.swift), and [codemagic.yaml](../../codemagic.yaml) (`xcode: "27.2"` pinned).
4. Uploaded signed `v0.4.1 (Build 14)` to TestFlight (`Delivery UUID: 3b400463-8f89-4653-b63a-778d23dd3d94`) and verified across `63` live scans on iPhone Duo ([LA-R2-C-VERIFICATION-REPORT-001.md](LA-R2-C-VERIFICATION-REPORT-001.md)).
