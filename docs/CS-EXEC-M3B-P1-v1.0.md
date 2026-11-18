# LIQUID ANALYZER

## M3B Physical-Run Execution Checklist

- **Checklist ID:** `CS-EXEC-M3B-P1-v1.0`
- **Governing SOP:** `CS-SOP-M3B-P1-v1.1`
- **Physical Checklist:** `CS-CHK-M3B-P1-v1.0`
- **Operator SOP:** `CS-OPS-M3B-P1-v1.0`
- **Acceptance Criteria:** `CS-ACC-M3B-P1-v1.0`
- **Hardware Domain:** `IPHONE_NATIVE`

---

### 1. PRE-RUN FREEZE

- `[ ]` Controlled documents match the identifiers above
- `[ ]` No unreviewed software changes after final verification
- `[ ]` Software build identity recorded
- `[ ]` Dataset-manifest mechanism available
- `[ ]` Configuration/threshold digest recorded
- `[ ]` No liquid classifier enabled
- `[ ]` Gate 0B thresholds unchanged
- `[ ]` Baseline iPhone designated

---

### 2. DEVICE PREPARATION

- `[ ]` Phone case removed
- `[ ]` Charging disconnected
- `[ ]` External audio accessories disconnected
- `[ ]` Battery level recorded
- `[ ]` iPhone model/identifier recorded
- `[ ]` iOS version recorded
- `[ ]` App build recorded
- `[ ]` Bench/location recorded
- `[ ]` Phone orientation documented
- `[ ]` Ambient conditions recorded

---

### 3. SESSION ACTIVATION

- `[ ]` Audio session activated
- `[ ]` Requested configuration recorded
- `[ ]` Realized configuration recorded
- `[ ]` Sample rate recorded
- `[ ]` Input channel count recorded
- `[ ]` Output channel count recorded
- `[ ]` Stereo-locked output status recorded
- `[ ]` Input/output route recorded
- `[ ]` Data sources recorded where available
- `[ ]` I/O buffer duration recorded
- `[ ]` Input latency recorded
- `[ ]` Output latency recorded
- `[ ]` Initial `outputVolume` recorded

> **Rule:** Realized stereo output is not, by itself, a failure.

---

### 4. `3B-01` / `3B-02`

Perform controlled acquisition and export.

- `[ ]` 81-field record present
- `[ ]` Explicit nulls preserved
- `[ ]` Unique scan ID
- `[ ]` WAV exists
- `[ ]` SHA-256 check passes
- `[ ]` Timestamps internally ordered
- `[ ]` Requested/realized hardware states remain distinct
- `[ ]` No unexpected route change in accepted scan

---

### 5. `3B-03` SILENCE SERIES

Run at least the required repeated bare-phone silence acquisitions.

- `[ ]` `N >= 2` valid captures
- `[ ]` RMS recorded
- `[ ]` Peak recorded
- `[ ]` SD/repeatability recorded
- `[ ]` Drift recorded
- `[ ]` Clipping checked
- `[ ]` Narrowband/hum candidates reported
- `[ ]` `liquid_inference_permitted = False` retained

No liquid interpretation is permitted.

---

### 6. `3B-04` FREE-AIR ESS SERIES

Acquire at least **N >= 5 valid unclipped repetitions**:

- `[ ]` Five valid repetitions completed
- `[ ]` Peak level recorded
- `[ ]` Arrival alignment measured
- `[ ]` T20/ring-down characterized
- `[ ]` Five-repetition spectral variability recorded
- `[ ]` No synthetic repeatability cutoff introduced

---

### 7. `3B-05` PORT-OCCLUSION PROBE

- `[ ]` Unoccluded acquisition preserved
- `[ ]` Occluded acquisition preserved
- `[ ]` Scan IDs paired
- `[ ]` Attenuation/change calculated
- `[ ]` Interpretation recorded

If attenuation is below the currently controlled `2.0 dB` handling threshold: **`PATH INDETERMINATE`**. Do not convert an indeterminate result into proof of a particular transducer path.

---

### 8. `3B-06` / `3B-07` TIMING AND OUTPUT

- `[ ]` Sample rate verified from WAV
- `[ ]` Frame count valid
- `[ ]` Frame-derived duration valid
- `[ ]` Pre-roll present
- `[ ]` Excitation interval present
- `[ ]` Post-roll present
- `[ ]` No unexplained truncation
- `[ ]` No unexplained discontinuity

- **Pre-scan `outputVolume`:** `__________`
- **Post-scan `outputVolume`:** `__________`
- **Difference:** `__________`
- **Required tolerance:** **±0.01**
- `[ ]` `PASS`
- `[ ]` `INVALID_MEASUREMENT`

---

### 9. `3B-08` COOLDOWN

Verify every applicable path:
- `[ ]` Accepted
- `[ ]` Rejected
- `[ ]` Aborted
- `[ ]` Recovery

- **Requirement:** `next excitation start >= previous excitation end + 2.0 s`
- **Cooldown violations:** `__________`
- **Required:** **ZERO**

---

### 10. `3B-09` FAILURE / RECOVERY

Exercise a supported recoverable failure.

- `[ ]` Failure exercised
- `[ ]` No application crash
- `[ ]` Partial scan not promoted
- `[ ]` Rejection reason preserved
- `[ ]` Recovery state valid
- `[ ]` New legal acquisition succeeds
- `[ ]` Cooldown survives recovery

If this required characterization is omitted: **`M3B CONDITIONAL`**.

---

### 11. `3B-10` FINAL BUNDLE INTEGRITY

Record:
- **Attempted scans:** `__________`
- **Accepted scans:** `__________`
- **Rejected scans:** `__________`
- **Aborted scans:** `__________`

Required integrity:
- `[ ]` Missing required WAVs = `0`
- `[ ]` Untracked orphan WAVs = `0`
- `[ ]` Duplicate scan IDs = `0`
- `[ ]` Malformed required JSONL = `0`
- `[ ]` Unexplained SHA-256 failures = `0`
- `[ ]` Unexplained data loss = `0`
- `[ ]` Cooldown violations = `0`

---

### 12. CONTROLLED AUTOMATED VERIFICATION

Export physical bundle as: **`CSRD_P1_SESS_001`**

Run the controlled `m3b run-all` procedure. Confirm production of:
- `[ ]` `m3b_audit_report.json`
- `[ ]` `m3b_checklist.md`
- `[ ]` `m3b_audio_metrics.json`
- `[ ]` `m3b_plots_manifest.json`

Record:
- **Software build identity:** `__________________________`
- **Dataset manifest SHA-256:** `__________________________`
- **Threshold/configuration SHA-256:** `__________________________`

---

### 13. FINAL PHYSICAL DISPOSITION

Select one only:
- `[ ]` **M3B PASS — AUTHORIZE MILESTONE 3C**
- `[ ]` **M3B CONDITIONAL — CORRECT LOCALIZED DEFECT AND REPEAT AFFECTED TEST**
- `[ ]` **M3B FAIL — HOLD PHYSICAL DEVELOPMENT**

**Rationale:**

`____________________________________________________________`

`____________________________________________________________`

- **Operator:** `__________________________`
- **Signature:** `__________________________`
- **Date:** `__________________________`

---

### STOP RULE

Stop the affected acquisition following route change, clipping, missing mandatory metadata, interruption, uncontrolled acoustic contamination, overheating, or unexpected acquisition behavior.

**Never erase the evidence merely because the run failed.** Preserve the attempted acquisition and its rejection reason.
