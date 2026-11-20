# LA-R2-SPEC-001: Phase R2 (`v0.4.0` / `v0.4.1`) Airborne `MODE_A` Architecture & Governance Specification

- **Document ID:** `LA-R2-SPEC-001`
- **Status:** RATIFIED & IMPLEMENTED ([LA-R2-FINAL-ACCEPTANCE-REPORT.md](LA-R2-FINAL-ACCEPTANCE-REPORT.md))
- **Accepted Release Tag:** `v0.4.1-build14-accepted` (`6d067cff97ef1641cce3772e72da0cd14ad593ca`)
- **Pinned Toolchain:** `xcode: "27.2"` (`Build 27B52`, `macOS 27.2`, `Swift 6.4.2` — zero floating `latest` tags)

> [!IMPORTANT]
> **Governance & Scope Mandate:** Phase R1 (`v0.3.7`, Build 12) established run-to-run hardware repeatability (`CV = 0.023%–0.075%` on single-mode stationary targets) while proving that uncalibrated airborne reflection ($R \approx 99.94\%$ at the air-liquid boundary) cannot separate non-effervescent bulk liquids across arbitrary containers. Phase R2 strictly isolates **non-contact airborne cavity/scatter screening (`MODE_A`)** from **structural wall-coupled impedance/damping interrogation (`MODE_B`, deferred to Phase R3)**, replaces clamped STFT linear decay regressions with **Chu-compensated narrowband Schroeder Energy Decay Curves (EDC)**, tracks **4-mode sub-bin vectors with explicit `NaN` missing-mode masks**, and enforces truth-in-labeling across all uncalibrated scans.

---

## 1. Operational Mode Boundary (`MODE_A` vs. Deferred `MODE_B`)

### 1.1 `MODE_A` — Calibrated Airborne Non-Contact Screening (`v0.4.0`–`v0.4.1`)
- **Permitted Physical Claims:**
  - `EMPTY_CONTAINER` vs. `LIQUID_LOADED` (calibrated container mass-loading shift)
  - `BUBBLE_SCATTER_DETECTED` (micro-bubble / reactive effervescence scatter verified by both differential high-frequency scatter $\Delta S_{\text{HF}} \ge +2.50\text{ dB}$ and active pre-roll fizz `preRollExcessHFDB > 0.0`)
  - `NONSTANDARD_SURFACE_RESPONSE` (solid / non-liquid surface rejection)
  - Calibrated differential modal shift vectors ($\Delta \vec{F} / \vec{F}_{\text{empty}}$ and $\Delta \vec{F} / \vec{F}_{\text{water}}$)
- **Prohibited Claims in `MODE_A`:**
  - Zero uncalibrated chemical or molecular labels on non-effervescent liquids (`Water`, `Saline`, `Vinegar`, `Cooking Oil`).
  - Zero airborne dynamic viscosity or bulk sound-speed claims.
- **Deconvolved Time-of-Flight Gate:** $[t_0 + 2.15\text{ ms},\; t_0 + 19.50\text{ ms}]$ at $48\text{ kHz}$, zero-padded to $N_{\text{FFT}} = 8{,}192$ ($\Delta f_{\text{bin}} = 5.859375\text{ Hz}$).

### 1.2 `MODE_B` — Direct Structural Wall Coupling (Deferred to [LA-R3-SPEC-001.md](LA-R3-SPEC-001.md))
- Guided-wave Lamb modes and ultrasonic pulse-echo bulk velocity / impedance interrogation require direct wall-coupled piezoelectric hardware and remain 100% isolated from the `MODE_A` production codebase.

---

## 2. Core Signal-Processing Specifications

### 2.1 Transient Conditioning ($K_{\text{cond}} = 2$) & Acoustic Settle ($\ge 900\text{ ms}$)
- **Purge Cycle:** `20×` calibration bursts mark `Sweeps 1–2` (`is_conditioning_cycle = true`) as conditioning purges excluded from steady-state baseline medians (`Sweeps 3–20`).
- **Inter-Sweep Settle:** Enforces `minimumInterSweepSettleMs = 900` between consecutive sweeps in [ConsumerScanCoordinator.swift](../../LiquidAnalyzer/Consumer/ConsumerScanCoordinator.swift) so container ring-down decays to background before the next capture.
- **Late Pre-Roll Noise Window:** Samples ambient noise strictly from `[onset - 95 ms .. onset - 10 ms]` prior to ESS emission, preventing late reverberant tail contamination.

### 2.2 Chu-Compensated Narrowband Schroeder EDC
- Replaces clamped (`145.0 dB/s`) linear STFT slope fits with backward energy integration over narrowband modal envelopes:
  $$\text{EDC}(t) = \int_t^T [h_i(\tau)]^2\, d\tau - C_{\text{Chu}}$$
  eliminating saturation clamping across `80–12,100 dB/s` physical container decays.

### 2.3 Sub-Bin 4-Mode Vector Extraction & Explicit `NaN` Masking
- Extracts up to 4 persistent structural/cavity modes ($f_1 < f_2 < f_3 < f_4$) via 3-point log-parabolic interpolation in [OnDeviceAcousticClassifier.swift](../../LiquidAnalyzer/Consumer/OnDeviceAcousticClassifier.swift), enforcing a `-14.0 dB` sidelobe floor and `150 Hz` minimum modal spacing.
- Absent or unresolvable modes emit `mask_i = 0` and literal `NaN` (`Double.nan`) in telemetry and CSV exports — synthetic zero-padding and centroid substitution are prohibited.

### 2.4 Steady-State (`Sweeps 3–20`) Baseline Calibration & Log-Ratio Diagnostics
- Supports one-tap persistence of `Sweeps 3–20` steady-state medians as `EMPTY_CONTAINER`, `H2O_DIST` (`WATER_REFERENCE`), or `SOLID_SURFACE`, reconciling differential columns (`delta_f_empty_pct_1_4`, `delta_f_water_pct_1_4`, `delta_s_hf_db`).
- Normalizes candidate decay distances in log-ratio space:
  $$d_{\text{decay}} = \frac{\left|\ln\!\left(\dfrac{\max(1.0,\ \alpha)}{\max(1.0,\ \alpha_{\text{prior}})}\right)\right|}{0.42}$$
