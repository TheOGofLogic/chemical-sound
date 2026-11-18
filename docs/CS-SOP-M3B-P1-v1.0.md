# LIQUID ANALYZER

## Milestone 3B Bare-Phone Bench Audio Characterization SOP

**Document ID:** `CS-SOP-M3B-P1-v1.0`  
**Governing Specification:** `CS-SPEC-P1-v1.2`  
**Associated Report:** `CS-MFR-P1-v1.2-001`  
**Hardware Domain:** `IPHONE_NATIVE`  
**Purpose:** Device validation before Milestone 3C fixture lock and Gate 0A/0B testing.

---

## 1. PURPOSE

Milestone 3B shall determine whether the designated baseline iPhone and Minimal Swift Acquisition Prototype provide a sufficiently stable, reproducible native audio acquisition platform for subsequent Liquid Analyzer feasibility experiments.

Milestone 3B does **not** establish:
- liquid identity;
- liquid concentration;
- chemical composition;
- electrical properties;
- electrical safety;
- diagnostic classification capability; or
- the existence of a liquid-dependent acoustic phenomenon.

Its purpose is restricted to characterization of the acquisition instrument.

---

## 2. PRECONDITIONS

Before beginning M3B:
- Milestone 3A source tests pass.
- Native Swift/XCTest suites pass on the development Mac.
- The app successfully installs on the designated baseline iPhone.
- The designated waveform manifest passes SHA-256 verification.
- The acquisition state machine is operational.
- The required `2.0 s` excitation cooldown invariant is enabled.
- No on-device liquid classification is enabled.
- Export produces `CSRD-P1`-compatible records.
- Test device is unplugged from charging power.
- Phone case is removed.
- Experimental environment is documented.

Failure of any prerequisite places M3B on **HOLD**.

---

## 3. BASELINE DEVICE LOCK

Record before testing:
- **Commercial device:** ____________________
- **Hardware identifier:** ____________________
- **iOS version:** ____________________
- **App build:** ____________________
- **Swift/build environment:** ____________________
- **Case:** `NONE`
- **Charging:** `UNPLUGGED`
- **Requested `AVAudioSession` category:** `playAndRecord`
- **Requested `AVAudioSession` mode:** `measurement`
- **Requested sample rate:** `48,000 Hz`
- **Requested channels:** `1 input / 1 output`

The realized post-activation configuration shall be logged independently from the requested configuration. No assumption shall be made that a requested audio-system property equals its realized hardware value.

---

## 4. TEST ENVIRONMENT

Document: room/test location, bench location, phone orientation, nearby operating equipment, HVAC state if relevant, obvious transient noise sources, battery percentage at test start and end, approximate ambient temperature, and test start/end timestamps.

Testing shall be interrupted when obvious uncontrolled acoustic contamination occurs. The affected scan shall remain recorded in the audit trail and shall not silently disappear.

---

## 5–14. MILESTONE 3B BENCH TEST SUITE (`3B-01` THROUGH `3B-10`)

- **TEST 3B-01 (Schema & Export Round Trip):** All 81 `ScanRecord` fields represented, explicit JSON `null`s preserved, unique scan IDs, WAV existence, ordered timestamps, accepted vs. rejected distinction, waveform SHA-256 match.
- **TEST 3B-02 (Realized Audio Configuration):** Actual sample rate, in/out channel counts, input port & data source, output route & data source, I/O buffer duration, input/output latency, pre/post `outputVolume`.
- **TEST 3B-03 (Silence Characterization):** Repeated `SIG_SIL_v1` quiet-bench captures; RMS/peak dBFS, clipping count, spectrum, narrowband line-hum check, repetition variability, temporal drift.
- **TEST 3B-04 (Free-Air ESS Characterization):** `N >= 5` valid uncoupled `SIG_ESS_v1` repetitions; raw WAV, SHA-256, pre/post `outputVolume`, peak level, impulse-response arrival & ring-down, repetition SD.
- **TEST 3B-05 (Port-Occlusion Probe):** Paired Condition A (unobstructed) vs. Condition B (selective physical output aperture occlusion) establishing empirical active transducer path.
- **TEST 3B-06 (Frame & Timing Integrity):** WAV sample rate, frame count, realized duration (`frames / sr`) vs. scheduled pre-roll + excitation + post-roll, transition & cooldown timestamps.
- **TEST 3B-07 (Output-State Stability):** Pre/post `outputVolume` within `±0.01` scalar tolerance (treated strictly as an instrument-state control variable, not calibrated SPL).
- **TEST 3B-08 (Cooldown Invariant):** `next t_exc_start >= previous t_exc_end + 2.0 s` verified across nominal scans, aborts, arm failures, QC rejections, and recoveries.
- **TEST 3B-09 (Recoverable Failure Behavior):** No crash, no incomplete scan promoted, rejection reason persisted, cooldown preserved across recovery.
- **TEST 3B-10 (Raw-Data Integrity):** Full chain audit (`ScanRecord -> WAV -> manifest -> timestamps`), zero orphan/missing WAVs, zero lost rejected scans.

---

## 15. DEVICE-VALIDATION DISPOSITION

- `[ ]` **PASS:** Advance to Milestone 3C (Adjustable Mode B Fixture).
- `[ ]` **CONDITIONAL:** Correct acquisition defect and repeat affected M3B test.
- `[ ]` **FAIL:** Native-iPhone acquisition not sufficiently characterized for fixture development.

---

## 16. GATE 0B PRE-REGISTERED ACCEPTANCE THRESHOLDS

*(Frozen engineering feasibility criteria prior to inspecting labeled Water-vs-Oil results)*

1. **Measurement QC (`16.1`):** Reject clipping, incomplete pre/post-roll, SHA-256 failure, route change, missing metadata, `|outputVolume - target| > 0.01`, or cooldown `< 2.0 s`.
2. **Independence (`16.2`):** Independent experimental unit is the **fresh liquid preparation/sample** (`scan -> preparation/fill -> container -> batch/session -> liquid class`).
3. **Minimum Gate Dataset (`16.3`):** `>= 4` independent preparations/class across `>= 2` sessions/days, fresh fills, balanced dev containers, and `>= 1` unseen-container evaluation/class (otherwise **`GATE INCOMPLETE`**).
4. **Decision-A Performance Thresholds (`16.4–16.6`):**
   - Primary sample-level balanced accuracy **`>= 80%`**
   - Prespecified 95% CI lower bound **`> 50%`**
   - Unseen-container balanced accuracy **`>= 70%`**
   - Cross-session/day balanced accuracy **`>= 70%`**
   - Both Water and Vegetable Oil sensitivities **`>= 70%`**
5. **Non-Acoustic Nuisance-Only Negative Control (`16.7`):** Held-out balanced accuracy from non-acoustic allocation metadata (`container_id`, scan order, session/day, sequence, fixture metadata) **`< 60%`** and compatible with chance.
6. **Fixture Repeatability Ratios (`16.8`):**
   - `Water-vs-Oil separation >= 2.0 x remove-and-replace variability`
   - `Session drift <= 25% of Water-vs-Oil separation`
7. **Confounder Exclusion (`16.9`):** Separation not plausibly explained by container ID, `K1` added mass, `K2` force, `F` fill height, `G` temperature, session order, repositioning, airborne bypass, or drift.

---

## 17–18. GATE 0B DECISION LOGIC & GOVERNING SCIENTIFIC RULE

- **DECISION A — PROCEED:** All 10 criteria in Section 17 satisfied → Advance to Milestone 5 / Phase 1A.
- **DECISION B — HOLD AND REDESIGN:** Fixture/path effects dominate → Redesign Mode B and repeat Gate 0A/0B.
- **DECISION C — EXTERNAL TRANSDUCER DIAGNOSTIC:** Native iPhone SNR insufficient → Run quarantined `EXTERNAL_TRANSDUCER_DIAGNOSTIC` experiment (never merged with `IPHONE_NATIVE`).
- **DECISION D — PHENOMENON NOT YET ESTABLISHED:** Neither native iPhone nor segregated diagnostic separates liquids above nuisance controls → Suspend classification development.

**Governing Progression:** `Instrument validity -> Signal-path validity -> Phenomenon validity -> Classification validity`.
