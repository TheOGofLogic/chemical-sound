# Liquid Analyzer — Mac / Xcode Milestone 3B Handoff Guide

- **Archive Purpose:** Transfer frozen Milestone 3A/3B Swift iOS acquisition code, verified `48 kHz` Float32 waveform assets, unit tests, and controlled M3B bench SOPs to macOS for real-device `CSRD_P1_SESS_001` execution.
- **Governing Freeze Checkpoint:** `CS-FREEZE-M3B-P1-v1.0` (`chemical-sound==0.1.2` / `src-f4f936ab4542`)

---

## 1. Verify Archive Integrity & Run `swift test` on macOS

Unzip `LiquidAnalyzer_M3B_Mac_Handoff_v1.0.zip` on your Mac, open Terminal in the unzipped folder, and run:

```bash
swift test
```

Confirm all five XCTest suites (`StateMachineTests`, `ManifestVerificationTests`, `RouteValidationTests`, `QualityControlTests`, `ExportBundleTests`) pass before deploying to your iPhone.

---

## 2. Build & Install on Your Designated Baseline iPhone in Xcode

1. Open **Xcode** → **File > New > Project…** → **iOS > App** (`Product Name: LiquidAnalyzer`, `Interface: SwiftUI`, `Language: Swift`).
2. Delete Xcode's auto-generated `ContentView.swift` and `LiquidAnalyzerApp.swift` (our `LiquidAnalyzer/App/LiquidAnalyzerApp.swift` already provides `@main`).
3. Drag the **`LiquidAnalyzer`** folder (excluding `Info.plist`) and the **`Assets`** folder (`SIG_ESS_v1.wav`, `SIG_ESS_v1_inverse.wav`, `SIG_STEP_v1.wav`, `SIG_SIL_v1.wav`, `waveform_manifest.json`) into the `LiquidAnalyzer` app target (**Copy items if needed** checked; either folder reference or group works—`WaveformRepository` supports both).
4. In the Target **Info** tab, add Privacy key:
   - `NSMicrophoneUsageDescription` (`Privacy - Microphone Usage Description`):
     `"Liquid Analyzer requires microphone access to record acoustic impulse responses for controlled research feasibility testing."`
5. In **Signing & Capabilities**, select your Apple Developer / Personal Team, connect your designated baseline iPhone, and click **Run (`⌘R`)**.
6. Once installed on the iPhone, **unplug the USB/charging cable**, **remove the phone case**, and confirm **no Bluetooth/wired audio accessories** are connected (`CS-OPS-M3B-P1-v1.0` Preconditions).

---

## 3. Execute Physical Session `CSRD_P1_SESS_001` on the iPhone

Follow `Docs/CS-EXEC-M3B-P1-v1.0.md`:

1. **Setup & Audio Tab (`3B-02`):**
   - Set **Session ID** = `SESS_001`, fill Operator / Room / iPhone fields, set hardware volume to target (`0.65 ± 0.01`), and tap **Activate & Verify Audio Session**.
   - Confirm `48,000 Hz`, `.measurement` mode, `1` input channel, and built-in mic/speaker route (stereo-locked output is logged and nonfatal).
2. **Silence Series (`3B-03`):**
   - Record **at least 2** valid bare-phone `SIG_SIL_v1` captures (`M3B_SIL`, rep 1 & rep 2).
3. **Free-Air ESS Series (`3B-04`):**
   - Record **at least 5** valid unclipped bare-phone `SIG_ESS_v1` repetitions (`M3B_FREE_AIR`, reps 1–5), respecting the automatic `≥ 2.0 s` cooldown timer.
4. **Paired Port-Occlusion Probe (`3B-05`):**
   - Set Sample ID to `M3B_OCCLUDED_BOTTOM` (or include `OCCLUDED` in Operator Notes), gently occlude the target port without moving the phone, and record **at least 1** `SIG_ESS_v1` scan.
5. **Recoverable Failure + Recovery Scan (`3B-07` / `3B-08` / `3B-09`):**
   - Exercise **1** recoverable failure (e.g., nudge hardware volume outside `±0.01` or tap **Abort** during a test scan so a rejected/aborted record is retained with its reason flag).
   - Restore nominal hardware volume, wait for the `≥ 2.0 s` cooldown, and record **1** valid post-recovery `SIG_ESS_v1` scan.
6. **Export (`3B-01` / `3B-10`):**
   - Open the **Export** tab → tap **Export Session Bundle** → AirDrop or save the exported `CSRD_P1_SESS_001` folder (`scans.jsonl`, `transitions.jsonl`, `.wav` files, and `waveform_manifest.json`) back to the Windows machine.

---

## 4. Generate the Four Controlled M3B Review Artifacts on Windows

Once `CSRD_P1_SESS_001` is copied back to Windows, run:

```powershell
C:\Users\acath\.gemini\antigravity\scratch\chemical-sound\.venv\Scripts\python.exe -m liquid_analyzer.cli m3b run-all --bundle-dir path\to\CSRD_P1_SESS_001 --output-dir C:\Users\acath\.gemini\antigravity\scratch\chemical-sound\reports\CSRD_P1_SESS_001
```

Attach the four generated files from `reports\CSRD_P1_SESS_001\` for formal M3B disposition review:
1. `m3b_audit_report.json`
2. `m3b_checklist.md`
3. `m3b_audio_metrics.json`
4. `m3b_plots_manifest.json`
