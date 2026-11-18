# Liquid Analyzer — Reconciled 22-State Acquisition Machine (`CS-SPEC-P1-v1.2`)

This document specifies the deterministic acquisition state machine implemented in `LiquidAnalyzer/StateMachine/` for Milestone 3A.

---

## 1. The 22 Canonical States

| # | State | Active Capture? | Responsibility |
| :- | :--- | :--- | :--- |
| 1 | `unconfigured` | No | Initial boot state prior to protocol, asset SHA-256, and `AVAudioSession` verification. |
| 2 | `configuring` | No | Verifying `waveform_manifest.json` SHA-256 digests, mic permission, and runtime audio session. |
| 3 | `configurationFailed` | No | Blocking asset, permission, route, or sample-rate negotiation failure. |
| 4 | `readyForCalibration` | No | Audio/assets verified; awaiting mandatory session calibration (`CAL_START`). |
| 5 | `calibrating` | No* | Acquiring silence, fixture-only, empty-container, or distilled-water baseline scans. |
| 6 | `calibrationPassed` | No | Required calibration scans provisionally passed immediate QC. |
| 7 | `calibrationFailed` | No | One or more required calibration scans failed QC; blocks sample acquisition. |
| 8 | `readyForSample` | No | Calibration acknowledged; ready to accept sample & adjustable-fixture metadata. |
| 9 | `settling` | No | Enforcing mandatory 180-second post-fill stationary microbubble settling countdown. |
| 10 | `armed` | No | Metadata, calibration, route, `48 kHz` rate, and pre-scan `outputVolume` verified. |
| 11 | `recordingPreRoll` | **Yes** | Input tap writing lossless Float32 PCM (`150 ms` pre-excitation ambient window). |
| 12 | `playingExcitation` | **Yes** | Verified active waveform (`SIG_ESS_v1` / `SIG_STEP_v1` / `SIG_SIL_v1`) playing while capture continues. |
| 13 | `recordingPostRoll` | **Yes** | Excitation complete (`t_exc_end` logged); capturing modal ring-down tail (`150 ms`). |
| 14 | `coolingDown` | No | Recording closed; enforcing thermal/mechanical cooldown (`t >= t_exc_end + 2.0 s`). |
| 15 | `evaluatingQC` | No | Computing immediate signal, clipping, noise-floor, duration, and post-scan volume QC. |
| 16 | `repetitionAccepted` | No | Repetition recorded as `PROVISIONALLY_ACCEPTED` in `scans.jsonl`. |
| 17 | `repetitionRejected` | No | Repetition preserved in `scans.jsonl` (`REJECTED`) with flags, excluded from valid count. |
| 18 | `batchComplete` | No | Required accepted repetitions (`5`) obtained for current physical sample. |
| 19 | `saving` | No | Committing session manifests, checksums, and audit logs atomically. |
| 20 | `exportReady` | No | Verified Python-compatible `CSRD-P1` bundle ready for export. |
| 21 | `interrupted` | No | Route change, OS audio interruption, or app backgrounding aborted active capture. |
| 22 | `fatalError` | No | Unrecoverable storage, checksum, or persistence integrity failure. |

---

## 2. Timing & Validity Invariants

1. **Inter-Excitation Cooldown Invariant:**  
   `TimingController` records `lastExcitationEndUptime` at `excitationCompleted`. Even after `coolingDown -> evaluatingQC -> repetitionAccepted -> armed`, the next repetition cannot enter `playingExcitation` before `lastExcitationEndUptime + cooldownSeconds` (`2.0 s` provisional).
2. **Two-Stage Session Calibration Promotion:**  
   Every scan reaching `repetitionAccepted` is persisted with `quality_status = "PROVISIONALLY_ACCEPTED"`. Only after end-of-session calibration (`CAL_END`) completes within drift limits does `session_validity_state` become `SESSION_VALID` (`final_scan_validity = "FINAL_ACCEPTED"`).
3. **Zero Silent Recovery During Active Capture:**  
   Any `routeChanged`, `audioInterrupted`, or `appBackgrounded` event while `state.isActivelyAcquiring == true` immediately stops `AVAudioEngine`, marks any partial capture `INTERRUPTED`, transitions to `interrupted`, and requires explicit re-verification through `configuring`.
