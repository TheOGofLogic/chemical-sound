# LA-R2-B-FIELD-AUDIT-001: Live On-Device Verification of `v0.4.0` (Build `13`) on iPhone Duo

**Date:** 2026-11-19  
**Build Audited:** `v0.4.0` (Build `13`, Commit `3bec6af`, `MODE_A` Airborne Screening)  
**Hardware & Setup:** Apple iPhone Duo (`STATIONARY_15IN_BASELINE`), glass container elevated on *Oracle Unleashed* hardcover book (`Scans 192–331`, `7` batches × `20` sweeps = `140` scans)

---

## 1. Cohort Manifest & File Reconciliation

All `7` live `20x` CSV logs (`140` total scans) and `7` result screenshots reconcile `1:1` by `batch_run_id`, timestamp, and Sweep 20 `primary_peak_hz`:

| # | Physical Target | Batch Run ID (`Scans`) | Sweep 20 Peak | `target_lock_state` |
| :--- | :--- | :--- | :---: | :--- |
| **1** | **Empty Glass** | `R1_20X_20261119_122506` (`192–211`) | `2527.0 Hz` | `R1_STATIONARY_LOCKED` |
| **2** | **Glass with Water** | `R1_20X_20261119_123333` (`212–231`) | `2177.0 Hz` | `R1_STATIONARY_LOCKED` |
| **3** | **Salt Water** | `R1_20X_20261119_124135` (`232–251`) | `3336.2 Hz` | `R1_STATIONARY_LOCKED` |
| **4** | **Vinegar** | `R1_20X_20261119_124919` (`252–271`) | `2145.5 Hz` | `R1_STATIONARY_LOCKED` |
| **5** | **Cooking Oil** | `R1_20X_20261119_130020` (`272–291`) | `2805.1 Hz` | `R1_STATIONARY_LOCKED` |
| **6** | **Hydrogen Peroxide** | `R1_20X_20261119_130848` (`292–311`) | `3502.2 Hz` | `R1_BATCH_MANUAL_AIM` |
| **7** | **Hard Surface (Book)** | `R1_20X_20261119_131812` (`312–331`) | `3540.6 Hz` | `R1_STATIONARY_LOCKED` |

---

## 2. Verified Phase R2-B (`v0.4.0`) Governance & DSP Upgrades

Every core architectural upgrade mandated by [LA-R2-A-SANDBOX-REPORT-001.md](LA-R2-A-SANDBOX-REPORT-001.md) executed cleanly on live iPhone Duo hardware:

1. **Zero `145.0 dB/s` Clamp Saturation (`0 / 140` = `0.00%` vs. Build 12's `57.14%`)**:
   * Chu-compensated narrowband Schroeder EDC resolved true physical decay slopes across `[80.0 .. 12,101.2 dB/s]`, with steady-state medians ranging from `435.6 dB/s` (Oil) to `2,955.9 dB/s` (Peroxide).
2. **`K_cond = 2` Purge & `>= 900 ms` Inter-Sweep Settle (`100%` Verified)**:
   * Every batch marked `is_conditioning_cycle = true` strictly on `batch_index` `1` and `2` (`false` on `3..20`), with `~1.75–2.00 s` inter-sweep cadence.
   * **Inter-Sweep Ring-Down Bleed Eliminated**: In Build 12, Salt-Water Sweep 2 suffered a `+32.26 dB` pre-roll bleed spike (`19.63 dB` SNR). In Build 13 (`124135`), Salt-Water Sweep 2 `late_preroll_dbfs` is **`-73.22 dBFS`** vs. Sweeps `3–20` median **`-72.14 dBFS`** (`-1.08 dB` delta, `31.45 dB` SNR), and Water Sweep 2 is **`-72.22 dBFS`** vs. **`-71.72 dBFS`** (`-0.50 dB` delta, `33.33 dB` SNR).
3. **4-Mode Vector (`[f_1..f_4]`), Spectral $Q_i$, and Schroeder $\alpha_i$ with Explicit `NaN` Masks**:
   * All `140` rows emit sub-bin interpolated 4-mode frequencies and emit literal `NaN` (zero synthetic padding) whenever $-3\text{ dB}$ $Q_i$ encounters mode crowding or narrowband EDC lacks SNR.
4. **Truth-in-Labeling (`0 / 140` Uncalibrated False Chemical Names)**:
   * Because all `7` runs were executed in `UNLABELED_BLIND` mode without saving a container baseline (`EMPTY_CONTAINER` / `WATER_REFERENCE`), `MODE_A` held **`140 / 140` (`100%`)** of scans as `Unmatched Liquid` (`NO_VALIDATED_MATCH`), completely eliminating Build 12's false `"Milk"` / `"Sweetened Beverage"` claims on Empty Glass, Cooking Oil, and Hard Surface.

---

## 3. Steady-State (`Sweeps 3..20`) Multi-Modal Acoustic Summary

| Cohort | Median $\vec{F}_{1..4}\ (\text{Hz})$ | Median $\vec{Q}_{1..4}$ | Median EDC $\vec{\alpha}_{1..4}\ (\text{s}^{-1})$ | Echo Return $(\text{dB})$ | `hf_scatter_db` $(\text{dB})$ | Late Pre-Roll $(\text{dBFS})$ |
| :--- | :--- | :--- | :--- | :---: | :---: | :---: |
| **1. Empty Glass** | `[2129.6, 2516.4, 2845.8, 3309.7]` | `[11.9, 12.9, 10.3, 30.0]` | `[75.5, 90.7, 49.0, 56.1]` | `-36.67` | `-4.56` | `-71.36` |
| **2. Water** | `[1724.4, 2155.1, 2494.9, 2892.3]` | `[13.9, 14.8, 22.4, 10.0]` | `[84.8, 105.3, 33.6, 46.8]` | `-34.82` | `-7.48` | `-71.72` |
| **3. Salt Water** | `[2128.5, 2506.9, 2800.0, 3321.9]` | `[12.6, 10.9, 12.0, 36.0]` | `[57.0, 36.8, 55.4, 139.7]` | `-36.84` | `-3.71` | `-72.14` |
| **4. Vinegar** | `[1187.4, 2148.4, 2472.0, 2818.9]` | `[14.2, 14.1, 7.6, 10.0]` | `[69.9, 65.8, 47.8, 46.4]` | `-35.48` | `-4.30` | `-79.39` |
| **5. Cooking Oil** | `[2134.6, 2395.5, 2562.0, 2797.3]` | `[14.2, 13.6, 16.5, 18.8]` | `[81.4, 34.4, 32.9, 55.4]` | `-34.89` | `-3.23` | `-78.25` |
| **6. Peroxide** | `[2144.0, 2860.2, 3338.2, 3500.8]` | `[19.2, 9.9, 33.6, 37.2]` | `[128.7, 67.6, 222.2, 263.0]` | `-33.00` | `-12.00` | `-72.24` |
| **7. Hard Surface** | `[2751.5, 3020.1, 3374.3, 3686.4]` | `[25.7, 36.4, 36.2, 32.7]` | `[73.1, 59.0, 119.3, 227.4]` | `-31.17` | `-11.12` | `-80.23` |

### Differential Shift Verification ($\Delta \vec{X}_{\text{empty}}$ & $\Delta \vec{X}_{\text{water}}$)
When Batch 1 (`122506`) is treated as the `EMPTY_CONTAINER` baseline and Batch 2 (`123333`) as `WATER_REFERENCE`:
* **Water Mass-Loading Shift ($\Delta \vec{F} / \vec{F}_{\text{empty}}$)**: `[-19.03%, -14.36%, -12.33%, -12.61%]` with `+1.85 dB` stronger echo return — unambiguous `LIQUID_LOADED` downward modal shift across all 4 modes.
* **Vinegar Shift ($\Delta \vec{F} / \vec{F}_{\text{empty}}$)**: `[-44.24%, -14.62%, -13.13%, -14.83%]` (`[-0.31%, -0.92%, -2.54%]` on $f_2..f_4$ relative to Water).
* **Cooking Oil Shift ($\Delta \vec{F} / \vec{F}_{\text{empty}}$)**: `[+0.23%, -4.80%, -9.97%, -15.48%]` (distinct density/speed-of-sound dispersion slope across modes `1..4`, with pairwise prototype centroid distance `1.156` from Water and `0.965` from Salt Water).
* **Hard Surface Rejection ($\Delta \vec{F} / \vec{F}_{\text{empty}}$)**: `[+29.20%, +20.02%, +18.57%, +11.38%]` and `+5.50 dB` higher specular echo return (`-31.17 dB` vs. `-36.67 dB`).

---

## 4. Three Actionable Findings Remediated in Phase R2-C (`v0.4.1` Build `14`)

> [!IMPORTANT]
> Elevating the tumbler on the *Oracle Unleashed* hardcover book changed the acoustic coupling and echo return level (`-36.8 dB` vs. Build 12's `-31.5 dB`), exposing three specific edge behaviors in `v0.4.0` that were resolved in [LA-R2-C-PLAN-001.md](LA-R2-C-PLAN-001.md):

1. **Finding A — Geometry-Dependent `BUBBLE_SCATTER_DETECTED` Floor Bias**: `cleanP1[b] = max(unitFull * 0.04, unitFull - 1.45 * nf)` applied a `4%` (`-14 dB`) spectral floor across `563` high-frequency bins (`[5.2..11.8 kHz]`), lifting weak-echo dry Empty Glass scans (`-76 dBFS`) to `-4.56 dB`. Resolved in Build `14` via floor removal above `5.2 kHz` and the dual-condition differential scatter gate ($\Delta S_{\text{HF}} \ge +2.5\text{ dB}$ AND `preRollExcessHFDB > 0.0`).
2. **Finding B — Uncalibrated Diagnostic `top_dist` Scale Divergence**: `computeFrozenCandidateDistances` divided linear `(decaySlopeDBPerSec - expectedDecayDBPerSec) / 38.0` against legacy `64–128 dB/s` priors. Resolved in Build `14` via log-ratio decay scaling (`abs(log(max(1.0, decay) / max(1.0, prior))) / 0.42`).
3. **Finding C — Cached Thumbnail Reuse When `Run 20x` Launched From Stopped Camera**: `CameraTargetingService.stopCamera()` left `isCameraLive = true` and retained `cachedThumbnailJPEG`. Resolved in Build `14` via synchronous `isCameraLive = false`, `clearCachedFrames()`, and live-frame acquisition before batch start.
