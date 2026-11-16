# CHEMICAL SOUND

## Milestone 3B Pre-Bench Freeze Note

- **Freeze ID:** `CS-FREEZE-M3B-P1-v1.0`
- **Hardware Domain:** `IPHONE_NATIVE`

Chemical Sound has reached the Milestone 3B pre-bench freeze point.

The software acquisition, auditing, provenance, reporting, and decision-control architecture is considered development-complete for purposes of beginning the designated baseline-iPhone physical validation experiment.

---

### Frozen Controlled Documents

- `CS-SOP-M3B-P1-v1.1`
- `CS-CHK-M3B-P1-v1.0`
- `CS-OPS-M3B-P1-v1.0`
- `CS-ACC-M3B-P1-v1.0`
- `CS-EXEC-M3B-P1-v1.0`

---

### Frozen Provenance & Configuration Digests

- **Software Build Identity:** `chemical-sound==0.1.2` (`src-f4f936ab4542`)
- **Package Source SHA-256:** `f4f936ab454281729951f4a18eb313ad24ae01df8723b18cd79bacef50853394`
- **M3B Configuration / Threshold SHA-256 (`CS-ACC-M3B-P1-v1.0`):** `918f523f150981cacc9f6c402cdbdca3663704e54968a156322be839b02f2de8`
- **Gate 0B Threshold & Frozen Classifier SHA-256 (`CS-SOP-M3B-P1-v1.1`):** `7e78adf1ce2ebd85ad485ef039bb44e7d5ef8f47b19c4baef52b19722d938c0f`

---

### Reported Verification Checkpoint

The project reports that `test_pipeline.py` completed all 11 controlled verification suites successfully:

- **Result:** **11/11 PASS**
- **Reported runtime:** **14.88 s**

This freeze note records that result as the project's reported repository verification checkpoint.

---

### Verified Development Scope

The reported verification covers the controlled software architecture for:
- waveform integrity;
- acquisition-state handling;
- CSRD-P1 schema handling;
- explicit-null preservation;
- native audio-state provenance;
- repeated silence characterization;
- free-air ESS characterization;
- port-occlusion handling;
- frame/timestamp checks;
- output-state QC;
- all-path excitation cooldown;
- recoverable failure behavior;
- orphan and missing WAV detection;
- controlled bundle auditing;
- audio summarization;
- Gate 0B design validation;
- nuisance-confounding detection;
- formal Gate 0B decision mapping; and
- controlled CLI execution.

The corrected orphan-WAV test remains a useful validation-control event: an untracked WAV was detected by `3B-10` rather than silently accepted.

---

### Frozen Experimental Boundary

At this checkpoint:
- **Software operationalization:** `COMPLETE`
- **Synthetic verification:** `REPORTED 11/11 PASS`
- **Real-device M3B validation:** `NOT YET EXECUTED`
- **Milestone 3C:** `NOT YET AUTHORIZED`
- **Gate 0A:** `NOT YET EXECUTED`
- **Gate 0B:** `NOT YET EXECUTED`
- **Liquid-dependent phenomenon:** `NOT YET ESTABLISHED`
- **Liquid classification capability:** `NOT ESTABLISHED`

---

### Change-Control Rule

Following this freeze, software or protocol changes shall be limited to defects necessary to execute or correctly interpret the physical M3B run.

Any change affecting:
- measurement acceptance;
- timing;
- cooldown;
- signal processing;
- feature extraction;
- path interpretation;
- noise handling;
- ESS handling;
- disposition rules;
- Gate 0B thresholds;
- nuisance controls; or
- classification behavior

shall be documented and versioned before the affected evidence is treated as controlled confirmatory evidence.

- **Observed physical results** shall not be used to retroactively modify the frozen acceptance rules and then reinterpret the same experiment as though the revised rules had been preregistered.

#### Post-Freeze Build Defect Log (Pre-Physical Run)
- **`M3B-BF-01` (Swift 6 `@MainActor` Concurrency Compile Fix):** Replaced `inout` parameter across `async` boundary in `SampleSetupView.swift` / `AcquisitionCoordinator.acceptSampleAndRunSettling` with a value-returning `SampleMetadata` signature, and wrapped `UIDevice.current` telemetry reads inside `await MainActor.run` in `AudioSessionController.swift`. Zero impact on audio routing, timing, cooldown, QC thresholds, schema fields, DSP, or Gate 0B rules; Python `package_source_sha256` (`f4f936ab454281729951f4a18eb313ad24ae01df8723b18cd79bacef50853394`) and M3B/Gate 0B threshold digests remain unchanged.
- **`M3B-BF-03` (Real-Device `iPhone15,3` `AVAudioSession` `OSStatus -50` Activation Ordering Fix, Build `3`):** Empirical testing on physical baseline `iPhone15,3` (`IOS_DEV_21F03054`, Build `2`) exposed `NSOSStatusErrorDomain Code=-50` (`paramErr`) when calling `setPreferredInputNumberOfChannels(1)` / `.defaultToSpeaker` prior to `AVAudioSession.setActive(true)` in `.measurement` mode. Reordered `AudioSessionController.configure` to activate `.playAndRecord` / `.measurement` first (falling back cleanly if `.defaultToSpeaker` is rejected pre-activation and applying `overrideOutputAudioPort(.speaker)` + preferred input/output channel preferences post-activation), while preserving strict post-activation verification in `AudioRouteValidator`.

---

### Next Authorized Experimental Artifact

The next controlled empirical artifact is: **`CSRD_P1_SESS_001`** generated from the designated physical baseline iPhone under `CS-OPS-M3B-P1-v1.0`.

Upon export, the real-device bundle shall undergo the controlled M3B audit and audio-summary workflow (`m3b run-all`).

The resulting evidence shall support exactly one M3B disposition:
- **`M3B PASS`**
- **`M3B CONDITIONAL`**
- **`M3B FAIL`**

Only **`M3B PASS`** authorizes progression to Milestone 3C Adjustable Mode B Fixture characterization.

---

### Scientific Status

Milestone 3B remains an **instrument-validation milestone**.

A successful physical M3B result will establish that the designated iPhone/software configuration is sufficiently operationally characterized to proceed with fixture experiments.

It will **not** establish that Chemical Sound distinguishes Water from Oil, identifies liquids, estimates concentration, or demonstrates the proposed liquid-dependent acoustic phenomenon.

The governing progression remains:

`Software validity -> instrument validity -> signal-path validity -> phenomenon validity -> classification validity`

> **Checkpoint frozen. Next evidence must come from the physical instrument.**
