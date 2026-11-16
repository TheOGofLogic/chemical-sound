# Chemical Sound — Milestone 4 Measurement Feasibility Report (Gate 0A & Gate 0B)

**Report ID:** `CS-MFR-P1-v1.2-001`  
**Governing Specification:** `CS-SPEC-P1-v1.2`  
**Hardware Domain:** `IPHONE_NATIVE`  
**Study Dates:** `YYYY-MM-DD` to `YYYY-MM-DD`  
**Operator(s):** `<operator_id>`  

> [!NOTE]
> Complete this Milestone 4 Gate Report **before** preparing the full 4-batch Phase 1A concentration dataset. Its sole purpose is to establish whether the physical instrument measures a repeatable, liquid-dependent signal that survives fresh fills, container swaps, and separate days.

---

## 1. Milestone 3B: Baseline Instrument & Bench Audio Characterization

*(Measured using the Minimal Swift Acquisition Prototype **before** locking Mode B fixture geometry)*

| Property | Requested Setting | Post-Activation Verified Value | Status |
| :--- | :--- | :--- | :--- |
| **Commercial Model & Identifier** | Single Baseline Unit | `<e.g., iPhone 15 Pro / iPhone16,1>` | `[ ]` |
| **iOS Version & App Build** | Locked for Phase 1 | `<e.g., iOS 19.x / Build 0.1.2>` | `[ ]` |
| **Case & Charging State** | `NONE` / Unplugged | `<NONE / Unplugged>` | `[ ]` |
| **`AVAudioSession` Category & Mode** | `.playAndRecord` / `.measurement` | `<actual category / mode>` | `[ ]` |
| **Sample Rate** | `48,000 Hz` | `<verified Hz>` | `[ ]` |
| **Channel Configuration (In / Out)** | `1 / 1` | `<verified in / out channels>` | `[ ]` |
| **Input Port, Data Source & Polar** | Built-In Mic / Omni | `<verified port / source / polar>` | `[ ]` |
| **Output Port & Active Transducer** | Built-In Speaker (Probe-Verified) | `<port-occlusion probe result>` | `[ ]` |
| **Input / Output Latency & Buffer** | Logged | `<in ms / out ms / ioBuffer ms>` | `[ ]` |
| **Hardware `outputVolume` Lock** | Target `± 0.01` | `<locked scalar>` | `[ ]` |
| **Bare-Phone Noise Floor (`SIG_SIL_v1`)** | Quiet Bench Baseline | `<RMS dBFS & line-hum check>` | `[ ]` |
| **Direct Speaker→Mic ESS Impulse** | Free-Air Uncoupled Baseline | `<peak dBFS, ring-down ms, 5-rep SD>` | `[ ]` |

---

## 2. Milestone 3C: Adjustable Mode B Fixture & Signal-Path Specification (`fixture_version`)

Attach CAD/photo cross-section and record exact mechanical dimensions:

- **Fixture Version ID:** `<FIX_MODE_B_v01>`
- **Coupling Pad Specification:** Material `<e.g., Silicone / Sorbothane / TPU>`, Hardness `<Shore A>`, Uncompressed thickness $t_0 =$ `<mm>`, Compressed thickness $t_c =$ `<mm>`, Contact area $A_c =$ `<mm x mm>`, Elevation above vessel base $=$ `<mm>` (Liquid meniscus height $h_{\text{liq}} =$ `<mm>`).
- **Receiving Interface (`Container → Port M`):** `<Direct secondary pad / Shielded near-field cavity dimensions>`
- **Speaker-to-Mic Airborne Septum:** Material `<closed-cell foam + barrier>`, Thickness `<mm>`, Clearance to vessel wall `<mm>`.
- **Clamping Force Mechanism:** `<Calibrated compression spring / counterweight>`, Nominal force $F_c =$ `<N ± tolerance>`.
- **Baseplate Isolation:** `<Elastomer isolation feet on rigid bench>`.

---

## 3. Gate 0A: Five-Condition Path-Isolation Results

*(Minimum $N = 5$ accepted scans per configuration using candidate container `<catalog_id>`)*

| Condition ID | Configuration | Resonance-Tail RMS (dBFS) | Direct-to-Tail Ratio (dB) | Dominant Modal Peaks (Hz / Q) | Interpretation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`PATH_01`** | Phone + Fixture Only (No Vessel) | | | | Baseline chassis/frame bleed |
| **`PATH_02`** | Empty PP Vessel Engaged ($F_c$) | | | | Dry container contribution |
| **`PATH_03`** | Water-Filled Vessel Engaged ($F_c$) | | | | Coupled fluid-loaded signal |
| **`PATH_04`** | Water-Filled Vessel Disengaged (`1–2 mm` gap) | | | | Contact vs. airborne dependence |
| **`PATH_05`** | Engaged + Supplemental Port Baffle | | | | Airborne bypass sensitivity |

- **Mechanical Contact Gain (`PATH_03` vs. `PATH_04` modal energy shift):** `<dB>`
- **Fluid-Loading Separation (`PATH_03` vs. `PATH_02` spectral $L_2$ distance):** `<dB>`
- **Temporal Gate-Separability Decision:**
  - `[ ]` **Split Gates Adopted:** Direct arrival ($t_0$ to $t_0 + t_d$) and fluid-loaded modal tail ($t_0 + t_d$ to $t_0 + t_r$) are empirically separable (`t_d = ___ ms`, `t_r = ___ ms`).
  - `[ ]` **Fallback Window Adopted:** Mechanical contact overlaps initial arrival; relying on fixture-subtracted composite impulse and/or `SIG_STEP_v1` speaker-silent `40 ms` decay gaps.

---

## 4. Candidate Polypropylene Container Screening

| Candidate Vessel (Mfr / Part / Lot) | Capacity & Cap Type | Empty Repeatability (dB) | Remove & Replace SD (dB) | Water-vs-Empty Distance (dB) | Separation-to-Noise Ratio | Selected? |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Candidate A:** `<id>` | | | | | | `[ ]` |
| **Candidate B:** `<id>` | | | | | | `[ ]` |
| **Candidate C:** `<id>` | | | | | | `[ ]` |

- **Standardized Boundary Conditions Locked:**
  - Closure state: `<CAPPED_TORQUE_MARK / CAPPED_SNAP_STOP / OPEN>`
  - Nominal fill mass / volume: `<g / mL>`, Fill height $h_{\text{liq}} =$ `<mm>`, Headspace $h_{\text{air}} =$ `<mm>`
  - Temperature SOP: `<Thermometer model, accuracy, timing prior to 3-min settle>`

---

## 5. Excitation Sweep-Duration, Playback-Level & Modality Optimization

*(Selected strictly by **repeatability and across-fill/container separation**, not raw amplitude)*

| Setting ID | Excitation Type & Duration | Hardware `outputVolume` | Post-Roll (ms) | Rep 1→5 Thermal Drift (dB) | Remove/Replace SD (dB) | Water-vs-Oil Separation Ratio | Selected? |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **EX_01** | `SIG_ESS` `200 ms` | `0.50` | `150` | | | | `[ ]` |
| **EX_02** | `SIG_ESS` `200 ms` | `0.65` | `150` | | | | `[ ]` |
| **EX_03** | `SIG_ESS` `500 ms` | `0.65` | `300` | | | | `[ ]` |
| **EX_04** | `SIG_ESS` `1000 ms` | `0.65` | `300` | | | | `[ ]` |
| **EX_05** | `SIG_ESS` `500 ms` | `0.80` | `300` | | | | `[ ]` |
| **EX_06** | `SIG_STEP` (`10 x 60/40 ms`) | `0.65` | `150` | | | | `[ ]` |

- **Validated Usable Passband:** `<f_low Hz>` to `<f_high Hz>` (noisy/distorted band edges trimmed).
- **Validated Cooldown Interval ($\Delta t_{\text{cooldown}}$):** `<sec>` from `t_exc_end` to next `t_exc_start`.

---

## 6. Confounder & Drift Characterization Summary

| Control Test | Perturbation Applied | Spectral / Feature Shift vs. Stationary SD | Magnitude Relative to Water-vs-Oil Shift (%) | Operating Tolerance Required |
| :--- | :--- | :--- | :--- | :--- |
| **Stationary (`Control A`)** | $N=15$ untouched scans | | | Baseline floor |
| **Remove & Replace (`Control B`)** | $N=10$ full re-clamp cycles | | | Fixture seating check |
| **Inter-Container (`Control D`)** | $N=5$ virgin `container_id`s | | | Lot consistency |
| **Added Mass (`Control K1`)** | `+10%`, `+20%` upper-cap rim collar | | | *(Fixture weighing check only)* |
| **Coupling Force (`Control K2`)** | `-20%`, `Nominal`, `+20%` $F_c$ | | | Force tolerance `± ___ N` |
| **Fill Volume (`Control F`)** | `-5%`, `Nominal`, `+5%` fill height | | | Mass/height tolerance `± ___ g` |
| **Temperature (`Control G`)** | `~18 °C`, `~22 °C`, `~26 °C` | | | Temp window `___ to ___ °C` |
| **Session Drift (`CAL_START`→`END`)** | Beginning vs. ending water & empty | | | Drift limit `< ___ dB` |

---

## 7. Gate 0B: Two-Liquid Randomized Multi-Session Feasibility (`Water` vs. `Vegetable Oil`)

- **Experimental Design:**
  - Liquids: `H2O_DIST` vs. `OIL_VEG` (minimum **4 independent preparation/bottle lots per class**, fresh fills per sample, randomized blinded scan order across **$\ge 2$ separate days/sessions**).
  - Container Allocation: Balanced block of virgin lot-matched `container_id`s + **reserved unseen `container_id` holdout** (preventing oleophilic polypropylene carryover without confounding container ID with class).
- **Acquisition & Session Yield:**
  - Attempted repetitions: `<N>` | `PROVISIONALLY_ACCEPTED`: `<N>` | Promoted to `FINAL_ACCEPTED`: `<N>` | `INVALID_MEASUREMENT` (QC/Drift): `<N>`
- **Held-Out Preparation & Unseen-Container Performance (Sample-Level Primary Unit):**

| Evaluation Partition | Samples ($N$) | Batches ($B$) | Per-Batch Accuracies | Pooled Balanced Accuracy (95% Batch CI) | Nuisance-Only Classifier Accuracy (Chance = 50%) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Nested LOBO-CV (Dev Containers)** | | | `<B1, B2, B3, B4>` | | |
| **Unseen `container_id` Holdout** | | | `<B_hold1, B_hold2>` | | |
| **Cross-Session / Day-2 Transfer** | | | | | |

---

## 8. Milestone 4 Stop/Go Gate Decision

Select **one** formal engineering disposition based on Sections 3–7:

- `[ ]` **DECISION A — PROCEED TO MILESTONE 5 (Phase 1A Dataset Collection):**
  Dominant signal path is verified; `Water` vs. `Oil` separates reliably across fresh fills, unseen containers, and sessions; `Controls K1/K2` and nuisance-only diagnostics confirm separation is not a weighing, clamping, or session-order artifact.
- `[ ]` **DECISION B — HOLD & REDESIGN MODE B FIXTURE (Repeat Gate 0A/0B):**
  Signal is dominated by direct chassis/airborne bypass (`PATH_03 ≈ PATH_01/04`), repositioning error (`Control B`), or clamping-force drift (`Control K2`). Adjust pad material, compression, baffle/separator, container position, force, or microphone-side geometry and repeat Gate 0A/0B.
- `[ ]` **DECISION C — TRIGGER SEGREGATED HARDWARE DIAGNOSTIC (`EXTERNAL_TRANSDUCER_DIAGNOSTIC`):**
  Baseline iPhone native audio acquisition lacks sufficient repeatable vibro-acoustic signal-to-noise ratio after excitation, level, coupling, and fixture optimization. Conduct a separately identified external contact-exciter/sensor experiment to determine whether reproducible container-liquid modes exist independently of native iPhone transducer limitations. Results from this diagnostic shall not be merged with the `IPHONE_NATIVE` training or validation dataset.
- `[ ]` **DECISION D — PHENOMENON NOT YET ESTABLISHED:**
  Neither the native-iPhone configuration nor the segregated diagnostic demonstrates reproducible liquid-dependent separation after nuisance controls. Suspend classification development. Do not proceed to the Phase 1A reference dataset until a measurable physical signal is independently demonstrated.
