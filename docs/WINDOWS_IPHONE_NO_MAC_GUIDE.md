# Liquid Analyzer — Windows PC + iPhone (No-Mac) M3B Execution Guide

Because Apple's `AVFAudio` / `SwiftUI` SDK only compiles on macOS, this repository includes a preconfigured **GitHub Actions `macos-14` cloud Mac workflow** (`.github/workflows/macos-swift-test.yml`) plus `project.yml` so you can run `swift test` **and** build an installable iPhone `.ipa` directly from your **Windows PC** without owning a Mac.

---

## Step 1 — Run `swift test` & Build `LiquidAnalyzer_M3B_v1.0.ipa` on GitHub's Cloud Mac

1. Create a new empty repository on GitHub (for example `chemical-sound`, Private or Public—note that GitHub gives unlimited free `macos-14` minutes on Public repos and free monthly minutes on Private repos).
2. Push this local repository (`C:\Users\acath\.gemini\antigravity\scratch\chemical-sound`) to GitHub:
   ```powershell
   cd C:\Users\acath\.gemini\antigravity\scratch\chemical-sound
   git remote add origin https://github.com/<YOUR_GITHUB_USERNAME>/chemical-sound.git
   git push -u origin main
   ```
3. On GitHub, open the **Actions** tab → click **`macOS Swift XCTest & Unsigned iOS IPA Build`**.
4. When it turns green (~2–3 minutes), scroll down to **Artifacts** and download **`LiquidAnalyzer-M3B-macOS-Evidence-and-IPA.zip`**, which contains:
   - `LiquidAnalyzer_M3B_Mac_Handoff_v1.0.sha256.txt` *(exact `shasum -a 256` output)*
   - `swift_test_output.txt` *(complete macOS `swift test` log for Copilot review)*
   - `LiquidAnalyzer_M3B_v1.0.ipa` *(native iOS 17+ `IPHONE_NATIVE` app bundle)*
   - `LiquidAnalyzer_M3B_v1.0.ipa.sha256.txt`

---

## Step 2 — Install `LiquidAnalyzer_M3B_v1.0.ipa` onto Your iPhone from Windows

1. On Windows, ensure **iTunes** (non-Microsoft-Store desktop build) & **iCloud** are installed, and install **Sideloadly** (`https://sideloadly.io`).
2. Connect your designated baseline iPhone to this Windows PC via USB and tap **Trust This Computer** on the iPhone.
3. Open **Sideloadly**:
   - Drag **`LiquidAnalyzer_M3B_v1.0.ipa`** into Sideloadly.
   - Enter your Apple ID (free Apple ID works—Sideloadly signs the `.ipa` locally using Apple's free 7-day personal developer provisioning).
   - Click **Start**.
4. On your iPhone:
   - Open **Settings > General > VPN & Device Management** → tap your Apple ID under *Developer App* → tap **Trust**.
   - If iOS 17+ prompts for **Developer Mode**, enable **Settings > Privacy & Security > Developer Mode** and restart once.

---

## Step 3 — Run Physical Session `CSRD_P1_SESS_001` on Your iPhone

1. **Unplug the USB cable** from the iPhone, **remove the phone case**, and confirm **no Bluetooth/wired audio accessories** are connected (`CS-OPS-M3B-P1-v1.0` Preconditions).
2. Open **Liquid Analyzer** on the iPhone and grant Microphone permission.
3. Execute the controlled bare-phone run (`CS-EXEC-M3B-P1-v1.0`):
   - **Setup & Audio (`3B-02`):** Set `Session ID = SESS_001`, set hardware volume to `0.65 ± 0.01`, tap **Activate & Verify Audio Session**.
   - **Silence (`3B-03`):** Record **≥ 2** valid `SIG_SIL_v1` scans (`M3B_SIL`).
   - **Free-Air ESS (`3B-04`):** Record **≥ 5** valid unclipped `SIG_ESS_v1` repetitions (`M3B_FREE_AIR`).
   - **Port Occlusion (`3B-05`):** Set Sample ID to `M3B_OCCLUDED_BOTTOM` and record **≥ 1** occluded `SIG_ESS_v1` scan.
   - **Failure & Recovery (`3B-07`–`3B-09`):** Trigger **1** rejected/aborted scan (e.g., nudge volume outside `±0.01` or tap **Abort**), restore volume, wait `≥ 2.0 s` cooldown, and record **1** valid post-recovery `SIG_ESS_v1` scan.
4. Open the **Export** tab → tap **Build & SHA-256-Verify Export Bundle** → tap **Share / AirDrop CSRD-P1 Bundle** → **Save to Files > OneDrive > LiquidAnalyzer**.

---

## Step 4 — Generate the Four Controlled M3B Review Files on Windows

Once `CSRD_P1_SESS_001` syncs into `C:\Users\acath\OneDrive\LiquidAnalyzer\CSRD_P1_SESS_001`, run:

```powershell
C:\Users\acath\.gemini\antigravity\scratch\chemical-sound\.venv\Scripts\python.exe -m liquid_analyzer.cli m3b run-all --bundle-dir C:\Users\acath\OneDrive\LiquidAnalyzer\CSRD_P1_SESS_001 --output-dir C:\Users\acath\OneDrive\LiquidAnalyzer\reports\CSRD_P1_SESS_001
```

Then attach `swift_test_output.txt` plus the four generated files in `OneDrive\LiquidAnalyzer\reports\CSRD_P1_SESS_001\` for formal M3B disposition review:
- `m3b_audit_report.json`
- `m3b_checklist.md`
- `m3b_audio_metrics.json`
- `m3b_plots_manifest.json`
