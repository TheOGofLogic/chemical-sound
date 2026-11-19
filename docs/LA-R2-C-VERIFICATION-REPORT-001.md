# LA-R2-C-VERIFICATION-REPORT-001: Final On-Device Verification of `v0.4.1` (Build `14`) on iPhone Duo

**Date:** 2026-11-19  
**Build Verified:** `v0.4.1` (Build `14`, Commit `6d067cf`, Codemagic Build `#15` / Delivery UUID `3b400463-8f89-4653-b63a-778d23dd3d94`)  
**Source Archive:** `R1_Exports.zip` (`39` exported CSV files; `LiquidAnalyzer_R1_latest_all.csv` = `63` live Build `14` scans)  
**Disposition:** **`R2_C_VERIFIED_COMPLETE`**

---

## 1. Cross-Build Progression (`Build 12` $\rightarrow$ `Build 13` $\rightarrow$ `Build 14`)

| Verification Metric | Build `12` (`v0.3.7`) | Build `13` (`v0.4.0` R2-B) | Build `14` (`v0.4.1` R2-C) |
| :--- | :--- | :--- | :--- |
| **`145.0 dB/s` Decay Clamp Rate** | `80 / 140` (`57.14%`) | **`0 / 140` (`0.00%`)** | **`0 / 63` (`0.00%`)** |
| **Sweep 2 Ring-Down Bleed ($\Delta\text{PreRoll}$)** | `+32.26 dB` (Salt Sweep 2) | **`-1.08 dB` (Resolved)** | **`-0.50` to `+3.37 dB` (`K_cond = 2` Purged)** |
| **False Uncalibrated Chemical Claims** | `"Milk"` / `"Sweetened Beverage"` | **`0 / 140` (`0.00%`)** | **`0 / 63` (`0.00%`)** |
| **False `BUBBLE_SCATTER_DETECTED` Rate** | N/A | `76 / 126` (`60.3%` on dry/still runs) | **`0 / 63` (`0.00%`)** |
| **Diagnostic `top_dist` Range** | `0.4 – 3.9` (clamped) | `0.39 – 118.07` (inflated) | **`1.45 – 4.52` (Log-Ratio Normalized)** |
| **Back-to-Back Camera Thumbnail Integrity** | Live | Stale Oil photo on `130848` | **`100%` Fresh Frame (`3:13` Empty, `3:37` Water, `3:45` Oil)** |
| **`20×` Steady-State Baseline Action** | Not present | Single-scan only | **Verified Live (`Sweeps 3–20` `EMPTY_CONTAINER`)** |

---

## 2. Complete Audit of All `63` Build `14` (`v0.4.1`) Live Scans

Extracted from `LiquidAnalyzer_R1_latest_all.csv` (`R1_Exports/`):

| Run ID (`Scans`) | Target | Steady Screening State | Steady $\vec{F}_{1..4}\ (\text{Hz})$ | $\Delta \vec{F} / \vec{F}_{\text{empty}}$ (`Last`) | `hf_scatter_db` / $\Delta S_{\text{HF}}$ | Bubble Triggers |
| :--- | :--- | :--- | :--- | :--- | :--- | :---: |
| **`R1_20X_20261119_151200`** (`1–20`) | **Empty Glass** | `EMPTY_CONTAINER` (`16/20`, `5/5` on `16–20`, `d=0.281`) | `[2836.4, 3418.6, 3637.6, 4314.4]` | `[-0.00%, -0.12%, +0.16%, +0.03%]` | `-9.41 dB` / `-0.02 dB` | **`0 / 20`** |
| **`R1_20X_20261119_153522`** (`21–40`) | **Glass with Water** | **`18 / 18` `LIQUID_LOADED`** (`20/20` total) | `[1811.0, 3117.4, 3608.3, 4329.3]` | `[NaN, +9.91%, -0.77%, +0.30%]` | `-10.15 dB` / `-1.46 dB` | **`0 / 20`** |
| **`R1_20X_20261119_154156`** (`41–60`) | **Aqueous Test Liquid** (`3:42 PM`) | **`18 / 18` `LIQUID_LOADED`** (`20/20` total) | `[3098.2, 3296.2, 3461.1, 4126.7]` | `[+9.30%, -3.61%, -4.85%, -4.42%]` | `-9.76 dB` / `-0.28 dB` | **`0 / 20`** |
| **`SINGLE_20261119_154420`** (`61`) | **Single Scan #1** (`3:44:22 PM`) | `LIQUID_LOADED` | `[3027.3, 3454.6, 4086.2, 4304.6]` | `[+6.74%, +1.05%, -5.30%, +18.38%]` | `-10.22 dB` / `-0.82 dB` | **`0 / 1`** |
| **`SINGLE_20261119_154500`** (`62`) | **Single Scan #2** (`3:45:01 PM`) | `LIQUID_LOADED` | `[1812.5, 2679.3, 3075.2, 4307.3]` | `[NaN, -5.53%, -10.05%, -0.17%]` | `-6.44 dB` / **`+2.97 dB`** | **`0 / 1`** |
| **`SINGLE_20261119_154520`** (`63`) | **Cooking Oil** (`3:45:20 PM`) | `LIQUID_LOADED` (`max \|Δf/f\| = 26.89%`) | `[2073.5, 3071.9, 4165.7, 4324.3]` | `[-26.89%, -10.14%, -3.45%, +18.92%]` | `-10.61 dB` / `-1.20 dB` | **`0 / 1`** |

---

## 3. Notable Empirical Proofs in `Scans 61–63`

1. **Exact Match to Cooking Oil Result (`Scan 63`, `SINGLE_20261119_154520`)**:
   * `Scan 63` reconciled `delta_f_empty_pct_1_4 = -26.89%; -10.14%; -3.45%; +18.92%`, matching the live UI card `max |Δf/f| = 26.89% vs. Empty Container` to `0.01%`.
   * Even though golden oil colorimetry ranked `Cooking / Vegetable Oil` `#1` in raw candidate diagnostics (`d = 3.836`), `MODE_A` respected the uncalibrated screening boundary and emitted **zero airborne viscosity or molecular claims**.
2. **Live Hardware Proof of the Dual-Condition Bubble Gate (`Scan 62`, `SINGLE_20261119_154500`)**:
   * On `Scan 62`, reflected high-frequency scatter rose to `-6.44 dB` (`delta_s_hf_db = +2.97 dB >= +2.50 dB`).
   * Because there was **no genuine pre-roll acoustic fizz** (`preRollExcessHFDB <= 0.0`), the second gate in [OnDeviceAcousticClassifier.swift](../LiquidAnalyzer/Consumer/OnDeviceAcousticClassifier.swift) properly blocked a false effervescence claim (`0 / 63` false bubble triggers across the entire session).
3. **Computed $\Delta \vec{F} / \vec{F}_{\text{water}}$ Shifts Against `153522` (`Water` `[1811.0, 3117.4, 3608.3, 4329.3] Hz`)**:
   * **`154156` (`Scans 41–60`) vs. Water**: `[-0.62%, +5.74%, -4.08%, -4.68%]` across paired modes (`3117 -> 3098 Hz`, `3608 -> 3461 Hz`, `4329 -> 4127 Hz`), with mode-3 Schroeder decay dropping from `187.6 s⁻¹` (Water) to `88.3 s⁻¹`.
   * **`Scan 63` (Cooking Oil) vs. Water**: `[+14.50%, -1.46%, +15.45%, -0.12%]` (`1811 -> 2073.5 Hz`, `3117.4 -> 3071.9 Hz`, `4329.3 -> 4324.3 Hz`).
