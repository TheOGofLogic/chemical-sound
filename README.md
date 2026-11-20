# Liquid Analyzer — Airborne `MODE_A` Screening Baseline (`v0.4.1` Build `14`) & Phase 1 Reference Pipeline

> **Project Description:** **Liquid Analyzer** is an experimental acoustic response measurement and reference-comparison platform for controlled laboratory research. Using a baseline mobile device's built-in speaker and microphone together with a standardized sample vessel and mechanical coupling fixture, the system emits calibrated acoustic test signals (`400 Hz–14 kHz` exponential sine sweeps and stepped tone bursts), captures the coupled container-liquid vibro-acoustic response at `48 kHz`, and exports quality-controlled, checksum-verified measurement bundles for offline digital signal processing. Offline analysis extracts compact resonance and decay features and evaluates whether observed responses match previously characterized reference liquids within tested operating bounds, returning one of three states: `REFERENCE_MATCH`, `NO_VALIDATED_MATCH`, or `INVALID_MEASUREMENT`. Liquid Analyzer is an empirical signal-classification research instrument; it does not determine molecular composition, purity, potability, toxicity, or safety, and is not a substitute for laboratory analytical testing.

## Ratified Phase R2 Baseline (`v0.4.1-build14-accepted`)

The repository's airborne **`MODE_A`** non-contact acoustic screening engine is formally ratified and frozen at tag **`v0.4.1-build14-accepted`** (Commit `6d067cf`, `39 / 39` Swift XCTests passing on pinned `xcode: "27.2"`):
- **Final Acceptance Report:** [`docs/reports/LA-R2-FINAL-ACCEPTANCE-REPORT.md`](docs/reports/LA-R2-FINAL-ACCEPTANCE-REPORT.md) (`R2_ACCEPTANCE_GRANTED`)
- **Supporting Empirical & Verification Records:**
  - [`docs/reports/LA-R2-SPEC-001.md`](docs/reports/LA-R2-SPEC-001.md) — Governing Phase R2 airborne `MODE_A` architecture & scope specification.
  - [`docs/reports/LA-R2-A-SANDBOX-REPORT-001.md`](docs/reports/LA-R2-A-SANDBOX-REPORT-001.md) — Offline sandbox verification across `140` raw Float32 WAVs (`48 kHz`), ratifying Chu-compensated narrowband Schroeder EDC (`0.00%` clamp saturation), $K_{\text{cond}} = 2$ conditioning purge, $\ge 900\text{ ms}$ inter-sweep settle, and late pre-roll noise isolation.
  - [`docs/reports/LA-R2-B-FIELD-AUDIT-001.md`](docs/reports/LA-R2-B-FIELD-AUDIT-001.md) — Live iPhone Duo field audit of `v0.4.0` (Build `13`, `140` scans across `7` stationary cohorts).
  - [`docs/reports/LA-R2-C-PLAN-001.md`](docs/reports/LA-R2-C-PLAN-001.md) & [`docs/reports/LA-R2-C-VERIFICATION-REPORT-001.md`](docs/reports/LA-R2-C-VERIFICATION-REPORT-001.md) — Implementation and `63`-scan live iPhone Duo verification of `v0.4.1` (Build `14`), confirming `20×` (`Sweeps 3–20`) steady-state baseline calibration, the dual-condition differential bubble gate ($\Delta S_{\text{HF}} \ge +2.50\text{ dB}$ AND `preRollExcessHFDB > 0.0`, `0.00%` false triggers), log-ratio diagnostic decay normalization, and live camera frame integrity.
- **Airborne `MODE_A` Scope Boundary:** Strictly restricted to physically verifiable airborne phenomena (`EMPTY_CONTAINER`, `LIQUID_LOADED`, `BUBBLE_SCATTER_DETECTED`, `NONSTANDARD_SURFACE_RESPONSE`, and calibrated $\Delta \vec{F}/\vec{F}_{\text{empty}}$ & $\Delta \vec{F}/\vec{F}_{\text{water}}$ modal shift vectors with explicit `NaN` missing-mode masks). All ungrounded airborne viscosity claims remain removed; bulk acoustic impedance and shear-viscosity discrimination through the container wall are isolated for **Phase R3 (`MODE_B` Direct Structural Coupling — [`docs/reports/LA-R3-SPEC-001.md`](docs/reports/LA-R3-SPEC-001.md))**.

Controlled implementation across **Phase 1 (`CS-SPEC-P1-v1.2`)** and **Phase R2 (`v0.4.1` Build `14`)**, covering:
- **Milestone 1:** Frozen v1.2 Specification & Milestone 4 Stop/Go Gate Report (`docs/`).
- **Milestone 2:** Authoritative offline Python DSP, quality-control, and open-set evaluation reference pipeline (`src/liquid_analyzer/`).
- **Milestone 3A & Phase R2 (`MODE_A`):** Swift Acquisition iOS Instrument + Two-Layer Consumer Experience (`LiquidAnalyzer/`, `Assets/`, `LiquidAnalyzerTests/`, `v0.4.1` / Build `14`):
  - **Layer 1 (Consumer Interface):** `Scan | History | Learn | More` navigation implementing **AIM → SCAN → RESULT → LISTEN (Chemical Tune)** plus calibrated `20×` (`Sweeps 3–20`) steady-state baseline capture (`EMPTY_CONTAINER`, `WATER_REFERENCE`, `SOLID_SURFACE`).
  - **Layer 2 (Research Engine):** Deterministic 22-state acquisition machine, SHA-256 stimulus verification, `48 kHz` `.measurement` capture, Chu-compensated Schroeder EDC & 4-mode sub-bin extraction, signal QC, and a protected **Research & Developer Mode** console inside **More**.
- **First Classification Milestone (Milestone 4 / Gate 0B):** Preregistered two-liquid fresh-fill feasibility evaluation (`H2O_DIST` vs. `OIL_VEG`) across `>= 4` independent preparations/class, `>= 2` sessions, and unseen holdout containers, gated by M3B instrument validation and Gate 0A 5-state signal-path isolation.

---

## Repository Structure

```text
liquid-analyzer/
├── docs/
│   ├── reports/
│   │   ├── LA-R2-SPEC-001.md            # Governing Phase R2 MODE_A architecture specification
│   │   ├── LA-R2-A-SANDBOX-REPORT-001.md # Phase R2-A 140-WAV offline DSP estimator audit report
│   │   ├── LA-R2-B-FIELD-AUDIT-001.md   # Live 140-scan iPhone Duo field audit of v0.4.0 Build 13
│   │   ├── LA-R2-C-PLAN-001.md          # Phase R2-C calibration & field edge-case remediation plan
│   │   ├── LA-R2-C-VERIFICATION-REPORT-001.md # Live 63-scan iPhone Duo verification of v0.4.1 Build 14
│   │   ├── LA-R2-FINAL-ACCEPTANCE-REPORT.md # Ratified Phase R2 Acceptance Report (v0.4.1-build14-accepted)
│   │   └── LA-R3-SPEC-001.md            # Draft Phase R3 MODE_B wall-coupled transducer specification
│   ├── CS-SPEC-P1-v1.2.md               # Frozen Phase 1 v1.2 Master Specification
│   ├── CS-SOP-M3B-P1-v1.1.md            # Controlled Milestone 3B Bench SOP & Gate 0B Thresholds (v1.1)
│   ├── CS-CHK-M3B-P1-v1.0.md            # Milestone 3B Physical-Run Checklist (Sections A-O)
│   ├── CS-OPS-M3B-P1-v1.0.md            # M3B Real-Device Operator SOP (Steps 1-10 & Stop Rule)
│   ├── CS-ACC-M3B-P1-v1.0.md            # M3B Real-Device Bundle Acceptance Criteria (Sections A-G)
│   ├── CS-EXEC-M3B-P1-v1.0.md           # M3B Physical-Run Execution Checklist (Steps 1-13)
│   ├── CS-FREEZE-M3B-P1-v1.0.md         # Milestone 3B Pre-Bench Freeze Note & Refreshed Digests
│   ├── CS-SOP-M3B-P1-v1.0.md            # Archived Milestone 3B Bench SOP (v1.0)
│   ├── CS-MFR-P1-v1.2-001.md            # Milestone 4 Gate 0A/0B Feasibility Report (Decisions A-D)
│   └── AcquisitionStateMachine.md       # Reconciled 22-state acquisition machine & timing invariants
├── Assets/                              # Unpadded active Float32 WAVs + SHA-256 manifest for Swift
│   ├── waveform_manifest.json
│   ├── SIG_ESS_v1.wav                   # 200 ms active ESS (400 Hz -> 14 kHz, -6 dBFS)
│   ├── SIG_ESS_v1_inverse.wav           # 200 ms matched inverse filter
│   ├── SIG_STEP_v1.wav                  # 1000 ms stepped tones (10 x [60 ms tone + 40 ms silent gap])
│   └── SIG_SIL_v1.wav                   # 200 ms digital-zero silence control
├── LiquidAnalyzer/                      # Two-Layer iOS Application (v0.4.1 / Build 14, MODE_A Frozen)
│   ├── App/                             # LiquidAnalyzerApp, AppCoordinator (scenePhase monitor)
│   ├── Consumer/                        # Layer 1: Calibrated MODE_A Screening, Schroeder EDC & 4-tab UI
│   ├── Domain/                          # Layer 2: 22 states, events, failures, flags, ScanRecord parity
│   ├── StateMachine/                    # TransitionRule, AcquisitionStateMachine, TransitionAuditRecord
│   ├── Waveforms/                       # CryptoKit SHA256Verifier, WaveformRepository
│   ├── Audio/                           # AudioSessionController, WarmBatchAudioEngine, RecordingController
│   ├── Acquisition/                     # AcquisitionCoordinator, TimingController, RepetitionManager
│   ├── Calibration/                     # CalibrationManager (SESSION_OPEN -> SESSION_VALID / DRIFT)
│   ├── QualityControl/                  # QualityControlEngine, ImmediateAudioAnalyzer, MetadataValidator
│   ├── Persistence/                     # Atomic AcquisitionStore, AuditLogger, SHA-256 ExportManager
│   └── UI/                              # Protected Research / Developer Mode Bench Views
├── LiquidAnalyzerTests/                 # Swift XCTest suite (39 tests: R2-B/R2-C DSP, State, QC, Export)
├── codemagic.yaml                       # Pinned CI workflow (xcode: "27.2", zero floating tags)
├── Package.swift                        # Swift Package manifest (LiquidAnalyzer — iOS 17+ / macOS 14+)
├── project.yml                          # XcodeGen iOS App specification (org.chemicalsound.acquisition)
├── reference_waveforms/                 # Framed 500 ms / 1300 ms Python reference bundle
├── src/liquid_analyzer/                 # Authoritative Python DSP, QC, & Nested LOBO-CV pipeline
└── tests/test_pipeline.py               # Python verification & Swift-Python schema parity suite
```

---

## Running Verification Suites

### 1. Python Reference & Swift-Schema Parity Suite
```powershell
.\.venv\Scripts\python.exe -B tests\test_pipeline.py -v
```

### 2. Building on macOS / Xcode or Codemagic (`v0.4.1` Build `14`, Pinned `Xcode 27.2`)
1. Open the project on macOS (`Package.swift` for `swift test`, or generate `LiquidAnalyzer.xcodeproj` via `xcodegen generate` for iOS `v0.4.1` Build `14`).
2. Run the `39 / 39` XCTest verification gate on macOS or iOS Simulator:
   ```bash
   swift test
   ```
3. Deploy **Liquid Analyzer** (`v0.4.1` Build `14`) via TestFlight to the physical baseline iPhone (case removed, external audio disconnected), set hardware volume to `0.65 ± 0.01`, inspect the **Milestone 3B Requested vs. Verified Runtime Profile** in the **Setup & Audio** tab, run **Calibration** + bare-phone free-air sweeps, and AirDrop the exported `CSRD_P1_<sessionID>` bundle back to Python:
   ```powershell
   # Milestone 3B Automated Bundle Audit (Tests 3B-01 through 3B-10 -> JSON + Markdown audit)
   .\.venv\Scripts\python.exe -m liquid_analyzer.cli m3b audit-bundle --bundle-dir path\to\CSRD_P1_SESS_001 --output-dir reports\m3b

   # Milestone 3B Audio Characterization Summaries (Silence, ESS, timing, hum & occlusion -> Metrics + plots manifest)
   .\.venv\Scripts\python.exe -m liquid_analyzer.cli m3b summarize-audio --bundle-dir path\to\CSRD_P1_SESS_001 --output-dir reports\m3b

   # Or execute CS-OPS-M3B-P1-v1.0 Step 10 (audit + summarize + verify CS-ACC-M3B-P1-v1.0 artifact completeness) in one step
   .\.venv\Scripts\python.exe -m liquid_analyzer.cli m3b run-all --bundle-dir path\to\CSRD_P1_SESS_001 --output-dir reports\m3b

   # Gate 0B Pre-Scoring Study Design Validation (COMPLETE / GATE_INCOMPLETE before labels are scored)
   .\.venv\Scripts\python.exe -m liquid_analyzer.cli gate0b validate-design --dataset-dir path\to\CSRD_P1_GATE0B --output-dir reports\gate0b

   # Gate 0B Frozen Grouped Evaluation & Nuisance Controls (Metrics + threshold matrix)
   .\.venv\Scripts\python.exe -m liquid_analyzer.cli gate0b evaluate --dataset-dir path\to\CSRD_P1_GATE0B --output-dir reports\gate0b

   # Gate 0B Pre-Registered Stop/Go Decision Engine (Decisions A-D / GATE_INCOMPLETE + reasons)
   .\.venv\Scripts\python.exe -m liquid_analyzer.cli gate0b decide --dataset-dir path\to\CSRD_P1_GATE0B --output-dir reports\gate0b

   # Inspect an individual deconvolved ESS recording
   .\.venv\Scripts\python.exe -m liquid_analyzer.cli inspect-recording --recording path\to\scan.wav
   ```

---

## Scientific Governance & Phase R2 Milestones

Liquid Analyzer adheres to strict physical boundary isolation and reproducibility standards.

### Ratified Phase R2 Documentation (Build 12 → Build 14)
* **Governing Specification:** [`LA-R2-SPEC-001`](docs/reports/LA-R2-SPEC-001.md)
* **Offline Verification & Estimator Selection:** [`LA-R2-A-SANDBOX-REPORT-001`](docs/reports/LA-R2-A-SANDBOX-REPORT-001.md)
* **Field Audit (Build 13 Evaluation):** [`LA-R2-B-FIELD-AUDIT-001`](docs/reports/LA-R2-B-FIELD-AUDIT-001.md)
* **Build 14 Remediation Plan:** [`LA-R2-C-PLAN-001`](docs/reports/LA-R2-C-PLAN-001.md)
* **On-Device Hardware Verification:** [`LA-R2-C-VERIFICATION-REPORT-001`](docs/reports/LA-R2-C-VERIFICATION-REPORT-001.md)
* **Final Acceptance & Release Record:** [`LA-R2-FINAL-ACCEPTANCE-REPORT`](docs/reports/LA-R2-FINAL-ACCEPTANCE-REPORT.md)
* **Phase R3 Contact Architecture (Draft):** [`LA-R3-SPEC-001`](docs/reports/LA-R3-SPEC-001.md)

### Release Provenance
* **Accepted Release Tag:** [`v0.4.1-build14-accepted`](https://github.com/TheOGofLogic/chemical-sound/releases/tag/v0.4.1-build14-accepted)
* **Head Commit:** `6d067cff97ef1641cce3772e72da0cd14ad593ca`
* **Pinned Toolchain:** Xcode 27.2 (`Build 27B52`), macOS 27.2 (`26B123`), Apple Swift 6.4.2
* **Operational Scope:** `MODE_A` is strictly bounded to physical acoustic screening (`EMPTY_CONTAINER`, `LIQUID_LOADED`, `BUBBLE_SCATTER_DETECTED`, `NONSTANDARD_SURFACE_RESPONSE`, and calibrated differential shift vectors $\Delta \vec{F}/\vec{F}_{\text{empty}}$ / $\Delta \vec{F}/\vec{F}_{\text{water}}$). All contact/guided-wave operations are deferred to Phase R3 `MODE_B`.
