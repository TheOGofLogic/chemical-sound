# LA-R2-FINAL-ACCEPTANCE-REPORT: Phase R2 Progression & Acceptance (Build 12 → Build 14)

**Repository:** `org.chemicalsound.acquisition` (Liquid Analyzer)  
**Governing Specifications:** `LA-R2-SPEC-001`, [LA-R2-A-SANDBOX-REPORT-001.md](LA-R2-A-SANDBOX-REPORT-001.md), [LA-R2-C-PLAN-001.md](LA-R2-C-PLAN-001.md)  
**Target Tag:** `v0.4.1-build14-accepted`  
**Base Commit:** `6d067cff97ef1641cce3772e72da0cd14ad593ca`  
**Date:** 2026-11-19  
**Status:** ACCEPTED & TAGGED (`R2_ACCEPTANCE_GRANTED`)  

---

## 1. Executive Summary & Disposition
Phase R2 has successfully transitioned the Liquid Analyzer airborne acoustic acquisition engine from an uncalibrated, estimator-saturated prototype (`v0.3.7`, Build 12) into a scientifically grounded, calibrated screening system (`v0.4.1`, Build 14).

Across 140 laboratory scans and 63 on-device live field scans on the Apple iPhone Duo hardware ([LA-R2-B-FIELD-AUDIT-001.md](LA-R2-B-FIELD-AUDIT-001.md), [LA-R2-C-VERIFICATION-REPORT-001.md](LA-R2-C-VERIFICATION-REPORT-001.md)), all core architectural, DSP, and physical boundary failures have been resolved:
* **Decay Clamp Saturation ($145.0\text{ dB/s}$):** Reduced from **57.14%** to **0.00%**.
* **Inter-Sweep Ring-Down Bleed:** Reduced from **$+32.26\text{ dB}$** pre-roll bleed to steady-state background ($0.50\text{ to } 3.37\text{ dB}$ SNR delta) via mandatory $K_{\text{cond}} = 2$ purge and a $\ge 900\text{ ms}$ inter-sweep settle pause.
* **False Airborne Chemical Claims:** Completely eliminated (**0.00%** false positive chemical claims across all uncalibrated test sets).
* **False Bubble Scatter Triggers:** Reduced from **60.3%** in Build 13 to **0.00%** in Build 14 via the dual-condition differential gate.
* **Diagnostic Subtitle Distances:** Normalized from uncalibrated excursions ($d = 0.39\text{--}118.07$) into bounded log-ratio space ($d = 1.45\text{--}4.52$).

**Formal Disposition:** **`R2_ACCEPTANCE_GRANTED`**. The `main` branch at commit `6d067cf` is tagged as `v0.4.1-build14-accepted`.

---

## 2. Multi-Build Progression Matrix (Build 12 → Build 13 → Build 14)

| Verification Dimension | Build 12 (`v0.3.7`, Commit `2cd6557`) | Build 13 (`v0.4.0`, Commit `3bec6af`) | Build 14 (`v0.4.1`, Commit `6d067cf`) |
| :--- | :--- | :--- | :--- |
| **Toolchain Pinning** | Unpinned / CI floating | Pinned `xcode: "27.2"`, macOS 27.2 | Pinned `xcode: "27.2"`, macOS 27.2 |
| **Decay Estimator** | STFT linear slope, clamped at $145.0\text{ dB/s}$ | Narrowband Schroeder EDC (unclamped) | Narrowband Schroeder EDC (unclamped) |
| **$145.0\text{ dB/s}$ Clamp Rate** | **57.14%** (80 / 140 scans) | **0.00%** (0 / 140 scans) | **0.00%** (0 / 63 scans) |
| **Conditioning & Settle** | Single-sweep purge, $650\text{ ms}$ sleep | $K_{\text{cond}} = 2$, $\ge 900\text{ ms}$ settle gap | $K_{\text{cond}} = 2$, $\ge 900\text{ ms}$ settle gap |
| **Sweep 2 Ring-Down Bleed** | $+32.26\text{ dB}$ (Salt Sweep 2) | $-1.08\text{ dB}$ delta | $-0.50\text{ to } +3.37\text{ dB}$ delta |
| **Modal Association & Masking** | Single dominant peak hopping | 4-mode vector ($f_1..f_4$) with `NaN` masks | 4-mode vector ($f_1..f_4$) with `NaN` masks |
| **False Bubble Scatter Rate** | N/A | **60.3%** (weak-echo floor bias) | **0.00%** (dual-condition differential gate) |
| **Diagnostic Distance ($d$)** | $0.4\text{--}3.9$ (clamped decay priors) | $0.39\text{--}118.07$ (linear decay divergence) | **$1.45\text{--}4.52$** (log-ratio normalized) |
| **Camera Targeting Thumbnail** | Stale on back-to-back runs | Stale Oil photo reused on Peroxide | **100% fresh frame** (grace delay = 0) |
| **20× Baseline Calibration** | None (unlabeled single-scan only) | Manual single-scan | **Full steady-state median (Sweeps 3–20)** |
| **Swift XCTest Gate** | 32 / 32 passing | 35 / 35 passing | **39 / 39 passing** (0 failures) |

---

## 3. Engineering & Architectural Solutions Implemented

### 3.1 Toolchain Reproducibility (ITMS-90725)
* **Configuration:** Eliminated all occurrences of floating `xcode: latest` tags across workflows in [codemagic.yaml](../codemagic.yaml). Pinned to explicit release string `xcode: "27.2"` on the `mac_mini_m2` architecture.
* **Manifest Provenance:** Enabled automatic generation of `toolchain_manifest.txt` capturing host OS version (`macOS 26B123`), Xcode build (`27B52`), SDK (`iphoneos27.2`), and Swift compiler version (`6.4.2`).

### 3.2 Transient Settling & Inter-Sweep Acoustic Isolation
* **Purge Window ($K_{\text{cond}} = 2$):** Calibration bursts enforce `isConditioningCycle = true` on sweeps $1$ and $2$.
* **Physical Ring-Down Decay:** Enforced `minimumInterSweepSettleMs = 900` via `awaitInterSweepSettle()` in [ConsumerScanCoordinator.swift](../LiquidAnalyzer/Consumer/ConsumerScanCoordinator.swift).
* **Pre-Roll Noise Sampling:** Relocated ambient deconvolved noise extraction to the late pre-roll silence slice (`[onset - 95 ms .. onset - 10 ms]`), insulating noise baselines from late reverberant tail reflections.

### 3.3 Chu-Compensated Schroeder EDC & 4-Mode Vector Masking
* **Schroeder Decay Integration:** Replaced linear STFT regressions with backward energy decay integration:
  $$\text{EDC}(t) = \int_t^T [h(\tau)]^2 d\tau - C_{\text{Chu}}$$
  completely removing the arbitrary $145.0\text{ dB/s}$ saturation ceiling.
* **Modal Vector Tracking & Sidelobe Guards:** Implemented an 8,192-bin FFT peak tracker isolating up to 4 persistent resonances ($f_1 < f_2 < f_3 < f_4$) with a $-14.0\text{ dB}$ sidelobe guard and a $150\text{ Hz}$ minimum peak separation.
* **Explicit Missing-Mode Masking:** Mode dropouts strictly emit `mask_i = 0` and `f_i = NaN`. Artificial zero-padding and synthetic centroid substitutions are strictly prohibited.

### 3.4 Dual-Condition Differential Bubble Scatter Gate
* **Noise Floor Bias Elimination:** Removed the static `0.04 * unitFull` high-frequency spectral floor above $5.2\text{ kHz}$ in [OnDeviceAcousticClassifier.swift](../LiquidAnalyzer/Consumer/OnDeviceAcousticClassifier.swift).
* **Differential Excess Metric:** Asserted that high-frequency scatter must exceed baseline container reflection by at least $+2.50\text{ dB}$:
  $$\Delta S_{\text{HF}} = S_{\text{HF, sample}} - \max(S_{\text{HF, empty}}, S_{\text{HF, water}}) \ge +2.50\text{ dB}$$
* **Acoustic Fizz Confounder Lock:** Mandated non-zero pre-roll acoustic hiss (`preRollExcessHFDB > 0.0`) to confirm effervescence before emitting `BUBBLE_SCATTER_DETECTED`, blocking false triggers on still liquids and elevated glass reflections.

### 3.5 Calibration Persistence & Diagnostic Distance Normalization
* **20× Steady-State Baseline Action:** Added user actions in [ConsumerTabsView.swift](../LiquidAnalyzer/Consumer/ConsumerTabsView.swift) and [ConsumerScanFlowView.swift](../LiquidAnalyzer/Consumer/ConsumerScanFlowView.swift) to save the steady-state median ($\text{Sweeps } 3\text{--}20$) of any stationary cohort as `EMPTY_CONTAINER`, `WATER_REFERENCE`, or `SOLID_SURFACE`.
* **Log-Ratio Distance Scaling:** Updated `computeFrozenCandidateDistances` decay distance to use bounded log-ratios:
  $$d_{\text{decay}} = \frac{\left| \ln\!\left(\dfrac{\max(1.0, \alpha)}{\max(1.0, \alpha_{\text{prior}})}\right) \right|}{0.42}$$
  preventing multi-point decay slopes from corrupting candidate matching diagnostics.

---

## 4. Empirical On-Device Verification Evidence

### 4.1 Stationary Control Baseline Shifts (iPhone Duo, 15-in Distance)
When cohort `R1_20X_20261119_151200` is locked as `EMPTY_CONTAINER` ($[2836.4, 3418.6, 3637.6, 4314.4]\text{ Hz}$):
* **Water Loading (`R1_20X_20261119_153522`):** Resolves a downward modal shift across persistent resonances ($\Delta F / F_{\text{empty}} = [\text{NaN}, +9.91\%, -0.77\%, +0.30\%]$, fundamental at $1811.0\text{ Hz}$) with $+1.85\text{ dB}$ higher acoustic echo return, cleanly identifying `LIQUID_LOADED`.
* **Cooking Oil Loading (Scan 63, `SINGLE_20261119_154520`):** Resolves a maximum shift of $\max |\Delta f / f| = 26.89\%$ ($\Delta F / F_{\text{empty}} = [-26.89\%, -10.14\%, -3.45\%, +18.92\%]$).
* **Solid Surface Rejection (`R1_20X_20261119_131812`):** Displays $+11.38\%\text{ to } +29.20\%$ upward structural modal stiffening and $+5.50\text{ dB}$ specular reflection excess.

### 4.2 Proof of Dual-Condition Bubble Gate (Scan 62)
* In Scan 62 (`SINGLE_20261119_154500`), high-frequency energy rose to $-6.44\text{ dB}$ ($\Delta S_{\text{HF}} = +2.97\text{ dB} \ge +2.50\text{ dB}$).
* Because pre-roll background acoustic hiss remained inactive (`preRollExcessHFDB <= 0.0`), the gate successfully suppressed a false bubble trigger, verifying complete decoupling of container reflection anomalies from true chemical gas evolution.

---

## 5. Scope Boundary & Truth in Labeling
* **MODE_A (Airborne Screening):** Operation is strictly restricted to physically observable acoustic phenomena:
  * `EMPTY_CONTAINER` vs. `LIQUID_LOADED`
  * `BUBBLE_SCATTER_DETECTED` (Gas-evolving effervescence)
  * `NONSTANDARD_SURFACE_RESPONSE` (Solid / Non-liquid rejection)
  * Calibrated differential shift vectors ($\Delta \vec{F} / \vec{F}_{\text{empty}}$, $\Delta \vec{F} / \vec{F}_{\text{water}}$)
* **Viscosity Claims:** All airborne viscosity and bulk sound-speed claims for uncalibrated fluids (e.g., Cooking Oil) remain removed from production models due to the fundamental $99.94\%$ air-liquid reflection boundary.
* **MODE_B Boundary:** Structural wall-coupling (guided wave / piezo transducer) remains strictly isolated from the production codebase pending dedicated external hardware development in Phase R3.
