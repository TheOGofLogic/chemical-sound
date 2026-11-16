"""Automated Milestone 3B Bare-Phone Bench Audio Characterization Auditor.

Operationalizes:
- Parent SOP: `CS-SOP-M3B-P1-v1.1` (Appendix A.1 & A.3)
- Physical-Run Checklist: `CS-CHK-M3B-P1-v1.0` (Sections A through O)
- Real-Device Operator SOP: `CS-OPS-M3B-P1-v1.0` (Steps 1 through 10 & Stop Rule)
- Bundle Acceptance Criteria: `CS-ACC-M3B-P1-v1.0` (Sections A through G)

Automated checks across Tests 3B-01 through 3B-10:
- 3B-01: 81-field ScanRecord parity, explicit JSON nulls, unique IDs, WAV existence, timestamp order, SHA-256
- 3B-02: Requested vs. realized runtime audio state (stereo-locked output nonfatal; route change invalidates scan)
- 3B-03: Repeated SIG_SIL_v1 noise floor (N >= 2), RMS/peak, clipping, narrowband hum candidates (never liquid inference)
- 3B-04: Free-air SIG_ESS_v1 characterization (N >= 5 valid reps, arrival, ring-down ms, repeatability SD; no synthetic cutoff)
- 3B-05: Paired port-occlusion probe with preserved IDs (`DOMINANT_PATH_SUPPORTED` vs `PATH INDETERMINATE`)
- 3B-06: WAV rate, mono channel, frame count vs. scheduled duration & host timestamps, transition log order
- 3B-07: Pre/post outputVolume stability (+-0.01 scalar tolerance) & rejection enforcement
- 3B-08: Inter-excitation cooldown invariant (next t_exc_start >= prev t_exc_end + 2.0 s) across accepted, rejected, and aborted scans
- 3B-09: Recoverable failure exercise (no partial promotion, retained rejection reason, legal subsequent recovery)
- 3B-10: Final bundle integrity (attempted/accepted/rejected/aborted counts, zero orphans/missing WAVs/duplicates/malformed/hash/loss)
"""

from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import asdict, fields
import json
from pathlib import Path
from typing import Any

import numpy as np

from . import SOP_M3B_VERSION
from .dsp import DSPConfig, aggregate_sample_repetitions, extract_scan_features
from .ingestion_alignment import ingest_audio_file
from .reporting import (
    compute_canonical_json_sha256,
    compute_dataset_manifest_digest,
    compute_software_build_identity,
)
from .schema_qc import QCThresholds, ScanRecord, read_scans_jsonl
from .waveforms import ESSConfig, generate_ess_pair, linear_to_dbfs, read_wav_float32, sha256_file


CHECKLIST_M3B_ID = "CS-CHK-M3B-P1-v1.0"
OPERATOR_SOP_M3B_ID = "CS-OPS-M3B-P1-v1.0"
ACCEPTANCE_M3B_ID = "CS-ACC-M3B-P1-v1.0"

EXPECTED_SCAN_RECORD_FIELDS: frozenset[str] = frozenset(f.name for f in fields(ScanRecord))
ACCEPTED_STATUSES = frozenset({"PROVISIONALLY_ACCEPTED", "FINAL_ACCEPTED", "PASS"})
ABORTED_STATUSES = frozenset({"INTERRUPTED", "ABORTED"})
ROUTE_OR_INTERRUPT_FLAGS = frozenset(
    {
        "AUDIO_ROUTE_INVALID",
        "INTERRUPTED_AUDIO",
        "AUDIO_ROUTE_CHANGED",
        "AUDIO_INTERRUPTION",
        "MEDIA_SERVICES_RESET",
    }
)

M3B_SCOPE_STATEMENT = (
    "M3B validates the acquisition instrument only. It does not establish liquid discrimination, "
    "Water-vs-Oil separability, concentration, unknown identity, or phenomenon validity."
)


def detect_narrowband_interference(
    recording: np.ndarray,
    sample_rate_hz: int = 48_000,
    prominence_threshold_db: float = 12.0,
) -> list[dict[str, float]]:
    """Identify persistent narrowband tonal spikes (e.g. 50/60 Hz mains harmonics or coil whine).

    Per CS-SOP-M3B-P1-v1.1 Appendix A.1 and CS-OPS-M3B-P1-v1.0 Step 3, narrowband candidates
    characterize the instrument noise floor only and are never converted into a liquid inference.
    """
    x = np.asarray(recording, dtype=np.float64)
    if x.ndim > 1:
        x = x[:, 0]
    if x.size < 256:
        return []

    x = x - np.mean(x)
    n_fft = max(16_384, 1 << x.size.bit_length())
    win = np.hanning(x.size)
    spec = np.fft.rfft(x * win, n=n_fft)
    power_db = 20.0 * np.log10(np.abs(spec) / max(1.0, float(np.sum(win)) * 0.5) + 1e-15)
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / sample_rate_hz)

    valid_mask = (freqs >= 35.0) & (freqs <= 20_000.0)
    idxs = np.flatnonzero(valid_mask)
    if idxs.size < 60:
        return []

    sub_db = power_db[idxs]
    sub_f = freqs[idxs]
    half_win = 25
    tones: list[dict[str, float]] = []

    local_max = (
        np.flatnonzero((sub_db[1:-1] > sub_db[:-2]) & (sub_db[1:-1] >= sub_db[2:])) + 1
    )
    for p in local_max:
        lo = max(0, p - half_win)
        hi = min(sub_db.size, p + half_win + 1)
        floor_db = float(np.median(sub_db[lo:hi]))
        prom_db = float(sub_db[p]) - floor_db
        if prom_db >= prominence_threshold_db and float(sub_db[p]) > -110.0:
            tones.append(
                {
                    "frequency_hz": round(float(sub_f[p]), 2),
                    "level_dbfs": round(float(sub_db[p]), 2),
                    "excess_over_floor_db": round(prom_db, 2),
                }
            )

    tones.sort(key=lambda d: d["level_dbfs"], reverse=True)
    return tones[:10]


def _compute_log_spectrum_series(
    recording: np.ndarray,
    sample_rate_hz: int = 48_000,
    num_bins: int = 64,
) -> dict[str, list[float]]:
    """Compute a compact log-spaced power spectrum (35 Hz to 18 kHz) for plots_manifest."""
    x = np.asarray(recording, dtype=np.float64)
    if x.ndim > 1:
        x = x[:, 0]
    if x.size < 256:
        return {"frequencies_hz": [], "magnitude_dbfs": []}
    x = x - np.mean(x)
    n_fft = max(16_384, 1 << x.size.bit_length())
    win = np.hanning(x.size)
    spec = np.fft.rfft(x * win, n=n_fft)
    power_db = 20.0 * np.log10(np.abs(spec) / max(1.0, float(np.sum(win)) * 0.5) + 1e-15)
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / sample_rate_hz)

    edges = np.geomspace(35.0, 18_000.0, num_bins + 1)
    centers: list[float] = []
    levels: list[float] = []
    for i in range(num_bins):
        mask = (freqs >= edges[i]) & (freqs < edges[i + 1])
        if np.any(mask):
            centers.append(round(float(np.sqrt(edges[i] * edges[i + 1])), 2))
            levels.append(round(float(np.max(power_db[mask])), 3))
    return {"frequencies_hz": centers, "magnitude_dbfs": levels}


def _load_waveform_manifest_metadata(base: Path) -> tuple[dict[str, str], dict[str, int]]:
    wf_manifest_hashes: dict[str, str] = {}
    wf_manifest_durations_ms: dict[str, int] = {
        "SIG_ESS_v1": 200,
        "SIG_STEP_v1": 1000,
        "SIG_SIL_v1": 200,
    }
    for candidate_wf in (
        base / "reference_waveforms" / "waveform_manifest.json",
        base / "waveform_manifest.json",
    ):
        if candidate_wf.is_file():
            wf_json = json.loads(candidate_wf.read_text(encoding="utf-8"))
            if "assets" in wf_json:
                for item in wf_json["assets"]:
                    wf_manifest_hashes[item["asset_id"]] = item["sha256"].lower()
                    wf_manifest_durations_ms[item["asset_id"]] = int(item["duration_ms"])
            elif "signals" in wf_json:
                for sig_id, item in wf_json["signals"].items():
                    wf_manifest_hashes[sig_id] = item["sha256"].lower()
            break
    return wf_manifest_hashes, wf_manifest_durations_ms


def _render_m3b_checklist_markdown(
    base: Path,
    first: ScanRecord,
    report: dict[str, Any],
) -> str:
    """Format human-readable controlled audit checklist aligned with CS-CHK-M3B-P1-v1.0 Sections A-O."""
    b_id = report["software_build_identity"]
    tests = report["tests"]
    t01 = tests["3B-01_schema_and_export"]
    t02 = tests["3B-02_realized_audio_config"]
    t03 = tests["3B-03_silence_characterization"]
    t04 = tests["3B-04_free_air_ess"]
    t05 = tests["3B-05_port_occlusion_probe"]
    t06 = tests["3B-06_frame_and_timing"]
    t07 = tests["3B-07_output_volume_stability"]
    t08 = tests["3B-08_cooldown_invariant"]
    t09 = tests["3B-09_recoverable_failures"]
    t10 = tests["3B-10_raw_data_integrity"]
    real = t02["realized"]

    io_buf_ms = (
        f"{real['io_buffer_duration_sec'] * 1000.0:.2f}"
        if real["io_buffer_duration_sec"] is not None
        else "N/A"
    )
    in_lat_ms = (
        f"{real['input_latency_sec'] * 1000.0:.2f}"
        if real["input_latency_sec"] is not None
        else "N/A"
    )
    out_lat_ms = (
        f"{real['output_latency_sec'] * 1000.0:.2f}"
        if real["output_latency_sec"] is not None
        else "N/A"
    )
    tones_str = (
        ", ".join(f"{t['frequency_hz']} Hz ({t['level_dbfs']} dBFS)" for t in t03["narrowband_tones_detected"])
        if t03["narrowband_tones_detected"]
        else "None detected above prominence threshold"
    )

    lines = [
        f"# Milestone 3B Automated Physical-Run Audit (`{CHECKLIST_M3B_ID}` / `{SOP_M3B_VERSION}`)",
        "",
        f"- **Acceptance Criteria Authority:** `{ACCEPTANCE_M3B_ID}`",
        f"- **Operator SOP Authority:** `{OPERATOR_SOP_M3B_ID}`",
        f"- **Hardware Domain:** `{first.hardware_domain or 'IPHONE_NATIVE'}`",
        f"- **Overall Disposition:** **`{report['disposition_label']}`**",
        "",
        "### A. Session & Provenance Identification",
        f"- **Bundle Directory:** `{base.name}`",
        f"- **Session ID:** `{first.session_id or 'UNSPECIFIED'}`",
        f"- **Operator ID:** `{first.operator_id or 'UNSPECIFIED'}`",
        f"- **Device Model / Identifier:** `{first.iphone_model or 'UNSPECIFIED'}` (`{first.hardware_model_identifier or 'UNSPECIFIED'}`)",
        f"- **iOS Version / App Version:** `{first.ios_version or 'UNSPECIFIED'}` / `{first.app_version or 'UNSPECIFIED'}`",
        f"- **Software Build Identity:** `{b_id['package_name']}=={b_id['package_version']}` (`{b_id['build_id']}`)",
        "",
        "### D. Post-Activation Audio State (`3B-02`: `" + t02["status"] + "`)",
        f"- **Sample Rate:** Requested `{t02['requested']['requested_sample_rate_hz']} Hz` | Observed `{real['verified_sample_rate_hz']} Hz`",
        f"- **Channels:** Requested `1 in / 1 out preferred` | Observed `{real['input_channel_count']} in / {real['output_channel_count']} out` (Stereo-locked nonfatal: `{'YES' if real['stereo_locked_output_observed'] else 'NO'}`)",
        f"- **Category / Mode:** Requested `.playAndRecord` / `{t02['requested']['requested_audio_mode']}` | Observed `{real['verified_audio_mode']}`",
        f"- **Input / Output Ports:** `{real['verified_input_port']}` ({real['verified_mic_datasource']}) -> `{real['verified_output_port']}`",
        f"- **Buffer / Latencies:** I/O Buffer `{io_buf_ms} ms` | Input `{in_lat_ms} ms` | Output `{out_lat_ms} ms`",
        f"- **Target `outputVolume`:** `{t02['requested']['target_hardware_volume']}`",
        "",
        "### E–M. Automated Test Results (`3B-01` through `3B-10`)",
        f"- **E. Test `3B-01` (Schema/Export):** `{t01['status']}` — Records `{t01['num_records']}`, 81-field parity `{t01['all_81_fields_present']}`, explicit-null records `{t01['records_preserving_explicit_nulls']}`",
        f"- **F. Test `3B-03` (Bare-Phone Silence):** `{t03['status']}` — Attempted `{t03['attempted_silence_scans']}`, Valid `{t03['num_silence_scans']}`, Mean RMS `{t03['mean_rms_dbfs']} dBFS` (SD `{t03['rms_sd_db']} dB`), Peak `{t03['max_peak_dbfs']} dBFS`, Hum `{tones_str}`",
        f"- **G. Test `3B-04` (Free-Air ESS):** `{t04['status']}` — Valid reps `{t04['num_valid_repetitions']}` (min `5`), Mean peak `{t04.get('mean_peak_dbfs')} dBFS`, Ring-down T20 `{t04.get('mean_ringdown_t20_ms')} ms`, 5-rep SD `{t04.get('median_pairwise_spectral_repeatability_db')} dB`",
        f"- **H. Test `3B-05` (Port-Occlusion Probe):** `{t05['status']}` — Classification **`{t05.get('physical_path_classification', 'NOT_RUN')}`**, Delta `{t05.get('occluded_active_rms_delta_db')}`",
        f"- **I. Test `3B-06` (Timing Integrity):** `{t06['status']}` — Frame violations `{len(t06['accepted_wav_frame_violations'])}`, Timestamp discontinuities `{len(t06['frame_vs_timestamp_discontinuities'])}`",
        f"- **J. Test `3B-07` (Output-State Stability ±0.01):** `{t07['status']}` — Unflagged violations `{len(t07['unflagged_accepted_volume_violations'])}`, Properly rejected `{t07['properly_rejected_out_of_tolerance_scans']}`",
        f"- **K. Test `3B-08` (Cooldown ≥2.0 s All Paths):** `{t08['status']}` — Min observed `{t08['min_observed_cooldown_sec']} s`, Violations `{len(t08['cooldown_violations_all_paths'])}`",
        f"- **L. Test `3B-09` (Recoverable Failure):** `{t09['status']}` — Exercised events `{t09['num_recoverable_or_rejected_events']}`, Illegal promotions `{len(t09['illegally_promoted_scans'])}`, Subsequent legal scan `{t09['subsequent_legal_acquisition_observed']}`",
        f"- **M. Test `3B-10` (Final Bundle Integrity):** `{t10['status']}` — Attempted `{t10['attempted_scans']}`, Accepted `{t10['accepted_scans']}`, Rejected `{t10['rejected_scans']}`, Aborted `{t10['aborted_scans']}`, Missing WAVs `{t10['missing_wav_count']}`, Orphans `{t10['orphan_wav_count']}`, Duplicates `{t10['duplicate_scan_id_count']}`, Malformed `{t10['malformed_jsonl_count']}`, Hash failures `{t10['hash_failure_count']}`, Unexplained losses `{t10['unexplained_data_loss_count']}`",
        "",
        "### N. Automated Audit Digests",
        f"- **Dataset Manifest SHA-256:** `{report['dataset_manifest_sha256']}`",
        f"- **Threshold / Configuration SHA-256:** `{report['threshold_config_sha256']}`",
        "",
        "### O. Disposition & Basis",
        f"- **Disposition:** **`{report['disposition_label']}`**",
    ]
    for reason in report.get("disposition_reasons", []):
        lines.append(f"- {reason}")
    lines.extend(
        [
            "",
            "---",
            f"> **Control Statement:** {M3B_SCOPE_STATEMENT}",
        ]
    )
    return "\n".join(lines) + "\n"


def audit_m3b_bundle(
    bundle_dir: Path | str,
    qc_thresholds: QCThresholds = QCThresholds(),
    min_silence_reps: int = 2,
    min_free_air_ess_reps: int = 5,
    occlusion_support_threshold_db: float = 2.0,
    require_recoverable_failure_exercised: bool = True,
    output_report_dir: Path | str | None = None,
) -> dict[str, Any]:
    """Run CS-SOP-M3B-P1-v1.1 & CS-ACC-M3B-P1-v1.0 Tests 3B-01 through 3B-10 on an exported M3B bundle."""
    base = Path(bundle_dir)
    scans_path = base / "scans.jsonl"
    if not scans_path.is_file():
        raise FileNotFoundError(f"Missing scans.jsonl in bundle directory: {base}")

    build_identity = compute_software_build_identity()
    dataset_manifest_sha256, _ = compute_dataset_manifest_digest(dataset_dir=base)
    threshold_cfg_payload = {
        "sop_id": SOP_M3B_VERSION,
        "acceptance_criteria_id": ACCEPTANCE_M3B_ID,
        "qc_thresholds": asdict(qc_thresholds),
        "min_silence_reps": min_silence_reps,
        "min_free_air_ess_reps": min_free_air_ess_reps,
        "occlusion_support_threshold_db": occlusion_support_threshold_db,
        "require_recoverable_failure_exercised": require_recoverable_failure_exercised,
    }
    threshold_config_sha256 = compute_canonical_json_sha256(threshold_cfg_payload)

    wf_manifest_hashes, wf_manifest_durations_ms = _load_waveform_manifest_metadata(base)

    raw_lines = scans_path.read_text(encoding="utf-8").splitlines()
    malformed_lines: list[int] = []
    missing_81_field_lines: list[int] = []
    null_preserved_count = 0
    records: list[ScanRecord] = []

    for idx, line in enumerate(raw_lines, start=1):
        stripped = line.strip()
        if not stripped:
            continue
        try:
            obj = json.loads(stripped)
        except json.JSONDecodeError:
            malformed_lines.append(idx)
            continue
        if not isinstance(obj, dict):
            malformed_lines.append(idx)
            continue

        keys = set(obj.keys())
        if keys != EXPECTED_SCAN_RECORD_FIELDS:
            missing_81_field_lines.append(idx)
        if any(v is None for v in obj.values()):
            null_preserved_count += 1
        try:
            records.append(ScanRecord.from_dict(obj))
        except ValueError:
            malformed_lines.append(idx)

    # Unique scan IDs & timestamp ordering
    scan_keys = [f"{r.sample_id}__rep{r.repetition_number}" for r in records]
    key_counts = Counter(scan_keys)
    duplicate_scan_ids = sorted([k for k, c in key_counts.items() if c > 1])

    timestamps = [r.scan_timestamp for r in records if r.scan_timestamp is not None]
    timestamps_ordered = timestamps == sorted(timestamps)

    referenced_wavs: set[str] = set()
    missing_wavs: list[str] = []
    wav_hash_mismatches: list[str] = []
    wf_digest_mismatches: list[str] = []
    unexplained_rejections: list[str] = []
    uninvalidated_route_changes: list[str] = []

    for r in records:
        sid_key = f"{r.sample_id}__rep{r.repetition_number}"
        if r.raw_audio_filename:
            referenced_wavs.add(r.raw_audio_filename)
            wpath = base / r.raw_audio_filename
            if not wpath.is_file():
                missing_wavs.append(r.raw_audio_filename)
            elif r.raw_audio_sha256:
                actual_sha = sha256_file(wpath)
                if actual_sha.lower() != r.raw_audio_sha256.lower():
                    wav_hash_mismatches.append(r.raw_audio_filename)
        elif r.quality_status in ACCEPTED_STATUSES:
            missing_wavs.append(f"{sid_key}:missing_filename")

        if (
            r.excitation_signal_id
            and r.excitation_wav_sha256
            and r.excitation_signal_id in wf_manifest_hashes
        ):
            if r.excitation_wav_sha256.lower() != wf_manifest_hashes[r.excitation_signal_id]:
                wf_digest_mismatches.append(sid_key)

        if r.quality_status not in ACCEPTED_STATUSES:
            if not r.quality_flags:
                unexplained_rejections.append(sid_key)
        else:
            if set(r.quality_flags or []) & ROUTE_OR_INTERRUPT_FLAGS:
                uninvalidated_route_changes.append(sid_key)

    root_wavs = {p.name for p in base.glob("*.wav") if p.is_file()}
    orphan_wavs = sorted(root_wavs - referenced_wavs)

    # TEST 3B-01: Schema and export round trip
    t01_pass = (
        len(records) > 0
        and not malformed_lines
        and not missing_81_field_lines
        and not duplicate_scan_ids
        and not missing_wavs
        and timestamps_ordered
        and not wf_digest_mismatches
        and not unexplained_rejections
    )
    test_3b_01 = {
        "status": "PASS" if t01_pass else "FAIL",
        "num_records": len(records),
        "all_81_fields_present": len(missing_81_field_lines) == 0,
        "records_preserving_explicit_nulls": null_preserved_count,
        "duplicate_scan_ids": duplicate_scan_ids,
        "missing_wav_files": missing_wavs,
        "timestamps_internally_ordered": timestamps_ordered,
        "waveform_digest_mismatches": wf_digest_mismatches,
        "unexplained_rejections": unexplained_rejections,
    }

    # TEST 3B-02: Realized vs. Requested Audio Configuration (stereo-locked output nonfatal)
    first = records[0] if records else ScanRecord()
    requested_cfg = {
        "requested_category": ".playAndRecord",
        "requested_audio_mode": first.requested_audio_mode,
        "requested_sample_rate_hz": first.requested_sample_rate_hz,
        "requested_input_channels": 1,
        "preferred_output_channels": 1,
        "selected_input_port": first.selected_input_port,
        "selected_mic_datasource": first.selected_mic_datasource,
        "selected_polar_pattern": first.selected_polar_pattern,
        "target_hardware_volume": first.target_hardware_volume,
    }
    realized_cfg = {
        "verified_audio_mode": first.verified_audio_mode,
        "verified_sample_rate_hz": first.verified_sample_rate_hz,
        "input_channel_count": first.input_channel_count,
        "output_channel_count": first.output_channel_count,
        "stereo_locked_output_observed": (first.output_channel_count or 0) > 1,
        "verified_input_port": first.verified_input_port,
        "verified_mic_datasource": first.verified_mic_datasource,
        "verified_polar_pattern": first.verified_polar_pattern,
        "verified_output_port": first.verified_output_port,
        "reported_speaker_channel_mapping": first.reported_speaker_channel_mapping,
        "io_buffer_duration_sec": first.io_buffer_duration_sec,
        "input_latency_sec": first.input_latency_sec,
        "output_latency_sec": first.output_latency_sec,
    }
    t02_eligible = (
        first.verified_sample_rate_hz == qc_thresholds.expected_sample_rate_hz
        and (first.verified_audio_mode or "").lower() == "measurement"
        and (first.input_channel_count or 0) == 1
        and (first.output_channel_count or 0) >= 1
        and not uninvalidated_route_changes
    )
    test_3b_02 = {
        "status": "PASS" if (len(records) > 0 and t02_eligible) else "FAIL",
        "requested": requested_cfg,
        "realized": realized_cfg,
        "uninvalidated_route_change_scans": uninvalidated_route_changes,
        "eligible_for_m3b": t02_eligible,
    }

    # TEST 3B-03: Repeated Bare-Phone Silence Characterization (no universal noise-floor cutoff; never liquid inference)
    attempted_sil = [r for r in records if r.excitation_signal_id == "SIG_SIL_v1"]
    sil_records = [
        r
        for r in attempted_sil
        if r.quality_status in ACCEPTED_STATUSES
        and r.raw_audio_filename
        and (base / r.raw_audio_filename).is_file()
    ]
    sil_rms_list: list[float] = []
    sil_peak_list: list[float] = []
    sil_clips = 0
    sil_tones: list[dict[str, float]] = []
    for r in sil_records:
        sr, wav = read_wav_float32(base / str(r.raw_audio_filename))
        mono = wav if wav.ndim == 1 else wav[:, 0]
        mono_f = mono.astype(np.float64) - float(np.mean(mono))
        rms_db = linear_to_dbfs(float(np.sqrt(np.mean(mono_f**2))))
        pk_db = linear_to_dbfs(float(np.max(np.abs(mono_f))))
        clip_lin = 10.0 ** (qc_thresholds.clipping_ceiling_dbfs / 20.0)
        sil_clips += int(np.sum(np.abs(mono_f) >= clip_lin))
        sil_rms_list.append(rms_db)
        sil_peak_list.append(pk_db)
        if not sil_tones:
            sil_tones = detect_narrowband_interference(mono_f, sample_rate_hz=sr)

    if sil_clips > 0:
        t03_status = "FAIL"
    elif len(sil_records) >= min_silence_reps:
        t03_status = "PASS"
    elif len(sil_records) == 0:
        t03_status = "NOT_RUN"
    else:
        t03_status = "INSUFFICIENT_REPS"

    test_3b_03 = {
        "status": t03_status,
        "attempted_silence_scans": len(attempted_sil),
        "num_silence_scans": len(sil_records),
        "required_minimum": min_silence_reps,
        "mean_rms_dbfs": round(float(np.mean(sil_rms_list)), 3) if sil_rms_list else None,
        "rms_sd_db": round(float(np.std(sil_rms_list)), 4) if len(sil_rms_list) > 1 else 0.0,
        "first_to_last_drift_db": round(abs(sil_rms_list[-1] - sil_rms_list[0]), 4)
        if len(sil_rms_list) >= 2
        else 0.0,
        "max_peak_dbfs": round(float(np.max(sil_peak_list)), 3) if sil_peak_list else None,
        "clipped_sample_count": sil_clips,
        "narrowband_tones_detected": sil_tones,
        "narrowband_diagnostic_scope": "INSTRUMENT_NOISE_FLOOR_ONLY",
        "noise_floor_threshold_imposed": False,
        "liquid_inference_permitted": False,
    }

    # TEST 3B-04 & TEST 3B-05: Free-Air ESS (N >= 5) & Paired Port-Occlusion Probe
    ess_pair = generate_ess_pair(ESSConfig())
    dsp_cfg = DSPConfig()
    free_air_feats = []
    free_air_peaks_db: list[float] = []
    free_air_clips = 0
    unoccluded_ids: list[str] = []
    occluded_ids_by_group: dict[str, list[str]] = defaultdict(list)
    occlusion_rms_by_group: dict[str, list[float]] = defaultdict(list)

    for r in records:
        if (
            r.excitation_signal_id == "SIG_ESS_v1"
            and r.quality_status in ACCEPTED_STATUSES
            and r.raw_audio_filename
            and (base / r.raw_audio_filename).is_file()
        ):
            sid_key = f"{r.sample_id}__rep{r.repetition_number}"
            _, wav = read_wav_float32(base / str(r.raw_audio_filename))
            label_upper = f"{r.sample_id or ''} {r.operator_notes or ''}".upper()
            active_seg = wav[
                ess_pair.pre_roll_samples : ess_pair.pre_roll_samples + ess_pair.active_samples
            ]
            act_rms_db = linear_to_dbfs(float(np.sqrt(np.mean(active_seg.astype(np.float64) ** 2))))

            if "OCCLUD" in label_upper or "COND_B" in label_upper:
                grp = r.sample_id or "OCCLUDED"
                occlusion_rms_by_group[grp].append(act_rms_db)
                occluded_ids_by_group[grp].append(sid_key)
            else:
                occlusion_rms_by_group["UNOBSTRUCTED"].append(act_rms_db)
                unoccluded_ids.append(sid_key)
                free_air_feats.append(extract_scan_features(wav, ess_pair, config=dsp_cfg))
                free_air_peaks_db.append(linear_to_dbfs(float(np.max(np.abs(wav)))))
                clip_lin = 10.0 ** (qc_thresholds.clipping_ceiling_dbfs / 20.0)
                free_air_clips += int(np.sum(np.abs(wav) >= clip_lin))

    if len(free_air_feats) >= min_free_air_ess_reps and free_air_clips == 0:
        agg_free = aggregate_sample_repetitions(free_air_feats)
        lat_sd_ms = float(np.std([f.t0_latency_ms for f in free_air_feats]))
        first_last_drift = float(
            np.sqrt(
                np.mean(
                    (
                        free_air_feats[-1].raw_resonance_bands_db
                        - free_air_feats[0].raw_resonance_bands_db
                    )
                    ** 2
                )
            )
        )
        test_3b_04 = {
            "status": "PASS",
            "num_valid_repetitions": len(free_air_feats),
            "mean_peak_dbfs": round(float(np.mean(free_air_peaks_db)), 3),
            "max_peak_dbfs": round(float(np.max(free_air_peaks_db)), 3),
            "clipped_sample_count": free_air_clips,
            "mean_arrival_latency_ms": round(
                float(np.mean([f.t0_latency_ms for f in free_air_feats])), 4
            ),
            "sd_arrival_latency_ms": round(lat_sd_ms, 4),
            "impulse_alignment_stable": bool(lat_sd_ms <= 1.0),
            "mean_ringdown_t20_ms": round(
                float(np.mean([f.t20_estimates_ms[1] for f in free_air_feats])), 3
            ),
            "mean_mid_ringdown_slope_db_per_s": round(
                float(np.mean([f.ringdown_slopes_db_per_s[1] for f in free_air_feats])), 3
            ),
            "median_pairwise_spectral_repeatability_db": agg_free[
                "median_pairwise_repeatability_db"
            ],
            "first_to_last_band_drift_db": round(first_last_drift, 4),
            "synthetic_repeatability_cutoff_imposed": False,
        }
    elif len(free_air_feats) >= min_free_air_ess_reps and free_air_clips > 0:
        test_3b_04 = {
            "status": "FAIL",
            "num_valid_repetitions": len(free_air_feats),
            "clipped_sample_count": free_air_clips,
        }
    else:
        test_3b_04 = {
            "status": "NOT_RUN" if len(free_air_feats) == 0 else "INSUFFICIENT_REPS",
            "num_valid_repetitions": len(free_air_feats),
            "required_minimum": min_free_air_ess_reps,
        }

    unob_vals = occlusion_rms_by_group.get("UNOBSTRUCTED", [])
    occ_keys = [k for k in occlusion_rms_by_group.keys() if k != "UNOBSTRUCTED"]
    if unob_vals and occ_keys:
        unob_mean = float(np.mean(unob_vals))
        deltas = {
            k: round(float(np.mean(occlusion_rms_by_group[k])) - unob_mean, 3) for k in occ_keys
        }
        material_change = any(abs(v) >= occlusion_support_threshold_db for v in deltas.values())
        if material_change:
            path_class = "DOMINANT_PATH_SUPPORTED"
            dominant_cond: str | None = min(deltas.items(), key=lambda kv: kv[1])[0]
        else:
            # Per CS-ACC-M3B-P1-v1.0: weak or indeterminate occlusion recorded as PATH INDETERMINATE;
            # never rewritten as proof of a particular hardware path.
            path_class = "PATH INDETERMINATE"
            dominant_cond = None

        test_3b_05 = {
            "status": "PASS",
            "unoccluded_scan_ids": unoccluded_ids,
            "occluded_scan_ids": dict(occluded_ids_by_group),
            "unobstructed_active_rms_dbfs": round(unob_mean, 3),
            "occluded_active_rms_delta_db": deltas,
            "material_attenuation_observed": material_change,
            "physical_path_classification": path_class,
            "dominant_attenuated_condition": dominant_cond,
        }
    else:
        test_3b_05 = {
            "status": "NOT_RUN",
            "occluded_conditions_found": len(occ_keys),
            "physical_path_classification": "NOT_RUN",
        }

    # TEST 3B-06: Frame & Timing Integrity (including frame-versus-timestamp discontinuity)
    frame_violations: list[str] = []
    frame_timestamp_discontinuities: list[str] = []
    for r in records:
        if r.quality_status not in ACCEPTED_STATUSES or not r.raw_audio_filename:
            continue
        wpath = base / r.raw_audio_filename
        if not wpath.is_file():
            continue
        act_ms = wf_manifest_durations_ms.get(r.excitation_signal_id or "SIG_ESS_v1", 200)
        act_frames = int(round(act_ms * 48.0))
        ing = ingest_audio_file(
            wpath,
            expected_sample_rate_hz=qc_thresholds.expected_sample_rate_hz,
            pre_roll_samples=7_200,
            active_samples=act_frames,
            post_roll_samples=7_200,
            frame_tolerance=4_800,
        )
        if ing.report.quarantined:
            frame_violations.append(
                f"{r.raw_audio_filename}:{','.join(ing.report.quarantine_reasons)}"
            )
        if (
            r.excitation_start_host_time_s is not None
            and r.excitation_end_host_time_s is not None
        ):
            host_exc_s = r.excitation_end_host_time_s - r.excitation_start_host_time_s
            expected_exc_s = act_ms / 1000.0
            realized_wav_s = ing.report.duration_sec
            expected_wav_s = expected_exc_s + 0.300
            if abs(host_exc_s - expected_exc_s) > 0.12 or abs(realized_wav_s - expected_wav_s) > 0.12:
                frame_timestamp_discontinuities.append(
                    f"{r.raw_audio_filename}(wav={realized_wav_s:.3f}s,host_exc={host_exc_s:.3f}s)"
                )

    transitions_ordered = True
    transitions_path = base / "transitions.jsonl"
    if transitions_path.is_file():
        t_stamps = []
        for ln in transitions_path.read_text(encoding="utf-8").splitlines():
            if ln.strip():
                t_obj = json.loads(ln)
                if "timestamp" in t_obj:
                    t_stamps.append(str(t_obj["timestamp"]))
        transitions_ordered = t_stamps == sorted(t_stamps)

    test_3b_06 = {
        "status": "PASS"
        if (
            not frame_violations
            and not frame_timestamp_discontinuities
            and transitions_ordered
        )
        else "FAIL",
        "accepted_wav_frame_violations": frame_violations,
        "frame_vs_timestamp_discontinuities": frame_timestamp_discontinuities,
        "transition_timestamps_ordered": transitions_ordered,
    }

    # TEST 3B-07: Output-State Stability (pre/post outputVolume +-0.01 scalar units)
    unflagged_volume_violations: list[str] = []
    properly_rejected_volume_count = 0
    for r in records:
        if r.excitation_signal_id == "SIG_SIL_v1":
            continue
        if (
            r.target_hardware_volume is None
            or r.pre_scan_hardware_volume is None
            or r.post_scan_hardware_volume is None
        ):
            if r.quality_status in ACCEPTED_STATUSES:
                unflagged_volume_violations.append(f"{r.sample_id}_rep{r.repetition_number}")
            continue

        pre_err = abs(r.pre_scan_hardware_volume - r.target_hardware_volume)
        post_err = abs(r.post_scan_hardware_volume - r.target_hardware_volume)
        pre_post_diff = abs(r.post_scan_hardware_volume - r.pre_scan_hardware_volume)
        if (
            pre_err > qc_thresholds.volume_tolerance
            or post_err > qc_thresholds.volume_tolerance
            or pre_post_diff > qc_thresholds.volume_tolerance
        ):
            if r.quality_status in ACCEPTED_STATUSES:
                unflagged_volume_violations.append(f"{r.sample_id}_rep{r.repetition_number}")
            else:
                properly_rejected_volume_count += 1

    test_3b_07 = {
        "status": "PASS" if not unflagged_volume_violations else "FAIL",
        "frozen_tolerance_scalar": qc_thresholds.volume_tolerance,
        "unflagged_accepted_volume_violations": unflagged_volume_violations,
        "properly_rejected_out_of_tolerance_scans": properly_rejected_volume_count,
    }

    # TEST 3B-08: Cooldown Invariant (next t_exc_start >= prev t_exc_end + 2.0 s across ALL paths)
    cooldown_violations_all_paths: list[str] = []
    unflagged_cooldown_violations: list[str] = []
    observed_gaps_s: list[float] = []
    prev_end_time: float | None = None
    for r in records:
        if r.excitation_start_host_time_s is not None and prev_end_time is not None:
            gap = r.excitation_start_host_time_s - prev_end_time
            observed_gaps_s.append(round(gap, 4))
            if gap < (qc_thresholds.min_cooldown_sec - 1e-4):
                label_gap = (
                    f"{r.sample_id}_rep{r.repetition_number}"
                    f"[status={r.quality_status},gap={gap:.3f}s]"
                )
                cooldown_violations_all_paths.append(label_gap)
                if r.quality_status in ACCEPTED_STATUSES:
                    unflagged_cooldown_violations.append(label_gap)
        if r.excitation_end_host_time_s is not None:
            prev_end_time = r.excitation_end_host_time_s

    test_3b_08 = {
        "status": "PASS" if not cooldown_violations_all_paths else "FAIL",
        "cooldown_violations_all_paths": cooldown_violations_all_paths,
        "unflagged_accepted_cooldown_violations": unflagged_cooldown_violations,
        "min_observed_cooldown_sec": min(observed_gaps_s) if observed_gaps_s else None,
        "min_required_cooldown_sec": qc_thresholds.min_cooldown_sec,
    }

    # TEST 3B-09: Recoverable Failure Behavior (CS-OPS-M3B-P1-v1.0 Step 9 & CS-ACC-M3B-P1-v1.0 Sec A/C)
    illegally_promoted: list[str] = []
    non_accepted = [r for r in records if r.quality_status not in ACCEPTED_STATUSES]
    first_non_accepted_idx: int | None = None
    subsequent_legal_observed = False
    for idx_r, r in enumerate(records):
        if r.quality_status not in ACCEPTED_STATUSES:
            if first_non_accepted_idx is None:
                first_non_accepted_idx = idx_r
            if r.final_scan_validity == "FINAL_ACCEPTED":
                illegally_promoted.append(f"{r.sample_id}_rep{r.repetition_number}")
        elif first_non_accepted_idx is not None:
            subsequent_legal_observed = True

    if illegally_promoted or unexplained_rejections:
        t09_status = "FAIL"
    elif require_recoverable_failure_exercised and len(non_accepted) == 0:
        t09_status = "NOT_RUN"
    else:
        t09_status = "PASS"

    exercised_flags = sorted({fl for r in non_accepted for fl in (r.quality_flags or [])})
    test_3b_09 = {
        "status": t09_status,
        "num_recoverable_or_rejected_events": len(non_accepted),
        "exercised_failure_flags": exercised_flags,
        "illegally_promoted_scans": illegally_promoted,
        "subsequent_legal_acquisition_observed": subsequent_legal_observed,
    }

    # TEST 3B-10: Raw-Data Integrity & CS-CHK-M3B-P1-v1.0 Section M Summary
    status_tally = Counter(r.quality_status or "UNKNOWN" for r in records)
    accepted_count = sum(1 for r in records if r.quality_status in ACCEPTED_STATUSES)
    aborted_count = sum(
        1
        for r in records
        if (r.quality_status in ABORTED_STATUSES)
        or ("OPERATOR_ABORTED" in (r.quality_flags or []))
    )
    rejected_count = len(records) - accepted_count - aborted_count

    flag_tally: Counter[str] = Counter()
    for r in non_accepted:
        for fl in r.quality_flags or []:
            flag_tally[fl] += 1

    hash_failure_count = len(wav_hash_mismatches) + len(wf_digest_mismatches)
    unexplained_loss_count = (
        len(missing_wavs) + len(malformed_lines) + len(unexplained_rejections)
    )

    t10_pass = (
        not orphan_wavs
        and not missing_wavs
        and not duplicate_scan_ids
        and not malformed_lines
        and hash_failure_count == 0
        and unexplained_loss_count == 0
    )
    test_3b_10 = {
        "status": "PASS" if t10_pass else "FAIL",
        "attempted_scans": len(records),
        "accepted_scans": accepted_count,
        "rejected_scans": rejected_count,
        "aborted_scans": aborted_count,
        "status_counts": dict(status_tally),
        "rejection_reason_counts": dict(flag_tally),
        "missing_wav_count": len(missing_wavs),
        "orphan_wav_count": len(orphan_wavs),
        "duplicate_scan_id_count": len(duplicate_scan_ids),
        "malformed_jsonl_count": len(malformed_lines),
        "hash_failure_count": hash_failure_count,
        "cooldown_violation_count": len(cooldown_violations_all_paths),
        "unexplained_data_loss_count": unexplained_loss_count,
        "orphan_wav_files": orphan_wavs,
        "missing_wav_files": missing_wavs,
        "wav_sha256_mismatches": wav_hash_mismatches,
        "malformed_jsonl_lines": malformed_lines,
    }

    tests_dict = {
        "3B-01_schema_and_export": test_3b_01,
        "3B-02_realized_audio_config": test_3b_02,
        "3B-03_silence_characterization": test_3b_03,
        "3B-04_free_air_ess": test_3b_04,
        "3B-05_port_occlusion_probe": test_3b_05,
        "3B-06_frame_and_timing": test_3b_06,
        "3B-07_output_volume_stability": test_3b_07,
        "3B-08_cooldown_invariant": test_3b_08,
        "3B-09_recoverable_failures": test_3b_09,
        "3B-10_raw_data_integrity": test_3b_10,
    }

    failed_tests = [k for k, v in tests_dict.items() if v["status"] == "FAIL"]
    incomplete_tests = [k for k, v in tests_dict.items() if v["status"] not in ("PASS", "FAIL")]

    disposition_reasons: list[str] = []
    if failed_tests:
        disposition = "FAIL"
        disposition_label = "M3B FAIL - DO NOT PROCEED TO FIXTURE CHARACTERIZATION"
        for ft in failed_tests:
            disposition_reasons.append(f"Blocking defect in `{ft}` (`status=FAIL`).")
        disposition_reasons.append(
            "Do not proceed to Milestone 3C until the blocking defect is corrected."
        )
    elif incomplete_tests:
        disposition = "CONDITIONAL"
        disposition_label = (
            "M3B CONDITIONAL - CORRECT SPECIFIC DEFECT AND REPEAT AFFECTED TEST"
        )
        for it in incomplete_tests:
            disposition_reasons.append(
                f"Required characterization/recovery step incomplete: `{it}` (`status={tests_dict[it]['status']}`)."
            )
        disposition_reasons.append(
            "Complete or repeat the affected 3B test before advancing to Milestone 3C."
        )
    else:
        disposition = "PASS"
        disposition_label = "M3B PASS - ADVANCE TO MILESTONE 3C"
        disposition_reasons.append(
            "All 10 mandatory integrity, timing, silence, free-air ESS, port-occlusion, outputVolume, cooldown, and recovery checks satisfied (`CS-ACC-M3B-P1-v1.0` Section C)."
        )
        if test_3b_05.get("physical_path_classification") == "PATH INDETERMINATE":
            disposition_reasons.append(
                "Note: Port-occlusion attenuation was below threshold and is recorded as `PATH INDETERMINATE` for empirical M3C fixture evaluation."
            )

    report: dict[str, Any] = {
        "sop_id": SOP_M3B_VERSION,
        "checklist_id": CHECKLIST_M3B_ID,
        "operator_sop_id": OPERATOR_SOP_M3B_ID,
        "acceptance_criteria_id": ACCEPTANCE_M3B_ID,
        "bundle_dir": str(base),
        "disposition": disposition,
        "disposition_label": disposition_label,
        "disposition_reasons": disposition_reasons,
        "scope_statement": M3B_SCOPE_STATEMENT,
        "software_build_identity": build_identity,
        "dataset_manifest_sha256": dataset_manifest_sha256,
        "threshold_config_sha256": threshold_config_sha256,
        "tests": tests_dict,
    }

    if output_report_dir is not None:
        out = Path(output_report_dir)
        out.mkdir(parents=True, exist_ok=True)
        (out / "m3b_audit_report.json").write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8"
        )
        (out / "m3b_checklist.md").write_text(
            _render_m3b_checklist_markdown(base, first, report), encoding="utf-8"
        )

    return report


def summarize_m3b_audio(
    bundle_dir: Path | str,
    qc_thresholds: QCThresholds = QCThresholds(),
    occlusion_support_threshold_db: float = 2.0,
    output_report_dir: Path | str | None = None,
) -> dict[str, Any]:
    """Produce CS-SOP-M3B-P1-v1.1 Appendix A.3 (`m3b summarize-audio`) metrics and plots manifest."""
    base = Path(bundle_dir)
    scans_path = base / "scans.jsonl"
    if not scans_path.is_file():
        raise FileNotFoundError(f"Missing scans.jsonl in bundle directory: {base}")

    build_identity = compute_software_build_identity()
    dataset_manifest_sha256, _ = compute_dataset_manifest_digest(dataset_dir=base)
    threshold_config_sha256 = compute_canonical_json_sha256(
        {
            "sop_id": SOP_M3B_VERSION,
            "acceptance_criteria_id": ACCEPTANCE_M3B_ID,
            "qc_thresholds": asdict(qc_thresholds),
            "occlusion_support_threshold_db": occlusion_support_threshold_db,
        }
    )
    _, wf_manifest_durations_ms = _load_waveform_manifest_metadata(base)

    records = read_scans_jsonl(scans_path)
    ess_pair = generate_ess_pair(ESSConfig())
    dsp_cfg = DSPConfig()

    # 1. Silence & narrowband hum summary
    sil_entries: list[dict[str, Any]] = []
    sil_spectrum: dict[str, list[float]] = {"frequencies_hz": [], "magnitude_dbfs": []}
    hum_candidates: list[dict[str, float]] = []

    for r in records:
        if (
            r.excitation_signal_id == "SIG_SIL_v1"
            and r.quality_status in ACCEPTED_STATUSES
            and r.raw_audio_filename
            and (base / r.raw_audio_filename).is_file()
        ):
            sr, wav = read_wav_float32(base / r.raw_audio_filename)
            mono = (wav if wav.ndim == 1 else wav[:, 0]).astype(np.float64)
            mono = mono - float(np.mean(mono))
            rms_db = linear_to_dbfs(float(np.sqrt(np.mean(mono**2))))
            peak_db = linear_to_dbfs(float(np.max(np.abs(mono))))
            tones = detect_narrowband_interference(mono, sample_rate_hz=sr)
            if not sil_spectrum["frequencies_hz"]:
                sil_spectrum = _compute_log_spectrum_series(mono, sample_rate_hz=sr)
            if not hum_candidates and tones:
                hum_candidates = tones
            sil_entries.append(
                {
                    "scan_id": f"{r.sample_id}__rep{r.repetition_number}",
                    "rms_dbfs": round(rms_db, 3),
                    "peak_dbfs": round(peak_db, 3),
                    "narrowband_candidates": tones,
                }
            )

    sil_rms_vals = [e["rms_dbfs"] for e in sil_entries]
    silence_summary = {
        "count": len(sil_entries),
        "mean_rms_dbfs": round(float(np.mean(sil_rms_vals)), 3) if sil_rms_vals else None,
        "sd_rms_db": round(float(np.std(sil_rms_vals)), 4) if len(sil_rms_vals) > 1 else 0.0,
        "max_peak_dbfs": round(max(e["peak_dbfs"] for e in sil_entries), 3) if sil_entries else None,
        "first_to_last_drift_db": round(abs(sil_rms_vals[-1] - sil_rms_vals[0]), 4)
        if len(sil_rms_vals) >= 2
        else 0.0,
        "narrowband_hum_candidates": hum_candidates,
        "diagnostic_scope": "INSTRUMENT_NOISE_FLOOR_ONLY",
        "liquid_inference_permitted": False,
        "per_scan": sil_entries,
    }

    # 2. Free-air ESS & paired port-occlusion summaries
    free_air_feats = []
    free_air_entries: list[dict[str, Any]] = []
    occlusion_rms_by_cond: dict[str, list[float]] = defaultdict(list)

    for r in records:
        if (
            r.excitation_signal_id == "SIG_ESS_v1"
            and r.quality_status in ACCEPTED_STATUSES
            and r.raw_audio_filename
            and (base / r.raw_audio_filename).is_file()
        ):
            _, wav = read_wav_float32(base / r.raw_audio_filename)
            label_upper = f"{r.sample_id or ''} {r.operator_notes or ''}".upper()
            active_seg = wav[
                ess_pair.pre_roll_samples : ess_pair.pre_roll_samples + ess_pair.active_samples
            ]
            act_rms_db = linear_to_dbfs(float(np.sqrt(np.mean(active_seg.astype(np.float64) ** 2))))
            pk_db = linear_to_dbfs(float(np.max(np.abs(wav))))

            if "OCCLUD" in label_upper or "COND_B" in label_upper:
                occlusion_rms_by_cond[r.sample_id or "OCCLUDED"].append(act_rms_db)
            else:
                occlusion_rms_by_cond["UNOBSTRUCTED"].append(act_rms_db)
                feat = extract_scan_features(wav, ess_pair, config=dsp_cfg)
                free_air_feats.append(feat)
                free_air_entries.append(
                    {
                        "scan_id": f"{r.sample_id}__rep{r.repetition_number}",
                        "active_rms_dbfs": round(act_rms_db, 3),
                        "peak_dbfs": round(pk_db, 3),
                        "t0_latency_ms": round(feat.t0_latency_ms, 4),
                        "normalized_xcorr_peak": round(feat.normalized_xcorr_peak, 4),
                        "ringdown_t20_ms": round(feat.t20_estimates_ms[1], 3),
                        "mid_ringdown_slope_db_per_s": round(feat.ringdown_slopes_db_per_s[1], 3),
                    }
                )

    if free_air_feats:
        agg_ess = aggregate_sample_repetitions(free_air_feats)
        band_mat = np.vstack([f.raw_resonance_bands_db for f in free_air_feats])
        mean_bands = [round(float(x), 4) for x in np.mean(band_mat, axis=0)]
        sd_bands = [round(float(x), 4) for x in np.std(band_mat, axis=0)]
        free_air_summary: dict[str, Any] = {
            "count": len(free_air_feats),
            "mean_arrival_latency_ms": round(
                float(np.mean([f.t0_latency_ms for f in free_air_feats])), 4
            ),
            "sd_arrival_latency_ms": round(
                float(np.std([f.t0_latency_ms for f in free_air_feats])), 4
            ),
            "mean_ringdown_t20_ms": round(
                float(np.mean([f.t20_estimates_ms[1] for f in free_air_feats])), 3
            ),
            "mean_mid_ringdown_slope_db_per_s": round(
                float(np.mean([f.ringdown_slopes_db_per_s[1] for f in free_air_feats])), 3
            ),
            "median_pairwise_repeatability_db": agg_ess["median_pairwise_repeatability_db"],
            "mean_resonance_bands_db": mean_bands,
            "sd_resonance_bands_db": sd_bands,
            "per_scan": free_air_entries,
        }
    else:
        mean_bands = []
        sd_bands = []
        free_air_summary = {"count": 0, "per_scan": []}

    unob = occlusion_rms_by_cond.get("UNOBSTRUCTED", [])
    occ_conds = {
        k: round(float(np.mean(v)), 3)
        for k, v in sorted(occlusion_rms_by_cond.items())
        if k != "UNOBSTRUCTED"
    }
    unob_mean = round(float(np.mean(unob)), 3) if unob else None
    occ_attenuation = (
        {k: round(val - unob_mean, 3) for k, val in occ_conds.items()}
        if unob_mean is not None
        else {}
    )
    if occ_attenuation:
        occ_supported = any(
            abs(v) >= occlusion_support_threshold_db for v in occ_attenuation.values()
        )
        occ_path_class = "DOMINANT_PATH_SUPPORTED" if occ_supported else "PATH INDETERMINATE"
    else:
        occ_path_class = "NOT_RUN"

    port_occlusion_summary = {
        "unobstructed_mean_active_rms_dbfs": unob_mean,
        "occluded_mean_active_rms_dbfs": occ_conds,
        "attenuation_delta_db": occ_attenuation,
        "physical_path_classification": occ_path_class,
    }

    # 3. Timing & cooldown summary across all scans
    timing_entries: list[dict[str, Any]] = []
    cooldown_gaps_s: list[float] = []
    prev_end: float | None = None
    for r in records:
        gap_s: float | None = None
        if r.excitation_start_host_time_s is not None and prev_end is not None:
            gap_s = round(r.excitation_start_host_time_s - prev_end, 4)
            cooldown_gaps_s.append(gap_s)
        if r.excitation_end_host_time_s is not None:
            prev_end = r.excitation_end_host_time_s

        act_ms = wf_manifest_durations_ms.get(r.excitation_signal_id or "SIG_ESS_v1", 200)
        sched_wav_s = (act_ms / 1000.0) + 0.300
        realized_wav_s: float | None = None
        if r.raw_audio_filename and (base / r.raw_audio_filename).is_file():
            sr, wav = read_wav_float32(base / r.raw_audio_filename)
            realized_wav_s = round(wav.shape[0] / float(max(1, sr)), 4)

        timing_entries.append(
            {
                "scan_id": f"{r.sample_id}__rep{r.repetition_number}",
                "quality_status": r.quality_status,
                "scheduled_wav_duration_s": round(sched_wav_s, 4),
                "realized_wav_duration_s": realized_wav_s,
                "cooldown_gap_from_previous_s": gap_s,
            }
        )

    timing_summary = {
        "num_scans": len(records),
        "min_cooldown_gap_s": min(cooldown_gaps_s) if cooldown_gaps_s else None,
        "median_cooldown_gap_s": round(float(np.median(cooldown_gaps_s)), 4)
        if cooldown_gaps_s
        else None,
        "cooldown_violations_count": sum(
            1 for g in cooldown_gaps_s if g < (qc_thresholds.min_cooldown_sec - 1e-4)
        ),
        "per_scan": timing_entries,
    }

    band_edges = np.geomspace(
        dsp_cfg.f_band_min_hz, dsp_cfg.f_band_max_hz, dsp_cfg.num_diff_bands + 1
    )
    band_centers_hz = [
        round(float(np.sqrt(band_edges[i] * band_edges[i + 1])), 2)
        for i in range(dsp_cfg.num_diff_bands)
    ]

    plots_manifest = {
        "sop_id": SOP_M3B_VERSION,
        "acceptance_criteria_id": ACCEPTANCE_M3B_ID,
        "bundle_dir": str(base),
        "software_build_identity": build_identity,
        "dataset_manifest_sha256": dataset_manifest_sha256,
        "threshold_config_sha256": threshold_config_sha256,
        "plots": [
            {
                "plot_id": "P1_silence_spectrum_and_hum",
                "title": "Test 3B-03 Bare-Phone Silence Floor & Narrowband Hum Review",
                "x_label": "Frequency (Hz)",
                "y_label": "Level (dBFS)",
                "series": sil_spectrum,
                "annotated_tones": hum_candidates,
            },
            {
                "plot_id": "P2_free_air_ess_resonance_profile",
                "title": "Test 3B-04 Free-Air SIG_ESS_v1 16-Band Repeatability Profile",
                "x_label": "Band Center Frequency (Hz)",
                "y_label": "Deconvolved Band Level (dB)",
                "series": {
                    "band_centers_hz": band_centers_hz,
                    "mean_bands_db": mean_bands,
                    "sd_bands_db": sd_bands,
                },
            },
            {
                "plot_id": "P3_port_occlusion_attenuation",
                "title": "Test 3B-05 Paired Port-Occlusion Active RMS Attenuation",
                "x_label": "Port Condition",
                "y_label": "Attenuation vs Unobstructed (dB)",
                "physical_path_classification": occ_path_class,
                "series": {
                    "conditions": list(occ_attenuation.keys()),
                    "attenuation_db": list(occ_attenuation.values()),
                },
            },
            {
                "plot_id": "P4_inter_scan_cooldown_gaps",
                "title": "Test 3B-08 Inter-Excitation Cooldown Gaps Across All Scans",
                "x_label": "Transition Index",
                "y_label": "Cooldown Gap (s)",
                "required_minimum_s": qc_thresholds.min_cooldown_sec,
                "series": {
                    "transition_index": list(range(1, len(cooldown_gaps_s) + 1)),
                    "cooldown_gaps_s": cooldown_gaps_s,
                },
            },
        ],
    }

    result = {
        "sop_id": SOP_M3B_VERSION,
        "acceptance_criteria_id": ACCEPTANCE_M3B_ID,
        "bundle_dir": str(base),
        "software_build_identity": build_identity,
        "dataset_manifest_sha256": dataset_manifest_sha256,
        "threshold_config_sha256": threshold_config_sha256,
        "silence_summary": silence_summary,
        "free_air_ess_summary": free_air_summary,
        "port_occlusion_summary": port_occlusion_summary,
        "timing_summary": timing_summary,
        "plots_manifest": plots_manifest,
    }

    if output_report_dir is not None:
        out = Path(output_report_dir)
        out.mkdir(parents=True, exist_ok=True)
        metrics_only = {k: v for k, v in result.items() if k != "plots_manifest"}
        (out / "m3b_audio_metrics.json").write_text(
            json.dumps(metrics_only, indent=2) + "\n", encoding="utf-8"
        )
        (out / "m3b_plots_manifest.json").write_text(
            json.dumps(plots_manifest, indent=2) + "\n", encoding="utf-8"
        )

    return result


def run_m3b_complete_verification(
    bundle_dir: Path | str,
    output_report_dir: Path | str,
) -> dict[str, Any]:
    """Execute Step 10 of CS-OPS-M3B-P1-v1.0 and verify all CS-ACC-M3B-P1-v1.0 Section B artifacts."""
    out = Path(output_report_dir)
    audit = audit_m3b_bundle(bundle_dir, output_report_dir=out)
    audio = summarize_m3b_audio(bundle_dir, output_report_dir=out)

    required_files = (
        "m3b_audit_report.json",
        "m3b_checklist.md",
        "m3b_audio_metrics.json",
        "m3b_plots_manifest.json",
    )
    missing_artifacts = [f for f in required_files if not (out / f).is_file()]
    return {
        "acceptance_criteria_id": ACCEPTANCE_M3B_ID,
        "disposition": audit["disposition"],
        "disposition_label": audit["disposition_label"],
        "disposition_reasons": audit["disposition_reasons"],
        "software_build_identity": audit["software_build_identity"],
        "dataset_manifest_sha256": audit["dataset_manifest_sha256"],
        "threshold_config_sha256": audit["threshold_config_sha256"],
        "required_artifacts_complete": len(missing_artifacts) == 0,
        "written_artifacts": {f: str(out / f) for f in required_files if (out / f).is_file()},
        "missing_artifacts": missing_artifacts,
        "port_occlusion_classification": audio["port_occlusion_summary"][
            "physical_path_classification"
        ],
    }
