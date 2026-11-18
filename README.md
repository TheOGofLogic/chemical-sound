# Liquid Analyzer — Phase 1 (v1.2) Reference Pipeline & Minimal Swift Acquisition Instrument

> **Project Description:** **Liquid Analyzer** is an experimental acoustic response measurement and reference-comparison platform for controlled laboratory research. Using a baseline mobile device's built-in speaker and microphone together with a standardized sample vessel and mechanical coupling fixture, the system emits calibrated acoustic test signals (`400 Hz–14 kHz` exponential sine sweeps and stepped tone bursts), captures the coupled container-liquid vibro-acoustic response at `48 kHz`, and exports quality-controlled, checksum-verified measurement bundles for offline digital signal processing. Offline analysis extracts compact resonance and decay features and evaluates whether observed responses match previously characterized reference liquids within tested operating bounds, returning one of three states: `REFERENCE_MATCH`, `NO_VALIDATED_MATCH`, or `INVALID_MEASUREMENT`. Liquid Analyzer is an empirical signal-classification research instrument; it does not determine molecular composition, purity, potability, toxicity, or safety, and is not a substitute for laboratory analytical testing.

Controlled implementation of **Liquid Analyzer Phase 1 v1.2 (`CS-SPEC-P1-v1.2`)**, covering:
- **Milestone 1:** Frozen v1.2 Specification & Milestone 4 Stop/Go Gate Report (`docs/`).
- **Milestone 2:** Authoritative offline Python DSP, quality-control, and open-set evaluation reference pipeline (`src/liquid_analyzer/`).
- **Milestone 3A:** Minimal Swift Acquisition iOS Instrument + Two-Layer Consumer Experience (`LiquidAnalyzer/`, `Assets/`, `LiquidAnalyzerTests/`, v0.3.0 / Build `5`):
  - **Layer 1 (Consumer Interface):** `Scan | History | Learn | More` navigation implementing **AIM → SCAN → RESULT → LISTEN (Chemical Tune)** with zero exposed laboratory jargon.
  - **Layer 2 (Research Engine):** Deterministic 22-state acquisition machine, SHA-256 stimulus verification, `48 kHz` `.measurement` capture, signal QC, experimental reference matching, and a protected **Research & Developer Mode** console inside **More** so Milestone 3B bench characterization and Milestone 3C `Mode B` fixture experiments remain intact.
- **First Classification Milestone (Milestone 4 / Gate 0B):** Preregistered two-liquid fresh-fill feasibility evaluation (`H2O_DIST` vs. `OIL_VEG`) across `>= 4` independent preparations/class, `>= 2` sessions, and unseen holdout containers, gated by M3B instrument validation and Gate 0A 5-state signal-path isolation.

---

## Repository Structure

```text
chemical-sound/
├── docs/
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
├── LiquidAnalyzer/                      # Two-Layer iOS Application (v0.3.0 / Build 5)
│   ├── App/                             # LiquidAnalyzerApp, AppCoordinator (scenePhase monitor)
│   ├── Consumer/                        # Layer 1: AIM -> SCAN -> RESULT -> LISTEN (Chemical Tune) + 4-tab UI
│   ├── Domain/                          # Layer 2: 22 states, events, failures, flags, ScanRecord parity
│   ├── StateMachine/                    # TransitionRule, AcquisitionStateMachine, TransitionAuditRecord
│   ├── Waveforms/                       # CryptoKit SHA256Verifier, WaveformRepository
│   ├── Audio/                           # AudioSessionController, RouteValidator, Lock-safe RecordingController
│   ├── Acquisition/                     # AcquisitionCoordinator, TimingController, RepetitionManager
│   ├── Calibration/                     # CalibrationManager (SESSION_OPEN -> SESSION_VALID / DRIFT)
│   ├── QualityControl/                  # QualityControlEngine, ImmediateAudioAnalyzer, MetadataValidator
│   ├── Persistence/                     # Atomic AcquisitionStore, AuditLogger, SHA-256 ExportManager
│   └── UI/                              # Protected Research / Developer Mode Bench Views
├── LiquidAnalyzerTests/                 # Swift XCTest suite (Consumer, Tune, State, SHA-256, Route, QC, Export)
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

### 2. Building on macOS / Xcode or Codemagic for Milestone 3B Bench Characterization
1. Open the project on macOS (`Package.swift` for `swift test`, or generate `LiquidAnalyzer.xcodeproj` via `xcodegen generate` for iOS Build `4`).
2. Run XCTests on macOS or iOS Simulator:
   ```bash
   swift test
   ```
3. Deploy **Liquid Analyzer** (Build `4`) via TestFlight to the physical baseline iPhone (case removed, external audio disconnected), set hardware volume to `0.65 ± 0.01`, inspect the **Milestone 3B Requested vs. Verified Runtime Profile** in the **Setup & Audio** tab, run **Calibration** + bare-phone free-air sweeps, and AirDrop the exported `CSRD_P1_<sessionID>` bundle back to Python:
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
