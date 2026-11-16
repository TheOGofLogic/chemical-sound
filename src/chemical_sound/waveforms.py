"""Deterministic excitation waveform generation and lossless Float32 WAV I/O.

Implements CS-SPEC-P1-v1.1 Sections 8 and 19.4:
- SIG_ESS_v1: Exponential Sine Sweep (400 Hz -> 14 kHz, 200 ms, -6 dBFS, 10 ms fades, 150 ms pre/post)
- Matched inverse filter generated directly from the actual emitted active sweep
- SIG_STEP_v1: Stepped sine bursts (500 Hz -> 8 kHz, 60 ms active + 40 ms silent decay)
- SIG_SIL_v1: Digital-zero silence control
- Optional diagnostic impulse and single-tone generators
- Time-domain & frequency-domain summary manifests, SHA-256 checksums, and alignment conventions
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import json
import math
from pathlib import Path
import struct
from typing import Any

import numpy as np

from . import SPEC_VERSION

WAVEFORM_VERSION = "WF-P1-v1.2.0"


@dataclass(frozen=True)
class ESSConfig:
    """Provisional starting parameters for SIG_ESS_v1 (v1.2 Section 6.2)."""

    signal_id: str = "SIG_ESS_v1"
    waveform_version: str = WAVEFORM_VERSION
    governance_status: str = "PROPOSED_START"
    sample_rate_hz: int = 48_000
    f1_hz: float = 400.0
    f2_hz: float = 14_000.0
    sweep_duration_s: float = 0.200
    fade_in_s: float = 0.010
    fade_out_s: float = 0.010
    pre_roll_s: float = 0.150
    post_roll_s: float = 0.150
    peak_dbfs: float = -6.0


PILOT_SWEEP_PRESETS: dict[str, ESSConfig] = {
    "ESS_200MS_SHORT_TAIL": ESSConfig(
        signal_id="SIG_ESS_200ms_v1", sweep_duration_s=0.200, post_roll_s=0.150
    ),
    "ESS_500MS_LONG_TAIL": ESSConfig(
        signal_id="SIG_ESS_500ms_v1", sweep_duration_s=0.500, post_roll_s=0.300
    ),
    "ESS_1000MS_LONG_TAIL": ESSConfig(
        signal_id="SIG_ESS_1000ms_v1", sweep_duration_s=1.000, post_roll_s=0.300
    ),
}


@dataclass(frozen=True)
class StepToneWindow:
    """Sample-accurate timing metadata for one discrete tone + free-decay step."""

    step_index: int
    frequency_hz: float
    tone_start_sample: int
    steady_start_sample: int
    tone_end_sample: int
    decay_start_sample: int
    decay_end_sample: int


@dataclass(frozen=True)
class SteppedToneConfig:
    """Provisional starting parameters for SIG_STEP_v1 (Section 8.3)."""

    signal_id: str = "SIG_STEP_v1"
    waveform_version: str = WAVEFORM_VERSION
    governance_status: str = "PROPOSED_START"
    sample_rate_hz: int = 48_000
    f_min_hz: float = 500.0
    f_max_hz: float = 8_000.0
    num_tones: int = 10
    tone_duration_s: float = 0.060
    ramp_duration_s: float = 0.005
    decay_gap_s: float = 0.040
    pre_roll_s: float = 0.150
    post_roll_s: float = 0.150
    peak_dbfs: float = -6.0


@dataclass(frozen=True)
class SilenceConfig:
    """Parameters for SIG_SIL_v1 background noise control (Section 8.4)."""

    signal_id: str = "SIG_SIL_v1"
    waveform_version: str = WAVEFORM_VERSION
    governance_status: str = "PROPOSED_START"
    sample_rate_hz: int = 48_000
    duration_s: float = 0.500


@dataclass(frozen=True)
class ESSWaveformPair:
    """Framed ESS excitation, raw active sweep, and matched inverse filter."""

    config: ESSConfig
    framed_excitation: np.ndarray
    active_sweep: np.ndarray
    inverse_filter: np.ndarray
    pre_roll_samples: int
    active_samples: int
    post_roll_samples: int
    nominal_deconv_peak_index: int


@dataclass(frozen=True)
class SteppedToneWaveform:
    """Framed stepped-tone waveform and sample windows for steady/decay analysis."""

    config: SteppedToneConfig
    framed_excitation: np.ndarray
    pre_roll_samples: int
    post_roll_samples: int
    windows: tuple[StepToneWindow, ...]


def dbfs_to_linear(dbfs: float) -> float:
    if dbfs > 0.0:
        raise ValueError(f"dBFS peak cannot exceed 0.0 dBFS, got {dbfs}")
    return float(10.0 ** (dbfs / 20.0))


def linear_to_dbfs(value: float, floor_db: float = -120.0) -> float:
    if value <= 0.0:
        return floor_db
    return max(floor_db, 20.0 * math.log10(value))


def cosine_fade_window(num_samples: int, fade_in_samples: int, fade_out_samples: int) -> np.ndarray:
    """Construct raised-cosine fade-in / fade-out envelope."""
    if fade_in_samples + fade_out_samples > num_samples:
        raise ValueError("Combined fade-in and fade-out exceed signal length.")
    window = np.ones(num_samples, dtype=np.float64)
    if fade_in_samples > 0:
        t_in = np.arange(fade_in_samples, dtype=np.float64) / float(fade_in_samples)
        window[:fade_in_samples] = 0.5 * (1.0 - np.cos(np.pi * t_in))
    if fade_out_samples > 0:
        t_out = np.arange(1, fade_out_samples + 1, dtype=np.float64) / float(fade_out_samples)
        window[-fade_out_samples:] = 0.5 * (1.0 + np.cos(np.pi * t_out))
    return window


def harmonic_lag_seconds(
    harmonic_order: int,
    sweep_duration_s: float,
    f1_hz: float,
    f2_hz: float,
) -> float:
    """Return Farina negative arrival lag (seconds relative to linear impulse t0) for k-th harmonic."""
    if harmonic_order < 2:
        raise ValueError("Harmonic order must be >= 2.")
    return -sweep_duration_s * math.log(float(harmonic_order)) / math.log(f2_hz / f1_hz)


def generate_ess_pair(config: ESSConfig = ESSConfig()) -> ESSWaveformPair:
    """Generate Farina Exponential Sine Sweep and matched inverse filter from the actual sweep."""
    sr = config.sample_rate_hz
    if config.f1_hz <= 0 or config.f2_hz <= config.f1_hz or config.f2_hz >= 0.5 * sr:
        raise ValueError("Invalid ESS frequency bounds relative to Nyquist.")

    n_active = int(round(config.sweep_duration_s * sr))
    n_pre = int(round(config.pre_roll_s * sr))
    n_post = int(round(config.post_roll_s * sr))
    n_in = int(round(config.fade_in_s * sr))
    n_out = int(round(config.fade_out_s * sr))

    t = np.arange(n_active, dtype=np.float64) / float(sr)
    T = n_active / float(sr)
    log_ratio = math.log(config.f2_hz / config.f1_hz)
    L = T / log_ratio

    phase = 2.0 * math.pi * config.f1_hz * L * (np.exp(t / L) - 1.0)
    taper = cosine_fade_window(n_active, n_in, n_out)
    amplitude = dbfs_to_linear(config.peak_dbfs)

    # Quantize emitted sweep to exact Float32 first, then build inverse filter from ACTUAL emitted waveform (Section 8.2)
    active_f32 = (amplitude * taper * np.sin(phase)).astype(np.float32)
    emitted_f64 = active_f32.astype(np.float64)

    raw_inv = emitted_f64[::-1] * np.exp(-t / L)

    n_fft = 1 << (2 * n_active - 1).bit_length()
    X = np.fft.rfft(emitted_f64, n=n_fft)
    X_inv = np.fft.rfft(raw_inv, n=n_fft)
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / sr)
    mid_low = max(config.f1_hz * 1.3, math.sqrt(config.f1_hz * config.f2_hz) * 0.5)
    mid_high = min(config.f2_hz * 0.8, math.sqrt(config.f1_hz * config.f2_hz) * 2.0)
    band_mask = (freqs >= mid_low) & (freqs <= mid_high)
    passband_gain = float(np.median(np.abs(X[band_mask] * X_inv[band_mask])))
    inv_f32 = (raw_inv / max(passband_gain, 1e-12)).astype(np.float32)

    framed = np.zeros(n_pre + n_active + n_post, dtype=np.float32)
    framed[n_pre : n_pre + n_active] = active_f32

    return ESSWaveformPair(
        config=config,
        framed_excitation=framed,
        active_sweep=active_f32,
        inverse_filter=inv_f32,
        pre_roll_samples=n_pre,
        active_samples=n_active,
        post_roll_samples=n_post,
        nominal_deconv_peak_index=n_pre + n_active - 1,
    )


def generate_stepped_tones(config: SteppedToneConfig = SteppedToneConfig()) -> SteppedToneWaveform:
    """Generate log-spaced stepped sine bursts interleaved with silent ring-down gaps."""
    sr = config.sample_rate_hz
    if config.f_min_hz <= 0 or config.f_max_hz <= config.f_min_hz or config.f_max_hz >= 0.5 * sr:
        raise ValueError("Invalid stepped-tone frequency bounds.")

    n_pre = int(round(config.pre_roll_s * sr))
    n_post = int(round(config.post_roll_s * sr))
    n_tone = int(round(config.tone_duration_s * sr))
    n_ramp = int(round(config.ramp_duration_s * sr))
    n_gap = int(round(config.decay_gap_s * sr))

    if 2 * n_ramp >= n_tone:
        raise ValueError("Tone ramp duration must be strictly less than half the tone duration.")

    freqs = np.geomspace(config.f_min_hz, config.f_max_hz, config.num_tones)
    t_tone = np.arange(n_tone, dtype=np.float64) / float(sr)
    taper = cosine_fade_window(n_tone, n_ramp, n_ramp)
    amp = dbfs_to_linear(config.peak_dbfs)

    step_len = n_tone + n_gap
    total_len = n_pre + config.num_tones * step_len + n_post
    framed = np.zeros(total_len, dtype=np.float32)
    windows: list[StepToneWindow] = []

    cursor = n_pre
    for idx, f_hz in enumerate(freqs):
        burst = (amp * taper * np.sin(2.0 * math.pi * float(f_hz) * t_tone)).astype(np.float32)
        tone_start = cursor
        tone_end = cursor + n_tone
        decay_start = tone_end
        decay_end = tone_end + n_gap
        framed[tone_start:tone_end] = burst
        windows.append(
            StepToneWindow(
                step_index=idx,
                frequency_hz=round(float(f_hz), 4),
                tone_start_sample=tone_start,
                steady_start_sample=tone_start + n_ramp,
                tone_end_sample=tone_end - n_ramp,
                decay_start_sample=decay_start,
                decay_end_sample=decay_end,
            )
        )
        cursor = decay_end

    return SteppedToneWaveform(
        config=config,
        framed_excitation=framed,
        pre_roll_samples=n_pre,
        post_roll_samples=n_post,
        windows=tuple(windows),
    )


def generate_silence_control(config: SilenceConfig = SilenceConfig()) -> np.ndarray:
    """Generate digital-zero reference waveform for SIG_SIL_v1."""
    n = int(round(config.duration_s * config.sample_rate_hz))
    return np.zeros(n, dtype=np.float32)


def generate_diagnostic_waveform(
    mode: str = "impulse",
    sample_rate_hz: int = 48_000,
    duration_s: float = 0.500,
    pre_roll_s: float = 0.150,
    frequency_hz: float = 1_000.0,
    tone_duration_s: float = 0.100,
    peak_dbfs: float = -6.0,
) -> np.ndarray:
    """Generate optional diagnostic impulse or single-frequency tone (Section 19.4)."""
    n_total = int(round(duration_s * sample_rate_hz))
    n_pre = int(round(pre_roll_s * sample_rate_hz))
    amp = dbfs_to_linear(peak_dbfs)
    out = np.zeros(n_total, dtype=np.float32)

    if mode == "impulse":
        if n_pre < n_total:
            out[n_pre] = np.float32(amp)
    elif mode == "tone":
        n_tone = min(int(round(tone_duration_s * sample_rate_hz)), max(0, n_total - n_pre))
        n_ramp = min(int(round(0.005 * sample_rate_hz)), max(0, n_tone // 4))
        t = np.arange(n_tone, dtype=np.float64) / float(sample_rate_hz)
        env = cosine_fade_window(n_tone, n_ramp, n_ramp)
        out[n_pre : n_pre + n_tone] = (amp * env * np.sin(2.0 * math.pi * frequency_hz * t)).astype(
            np.float32
        )
    else:
        raise ValueError(f"Unsupported diagnostic mode: {mode}")
    return out


def summarize_waveform_spectrum(
    samples: np.ndarray,
    sample_rate_hz: int = 48_000,
) -> dict[str, Any]:
    """Compute time-domain peak/RMS and frequency-domain octave summary (Section 19.4)."""
    x = np.asarray(samples, dtype=np.float64)
    peak_lin = float(np.max(np.abs(x))) if x.size > 0 else 0.0
    rms_lin = float(np.sqrt(np.mean(x**2))) if x.size > 0 else 0.0

    n_fft = max(4096, 1 << x.size.bit_length())
    spec = np.fft.rfft(x, n=n_fft)
    power = (np.abs(spec) ** 2) / max(1, x.size)
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / sample_rate_hz)

    octave_centers = (250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 14000.0)
    octave_db: dict[str, float] = {}
    for fc in octave_centers:
        f_lo = fc / math.sqrt(2.0)
        f_hi = min(0.49 * sample_rate_hz, fc * math.sqrt(2.0))
        mask = (freqs >= f_lo) & (freqs < f_hi)
        val = float(np.mean(power[mask])) if np.any(mask) else 0.0
        octave_db[f"{int(fc)}Hz"] = round(10.0 * math.log10(val + 1e-15), 3)

    return {
        "sample_rate_hz": sample_rate_hz,
        "num_samples": int(x.size),
        "duration_sec": round(x.size / float(sample_rate_hz), 6),
        "peak_dbfs": round(linear_to_dbfs(peak_lin), 4),
        "rms_dbfs": round(linear_to_dbfs(rms_lin), 4),
        "octave_band_power_db": octave_db,
    }


def sha256_file(path: Path | str) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_wav_float32(path: Path | str, samples: np.ndarray, sample_rate_hz: int = 48_000) -> str:
    """Write lossless IEEE Float32 WAV (format tag 3) and return SHA-256."""
    arr = np.asarray(samples, dtype=np.float32)
    if arr.ndim == 1:
        num_channels = 1
        num_frames = arr.shape[0]
        interleaved = np.ascontiguousarray(arr, dtype="<f4")
    elif arr.ndim == 2:
        num_frames, num_channels = arr.shape
        interleaved = np.ascontiguousarray(arr, dtype="<f4")
    else:
        raise ValueError("WAV array must be 1D (mono) or 2D (frames, channels).")

    bytes_per_sample = 4
    block_align = num_channels * bytes_per_sample
    byte_rate = sample_rate_hz * block_align
    pcm_bytes = interleaved.tobytes()
    data_size = len(pcm_bytes)

    fmt_chunk = struct.pack(
        "<4sIHHIIHH",
        b"fmt ",
        16,
        3,  # WAVE_FORMAT_IEEE_FLOAT
        num_channels,
        sample_rate_hz,
        byte_rate,
        block_align,
        32,
    )
    fact_chunk = struct.pack("<4sII", b"fact", 4, num_frames)
    data_header = struct.pack("<4sI", b"data", data_size)
    pad_byte = b"\x00" if (data_size % 2 == 1) else b""
    riff_size = 4 + len(fmt_chunk) + len(fact_chunk) + len(data_header) + data_size + len(pad_byte)
    riff_header = struct.pack("<4sI4s", b"RIFF", riff_size, b"WAVE")

    out_path = Path(path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("wb") as fh:
        fh.write(riff_header)
        fh.write(fmt_chunk)
        fh.write(fact_chunk)
        fh.write(data_header)
        fh.write(pcm_bytes)
        if pad_byte:
            fh.write(pad_byte)

    return sha256_file(out_path)


def read_wav_float32(path: Path | str) -> tuple[int, np.ndarray]:
    """Read lossless WAV without implicit resampling, skipping CoreAudio FLLR/JUNK chunks."""
    raw = Path(path).read_bytes()
    if len(raw) < 12 or raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ValueError(f"Not a valid RIFF/WAVE file: {path}")

    offset = 12
    fmt_tag: int | None = None
    num_channels = 0
    sample_rate = 0
    bits_per_sample = 0
    data_bytes: bytes | None = None

    while offset + 8 <= len(raw):
        chunk_id = raw[offset : offset + 4]
        chunk_size = struct.unpack_from("<I", raw, offset + 4)[0]
        body_start = offset + 8
        body_end = body_start + chunk_size
        if body_end > len(raw):
            break

        if chunk_id == b"fmt ":
            if chunk_size < 16:
                raise ValueError("Malformed fmt chunk in WAV.")
            fmt_tag, num_channels, sample_rate, _, _, bits_per_sample = struct.unpack_from(
                "<HHIIHH", raw, body_start
            )
            if fmt_tag == 0xFFFE and chunk_size >= 40:
                fmt_tag = struct.unpack_from("<H", raw, body_start + 24)[0]
        elif chunk_id == b"data":
            data_bytes = raw[body_start:body_end]

        offset = body_end + (chunk_size % 2)

    if fmt_tag is None or data_bytes is None:
        raise ValueError(f"Missing fmt or data chunk in WAV: {path}")

    if fmt_tag == 3 and bits_per_sample == 32:
        samples = np.frombuffer(data_bytes, dtype="<f4").astype(np.float32, copy=True)
    elif fmt_tag == 1 and bits_per_sample == 16:
        samples = np.frombuffer(data_bytes, dtype="<i2").astype(np.float32) / 32768.0
    elif fmt_tag == 1 and bits_per_sample == 24:
        b_arr = np.frombuffer(data_bytes, dtype=np.uint8).reshape(-1, 3)
        signed = (
            b_arr[:, 0].astype(np.int32)
            | (b_arr[:, 1].astype(np.int32) << 8)
            | (b_arr[:, 2].astype(np.int8).astype(np.int32) << 16)
        )
        samples = signed.astype(np.float32) / 8388608.0
    elif fmt_tag == 1 and bits_per_sample == 32:
        samples = np.frombuffer(data_bytes, dtype="<i4").astype(np.float32) / 2147483648.0
    else:
        raise ValueError(f"Unsupported WAV format tag={fmt_tag}, bits={bits_per_sample}")

    if num_channels > 1:
        samples = samples.reshape(-1, num_channels)
    return sample_rate, samples


def export_reference_waveform_bundle(
    output_dir: Path | str,
    ess_config: ESSConfig = ESSConfig(),
    step_config: SteppedToneConfig = SteppedToneConfig(),
    silence_config: SilenceConfig = SilenceConfig(),
) -> dict[str, Any]:
    """Write versioned reference WAV assets, inverse filter, frequency summaries, and SHA-256 manifest."""
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    ess = generate_ess_pair(ess_config)
    step = generate_stepped_tones(step_config)
    sil = generate_silence_control(silence_config)

    ess_path = out / f"{ess_config.signal_id}.wav"
    inv_path = out / f"{ess_config.signal_id}_inverse.wav"
    step_path = out / f"{step_config.signal_id}.wav"
    sil_path = out / f"{silence_config.signal_id}.wav"

    ess_sha = write_wav_float32(ess_path, ess.framed_excitation, ess_config.sample_rate_hz)
    inv_sha = write_wav_float32(inv_path, ess.inverse_filter, ess_config.sample_rate_hz)
    step_sha = write_wav_float32(step_path, step.framed_excitation, step_config.sample_rate_hz)
    sil_sha = write_wav_float32(sil_path, sil, silence_config.sample_rate_hz)

    manifest: dict[str, Any] = {
        "spec_version": SPEC_VERSION,
        "waveform_version": WAVEFORM_VERSION,
        "governance_note": "Waveform parameters are pilot starting values subject to Milestone 4 bench validation.",
        "signals": {
            ess_config.signal_id: {
                "filename": ess_path.name,
                "sha256": ess_sha,
                "waveform_version": ess_config.waveform_version,
                "pre_roll_samples": ess.pre_roll_samples,
                "active_samples": ess.active_samples,
                "post_roll_samples": ess.post_roll_samples,
                "inverse_filter_filename": inv_path.name,
                "inverse_filter_sha256": inv_sha,
                "deconvolution_alignment_convention": {
                    "operation": "full_linear_convolution(aligned_recording, inverse_filter)",
                    "zero_delay_peak_index": ess.nominal_deconv_peak_index,
                    "formula": "pre_roll_samples + active_samples - 1 + residual_delay_samples",
                },
                "summary": summarize_waveform_spectrum(
                    ess.framed_excitation, ess_config.sample_rate_hz
                ),
                "config": asdict(ess_config),
            },
            step_config.signal_id: {
                "filename": step_path.name,
                "sha256": step_sha,
                "waveform_version": step_config.waveform_version,
                "pre_roll_samples": step.pre_roll_samples,
                "post_roll_samples": step.post_roll_samples,
                "summary": summarize_waveform_spectrum(
                    step.framed_excitation, step_config.sample_rate_hz
                ),
                "config": asdict(step_config),
                "windows": [asdict(w) for w in step.windows],
            },
            silence_config.signal_id: {
                "filename": sil_path.name,
                "sha256": sil_sha,
                "waveform_version": silence_config.waveform_version,
                "summary": summarize_waveform_spectrum(sil, silence_config.sample_rate_hz),
                "config": asdict(silence_config),
            },
        },
    }

    manifest_path = out / "waveform_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def export_swift_assets_bundle(
    output_dir: Path | str,
    ess_config: ESSConfig = ESSConfig(),
    step_config: SteppedToneConfig = SteppedToneConfig(),
) -> dict[str, Any]:
    """Export unpadded active WAV assets + SHA-256 waveform_manifest.json for the Swift iOS app.

    The Swift AcquisitionCoordinator captures preRollMs (150 ms), plays the active asset via
    AVAudioPlayerNode, and captures postRollMs (150 ms), yielding a 500 ms (ESS) or 1300 ms (STEP)
    lossless recording directly compatible with Python ingest_audio_file().
    """
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    ess = generate_ess_pair(ess_config)
    step = generate_stepped_tones(step_config)
    active_step = step.framed_excitation[
        step.pre_roll_samples : step.framed_excitation.shape[0] - step.post_roll_samples
    ]
    active_sil = np.zeros(ess.active_samples, dtype=np.float32)

    ess_path = out / "SIG_ESS_v1.wav"
    inv_path = out / "SIG_ESS_v1_inverse.wav"
    step_path = out / "SIG_STEP_v1.wav"
    sil_path = out / "SIG_SIL_v1.wav"

    ess_sha = write_wav_float32(ess_path, ess.active_sweep, ess_config.sample_rate_hz)
    inv_sha = write_wav_float32(inv_path, ess.inverse_filter, ess_config.sample_rate_hz)
    step_sha = write_wav_float32(step_path, active_step, step_config.sample_rate_hz)
    sil_sha = write_wav_float32(sil_path, active_sil, ess_config.sample_rate_hz)

    sr = ess_config.sample_rate_hz
    manifest: dict[str, Any] = {
        "manifest_version": "1.2.0",
        "protocol_id": "CS-P1-v1.2",
        "spec_version": SPEC_VERSION,
        "waveform_version": WAVEFORM_VERSION,
        "sample_rate_hz": sr,
        "assets": [
            {
                "asset_id": "SIG_ESS_v1",
                "role": "excitation",
                "filename": ess_path.name,
                "sha256": ess_sha,
                "duration_ms": int(round(1000.0 * ess.active_sweep.shape[0] / sr)),
                "num_frames": int(ess.active_sweep.shape[0]),
                "channels": 1,
                "format": "PCM_FLOAT32",
            },
            {
                "asset_id": "SIG_ESS_v1_inverse",
                "role": "inverse_filter",
                "filename": inv_path.name,
                "sha256": inv_sha,
                "duration_ms": int(round(1000.0 * ess.inverse_filter.shape[0] / sr)),
                "num_frames": int(ess.inverse_filter.shape[0]),
                "channels": 1,
                "format": "PCM_FLOAT32",
            },
            {
                "asset_id": "SIG_STEP_v1",
                "role": "excitation",
                "filename": step_path.name,
                "sha256": step_sha,
                "duration_ms": int(round(1000.0 * active_step.shape[0] / sr)),
                "num_frames": int(active_step.shape[0]),
                "channels": 1,
                "format": "PCM_FLOAT32",
            },
            {
                "asset_id": "SIG_SIL_v1",
                "role": "silence_control",
                "filename": sil_path.name,
                "sha256": sil_sha,
                "duration_ms": int(round(1000.0 * active_sil.shape[0] / sr)),
                "num_frames": int(active_sil.shape[0]),
                "channels": 1,
                "format": "PCM_FLOAT32",
            },
        ],
    }

    manifest_path = out / "waveform_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest
