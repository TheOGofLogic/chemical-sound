# LIQUID ANALYZER

## M3B Real-Device Bundle Acceptance Criteria

### `CS-ACC-M3B-P1-v1.0`

- **Parent SOP:** `CS-SOP-M3B-P1-v1.1`
- **Associated Checklist / Operator SOP:** `CS-CHK-M3B-P1-v1.0` / `CS-OPS-M3B-P1-v1.0`
- **Hardware Domain:** `IPHONE_NATIVE`

A real-device session bundle may receive **M3B PASS** only when all mandatory integrity criteria below are satisfied.

---

## A. HARD PASS REQUIREMENTS

### Data Integrity

**Required:**
- 81-field `ScanRecord` compatibility;
- explicit-null compatibility;
- zero unexplained duplicate scan IDs;
- zero missing required WAV files;
- zero unexplained orphan measurement WAVs;
- zero malformed required JSONL records;
- zero unexplained waveform-integrity failures;
- readable exported bundle.

- **Any unexplained failure:** **FAIL affected acquisition.**
- **Systematic failure:** **M3B FAIL.**

---

### Audio-State Provenance

The bundle must preserve both requested and realized audio configuration.

Required realized values include, where exposed:
- sample rate;
- channel counts;
- category/mode;
- active route;
- data-source information;
- I/O buffer duration;
- input latency;
- output latency; and
- `outputVolume`.

Realized stereo output is **not a failure merely because mono output was preferred**.

Unexpected route change during an acquisition invalidates that acquisition.

---

### File/Timing Integrity

Required:
- WAV sample rate readable;
- WAV frame count valid;
- frame-derived duration internally consistent;
- required pre-roll present;
- excitation interval present;
- required post-roll present;
- timestamps internally ordered;
- no unexplained truncation;
- no unexplained discontinuity.

Any scan failing these requirements: **`INVALID_MEASUREMENT`**.

---

### Output-State Stability

- **Frozen allowable difference:** **±0.01 `outputVolume` scalar units**
- **Outside frozen tolerance:** **`INVALID_MEASUREMENT`**

The scalar shall not be interpreted as calibrated sound pressure.

---

### Cooldown

- **Required:** **Δt ≥ 2.0 s** between previous excitation end and subsequent excitation start.
- **Scope:** accepted, rejected, aborted, and recoverable-failure paths.
- **Required violations:** **ZERO**.

Any software path permitting early re-excitation is an M3B blocking defect.

---

### Free-Air ESS

- **Minimum:** **5 valid repetitions**

Required:
- recordings complete;
- no analysis-window clipping;
- impulse/arrival measurement obtainable;
- ring-down measurement obtainable;
- valid repetition statistic obtainable.

M3B is incomplete if five valid characterization records cannot be obtained.

No predetermined numerical ESS repeatability threshold is assigned solely from synthetic testing. The observed repeatability becomes empirical input to the M3C fixture design.

---

### Silence Characterization

Required:
- repeated bare-phone silence measurements available;
- RMS recorded;
- peak recorded;
- clipping assessed;
- narrowband interference candidates reported;
- repetition variability reported.

No universal numerical noise-floor threshold is imposed at M3B. The measured baseline becomes an empirical property of the designated phone/environment combination.

---

### Port-Occlusion Probe

Required:
- paired unoccluded/occluded recordings;
- acquisition identity preserved;
- measured response difference calculated;
- physical interpretation documented.

A weak or indeterminate occlusion result shall be recorded as: **`PATH INDETERMINATE`**. It shall not be rewritten as proof of a particular hardware path.

---

### Recoverable-Failure Behavior

Required:
- application remains operational;
- incomplete scan not promoted;
- rejection reason retained;
- state machine reaches legal recovery state;
- next legal acquisition remains possible;
- cooldown remains enforced.

Any repeatable failure causing silent data promotion or loss: **M3B FAIL**.

---

## B. AUTOMATED BUNDLE REQUIREMENTS

The M3B Bundle Auditor must complete successfully.

The final artifact set shall contain:
- original exported bundle;
- `m3b_audit_report.json`;
- `m3b_checklist.md`;
- `m3b_audio_metrics.json`;
- `m3b_plots_manifest.json`;
- software build identity;
- dataset-manifest SHA-256; and
- applicable configuration/protocol digest.

The bundle shall retain rejected and aborted observations where specified by the governing schema.

---

## C. M3B PASS RULE

Assign **M3B PASS** only when:
1. mandatory data-integrity checks pass;
2. realized hardware configuration is documented;
3. recording/frame/timing integrity passes;
4. required silence characterization completes;
5. at least five valid free-air ESS repetitions complete;
6. port-occlusion testing completes;
7. output-state tolerance is respected by accepted scans;
8. cooldown violations equal zero;
9. recoverable-failure behavior passes;
10. the complete bundle passes automated audit; and
11. no unresolved defect threatens interpretation of the subsequent M3C experiment.

---

## D. CONDITIONAL RULE

Assign **M3B CONDITIONAL** when the acquisition platform is fundamentally operational but a localized, correctable defect prevents acceptance of one required test.

The failed test shall be repeated after correction. Unaffected completed tests need not be repeated unless the correction could reasonably alter their results.

---

## E. FAILURE RULE

Assign **M3B FAIL** when a systematic defect compromises:
- acquisition integrity;
- file integrity;
- timing integrity;
- route stability;
- state-machine safety;
- cooldown enforcement;
- evidence preservation; or
- reproducibility sufficiently to prevent meaningful M3C characterization.

Do not proceed to Milestone 3C until the blocking defect is corrected.

---

## F. WHAT M3B PASS MEANS

**M3B PASS means:**
The designated iPhone and Liquid Analyzer acquisition software have demonstrated sufficient operational integrity to begin controlled fixture characterization.

**M3B PASS does not mean:**
- Liquid Analyzer distinguishes liquids;
- Water and Oil are acoustically separable;
- concentration can be estimated;
- an unknown liquid can be identified;
- the acoustic phenomenon has been established; or
- the eventual Sound Multimeter concept has been validated.

Those questions remain downstream experimental questions.

---

## G. NEXT AUTHORIZED STEP AFTER PASS

`M3B PASS` → **Milestone 3C Adjustable Mode B Fixture** → **Gate 0A Path Isolation** → **Gate 0B Randomized/Blinded Water-vs-Oil Feasibility**

No Gate 0B liquid result may be used to retroactively alter the M3B instrument-acceptance criteria.
