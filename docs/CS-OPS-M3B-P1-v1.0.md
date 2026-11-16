# CHEMICAL SOUND

## M3B Real-Device Operator SOP

### `CS-OPS-M3B-P1-v1.0`

- **Parent:** `CS-SOP-M3B-P1-v1.1`
- **Domain:** `IPHONE_NATIVE`

---

### BEFORE START

- `[ ]` Baseline iPhone confirmed
- `[ ]` Correct app build confirmed
- `[ ]` Case OFF
- `[ ]` Charging DISCONNECTED
- `[ ]` No external audio accessory
- `[ ]` Phone position documented
- `[ ]` Environment documented
- `[ ]` Waveform SHA-256 verification PASS
- `[ ]` XCTest PASS
- `[ ]` Python suite PASS
- `[ ]` Classifier OFF

---

### 1 — ACTIVATE

Activate the Chemical Sound audio session.

Record the **realized**:
- sample rate;
- input/output channel counts;
- category and mode;
- input/output route;
- available data-source identity;
- I/O buffer duration;
- input/output latency; and
- `outputVolume`.

A stereo-locked speaker route is **recorded, not automatically rejected**.

---

### 2 — EXPORT CHECK

Perform one controlled acquisition. Run the schema/export check.

Required:
- `[ ]` 81 fields
- `[ ]` explicit nulls
- `[ ]` unique scan ID
- `[ ]` WAV present
- `[ ]` SHA-256 valid
- `[ ]` timestamps ordered

---

### 3 — SILENCE

Run repeated `SIG_SIL_v1` acquisitions.

Check:
- `[ ]` RMS/peak recorded
- `[ ]` clipping absent
- `[ ]` hum candidates reported
- `[ ]` repeatability reported

Do not perform liquid inference.

---

### 4 — FREE-AIR ESS

Run at least **5 valid `SIG_ESS_v1` repetitions**.

Check:
- `[ ]` no clipping
- `[ ]` alignment recorded
- `[ ]` peak recorded
- `[ ]` ring-down recorded
- `[ ]` repetition variability calculated

---

### 5 — PORT OCCLUSION

Record: **UNOBSTRUCTED → OCCLUDED**

Check:
- `[ ]` paired acquisitions preserved
- `[ ]` attenuation calculated
- `[ ]` physical interpretation recorded

---

### 6 — TIMING

Verify:
- `[ ]` frame count
- `[ ]` pre-roll
- `[ ]` excitation
- `[ ]` post-roll
- `[ ]` timestamp continuity
- `[ ]` no truncation

---

### 7 — OUTPUT STATE

Check `outputVolume` immediately before and after acquisition.

- **Required tolerance:** **±0.01**
- **Outside tolerance:** **INVALID MEASUREMENT**

---

### 8 — COOLDOWN

Verify: **next excitation start ≥ previous excitation end + 2.0 s**

- **Required violations:** **ZERO**

Include accepted, rejected, and aborted paths.

---

### 9 — FAILURE RECOVERY

Exercise one supported recoverable failure.

Required:
- `[ ]` no crash
- `[ ]` no partial promotion
- `[ ]` rejection reason retained
- `[ ]` recovery valid
- `[ ]` cooldown preserved

---

### 10 — EXPORT AND AUDIT

Export the real-device session bundle.

Run:
1. **M3B Bundle Auditor** (`m3b audit-bundle`)
2. **M3B Audio Summarizer** (`m3b summarize-audio`)
*(or `m3b run-all` to execute both in sequence)*

Required:
- `[ ]` no missing WAVs
- `[ ]` no orphan WAVs
- `[ ]` no duplicate scan IDs
- `[ ]` no malformed JSONL
- `[ ]` no unexplained hash failures
- `[ ]` no unexplained data loss
- `[ ]` zero cooldown violations

---

### STOP RULE

Stop the affected acquisition for:
**route change / clipping / missing metadata / interruption / uncontrolled noise / overheating / unexpected acquisition behavior**

Do **not** delete the attempted scan. Preserve the evidence and rejection reason.

---

### FINAL DISPOSITION

- `[ ]` **PASS → M3C**
- `[ ]` **CONDITIONAL → correct defect and repeat affected test**
- `[ ]` **FAIL → hold M3C**

> **M3B validates the instrument. It does not validate liquid discrimination.**
