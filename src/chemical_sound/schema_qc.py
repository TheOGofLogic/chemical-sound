"""CSRD-P1 v1.2 metadata schema, two-stage QC lifecycle, and cooldown/boundary validation.

Implements CS-SPEC-P1-v1.2 Sections 3, 4.3, 5.3, 6.1, and 8:
- Acquisition QC states: PROVISIONALLY_ACCEPTED, REJECTED, INTERRUPTED, INCOMPLETE
- Two-stage session calibration promotion: SESSION_VALID -> FINAL_ACCEPTED vs. SESSION_DRIFT_INVALIDATED
- Hardware domain segregation: IPHONE_NATIVE vs. EXTERNAL_TRANSDUCER_DIAGNOSTIC
- Tightened boundary fields: fill_height_mm, headspace_height_mm, cap_closure_state, K1 attachment, temp SOP
- Hard inter-excitation cooldown invariant: t_next_start >= t_prev_end + cooldown_sec
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, fields
import json
import math
from pathlib import Path
from typing import Any

import numpy as np

from . import DATASET_VERSION, SPEC_VERSION
from .waveforms import WAVEFORM_VERSION


ACQUISITION_QC_STATES = frozenset(
    {"PROVISIONALLY_ACCEPTED", "REJECTED", "INTERRUPTED", "INCOMPLETE"}
)
SESSION_VALIDITY_STATES = frozenset(
    {"SESSION_OPEN", "SESSION_VALID", "SESSION_DRIFT_INVALIDATED"}
)
HARDWARE_DOMAINS = frozenset({"IPHONE_NATIVE", "EXTERNAL_TRANSDUCER_DIAGNOSTIC"})

ALL_QC_FLAGS = frozenset(
    {
        "BACKGROUND_NOISE",
        "CLIPPING",
        "INTERRUPTED_AUDIO",
        "LOW_SIGNAL",
        "POSITION_NOT_CONFIRMED",
        "TEMPERATURE_MISSING",
        "PROTOCOL_MISMATCH",
        "VOLUME_MISMATCH",
        "AUDIO_ROUTE_INVALID",
        "SAMPLE_RATE_MISMATCH",
        "CHANNEL_CONFIGURATION_MISMATCH",
        "INPUT_DATASOURCE_MISMATCH",
        "HIGH_INTRA_BATCH_VARIANCE",
        "INSUFFICIENT_SETTLE_TIME",
        "VISIBLE_BUBBLES",
        "FIXTURE_FORCE_MISMATCH",
        "COOLDOWN_VIOLATION",
        "CALIBRATION_DRIFT",
        "FILE_WRITE_FAILURE",
        "METADATA_INCOMPLETE",
    }
)

VALID_SCAN_STAGES = frozenset({"GATE_0A", "GATE_0B", "BLANK", "P1A", "P1B", "P1C", "P1D"})
VALID_FIXTURE_MODES = frozenset({"MODE_B", "MODE_A"})
FORBIDDEN_PORT_KEYWORDS = (
    "bluetooth",
    "airpods",
    "headphone",
    "headset",
    "usb",
    "carplay",
    "airplay",
    "hdmi",
    "lineout",
)


@dataclass(frozen=True)
class QCThresholds:
    """QC cutoffs separating pilot starting values from pilot-derived thresholds."""

    expected_sample_rate_hz: int = 48_000
    expected_audio_mode: str = "measurement"
    expected_input_channels: int = 1
    volume_tolerance: float = 0.01
    clipping_ceiling_dbfs: float = -0.5
    max_pre_roll_excess_db: float = 6.0
    default_max_pre_roll_rms_dbfs: float = -50.0
    min_active_snr_db: float = 12.0
    min_settle_duration_sec: float = 180.0
    min_cooldown_sec: float = 2.0
    calibration_drift_limit_db: float = 1.5


@dataclass
class ScanRecord:
    """Complete CSRD-P1 v1.2 acquisition metadata record (explicit JSON null for missing values)."""

    dataset_version: str = DATASET_VERSION
    protocol_version: str = SPEC_VERSION
    waveform_version: str = WAVEFORM_VERSION
    hardware_domain: str = "IPHONE_NATIVE"
    study_id: str | None = None
    session_id: str | None = None
    operator_id: str | None = None
    scan_stage: str | None = None
    sample_id: str | None = None
    blind_code: str | None = None
    is_blinded_run: bool | None = None
    liquid_class: str | None = None
    formulation_id: str | None = None
    preparation_batch_id: str | None = None
    concentration_value: float | None = None
    concentration_unit: str | None = None
    preparation_method: str | None = None
    preparation_timestamp: str | None = None
    fill_timestamp: str | None = None
    scan_timestamp: str | None = None
    container_type: str | None = None
    container_product_number: str | None = None
    container_lot: str | None = None
    container_id: str | None = None
    is_held_out_container: bool | None = False
    cap_closure_state: str | None = None
    bubble_foam_flag: str | None = None
    position_confirmed: bool | None = True
    nominal_volume_ml: float | None = None
    measured_mass_g: float | None = None
    fill_height_mm: float | None = None
    headspace_height_mm: float | None = None
    sample_temperature_c: float | None = None
    temp_measurement_method: str | None = None
    temp_measurement_timing: str | None = None
    ambient_temperature_c: float | None = None
    ambient_humidity_pct: float | None = None
    sample_rest_duration_sec: float | None = None
    room_identifier: str | None = None
    fixture_version: str | None = None
    fixture_mode: str | None = None
    coupling_force_setting: str | None = None
    expected_coupling_force_setting: str | None = None
    added_deadweight_g: float | None = None
    deadweight_attachment_location: str | None = None
    deadweight_method: str | None = None
    iphone_model: str | None = None
    hardware_model_identifier: str | None = None
    ios_version: str | None = None
    app_version: str | None = None
    device_code: str | None = None
    case_status: str | None = None
    battery_level: float | None = None
    charging_state: str | None = None
    thermal_state: str | None = None
    device_orientation: str | None = None
    requested_audio_mode: str | None = None
    verified_audio_mode: str | None = None
    requested_sample_rate_hz: int | None = None
    verified_sample_rate_hz: int | None = None
    selected_input_port: str | None = None
    verified_input_port: str | None = None
    selected_mic_datasource: str | None = None
    verified_mic_datasource: str | None = None
    selected_polar_pattern: str | None = None
    verified_polar_pattern: str | None = None
    verified_output_port: str | None = None
    input_channel_count: int | None = 1
    output_channel_count: int | None = 1
    reported_speaker_channel_mapping: str | None = None
    target_hardware_volume: float | None = None
    pre_scan_hardware_volume: float | None = None
    post_scan_hardware_volume: float | None = None
    software_waveform_amplitude_dbfs: float | None = -6.0
    input_latency_sec: float | None = None
    output_latency_sec: float | None = None
    io_buffer_duration_sec: float | None = None
    route_profile_verified: bool | None = None
    excitation_signal_id: str | None = None
    excitation_wav_sha256: str | None = None
    recording_format: str | None = "WAV_IEEE_FLOAT32"
    repetition_number: int | None = None
    excitation_start_host_time_s: float | None = None
    excitation_end_host_time_s: float | None = None
    cooldown_sec: float | None = None
    peak_dbfs: float | None = None
    pre_roll_rms_dbfs: float | None = None
    quality_status: str | None = None  # PROVISIONALLY_ACCEPTED | REJECTED | INTERRUPTED | INCOMPLETE
    session_validity_state: str | None = None  # SESSION_OPEN | SESSION_VALID | SESSION_DRIFT_INVALIDATED
    final_scan_validity: str | None = None  # FINAL_ACCEPTED | INVALID_MEASUREMENT
    quality_flags: list[str] | None = None
    raw_audio_filename: str | None = None
    raw_audio_sha256: str | None = None
    feature_record_id: str | None = None
    calibration_id: str | None = None
    operator_notes: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "ScanRecord":
        valid_names = {f.name for f in fields(cls)}
        unknown = set(payload.keys()) - valid_names
        if unknown:
            raise ValueError(f"Unknown CSRD-P1 metadata fields: {sorted(unknown)}")
        return cls(**{k: payload.get(k, None) for k in valid_names})


REQUIRED_CORE_FIELDS = (
    "study_id",
    "session_id",
    "operator_id",
    "scan_stage",
    "sample_id",
    "fixture_mode",
    "hardware_model_identifier",
    "device_code",
    "requested_sample_rate_hz",
    "verified_sample_rate_hz",
    "requested_audio_mode",
    "verified_audio_mode",
    "verified_input_port",
    "verified_output_port",
    "excitation_signal_id",
    "repetition_number",
    "raw_audio_filename",
)


def compute_dbfs(value: float, floor_db: float = -120.0) -> float:
    if value <= 0.0:
        return floor_db
    return max(floor_db, 20.0 * math.log10(value))


def verify_inter_excitation_cooldown(
    prev_excitation_end_s: float,
    next_excitation_start_s: float,
    min_cooldown_sec: float = 2.0,
) -> bool:
    """Enforce v1.2 Section 8.1 timing invariant: t_next_start >= t_prev_end + cooldown_sec."""
    return (next_excitation_start_s - prev_excitation_end_s) >= (min_cooldown_sec - 1e-6)


def resolve_session_scan_validity(
    acquisition_qc_state: str,
    session_validity_state: str,
) -> str:
    """Promote PROVISIONALLY_ACCEPTED to FINAL_ACCEPTED only when SESSION_VALID (v1.2 Section 8.2)."""
    if acquisition_qc_state in ("PROVISIONALLY_ACCEPTED", "PASS"):
        if session_validity_state == "SESSION_VALID":
            return "FINAL_ACCEPTED"
        if session_validity_state == "SESSION_OPEN":
            return "PROVISIONALLY_ACCEPTED"
    return "INVALID_MEASUREMENT"


def evaluate_scan_qc(
    record: ScanRecord,
    recording: np.ndarray | None,
    pre_roll_samples: int,
    active_samples: int,
    thresholds: QCThresholds = QCThresholds(),
    silence_baseline_rms_dbfs: float | None = None,
    prev_excitation_end_host_time_s: float | None = None,
    is_silence_control: bool = False,
    is_liquid_sample: bool = True,
    expected_protocol_version: str = SPEC_VERSION,
) -> tuple[str, list[str], float, float]:
    """Evaluate v1.2 acquisition QC state (PROVISIONALLY_ACCEPTED | REJECTED | INTERRUPTED | INCOMPLETE)."""
    flags: list[str] = []

    if recording is None:
        return "INCOMPLETE", ["FILE_WRITE_FAILURE"], -120.0, -120.0

    if record.protocol_version != expected_protocol_version or (
        record.hardware_domain not in HARDWARE_DOMAINS
    ):
        flags.append("PROTOCOL_MISMATCH")

    missing_core = [f for f in REQUIRED_CORE_FIELDS if getattr(record, f) is None]
    if is_liquid_sample and not is_silence_control:
        if record.sample_temperature_c is None:
            flags.append("TEMPERATURE_MISSING")
        for req_f in ("container_id", "nominal_volume_ml", "measured_mass_g"):
            if getattr(record, req_f) is None:
                missing_core.append(req_f)
        if not record.is_blinded_run and (
            record.formulation_id is None or record.preparation_batch_id is None
        ):
            missing_core.append("formulation_or_batch_id")

    if missing_core or (record.scan_stage not in VALID_SCAN_STAGES) or (
        record.fixture_mode not in VALID_FIXTURE_MODES
    ):
        flags.append("METADATA_INCOMPLETE")

    if record.position_confirmed is False:
        flags.append("POSITION_NOT_CONFIRMED")

    if (
        record.expected_coupling_force_setting is not None
        and record.coupling_force_setting is not None
        and record.coupling_force_setting != record.expected_coupling_force_setting
    ):
        flags.append("FIXTURE_FORCE_MISMATCH")

    # Inter-excitation cooldown check (v1.2 Section 8.1)
    if (
        prev_excitation_end_host_time_s is not None
        and record.excitation_start_host_time_s is not None
        and not verify_inter_excitation_cooldown(
            prev_excitation_end_host_time_s,
            record.excitation_start_host_time_s,
            min_cooldown_sec=thresholds.min_cooldown_sec,
        )
    ):
        flags.append("COOLDOWN_VIOLATION")

    if (
        record.verified_sample_rate_hz != thresholds.expected_sample_rate_hz
        or record.requested_sample_rate_hz != thresholds.expected_sample_rate_hz
    ):
        flags.append("SAMPLE_RATE_MISMATCH")

    arr = np.asarray(recording, dtype=np.float64)
    actual_channels = 1 if arr.ndim == 1 else int(arr.shape[1])
    if (
        actual_channels != thresholds.expected_input_channels
        or (
            record.input_channel_count is not None
            and record.input_channel_count != thresholds.expected_input_channels
        )
    ):
        flags.append("CHANNEL_CONFIGURATION_MISMATCH")

    if record.hardware_domain == "IPHONE_NATIVE":
        in_port = (record.verified_input_port or "").lower()
        out_port = (record.verified_output_port or "").lower()
        mode_ok = (record.verified_audio_mode or "").lower() == thresholds.expected_audio_mode.lower()
        forbidden_route = any(kw in in_port or kw in out_port for kw in FORBIDDEN_PORT_KEYWORDS)
        built_in_ok = (
            "built-in" in in_port or "microphone" in in_port or "iphone" in in_port
        ) and ("speaker" in out_port or "built-in" in out_port)
        if (
            (not mode_ok)
            or forbidden_route
            or (not built_in_ok)
            or (record.route_profile_verified is False)
        ):
            flags.append("AUDIO_ROUTE_INVALID")

    if (
        record.selected_mic_datasource is not None
        and record.verified_mic_datasource is not None
        and record.selected_mic_datasource != record.verified_mic_datasource
    ):
        flags.append("INPUT_DATASOURCE_MISMATCH")

    if not is_silence_control:
        if (
            record.target_hardware_volume is None
            or record.pre_scan_hardware_volume is None
            or record.post_scan_hardware_volume is None
        ):
            if "METADATA_INCOMPLETE" not in flags:
                flags.append("METADATA_INCOMPLETE")
        else:
            pre_diff = abs(record.pre_scan_hardware_volume - record.target_hardware_volume)
            post_diff = abs(record.post_scan_hardware_volume - record.target_hardware_volume)
            if pre_diff > thresholds.volume_tolerance or post_diff > thresholds.volume_tolerance:
                flags.append("VOLUME_MISMATCH")

    if is_liquid_sample and not is_silence_control:
        foam_flag = (record.bubble_foam_flag or "").upper()
        if foam_flag in ("VISIBLE_FOAM", "VISIBLE_BUBBLES"):
            flags.append("VISIBLE_BUBBLES")
        if (
            record.sample_rest_duration_sec is not None
            and record.sample_rest_duration_sec < thresholds.min_settle_duration_sec
        ):
            flags.append("INSUFFICIENT_SETTLE_TIME")

    mono = arr if arr.ndim == 1 else arr[:, 0]
    if mono.size == 0 or not np.all(np.isfinite(mono)):
        flags.append("FILE_WRITE_FAILURE")
        return "INCOMPLETE", flags, -120.0, -120.0

    peak_lin = float(np.max(np.abs(mono)))
    peak_dbfs = round(compute_dbfs(peak_lin), 3)

    pre_seg = mono[: max(1, pre_roll_samples)] if pre_roll_samples > 0 else mono[:480]
    pre_seg = pre_seg - np.mean(pre_seg)
    pre_rms_lin = float(np.sqrt(np.mean(pre_seg**2))) if pre_seg.size > 0 else 0.0
    pre_roll_rms_dbfs = round(compute_dbfs(pre_rms_lin), 3)

    if peak_dbfs >= thresholds.clipping_ceiling_dbfs:
        flags.append("CLIPPING")

    if not is_silence_control:
        if mono.size < (pre_roll_samples + active_samples):
            flags.append("INTERRUPTED_AUDIO")
            return "INTERRUPTED", flags, peak_dbfs, pre_roll_rms_dbfs

        noise_limit_dbfs = (
            silence_baseline_rms_dbfs + thresholds.max_pre_roll_excess_db
            if (silence_baseline_rms_dbfs is not None and silence_baseline_rms_dbfs > -95.0)
            else thresholds.default_max_pre_roll_rms_dbfs
        )
        if pre_roll_rms_dbfs > noise_limit_dbfs:
            flags.append("BACKGROUND_NOISE")

        act_seg = mono[pre_roll_samples : pre_roll_samples + active_samples]
        act_seg = act_seg - np.mean(act_seg)
        act_rms_dbfs = compute_dbfs(float(np.sqrt(act_seg.dot(act_seg) / max(1, act_seg.size))))
        if (act_rms_dbfs - pre_roll_rms_dbfs) < thresholds.min_active_snr_db:
            flags.append("LOW_SIGNAL")

    if not flags:
        return "PROVISIONALLY_ACCEPTED", [], peak_dbfs, pre_roll_rms_dbfs

    if "INTERRUPTED_AUDIO" in flags:
        return "INTERRUPTED", flags, peak_dbfs, pre_roll_rms_dbfs
    if set(flags) <= {"METADATA_INCOMPLETE", "TEMPERATURE_MISSING", "FILE_WRITE_FAILURE"}:
        return "INCOMPLETE", flags, peak_dbfs, pre_roll_rms_dbfs
    return "REJECTED", flags, peak_dbfs, pre_roll_rms_dbfs


def detect_intra_batch_outliers(
    repetition_spectra_db: np.ndarray,
    outlier_mad_multiplier: float = 3.5,
    min_spread_floor_db: float = 0.75,
) -> tuple[np.ndarray, np.ndarray]:
    """Compute pairwise spectral distance from repetition median and flag outlier scans."""
    specs = np.asarray(repetition_spectra_db, dtype=np.float64)
    if specs.ndim != 2 or specs.shape[0] == 0:
        raise ValueError("repetition_spectra_db must have shape (n_reps, n_bands).")
    if specs.shape[0] < 3:
        return np.zeros(specs.shape[0], dtype=np.float64), np.zeros(specs.shape[0], dtype=bool)

    median_spec = np.median(specs, axis=0)
    rms_dev = np.sqrt(np.mean((specs - median_spec) ** 2, axis=1))
    med_dev = float(np.median(rms_dev))
    mad = float(np.median(np.abs(rms_dev - med_dev))) * 1.4826
    cutoff = max(
        med_dev + outlier_mad_multiplier * max(mad, min_spread_floor_db * 0.25),
        min_spread_floor_db,
    )
    return rms_dev, rms_dev > cutoff


def write_scans_jsonl(path: Path | str, records: list[ScanRecord]) -> None:
    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as fh:
        for rec in records:
            fh.write(json.dumps(rec.to_dict(), sort_keys=False) + "\n")


def read_scans_jsonl(path: Path | str) -> list[ScanRecord]:
    records: list[ScanRecord] = []
    with Path(path).open("r", encoding="utf-8") as fh:
        for line_no, line in enumerate(fh, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                payload = json.loads(stripped)
            except json.JSONDecodeError as exc:
                raise ValueError(f"Invalid JSON on line {line_no} of {path}: {exc}") from exc
            records.append(ScanRecord.from_dict(payload))
    return records
