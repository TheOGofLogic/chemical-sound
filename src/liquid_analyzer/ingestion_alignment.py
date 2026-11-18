"""Audio ingestion (Section 19.5) and fractional-sample cross-correlation alignment (Section 19.6)."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import numpy as np

from .waveforms import linear_to_dbfs, read_wav_float32, sha256_file


@dataclass(frozen=True)
class IngestionReport:
    """Traceable audio ingestion report (CS-SPEC-P1-v1.1 Section 19.5)."""

    filepath: str
    file_sha256: str
    actual_sample_rate_hz: int
    expected_sample_rate_hz: int
    num_channels: int
    num_frames: int
    expected_frames: int
    duration_sec: float
    has_nonfinite_values: bool
    clipped_sample_count: int
    is_clipped: bool
    peak_dbfs: float
    rms_dbfs: float
    pre_roll_rms_dbfs: float
    excitation_rms_dbfs: float
    post_roll_rms_dbfs: float
    quarantined: bool
    quarantine_reasons: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class IngestedAudio:
    """Immutable raw audio buffer, partitioned slices, and IngestionReport."""

    raw_samples: np.ndarray
    pre_roll_region: np.ndarray
    excitation_region: np.ndarray
    post_roll_region: np.ndarray
    report: IngestionReport


@dataclass(frozen=True)
class AlignmentResult:
    """Cross-correlation excitation alignment report and aligned working copy (Section 19.6)."""

    nominal_start_sample: int
    estimated_start_sample: int
    integer_delay_samples: int
    fractional_offset_samples: float
    total_delay_samples: float
    total_delay_ms: float
    normalized_peak_correlation: float
    secondary_to_primary_ratio: float
    ambiguous_alignment: bool
    aligned_working_copy: np.ndarray

    def to_report_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d.pop("aligned_working_copy", None)
        return d


def ingest_audio_file(
    path: Path | str,
    expected_sample_rate_hz: int = 48_000,
    pre_roll_samples: int = 7_200,
    active_samples: int = 9_600,
    post_roll_samples: int = 7_200,
    frame_tolerance: int = 4_800,
    clipping_ceiling_dbfs: float = -0.5,
) -> IngestedAudio:
    """Ingest lossless WAV without implicit resampling, preserve raw input, and audit integrity."""
    file_path = Path(path)
    digest = sha256_file(file_path)
    sr, samples = read_wav_float32(file_path)

    reasons: list[str] = []
    if sr != expected_sample_rate_hz:
        reasons.append("SAMPLE_RATE_MISMATCH")

    if samples.ndim == 1:
        num_channels = 1
        mono = samples.copy()
    else:
        num_channels = int(samples.shape[1])
        reasons.append("CHANNEL_CONFIGURATION_MISMATCH")
        mono = samples[:, 0].copy()

    mono.setflags(write=False)
    num_frames = int(mono.shape[0])
    expected_frames = pre_roll_samples + active_samples + post_roll_samples

    if abs(num_frames - expected_frames) > frame_tolerance:
        reasons.append("INCONSISTENT_DURATION")

    has_nonfinite = bool(not np.all(np.isfinite(mono)))
    if has_nonfinite:
        reasons.append("NONFINITE_SAMPLES")
        safe_f64 = np.nan_to_num(mono.astype(np.float64), nan=0.0, posinf=0.0, neginf=0.0)
    else:
        safe_f64 = mono.astype(np.float64)

    clip_lin = 10.0 ** (clipping_ceiling_dbfs / 20.0)
    clipped_count = int(np.sum(np.abs(safe_f64) >= clip_lin))
    is_clipped = clipped_count > 0

    peak_lin = float(np.max(np.abs(safe_f64))) if num_frames > 0 else 0.0
    rms_lin = float(np.sqrt(np.mean(safe_f64**2))) if num_frames > 0 else 0.0

    p0 = min(num_frames, pre_roll_samples)
    p1 = min(num_frames, pre_roll_samples + active_samples)
    pre_view = mono[:p0]
    exc_view = mono[p0:p1]
    post_view = mono[p1:]

    def _seg_rms_db(seg: np.ndarray) -> float:
        if seg.size == 0:
            return -120.0
        s64 = np.nan_to_num(seg.astype(np.float64), nan=0.0, posinf=0.0, neginf=0.0)
        s64 = s64 - np.mean(s64)
        return round(linear_to_dbfs(float(np.sqrt(np.mean(s64**2)))), 4)

    report = IngestionReport(
        filepath=str(file_path),
        file_sha256=digest,
        actual_sample_rate_hz=sr,
        expected_sample_rate_hz=expected_sample_rate_hz,
        num_channels=num_channels,
        num_frames=num_frames,
        expected_frames=expected_frames,
        duration_sec=round(num_frames / float(max(1, sr)), 6),
        has_nonfinite_values=has_nonfinite,
        clipped_sample_count=clipped_count,
        is_clipped=is_clipped,
        peak_dbfs=round(linear_to_dbfs(peak_lin), 4),
        rms_dbfs=round(linear_to_dbfs(rms_lin), 4),
        pre_roll_rms_dbfs=_seg_rms_db(pre_view),
        excitation_rms_dbfs=_seg_rms_db(exc_view),
        post_roll_rms_dbfs=_seg_rms_db(post_view),
        quarantined=len(reasons) > 0,
        quarantine_reasons=tuple(reasons),
    )

    return IngestedAudio(
        raw_samples=mono,
        pre_roll_region=pre_view,
        excitation_region=exc_view,
        post_roll_region=post_view,
        report=report,
    )


def apply_fractional_shift(signal: np.ndarray, shift_samples: float) -> np.ndarray:
    """Shift a working copy by -shift_samples (undoing a positive delay) via linear-phase FFT."""
    x = np.asarray(signal, dtype=np.float64)
    n = x.shape[0]
    if n == 0 or abs(shift_samples) < 1e-9:
        return x.astype(np.float32, copy=True)

    # Zero-pad to avoid circular wrap-around at signal edges
    pad = max(64, int(abs(shift_samples)) + 32)
    n_fft = 1 << (n + 2 * pad).bit_length()
    padded = np.zeros(n_fft, dtype=np.float64)
    padded[pad : pad + n] = x

    spec = np.fft.rfft(padded, n=n_fft)
    freqs_rad = 2.0 * np.pi * np.fft.rfftfreq(n_fft, d=1.0)
    # Undoing delay +tau multiplies spectrum by exp(+j * omega * tau)
    phase_ramp = np.exp(1j * freqs_rad * shift_samples)
    if n_fft % 2 == 0:
        phase_ramp[-1] = np.real(phase_ramp[-1])

    shifted = np.fft.irfft(spec * phase_ramp, n=n_fft)[pad : pad + n]
    return shifted.astype(np.float32)


def align_recording_to_reference(
    raw_recording: np.ndarray,
    active_reference: np.ndarray,
    nominal_start_sample: int,
    sample_rate_hz: int = 48_000,
    max_negative_drift_s: float = 0.005,
    max_positive_latency_s: float = 0.080,
    ambiguity_exclusion_s: float = 0.002,
    ambiguity_ratio_threshold: float = 0.72,
) -> AlignmentResult:
    """Cross-correlate recording with active reference, estimate fractional delay, and align copy."""
    rec = np.asarray(raw_recording, dtype=np.float64)
    if rec.ndim > 1:
        rec = rec[:, 0]
    ref = np.asarray(active_reference, dtype=np.float64)

    rec_zero = rec - float(np.mean(rec[: max(1, nominal_start_sample)]))
    n_rec = rec_zero.shape[0]
    n_ref = ref.shape[0]

    # Cross-correlation r_yx[lag] = sum_k y[k + lag] * ref[k] for lag >= 0
    n_fft = 1 << (n_rec + n_ref - 1).bit_length()
    Y = np.fft.rfft(rec_zero, n=n_fft)
    X = np.fft.rfft(ref, n=n_fft)
    xcorr = np.fft.irfft(Y * np.conj(X), n=n_fft)[:n_rec]

    min_lag = max(0, nominal_start_sample - int(round(max_negative_drift_s * sample_rate_hz)))
    max_lag = min(
        n_rec - 1,
        nominal_start_sample + int(round(max_positive_latency_s * sample_rate_hz)),
    )
    if max_lag <= min_lag:
        min_lag, max_lag = 0, max(1, n_rec - 1)

    abs_corr = np.abs(xcorr)
    peak_rel = int(np.argmax(abs_corr[min_lag : max_lag + 1]))
    peak_lag = min_lag + peak_rel
    peak_val = float(abs_corr[peak_lag])

    # Parabolic sub-sample peak refinement on |xcorr| (or signed xcorr around extremum)
    frac_offset = 0.0
    if 0 < peak_lag < (n_rec - 1):
        a = float(abs_corr[peak_lag - 1])
        b = float(abs_corr[peak_lag])
        c = float(abs_corr[peak_lag + 1])
        denom = a - 2.0 * b + c
        if abs(denom) > 1e-12:
            frac_offset = max(-0.5, min(0.5, 0.5 * (a - c) / denom))

    # Normalized correlation coefficient at peak_lag
    end_seg = min(n_rec, peak_lag + n_ref)
    rec_slice = rec_zero[peak_lag:end_seg]
    ref_slice = ref[: rec_slice.shape[0]]
    denom_norm = float(np.linalg.norm(rec_slice) * np.linalg.norm(ref_slice))
    norm_corr = float(abs(np.dot(rec_slice, ref_slice)) / denom_norm) if denom_norm > 1e-12 else 0.0

    # Ambiguity check: look for competing peaks outside +-ambiguity_exclusion_s
    excl = max(2, int(round(ambiguity_exclusion_s * sample_rate_hz)))
    window_corr = abs_corr[min_lag : max_lag + 1].copy()
    lo_ex = max(0, peak_rel - excl)
    hi_ex = min(window_corr.shape[0], peak_rel + excl + 1)
    window_corr[lo_ex:hi_ex] = 0.0
    second_peak = float(np.max(window_corr)) if window_corr.size > 0 else 0.0
    sec_ratio = (second_peak / peak_val) if peak_val > 1e-12 else 1.0
    ambiguous = (sec_ratio >= ambiguity_ratio_threshold) or (norm_corr < 0.15)

    int_delay = peak_lag - nominal_start_sample
    total_delay = float(int_delay) + frac_offset
    aligned_copy = apply_fractional_shift(raw_recording, total_delay)

    return AlignmentResult(
        nominal_start_sample=nominal_start_sample,
        estimated_start_sample=peak_lag,
        integer_delay_samples=int_delay,
        fractional_offset_samples=round(frac_offset, 5),
        total_delay_samples=round(total_delay, 5),
        total_delay_ms=round(1000.0 * total_delay / float(sample_rate_hz), 5),
        normalized_peak_correlation=round(norm_corr, 5),
        secondary_to_primary_ratio=round(sec_ratio, 5),
        ambiguous_alignment=ambiguous,
        aligned_working_copy=aligned_copy,
    )
