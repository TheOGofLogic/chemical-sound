# CHEMICAL SOUND

## Milestone 3B Physical-Run Checklist

- **Document ID:** `CS-CHK-M3B-P1-v1.0`
- **Parent SOP:** `CS-SOP-M3B-P1-v1.1`
- **Hardware Domain:** `IPHONE_NATIVE`
- **Purpose:** Real-device validation of the designated baseline iPhone acquisition system.

---

### A. Session Identification

- **Session ID:** `______________________________`
- **Date:** `__________________`
- **Operator:** `______________________________`
- **iPhone commercial model:** `______________________________`
- **Hardware identifier:** `______________________________`
- **iOS version:** `______________________________`
- **Chemical Sound build:** `______________________________`
- **Software build identity / commit:** `______________________________`
- **Battery start:** `__________ %`
- **Battery end:** `__________ %`
- **Ambient temperature:** `__________ °C`
- **Bench/location ID:** `______________________________`
- **Phone-position/photo ID:** `______________________________`

---

### B. Physical Preconditions

- `[ ]` Designated baseline iPhone used
- `[ ]` Phone case removed
- `[ ]` Charging cable disconnected
- `[ ]` External audio accessories disconnected
- `[ ]` Bench cleared of unnecessary vibrating equipment
- `[ ]` Obvious transient acoustic sources controlled
- `[ ]` Device orientation documented
- `[ ]` App build identity recorded
- `[ ]` Waveform manifest verification passed
- `[ ]` No liquid classifier enabled
- `[ ]` No fixture or liquid vessel attached during native bare-phone characterization

---

### C. Software Preconditions

- `[ ]` Swift/XCTest suite PASS
- `[ ]` Python verification suite PASS
- `[ ]` 22-state acquisition state machine enabled
- `[ ]` SHA-256 waveform verification enabled
- `[ ]` Rejected/aborted scans retained
- `[ ]` 2.0 s minimum excitation cooldown enabled
- `[ ]` CSRD-P1 export enabled
- `[ ]` Bundle Auditor available (`m3b audit-bundle`)
- `[ ]` Audio Summarizer available (`m3b summarize-audio`)

---

### D. Post-Activation Audio State

- **Requested sample rate:** `48,000 Hz`
- **Observed sample rate:** `__________ Hz`
- **Requested input channels:** `1`
- **Observed input channels:** `__________`
- **Preferred output channels:** `1`
- **Observed output channels:** `__________`
- **Observed stereo-locked route, if applicable:** `[ ] YES`   `[ ] NO`
  *(A stereo-locked output route alone is not a failure.)*
- **Requested category:** `.playAndRecord`
- **Observed category:** `______________________________`
- **Requested mode:** `.measurement`
- **Observed mode:** `______________________________`
- **Input port:** `______________________________`
- **Input data source:** `______________________________`
- **Output port:** `______________________________`
- **Output data source, if exposed:** `______________________________`
- **I/O buffer duration:** `__________ ms`
- **Input latency:** `__________ ms`
- **Output latency:** `__________ ms`
- **Starting `outputVolume`:** `__________`

---

### E. Test 3B-01 — Schema/Export

- `[ ]` Acquisition produced a valid record
- `[ ]` 81 `ScanRecord` fields represented
- `[ ]` Explicit nulls preserved
- `[ ]` Scan ID unique
- `[ ]` Referenced WAV exists
- `[ ]` Waveform identity retained
- `[ ]` SHA-256 verification passed
- `[ ]` Timestamp sequence valid
- `[ ]` Export bundle reopens successfully
- **Result:** `[ ] PASS`   `[ ] CONDITIONAL`   `[ ] FAIL`

---

### F. Test 3B-03 — Bare-Phone Silence

- **Number attempted:** `__________`
- **Number valid:** `__________`
- **RMS dBFS:** `______________________________`
- **Peak dBFS:** `______________________________`
- **Clipping detected:** `[ ] NO`   `[ ] YES`
- **Narrowband/hum candidates:** `______________________________`
- **Unexpected temporal drift:** `______________________________`
- **Operator observation:** `______________________________`

---

### G. Test 3B-04 — Free-Air ESS

- **Minimum required valid repetitions:** **5**
- **Valid repetitions obtained:** `__________`
- **Mean/representative peak dBFS:** `__________`
- **Five-repetition variability:** `__________`
- **Ring-down estimate:** `__________ ms`
- **Clipping:** `[ ] NONE`   `[ ] PRESENT`
- **Impulse alignment stable:** `[ ] YES`   `[ ] NO`
- **Unexplained progressive drift:** `[ ] NO`   `[ ] YES`

---

### H. Test 3B-05 — Port-Occlusion Probe

- **Unoccluded acquisition ID:** `______________________________`
- **Occluded acquisition ID:** `______________________________`
- **Occlusion location:** `______________________________`
- **Measured attenuation/change:** `__________ dB`
- **Repeatable:** `[ ] YES`   `[ ] NO`
- **Dominant physical path supported:** `[ ] YES`   `[ ] INDETERMINATE`
  *(Do not identify a port solely from the commercial phone model.)*

---

### I. Test 3B-06 — Timing Integrity

- `[ ]` WAV sample rate valid
- `[ ]` WAV frame count valid
- `[ ]` Frame-derived duration consistent
- `[ ]` Pre-roll present
- `[ ]` Excitation interval present
- `[ ]` Post-roll present
- `[ ]` State timestamps internally ordered
- `[ ]` No unexplained truncation
- `[ ]` No unexplained duplicated segment
- `[ ]` No unexplained discontinuity

---

### J. Test 3B-07 — Output-State Stability

- **Pre-scan `outputVolume`:** `__________`
- **Post-scan `outputVolume`:** `__________`
- **Absolute difference:** `__________`
- **Frozen tolerance:** **±0.01**
- `[ ]` **PASS**
- `[ ]` **INVALID MEASUREMENT**
  *(`outputVolume` is an instrument-state variable, not a calibrated acoustic-pressure measurement.)*

---

### K. Test 3B-08 — Cooldown

- **Minimum permitted interval:** **2.0 s**
- **Minimum observed interval:** `__________ s`
- **Cooldown violations:** `__________`
- **Required:** **0 violations**
- `[ ] PASS`   `[ ] FAIL`
  *(Verify successful, rejected, and aborted paths.)*

---

### L. Test 3B-09 — Recovery

- **Failure condition exercised:** `______________________________`
- `[ ]` No crash
- `[ ]` Partial scan not promoted
- `[ ]` Rejection reason preserved
- `[ ]` State machine recovered correctly
- `[ ]` Subsequent acquisition possible
- `[ ]` Cooldown remained enforced

---

### M. Test 3B-10 — Final Bundle Integrity

- **Attempted scans:** `__________`
- **Accepted scans:** `__________`
- **Rejected scans:** `__________`
- **Aborted scans:** `__________`
- **Missing WAVs:** `__________`
- **Orphan WAVs:** `__________`
- **Duplicate scan IDs:** `__________`
- **Malformed JSONL records:** `__________`
- **Hash failures:** `__________`
- **Cooldown violations:** `__________`
- **Unexplained data losses:** `__________`

---

### N. Automated Audit

- **`m3b audit-bundle`:** `[ ] PASS`   `[ ] FAIL`
- **`m3b summarize-audio`:** `[ ] COMPLETE`   `[ ] FAILED`
- **Audit report identity:** `______________________________`
- **Dataset manifest SHA-256:** `______________________________`
- **Threshold/configuration SHA-256:** `______________________________`

---

### O. Physical-Run Disposition

Select one:

- `[ ]` **M3B PASS — ADVANCE TO MILESTONE 3C**
- `[ ]` **M3B CONDITIONAL — CORRECT SPECIFIC DEFECT AND REPEAT AFFECTED TEST**
- `[ ]` **M3B FAIL — DO NOT PROCEED TO FIXTURE CHARACTERIZATION**

**Reason:**

`________________________________________________________________`

`________________________________________________________________`

- **Operator signature:** `______________________________`
- **Date:** `__________________`
