# CHEMICAL SOUND

## Milestone 3B Bare-Phone Bench Audio Characterization SOP

*Controlled Procedure, Operator Run Sheet, Device-Validation Checklist, and Gate 0B Results Record*

| Field | Value |
| :--- | :--- |
| **Document ID** | `CS-SOP-M3B-P1-v1.1` |
| **Supersedes** | `CS-SOP-M3B-P1-v1.0` |
| **Governing Specification** | `CS-SPEC-P1-v1.2` |
| **Associated Report** | `CS-MFR-P1-v1.2-001` |
| **Hardware Domain** | `IPHONE_NATIVE` |
| **Classification** | `CONTROLLED ENGINEERING DOCUMENT` |
| **Effective Date** | Upon approval |
| **Owner** | Gerald Clerge / Chemical Sound Project |

> **CONTROL STATUS:** The controlled PDF is the presentation copy; this archived Markdown source remains the editable source record in the repository. Printed copies are uncontrolled unless signed and dated.

---

## Document Control and Revision Record

| Version | Status | Change Summary | Approval |
| :--- | :--- | :--- | :--- |
| `v1.0` | Archived source | Initial controlled Milestone 3B SOP and Gate 0B thresholds. | Per project archive |
| `v1.1` | Controlled PDF | Added one-page operator run sheet; device-validation checklist; Gate 0B results tables; documented nonfatal stereo-locked output-route handling; codified bundle-auditor and decision-engine interfaces. | Pending |

### Controlled configuration statement
The software requests `preferredOutputNumberOfChannels(1)`. A realized stereo-locked iOS speaker route is recorded as observed configuration and is not, by itself, a fatal error. Requested and realized values remain separate fields. Eligibility is determined by post-activation validation, route stability, frame/timing integrity, and repeatability.

### Scope
This document governs native-iPhone bench characterization before fixture lock. It does not establish liquid identity, concentration, chemical composition, electrical properties, electrical safety, or classification capability.

### Scientific order
`Instrument validity -> signal-path validity -> phenomenon validity -> classification validity`. Classification performance cannot substitute for failure at an earlier level.

### Version-control rule
Any threshold, feature definition, aggregation rule, or decision mapping changed after labelled Gate 0B results are examined requires a new document version and a clearly identified exploratory analysis. It shall not be represented as the original preregistered result.

---

## ONE-PAGE OPERATOR RUN SHEET — MILESTONE 3B

*(Use at the bench. Complete one sheet per session. Do not place liquid samples in Milestone 3B.)*

- **Session ID:** `________________` | **Date/Time:** `________________` | **Operator:** `________________`
- **iPhone model / ID:** `________________` | **iOS / build:** `________________` | **Battery start/end:** `_______ / _______`
- **Room / bench:** `________________` | **Case / charging:** `NONE / UNPLUGGED` | **Ambient temp:** `_______ C`

| Step | Operator action | Record / acceptance | Done |
| :- | :--- | :--- | :-: |
| `0` | **Stop rule.** Stop active excitation for route change, clipping, missing metadata, interruption, uncontrolled noise, overheating, or unexpected behavior. Preserve the attempted scan and rejection reason. | Do not delete failed or aborted evidence. | `[ ]` |
| `1` | Confirm source tests/XCTests passed; app build installed; waveform manifest verified; classifier disabled. | Build: `________` Tests: `PASS / FAIL` | `[ ]` |
| `2` | Remove case; unplug charging; place phone in documented orientation; quiet nearby equipment. | Photo/position ID: `__________` | `[ ]` |
| `3` | Activate audio session. Capture requested and realized category, mode, rate, channels, route, data sources, buffer, and latencies. | Stereo-locked output is logged, not automatically fatal. | `[ ]` |
| `4` | Run **3B-01** schema/export round trip. | 81 fields; explicit nulls; unique IDs; all WAV references resolve. | `[ ]` |
| `5` | Run **3B-03** repeated `SIG_SIL_v1` captures. | RMS/peak dBFS; hum review; clipping; repeatability. | `[ ]` |
| `6` | Run **3B-04** free-air `SIG_ESS_v1`, minimum 5 valid repetitions. | Peak; alignment; ring-down; 5-rep SD; no clipping. | `[ ]` |
| `7` | Run **3B-05** paired port-occlusion probe. | Unoccluded vs occluded attenuation: `______ dB` | `[ ]` |
| `8` | Audit WAV rate/frame count, pre-roll, excitation, post-roll, state timestamps, and `>=2.0 s` cooldown. | Violations: `0` required. | `[ ]` |
| `9` | Exercise recoverable failure: arm failure, abort/QC rejection, or available route/interruption condition. | No crash; no partial promotion; reason retained; recovery legal. | `[ ]` |
| `10` | Export final session bundle and run automated M3B Bundle Auditor. | Orphans `0`; missing WAVs `0`; duplicate IDs `0`; malformed JSONL `0`. | `[ ]` |
| `11` | Assign disposition and sign. | `PASS / CONDITIONAL / FAIL` | `[ ]` |

- **Operator signature:** `____________________________` | **Date:** `____________`
- **Bundle path / ID:** `____________________________` | **Auditor report:** `PASS / FAIL`

---

## 1. Purpose and Preconditions

Milestone 3B determines whether the designated baseline iPhone and Minimal Swift Acquisition Prototype provide a sufficiently stable, reproducible native audio acquisition platform for subsequent Chemical Sound feasibility experiments.

### Preconditions
- Milestone 3A source tests and native XCTest suites pass.
- The app installs on the designated baseline iPhone.
- Waveform manifest SHA-256 verification passes.
- The 22-state acquisition machine and `2.0 s` cooldown invariant are enabled.
- No on-device liquid classification is enabled.
- CSRD-P1-compatible export is available.
- The device is unplugged and its case removed.

---

## 2. Baseline Device Lock and Environment

| Property | Requested / required | Post-activation verified value | Status |
| :--- | :--- | :--- | :-: |
| Commercial model and identifier | Single baseline unit | | `[ ]` |
| iOS version / app build | Locked for Phase 1 | | `[ ]` |
| Case / charging | `NONE` / Unplugged | | `[ ]` |
| Category / mode | `.playAndRecord` / `.measurement` | | `[ ]` |
| Sample rate | `48,000 Hz` requested | | `[ ]` |
| Channels | `1 input` / `1 output` preferred | | `[ ]` |
| Route / data source | Built-in; empirically verified | | `[ ]` |
| Latency / buffer | Logged | | `[ ]` |
| `outputVolume` | Frozen target `+/- 0.01` | | `[ ]` |

Document room, bench location, phone orientation, nearby equipment, HVAC state if relevant, obvious transient noise, battery at start/end, ambient temperature, and test timestamps. Interrupt testing when uncontrolled contamination occurs; retain the affected attempt in the audit trail.

---

## 3. Tests 3B-01 through 3B-10

- **3B-01 Schema and export round trip:** Verify all 81 fields, explicit nulls, unique scan IDs, timestamp order, accepted/rejected statuses, rejection reasons, waveform IDs and digests, and all referenced WAVs.
- **3B-02 Realized audio configuration:** Record actual sample rate, formats, channels, ports, data sources where exposed, buffer duration, latencies, route, and pre/post `outputVolume`. Preserve requested and realized values separately.
- **3B-03 Silence characterization:** Acquire repeated `SIG_SIL_v1` records; calculate RMS/peak dBFS, clipping, spectrum, narrowband interference, repetition variability, and drift.
- **3B-04 Free-air ESS characterization:** Acquire at least five valid uncoupled `SIG_ESS_v1` repetitions; preserve raw WAV, digest, volume, peak, clipping, impulse estimate, arrival, ring-down, and repetition statistics.
- **3B-05 Port-occlusion probe:** Compare unobstructed and selectively occluded acquisitions. Identify the dominant physical output path empirically; do not rely solely on model diagrams.
- **3B-06 Frame and timing integrity:** Verify rate, frame count, realized duration, pre-roll, excitation, post-roll, transition timestamps, and continuity. Investigate truncation, duplication, discontinuity, or displacement.
- **3B-07 Output-state stability:** Compare pre-arm and post-acquisition `outputVolume`. A mismatch outside the frozen tolerance invalidates the measurement; the scalar is not calibrated sound pressure.
- **3B-08 Cooldown invariant:** For every pair, require `next t_exc_start >= previous t_exc_end + 2.0 s`, including ordinary, aborted, rejected, and recoverable-failure paths.
- **3B-09 Recoverable failure behavior:** Confirm no crash, no partial promotion, retained rejection reason, correct recovery state, legal subsequent acquisition, and preserved cooldown.
- **3B-10 Raw-data integrity:** Audit attempted, accepted, rejected and aborted counts; orphan/missing WAVs; duplicate IDs; malformed JSONL; and unexpected hashes. No unexplained loss is permitted.

---

## 4. Device-Validation Checklist

### Software integrity
1. `[ ]` Swift package builds on Apple Silicon
2. `[ ]` All five XCTest suites pass
3. `[ ]` Python and Swift-parity tests remain passing
4. `[ ]` Waveform SHA-256 verification passes
5. `[ ]` 22-state machine verified
6. `[ ]` Cooldown invariant verified
7. `[ ]` No classifier active

### Audio configuration
1. `[ ]` Requested and actual category/mode recorded
2. `[ ]` Requested and actual rate recorded
3. `[ ]` Input/output formats and channel counts recorded
4. `[ ]` Route and data sources recorded where available
5. `[ ]` I/O buffer and latencies recorded
6. `[ ]` Stereo-locked output route treated as observed configuration, not automatic fatal error

### Recording integrity
1. `[ ]` Mono capture format verified
2. `[ ]` `48 kHz` Float32 WAV verified
3. `[ ]` Frame count and duration verified
4. `[ ]` Pre-roll/excitation/post-roll preserved
5. `[ ]` No unexplained truncation or reordering
6. `[ ]` Disk failures propagate deterministically

### Instrument baseline
1. `[ ]` `SIG_SIL` series completed
2. `[ ]` Noise floor and narrowband interference reviewed
3. `[ ]` Five-repetition free-air ESS completed
4. `[ ]` Peak, clipping, ring-down, and variability recorded
5. `[ ]` Port-occlusion probe completed

### Acquisition safeguards
1. `[ ]` `outputVolume` checked before and after
2. `[ ]` Out-of-tolerance scan rejected
3. `[ ]` Rejected and aborted scans retained
4. `[ ]` Arm failure recoverable
5. `[ ]` Cooldown verified after failure

### Export integrity
1. `[ ]` All 81 fields represented
2. `[ ]` Explicit JSON nulls preserved
3. `[ ]` Every WAV resolves to a scan
4. `[ ]` Unique identifiers verified
5. `[ ]` Reasons and waveform identities retained
6. `[ ]` Hashes verified after export
7. `[ ]` Bundle independently reopens

### Milestone 3B disposition
- **PASS** — advance to Milestone 3C.
- **CONDITIONAL** — correct the identified acquisition defect and repeat the affected 3B test.
- **FAIL** — native-iPhone acquisition is not sufficiently characterized for fixture development.

---

## 5. Pre-Registered Gate 0B Acceptance Thresholds

> These are Chemical Sound engineering gates, not external scientific or regulatory standards. Freeze them before labelled Water-versus-Oil results are inspected.

| Criterion | Frozen threshold / rule | Fail consequence |
| :--- | :--- | :--- |
| Independent sample structure | `>=4` independent preparations per class; `>=2` sessions/days; fresh fills; balanced development containers; unseen-container representation for each class. | `GATE_INCOMPLETE` |
| Primary metric | Sample-level balanced accuracy; technical scans aggregated by frozen rule. | No scan-level pseudoreplication |
| Primary performance | Balanced accuracy `>=80%`. | Decision A prohibited |
| Uncertainty | Prespecified 95% interval lower bound `>50%`. | Decision A prohibited |
| Unseen containers | Balanced accuracy `>=70%`. | Decision A prohibited |
| Cross-session/day | Balanced accuracy `>=70%`. | Decision A prohibited |
| Per-class sensitivity | Neither class sensitivity `<70%`. | Decision A prohibited |
| Nuisance-only classifier | Held-out balanced accuracy `<60%` and uncertainty compatible with chance. | Confounder investigation |
| Repositioning ratio | Water/Oil separation `>=2x` remove-and-replace variability. | Decision A prohibited |
| Session drift ratio | Session drift `<=25%` of Water/Oil separation. | Decision A prohibited |
| Volume state | Frozen `outputVolume` tolerance `+/-0.01` scalar units. | Measurement invalid |
| Cooldown | `>=2.0 s` between excitation end and next excitation start. | Measurement invalid |

### Decision logic
- **DECISION A** — Proceed only if Gate 0A path validity and every frozen Gate 0B criterion passes.
- **DECISION B** — Hold and redesign when fixture/path effects dominate or remain indeterminate.
- **DECISION C** — Segregated external-transducer diagnostic when native iPhone quality remains inadequate after reasonable optimization. Do not merge its data with `IPHONE_NATIVE` datasets.
- **DECISION D** — Phenomenon not yet established when neither native nor segregated diagnostic demonstrates reproducible liquid-dependent separation after nuisance controls.

---

## 6. Gate 0B Results Table — Study Structure and Yield

| Field | Required / frozen | Observed result | Pass? |
| :--- | :--- | :--- | :-: |
| Water preparations | `>=4` independent | | `[ ]` |
| Oil preparations | `>=4` independent | | `[ ]` |
| Sessions/days | `>=2` | | `[ ]` |
| Unseen containers per class | Represented | | `[ ]` |
| Attempted scans | Report | | `[ ]` |
| `PROVISIONALLY_ACCEPTED` | Report | | `[ ]` |
| `FINAL_ACCEPTED` | Report | | `[ ]` |
| `INVALID_MEASUREMENT` | Report by reason | | `[ ]` |
| GATE completeness | All structure requirements satisfied | `COMPLETE / GATE_INCOMPLETE` | `[ ]` |

### Primary performance record

| Evaluation partition | Independent samples | Balanced accuracy | 95% interval | Class sensitivities | Threshold met? |
| :--- | :--- | :--- | :--- | :--- | :-: |
| Nested grouped development validation | | | | Water: `___` Oil: `___` | `[ ]` |
| Unseen container holdout | | | | Water: `___` Oil: `___` | `[ ]` |
| Cross-session / day transfer | | | | Water: `___` Oil: `___` | `[ ]` |

### Nuisance and physical-control record

| Control | Frozen criterion | Observed | Pass? | Interpretation / action |
| :--- | :--- | :--- | :-: | :--- |
| Nuisance-only metadata classifier | `<60%` balanced accuracy; compatible with chance | | `[ ]` | |
| Acoustic pre-roll / bleed control | No class-predictive leakage | | `[ ]` | |
| Remove-and-replace | Separation `>=2x` variability | Ratio: `______` | `[ ]` | |
| Session drift | `<=25%` of separation | Ratio: `______` | `[ ]` | |
| Added mass K1 | Does not explain class | | `[ ]` | |
| Coupling force K2 | Within frozen tolerance | | `[ ]` | |
| Fill F / Temperature G | Do not explain class | | `[ ]` | |
| Path isolation Gate 0A | Acceptable physical signal path | | `[ ]` | |

---

## 7. Gate 0B Formal Disposition

| Select one | Disposition | Required basis / next action |
| :-: | :--- | :--- |
| `[ ]` | **DECISION A — PROCEED** | Gate 0A valid; complete independent-sample structure; all performance, uncertainty, nuisance, repositioning, drift and sensitivity criteria pass. Proceed to Milestone 5 / Phase 1A. |
| `[ ]` | **DECISION B — HOLD AND REDESIGN** | Measurable response exists, but fixture/path/repositioning/force/session effects dominate or remain indeterminate. Revise Mode B and repeat Gate 0A/0B. |
| `[ ]` | **DECISION C — EXTERNAL TRANSDUCER DIAGNOSTIC** | Native iPhone remains inadequate after reasonable optimization. Conduct segregated diagnostic; do not merge data into `IPHONE_NATIVE`. |
| `[ ]` | **DECISION D — PHENOMENON NOT YET ESTABLISHED** | Neither native nor segregated diagnostic establishes reproducible liquid-dependent separation after nuisance controls. Suspend classification development. |
| `[ ]` | **`GATE_INCOMPLETE`** | Minimum independent preparations, sessions/days, or required holdouts were not completed. Collect only the missing preregistered evidence; do not score as failure or success. |

> **Final control statement:** A failed Gate 0B does not establish that acoustic liquid discrimination is impossible. It establishes only that the specified Chemical Sound instrument and experiment did not demonstrate the required phenomenon under these frozen criteria.

---

## Appendix A — Software Operationalization Requirements

### A.1 Automated M3B Bundle Auditor
- Audit Tests `3B-01` through `3B-10` from one exported session bundle.
- Verify 81-field schema and explicit-null parity.
- Identify orphan and missing WAV files, duplicate scan IDs, malformed JSONL, unexpected hashes, and frame-versus-timestamp discontinuity.
- Calculate silence RMS/peak and flag narrowband line-hum candidates without converting the flag into a liquid inference.
- Calculate paired port-occlusion attenuation.
- Verify `>=2.0 s` cooldown across accepted, rejected, and aborted scans.
- Emit machine-readable JSON plus a human-readable controlled audit report.

### A.2 Gate 0B Decision Engine
- Return `GATE_INCOMPLETE` before model scoring when independent-preparation or session/day minima are unmet.
- Use the frozen sample-level aggregation and grouped/nested partition structure.
- Evaluate primary balanced accuracy, uncertainty limit, unseen-container transfer, cross-session transfer, class sensitivities, nuisance-only classifier, repositioning ratio, and drift ratio.
- Never promote exploratory feature selection or threshold changes into the preregistered result.
- Emit Decision A only when every mandatory requirement passes; otherwise map explicitly to B, C, D, or `GATE_INCOMPLETE` with reasons.

### A.3 Recommended CLI surface

| Subcommand | Purpose | Required output |
| :--- | :--- | :--- |
| `m3b audit-bundle` | Run `3B-01` through `3B-10` automated checks. | JSON + PDF/Markdown audit |
| `m3b summarize-audio` | Silence, ESS, timing, hum and occlusion summaries. | Metrics + plots manifest |
| `gate0b validate-design` | Check preparations, classes, sessions, groups and holdouts before labels are scored. | `COMPLETE` / `GATE_INCOMPLETE` |
| `gate0b evaluate` | Run frozen grouped evaluation and nuisance controls. | Metrics + threshold matrix |
| `gate0b decide` | Apply Sections 16–17 without threshold editing. | `A` / `B` / `C` / `D` / `GATE_INCOMPLETE` + reasons |

### Implementation note
The controlled PDF specifies behavior and acceptance. Source code, tests, generated audit outputs, and CLI help are controlled separately through repository versioning. Each decision report shall record software commit/build identity and the SHA-256 digests of the dataset manifest and threshold configuration.
