"""ESS deconvolution, stepped-tone analysis, calibration normalization, and feature extraction.

Implements CS-SPEC-P1-v1.1 Sections 15, 16, 19.7, 19.8, 19.9, 19.10, and 19.11:
- ESS deconvolution with recorded gate sample bounds and complete impulse export
- Full stepped-tone analysis (amplitude, noise floor, ring-down, slope, peak freq/width, SNR, THD, validity)
- Regularized transfer-function estimation and beginning-vs-ending calibration drift evaluation
- Versioned FeatureSpec registry (name, unit, definition, source region, missing rule, QC dependency)
- Compact primary feature vector (d = 25 <= 25, including 16 log-spaced differential band energies)
- Isolated Nuisance-Only feature vector (pre-roll background + initial direct-path region only)
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import math
from typing import Any

import numpy as np

from .ingestion_alignment import align_recording_to_reference
from .schema_qc import compute_dbfs, detect_intra_batch_outliers
from .waveforms import ESSWaveformPair, SteppedToneWaveform, harmonic_lag_seconds

FEATURE_SCHEMA_VERSION = "FEAT-P1-v1.2.0"


@dataclass(frozen=True)
class FeatureSpec:
    """Formal 3-tier feature metadata contract (v1.2 Section 7)."""

    name: str
    unit: str
    mathematical_definition: str
    source_region: str
    missing_value_rule: str
    qc_dependency: str
    tier: str = "TIER_2_FROZEN_VECTOR"  # TIER_1_CANDIDATE | TIER_2_FROZEN_VECTOR | TIER_3_QC_DIAGNOSTIC
    version: str = FEATURE_SCHEMA_VERSION


@dataclass(frozen=True)
class DSPConfig:
    """Configuration-driven gate boundaries and spectral settings (provisional pilot defaults)."""

    sample_rate_hz: int = 48_000
    use_pre_alignment: bool = True
    pre_arrival_guard_s: float = 0.0005
    direct_path_end_s: float = 0.0018
    resonance_tail_end_s: float = 0.0450
    late_room_end_s: float = 0.1200
    gate_taper_s: float = 0.0004
    harmonic_half_window_s: float = 0.0040
    max_causal_latency_s: float = 0.0600
    f_band_min_hz: float = 450.0
    f_band_max_hz: float = 12_000.0
    num_diff_bands: int = 16  # Section 19.10: 16 to 24 log-spaced differential bands
    num_nuisance_bands: int = 6
    num_modal_peaks_catalog: int = 4
    num_modal_peaks_primary: int = 3  # Keeps 16 + 3*2 + 3 = 25 primary features (<= 25)
    min_peak_prominence_db: float = 1.0
    modal_n_fft: int = 16_384
    transfer_regularization_eps: float = 1e-6
    spectral_floor_eps: float = 1e-12


@dataclass(frozen=True)
class GateWindowBounds:
    """Sample index locations of all deconvolution analysis windows (Section 19.7)."""

    t0_index: int
    harmonic_2_bounds: tuple[int, int]
    harmonic_3_bounds: tuple[int, int]
    direct_path_bounds: tuple[int, int]
    resonance_tail_bounds: tuple[int, int]
    late_room_bounds: tuple[int, int]


@dataclass(frozen=True)
class DeconvolvedGates:
    """Deconvolved ESS impulse response, recorded window bounds, and isolated gate arrays."""

    impulse_full: np.ndarray
    t0_index: int
    latency_samples: int
    alignment_delay_samples: float
    ambiguous_alignment: bool
    normalized_xcorr_peak: float
    window_bounds: GateWindowBounds
    h_harmonic_2: np.ndarray
    h_harmonic_3: np.ndarray
    h_direct_path: np.ndarray
    h_resonance_tail: np.ndarray
    h_late_room: np.ndarray
    direct_to_tail_ratio_db: float
    harmonic_ratio_db: float
    late_room_snr_db: float


@dataclass(frozen=True)
class ModalPeak:
    """Modal peak frequency, magnitude, prominence, -3 dB width, and Q-factor."""

    frequency_hz: float
    magnitude_db: float
    prominence_db: float
    bandwidth_3db_hz: float
    q_factor: float


@dataclass(frozen=True)
class SteppedToneMetric:
    """Per-tone stepped-excitation diagnostic & decay record (Section 19.8)."""

    step_index: int
    nominal_frequency_hz: float
    active_amplitude_dbfs: float
    noise_floor_dbfs: float
    post_tone_ringdown_dbfs: float
    decay_slope_db_per_s: float
    peak_frequency_hz: float
    peak_width_hz: float
    snr_db: float
    harmonic_distortion_db: float
    is_valid_decay: bool


@dataclass(frozen=True)
class ScanFeatureResult:
    """Primary compact features (d=25), full candidate catalog, nuisance vector, and diagnostics."""

    compact_features: np.ndarray
    compact_feature_names: tuple[str, ...]
    candidate_catalog: dict[str, float]
    nuisance_features: np.ndarray
    nuisance_feature_names: tuple[str, ...]
    raw_resonance_bands_db: np.ndarray
    modal_peaks: tuple[ModalPeak, ...]
    ringdown_slopes_db_per_s: tuple[float, float, float]
    t20_estimates_ms: tuple[float, float, float]
    direct_to_tail_ratio_db: float
    harmonic_ratio_db: float
    water_cal_distance_db: float
    empty_cal_distance_db: float
    t0_latency_ms: float
    alignment_delay_ms: float
    normalized_xcorr_peak: float
    late_room_snr_db: float
    window_bounds: GateWindowBounds


def get_primary_feature_registry(config: DSPConfig = DSPConfig()) -> tuple[FeatureSpec, ...]:
    """Return formal Section 19.10 registry for the 25 primary features."""
    specs: list[FeatureSpec] = []
    edges = np.geomspace(config.f_band_min_hz, config.f_band_max_hz, config.num_diff_bands + 1)
    for b in range(config.num_diff_bands):
        specs.append(
            FeatureSpec(
                name=f"diff_band_db_{b:02d}",
                unit="dB",
                mathematical_definition=(
                    f"10*log10(P_sample[{edges[b]:.0f}-{edges[b+1]:.0f}Hz]) - "
                    f"10*log10(P_water_cal[{edges[b]:.0f}-{edges[b+1]:.0f}Hz])"
                ),
                source_region="ESS Resonance-Tail Gate",
                missing_value_rule="Quarantine scan if water calibration missing unless self-centered pilot mode enabled",
                qc_dependency="PASS & valid session water calibration",
            )
        )
    for k in range(config.num_modal_peaks_primary):
        specs.append(
            FeatureSpec(
                name=f"modal_freq_khz_{k}",
                unit="kHz",
                mathematical_definition=f"Parabolic-interpolated frequency of modal peak #{k} ordered by frequency among top prominent peaks",
                source_region="ESS Resonance-Tail Gate",
                missing_value_rule="0.0 kHz when fewer than k+1 peaks exceed min_peak_prominence_db",
                qc_dependency="PASS",
            )
        )
    for k in range(config.num_modal_peaks_primary):
        specs.append(
            FeatureSpec(
                name=f"modal_q_{k}",
                unit="dimensionless",
                mathematical_definition=f"f_peak_{k} / bandwidth_-3dB_{k}",
                source_region="ESS Resonance-Tail Gate",
                missing_value_rule="0.0 when peak absent",
                qc_dependency="PASS",
            )
        )
    specs.append(
        FeatureSpec(
            name="ringdown_slope_mid_100db_s",
            unit="100 dB/s",
            mathematical_definition="Schroeder backward-integrated EDC linear regression slope (-2 to -22 dB) in mid modal sub-band divided by 100",
            source_region="ESS Resonance-Tail Gate",
            missing_value_rule="0.0 when tail energy below noise floor",
            qc_dependency="PASS",
        )
    )
    specs.append(
        FeatureSpec(
            name="direct_to_tail_ratio_db",
            unit="dB",
            mathematical_definition="10*log10(E_direct_path / E_resonance_tail)",
            source_region="ESS Direct-Path & Resonance-Tail Gates",
            missing_value_rule="Quarantine on zero tail energy",
            qc_dependency="PASS",
        )
    )
    specs.append(
        FeatureSpec(
            name="water_cal_distance_db",
            unit="dB",
            mathematical_definition="RMS L2 differential band distance from session distilled-water reference",
            source_region="ESS Resonance-Tail Gate",
            missing_value_rule="RMS of self-centered spectrum if water reference unavailable",
            qc_dependency="PASS & valid session water calibration",
        )
    )
    return tuple(specs)


def _apply_edge_taper(segment: np.ndarray, taper_samples: int) -> np.ndarray:
    n = segment.shape[0]
    if n == 0 or taper_samples <= 0:
        return segment.copy()
    t_len = min(taper_samples, n // 2)
    if t_len == 0:
        return segment.copy()
    win = np.ones(n, dtype=np.float64)
    ramp = 0.5 * (1.0 - np.cos(np.pi * np.arange(t_len, dtype=np.float64) / float(t_len)))
    win[:t_len] = ramp
    win[-t_len:] = ramp[::-1]
    return segment * win


def estimate_regularized_transfer_function(
    aligned_recording: np.ndarray,
    framed_excitation: np.ndarray,
    sample_rate_hz: int = 48_000,
    regularization_eps: float = 1e-6,
) -> tuple[np.ndarray, np.ndarray]:
    """Compute regularized frequency-domain transfer function H(f) = Y*conj(X) / (|X|^2 + eps) (Section 19.9)."""
    y = np.asarray(aligned_recording, dtype=np.float64)
    x = np.asarray(framed_excitation, dtype=np.float64)
    n_fft = 1 << max(y.size, x.size).bit_length()
    Y = np.fft.rfft(y, n=n_fft)
    X = np.fft.rfft(x, n=n_fft)
    denom = (np.abs(X) ** 2) + regularization_eps * float(np.max(np.abs(X) ** 2) + 1e-15)
    H = (Y * np.conj(X)) / denom
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / sample_rate_hz)
    return freqs, H


def deconvolve_ess_recording(
    recording: np.ndarray,
    ess_pair: ESSWaveformPair,
    config: DSPConfig = DSPConfig(),
) -> DeconvolvedGates:
    """Align recording (working copy), deconvolve with matched inverse filter, and extract 4 gates."""
    mono = np.asarray(recording, dtype=np.float64)
    if mono.ndim > 1:
        mono = mono[:, 0]

    sr = config.sample_rate_hz
    n_pre = ess_pair.pre_roll_samples
    inv = np.asarray(ess_pair.inverse_filter, dtype=np.float64)

    if config.use_pre_alignment:
        align_res = align_recording_to_reference(
            mono,
            ess_pair.active_sweep,
            nominal_start_sample=n_pre,
            sample_rate_hz=sr,
            max_positive_latency_s=config.max_causal_latency_s,
        )
        working = align_res.aligned_working_copy.astype(np.float64)
        align_delay = align_res.total_delay_samples
        ambiguous = align_res.ambiguous_alignment
        xcorr_peak = align_res.normalized_peak_correlation
    else:
        working = mono.copy()
        align_delay = 0.0
        ambiguous = False
        xcorr_peak = 1.0

    pre_mean = float(np.mean(working[: max(1, n_pre)]))
    y = working - pre_mean

    n_conv = y.shape[0] + inv.shape[0] - 1
    n_fft = 1 << n_conv.bit_length()
    h_full = np.fft.irfft(np.fft.rfft(y, n=n_fft) * np.fft.rfft(inv, n=n_fft), n=n_fft)[:n_conv]

    nominal_t0 = ess_pair.nominal_deconv_peak_index
    early_margin = int(round(0.003 * sr))
    max_lat = int(round(config.max_causal_latency_s * sr))
    search_start = max(0, nominal_t0 - early_margin)
    search_end = min(h_full.shape[0], nominal_t0 + max_lat)

    t0_idx = search_start + int(np.argmax(np.abs(h_full[search_start:search_end])))
    residual_lat = t0_idx - nominal_t0
    total_lat_samples = int(round(align_delay)) + residual_lat

    taper_n = int(round(config.gate_taper_s * sr))
    guard_n = int(round(config.pre_arrival_guard_s * sr))
    td_n = int(round(config.direct_path_end_s * sr))
    tr_n = int(round(config.resonance_tail_end_s * sr))
    tl_n = int(round(config.late_room_end_s * sr))

    dp_bounds = (max(0, t0_idx - guard_n), min(h_full.shape[0], t0_idx + td_n))
    rt_bounds = (dp_bounds[1], min(h_full.shape[0], t0_idx + tr_n))
    lr_bounds = (rt_bounds[1], min(h_full.shape[0], t0_idx + tl_n))

    hw_n = int(round(config.harmonic_half_window_s * sr))
    lag2_n = int(
        round(
            harmonic_lag_seconds(
                2, ess_pair.config.sweep_duration_s, ess_pair.config.f1_hz, ess_pair.config.f2_hz
            )
            * sr
        )
    )
    lag3_n = int(
        round(
            harmonic_lag_seconds(
                3, ess_pair.config.sweep_duration_s, ess_pair.config.f1_hz, ess_pair.config.f2_hz
            )
            * sr
        )
    )

    c2 = t0_idx + lag2_n
    c3 = t0_idx + lag3_n
    h2_bounds = (max(0, c2 - hw_n), min(dp_bounds[0], max(0, c2 + hw_n)))
    h3_bounds = (max(0, c3 - hw_n), min(dp_bounds[0], max(0, c3 + hw_n)))

    h_direct = _apply_edge_taper(h_full[dp_bounds[0] : dp_bounds[1]], taper_n)
    h_res = _apply_edge_taper(h_full[rt_bounds[0] : rt_bounds[1]], taper_n)
    h_late = _apply_edge_taper(h_full[lr_bounds[0] : lr_bounds[1]], taper_n)
    h_harm2 = _apply_edge_taper(h_full[h2_bounds[0] : h2_bounds[1]], taper_n)
    h_harm3 = _apply_edge_taper(h_full[h3_bounds[0] : h3_bounds[1]], taper_n)

    e_dp = float(np.sum(h_direct**2)) + config.spectral_floor_eps
    e_res = float(np.sum(h_res**2)) + config.spectral_floor_eps
    e_harm = float(np.sum(h_harm2**2) + np.sum(h_harm3**2)) + config.spectral_floor_eps

    direct_to_tail_db = 10.0 * math.log10(e_dp / e_res)
    harmonic_ratio_db = 10.0 * math.log10(e_harm / (e_dp + e_res))

    rms_res = math.sqrt(float(np.mean(h_res**2)) + config.spectral_floor_eps)
    rms_late = math.sqrt(float(np.mean(h_late**2)) + config.spectral_floor_eps)
    late_room_snr_db = 20.0 * math.log10(rms_res / rms_late)

    bounds_obj = GateWindowBounds(
        t0_index=t0_idx,
        harmonic_2_bounds=h2_bounds,
        harmonic_3_bounds=h3_bounds,
        direct_path_bounds=dp_bounds,
        resonance_tail_bounds=rt_bounds,
        late_room_bounds=lr_bounds,
    )

    return DeconvolvedGates(
        impulse_full=h_full.astype(np.float32),
        t0_index=t0_idx,
        latency_samples=total_lat_samples,
        alignment_delay_samples=align_delay,
        ambiguous_alignment=ambiguous,
        normalized_xcorr_peak=xcorr_peak,
        window_bounds=bounds_obj,
        h_harmonic_2=h_harm2.astype(np.float32),
        h_harmonic_3=h_harm3.astype(np.float32),
        h_direct_path=h_direct.astype(np.float32),
        h_resonance_tail=h_res.astype(np.float32),
        h_late_room=h_late.astype(np.float32),
        direct_to_tail_ratio_db=round(direct_to_tail_db, 4),
        harmonic_ratio_db=round(harmonic_ratio_db, 4),
        late_room_snr_db=round(late_room_snr_db, 4),
    )


def compute_log_band_energies_db(
    signal_segment: np.ndarray,
    sample_rate_hz: int,
    f_min_hz: float,
    f_max_hz: float,
    num_bands: int,
    n_fft: int = 8192,
    eps: float = 1e-12,
) -> np.ndarray:
    """Compute log-spaced spectral band levels (dB) across [f_min_hz, f_max_hz]."""
    seg = np.asarray(signal_segment, dtype=np.float64)
    if seg.size == 0:
        return np.full(num_bands, -120.0, dtype=np.float64)

    fft_len = max(n_fft, 1 << seg.size.bit_length())
    spec = np.fft.rfft(seg, n=fft_len)
    power = (np.abs(spec) ** 2) / max(1, seg.size)
    freqs = np.fft.rfftfreq(fft_len, d=1.0 / sample_rate_hz)

    edges = np.geomspace(f_min_hz, f_max_hz, num_bands + 1)
    band_db = np.empty(num_bands, dtype=np.float64)
    for b in range(num_bands):
        mask = (freqs >= edges[b]) & (freqs < edges[b + 1])
        if not np.any(mask):
            idx = int(np.argmin(np.abs(freqs - 0.5 * (edges[b] + edges[b + 1]))))
            mean_pow = float(power[idx])
        else:
            mean_pow = float(np.mean(power[mask]))
        band_db[b] = 10.0 * math.log10(mean_pow + eps)
    return band_db


def extract_modal_peaks(
    resonance_tail: np.ndarray,
    config: DSPConfig = DSPConfig(),
) -> tuple[ModalPeak, ...]:
    """Identify dominant resonance peaks, prominences, -3 dB widths, and Q-factors."""
    seg = np.asarray(resonance_tail, dtype=np.float64)
    k_target = config.num_modal_peaks_catalog
    if seg.size < 8:
        return tuple(ModalPeak(0.0, -120.0, 0.0, 0.0, 0.0) for _ in range(k_target))

    n_fft = max(config.modal_n_fft, 1 << seg.size.bit_length())
    mag = np.abs(np.fft.rfft(seg, n=n_fft))
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / config.sample_rate_hz)
    df = float(freqs[1] - freqs[0])

    mask = (freqs >= config.f_band_min_hz) & (freqs <= config.f_band_max_hz)
    idx_band = np.flatnonzero(mask)
    if idx_band.size < 5:
        return tuple(ModalPeak(0.0, -120.0, 0.0, 0.0, 0.0) for _ in range(k_target))

    mag_db_full = 20.0 * np.log10(mag + config.spectral_floor_eps)
    kernel = np.array([0.25, 0.5, 0.25], dtype=np.float64)
    mag_db = np.convolve(mag_db_full[idx_band], kernel, mode="same")
    f_sub = freqs[idx_band]

    local_max = np.flatnonzero((mag_db[1:-1] > mag_db[:-2]) & (mag_db[1:-1] >= mag_db[2:])) + 1

    candidates: list[ModalPeak] = []
    for p in local_max:
        peak_val = float(mag_db[p])

        left_higher = np.flatnonzero(mag_db[:p] > peak_val)
        left_bound = int(left_higher[-1]) if left_higher.size > 0 else 0
        left_min = float(np.min(mag_db[left_bound : p + 1]))

        right_higher = np.flatnonzero(mag_db[p + 1 :] > peak_val)
        right_bound = int(p + 1 + right_higher[0]) if right_higher.size > 0 else (mag_db.size - 1)
        right_min = float(np.min(mag_db[p : right_bound + 1]))

        prominence = peak_val - max(left_min, right_min)
        if prominence < config.min_peak_prominence_db:
            continue

        if 0 < p < (mag_db.size - 1):
            alpha, beta, gamma = float(mag_db[p - 1]), peak_val, float(mag_db[p + 1])
            denom = alpha - 2.0 * beta + gamma
            delta_bin = 0.5 * (alpha - gamma) / denom if abs(denom) > 1e-9 else 0.0
            delta_bin = max(-0.5, min(0.5, delta_bin))
            interp_freq = float(f_sub[p]) + delta_bin * df
            interp_mag = beta - 0.25 * (alpha - gamma) * delta_bin
        else:
            interp_freq = float(f_sub[p])
            interp_mag = peak_val

        half_power_db = interp_mag - 3.0103
        l_idx = p
        while l_idx > left_bound and mag_db[l_idx] > half_power_db:
            l_idx -= 1
        if l_idx < p and mag_db[l_idx] <= half_power_db:
            denom_l = float(mag_db[l_idx + 1] - mag_db[l_idx])
            frac_l = (half_power_db - float(mag_db[l_idx])) / denom_l if abs(denom_l) > 1e-9 else 0.0
            f_left = float(f_sub[l_idx]) + frac_l * df
        else:
            f_left = float(f_sub[l_idx])

        r_idx = p
        while r_idx < right_bound and mag_db[r_idx] > half_power_db:
            r_idx += 1
        if r_idx > p and mag_db[r_idx] <= half_power_db:
            denom_r = float(mag_db[r_idx - 1] - mag_db[r_idx])
            frac_r = (float(mag_db[r_idx - 1]) - half_power_db) / denom_r if abs(denom_r) > 1e-9 else 0.0
            f_right = float(f_sub[r_idx - 1]) + frac_r * df
        else:
            f_right = float(f_sub[r_idx])

        bw_hz = max(df, f_right - f_left)
        q_est = min(500.0, interp_freq / bw_hz)

        candidates.append(
            ModalPeak(
                frequency_hz=round(interp_freq, 3),
                magnitude_db=round(interp_mag, 3),
                prominence_db=round(prominence, 3),
                bandwidth_3db_hz=round(bw_hz, 3),
                q_factor=round(q_est, 3),
            )
        )

    candidates.sort(key=lambda m: m.prominence_db, reverse=True)
    top_k = sorted(candidates[:k_target], key=lambda m: m.frequency_hz)
    while len(top_k) < k_target:
        top_k.append(ModalPeak(0.0, -120.0, 0.0, 0.0, 0.0))
    return tuple(top_k)


def _schroeder_decay_and_t20(
    band_signal: np.ndarray,
    sample_rate_hz: int,
    eps: float = 1e-15,
) -> tuple[float, float]:
    """Estimate Schroeder EDC slope (dB/s) and T20-style 60 dB decay proxy (ms)."""
    sig = np.asarray(band_signal, dtype=np.float64)
    if sig.size < 16:
        return 0.0, 0.0

    tail_start = max(1, int(0.85 * sig.size))
    noise_pow = float(np.mean(sig[tail_start:] ** 2))
    inst_pow = np.maximum(0.0, sig**2 - noise_pow)
    edc = np.cumsum(inst_pow[::-1])[::-1]
    if edc[0] <= eps:
        return 0.0, 0.0

    edc_db = 10.0 * np.log10(edc / edc[0] + eps)
    fit_mask = (edc_db <= -2.0) & (edc_db >= -22.0)
    if int(np.sum(fit_mask)) < 6:
        fit_mask = slice(0, max(6, int(0.6 * sig.size)))

    t = np.arange(sig.size, dtype=np.float64)[fit_mask] / float(sample_rate_hz)
    y = edc_db[fit_mask]
    if t.size < 2 or float(np.var(t)) <= 1e-15:
        return 0.0, 0.0

    t_mean = float(np.mean(t))
    slope = float(np.sum((t - t_mean) * (y - np.mean(y))) / np.sum((t - t_mean) ** 2))
    t20_ms = (-60.0 / slope) * 1000.0 if slope < -1.0 else 0.0
    return round(slope, 3), round(t20_ms, 3)


def compute_subband_ringdown_slopes(
    resonance_tail: np.ndarray,
    config: DSPConfig = DSPConfig(),
) -> tuple[tuple[float, float, float], tuple[float, float, float]]:
    """Compute modal ring-down slopes (dB/s) and T20 estimates (ms) across 3 sub-bands."""
    seg = np.asarray(resonance_tail, dtype=np.float64)
    if seg.size < 32:
        return (0.0, 0.0, 0.0), (0.0, 0.0, 0.0)

    n_fft = 1 << seg.size.bit_length()
    spec = np.fft.rfft(seg, n=n_fft)
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / config.sample_rate_hz)
    edges = np.geomspace(config.f_band_min_hz, config.f_band_max_hz, 4)

    slopes: list[float] = []
    t20s: list[float] = []
    for i in range(3):
        band_spec = np.where((freqs >= edges[i]) & (freqs < edges[i + 1]), spec, 0.0)
        band_time = np.fft.irfft(band_spec, n=n_fft)[: seg.size]
        sl, t20 = _schroeder_decay_and_t20(band_time, config.sample_rate_hz)
        slopes.append(sl)
        t20s.append(t20)
    return (slopes[0], slopes[1], slopes[2]), (t20s[0], t20s[1], t20s[2])


def analyze_stepped_tones(
    recording: np.ndarray,
    stepped_ref: SteppedToneWaveform,
    latency_samples: int = 0,
    min_usable_decay_snr_db: float = 6.0,
) -> tuple[SteppedToneMetric, ...]:
    """Complete Section 19.8 stepped-tone analyzer with silent-interval SNR validity check."""
    mono = np.asarray(recording, dtype=np.float64)
    if mono.ndim > 1:
        mono = mono[:, 0]

    sr = stepped_ref.config.sample_rate_hz
    pre_seg = mono[: max(1, stepped_ref.pre_roll_samples)]
    pre_seg = pre_seg - np.mean(pre_seg)
    broadband_noise_rms = float(np.sqrt(np.mean(pre_seg**2))) if pre_seg.size > 0 else 1e-7

    guard_samples = int(round(0.0015 * sr))
    block_samples = max(24, int(round(0.004 * sr)))
    results: list[SteppedToneMetric] = []

    for idx, win in enumerate(stepped_ref.windows):
        f_hz = win.frequency_hz

        # Narrowband noise floor at f_hz from pre-roll
        t_pre = np.arange(pre_seg.size, dtype=np.float64) / float(sr)
        nb_noise = float(np.abs(np.mean(pre_seg * np.exp(-1j * 2.0 * math.pi * f_hz * t_pre)) * 2.0))
        noise_db = compute_dbfs(max(nb_noise, broadband_noise_rms * 0.15), floor_db=-130.0)

        # Steady-state active window
        s0 = min(mono.size, max(0, win.steady_start_sample + latency_samples))
        s1 = min(mono.size, max(s0 + 8, win.tone_end_sample + latency_samples))
        steady_seg = mono[s0:s1]
        t_st = np.arange(steady_seg.size, dtype=np.float64) / float(sr)

        iq_f1 = float(np.abs(np.mean(steady_seg * np.exp(-1j * 2.0 * math.pi * f_hz * t_st)) * 2.0))
        active_db = compute_dbfs(iq_f1, floor_db=-130.0)
        snr_db = active_db - noise_db

        # 2nd and 3rd harmonic distortion during steady tone (where below Nyquist)
        harm_pow = 0.0
        for h_ord in (2, 3):
            fh = h_ord * f_hz
            if fh < 0.48 * sr:
                iq_h = float(np.abs(np.mean(steady_seg * np.exp(-1j * 2.0 * math.pi * fh * t_st)) * 2.0))
                harm_pow += iq_h**2
        thd_db = 10.0 * math.log10((harm_pow + 1e-18) / (iq_f1**2 + 1e-18))

        # Spectral peak frequency & -3 dB width around nominal tone
        n_fft = max(4096, 1 << steady_seg.size.bit_length())
        mag = np.abs(np.fft.rfft(steady_seg * np.hanning(steady_seg.size), n=n_fft))
        freqs = np.fft.rfftfreq(n_fft, d=1.0 / sr)
        df = float(freqs[1] - freqs[0])
        pk_bin = int(np.argmax(mag))
        pk_freq = float(freqs[pk_bin])
        half_lin = float(mag[pk_bin]) / math.sqrt(2.0)
        above = np.flatnonzero(mag >= half_lin)
        pk_width = max(df, float(above[-1] - above[0]) * df) if above.size > 0 else df

        # Post-tone silent decay interval
        d0 = min(mono.size, max(0, win.decay_start_sample + latency_samples + guard_samples))
        d1 = min(mono.size, max(d0 + 8, win.decay_end_sample + latency_samples))
        decay_seg = mono[d0:d1]

        n_blocks = decay_seg.size // block_samples
        if n_blocks < 3:
            results.append(
                SteppedToneMetric(
                    idx, f_hz, round(active_db, 3), round(noise_db, 3), -130.0, 0.0,
                    round(pk_freq, 2), round(pk_width, 2), round(snr_db, 3), round(thd_db, 3), False
                )
            )
            continue

        env_db = np.empty(n_blocks, dtype=np.float64)
        block_times = np.empty(n_blocks, dtype=np.float64)
        for b in range(n_blocks):
            b_seg = decay_seg[b * block_samples : (b + 1) * block_samples]
            t_b = (b * block_samples + np.arange(block_samples, dtype=np.float64)) / float(sr)
            iq_b = float(np.abs(np.mean(b_seg * np.exp(-1j * 2.0 * math.pi * f_hz * t_b)) * 2.0))
            env_db[b] = compute_dbfs(iq_b, floor_db=-130.0)
            block_times[b] = (b + 0.5) * block_samples / float(sr)

        initial_ringdown_db = float(env_db[0])
        usable_decay_snr = (initial_ringdown_db - noise_db) >= min_usable_decay_snr_db

        valid_blocks = env_db > max(noise_db + 3.0, env_db[-1] + 2.5)
        if int(np.sum(valid_blocks)) >= 3:
            tb, eb = block_times[valid_blocks], env_db[valid_blocks]
        else:
            tb, eb = block_times, env_db
        t_mean = float(np.mean(tb))
        denom = float(np.sum((tb - t_mean) ** 2))
        slope = float(np.sum((tb - t_mean) * (eb - np.mean(eb))) / denom) if denom > 1e-15 else 0.0

        results.append(
            SteppedToneMetric(
                step_index=idx,
                nominal_frequency_hz=f_hz,
                active_amplitude_dbfs=round(active_db, 3),
                noise_floor_dbfs=round(noise_db, 3),
                post_tone_ringdown_dbfs=round(initial_ringdown_db, 3),
                decay_slope_db_per_s=round(slope, 3),
                peak_frequency_hz=round(pk_freq, 3),
                peak_width_hz=round(pk_width, 3),
                snr_db=round(snr_db, 3),
                harmonic_distortion_db=round(thd_db, 3),
                is_valid_decay=bool(usable_decay_snr),
            )
        )

    return tuple(results)


def extract_stepped_tone_decay_slopes(
    recording: np.ndarray,
    stepped_ref: SteppedToneWaveform,
    latency_samples: int = 0,
) -> dict[str, np.ndarray]:
    """Convenience array view over analyze_stepped_tones."""
    metrics = analyze_stepped_tones(recording, stepped_ref, latency_samples=latency_samples)
    return {
        "frequencies_hz": np.array([m.nominal_frequency_hz for m in metrics], dtype=np.float64),
        "steady_dbfs": np.array([m.active_amplitude_dbfs for m in metrics], dtype=np.float64),
        "decay_slopes_db_per_s": np.array([m.decay_slope_db_per_s for m in metrics], dtype=np.float64),
        "is_valid_decay": np.array([m.is_valid_decay for m in metrics], dtype=bool),
    }


def evaluate_session_calibration_drift(
    start_water_bands_db: np.ndarray,
    end_water_bands_db: np.ndarray,
    drift_limit_db: float = 1.5,
    start_empty_bands_db: np.ndarray | None = None,
    end_empty_bands_db: np.ndarray | None = None,
) -> dict[str, Any]:
    """Compare beginning and ending session calibrations for drift (Sections 15 & 19.9)."""
    w_diff = np.asarray(end_water_bands_db, dtype=np.float64) - np.asarray(
        start_water_bands_db, dtype=np.float64
    )
    water_rms_drift = float(np.sqrt(np.mean(w_diff**2)))
    water_max_abs = float(np.max(np.abs(w_diff)))

    empty_rms_drift: float | None = None
    if start_empty_bands_db is not None and end_empty_bands_db is not None:
        e_diff = np.asarray(end_empty_bands_db, dtype=np.float64) - np.asarray(
            start_empty_bands_db, dtype=np.float64
        )
        empty_rms_drift = round(float(np.sqrt(np.mean(e_diff**2))), 4)

    drift_exceeded = water_rms_drift > drift_limit_db or (
        empty_rms_drift is not None and empty_rms_drift > drift_limit_db
    )

    return {
        "water_rms_drift_db": round(water_rms_drift, 4),
        "water_max_band_drift_db": round(water_max_abs, 4),
        "empty_rms_drift_db": empty_rms_drift,
        "drift_limit_db": drift_limit_db,
        "calibration_valid": not drift_exceeded,
        "flag": "CALIBRATION_DRIFT" if drift_exceeded else "PASS",
    }


def extract_scan_features(
    recording: np.ndarray,
    ess_pair: ESSWaveformPair,
    water_cal_bands_db: np.ndarray | None = None,
    empty_cal_bands_db: np.ndarray | None = None,
    config: DSPConfig = DSPConfig(),
) -> ScanFeatureResult:
    """Extract compact 25-feature fingerprint, candidate catalog, and isolated nuisance features."""
    mono = np.asarray(recording, dtype=np.float64)
    if mono.ndim > 1:
        mono = mono[:, 0]

    gates = deconvolve_ess_recording(mono, ess_pair, config=config)

    raw_res_bands = compute_log_band_energies_db(
        gates.h_resonance_tail,
        sample_rate_hz=config.sample_rate_hz,
        f_min_hz=config.f_band_min_hz,
        f_max_hz=config.f_band_max_hz,
        num_bands=config.num_diff_bands,
        eps=config.spectral_floor_eps,
    )

    if water_cal_bands_db is not None:
        w_ref = np.asarray(water_cal_bands_db, dtype=np.float64)
        diff_bands = raw_res_bands - w_ref
        water_dist_db = float(np.sqrt(np.mean(diff_bands**2)))
    else:
        diff_bands = raw_res_bands - float(np.mean(raw_res_bands))
        water_dist_db = float(np.sqrt(np.mean(diff_bands**2)))

    if empty_cal_bands_db is not None:
        e_ref = np.asarray(empty_cal_bands_db, dtype=np.float64)
        empty_dist_db = float(np.sqrt(np.mean((raw_res_bands - e_ref) ** 2)))
    else:
        empty_dist_db = 0.0

    peaks = extract_modal_peaks(gates.h_resonance_tail, config=config)
    slopes, t20s = compute_subband_ringdown_slopes(gates.h_resonance_tail, config=config)

    # Primary compact feature vector: 16 diff bands + 3*(freq, Q) + 1 slope + 1 direct/tail + 1 water_dist = 25
    k_prim = config.num_modal_peaks_primary
    compact_vals: list[float] = [float(x) for x in diff_bands]
    compact_names: list[str] = [f"diff_band_db_{i:02d}" for i in range(config.num_diff_bands)]

    for k in range(k_prim):
        compact_vals.append(peaks[k].frequency_hz / 1000.0)
        compact_names.append(f"modal_freq_khz_{k}")
    for k in range(k_prim):
        compact_vals.append(peaks[k].q_factor)
        compact_names.append(f"modal_q_{k}")

    compact_vals.append(slopes[1] / 100.0)
    compact_names.append("ringdown_slope_mid_100db_s")

    compact_vals.append(gates.direct_to_tail_ratio_db)
    compact_names.append("direct_to_tail_ratio_db")

    compact_vals.append(water_dist_db)
    compact_names.append("water_cal_distance_db")

    # Full candidate catalog (Section 16 & Section 19.10)
    catalog: dict[str, float] = {
        name: round(float(val), 5) for name, val in zip(compact_names, compact_vals)
    }
    for k, pk in enumerate(peaks):
        catalog[f"catalog_modal_freq_hz_{k}"] = pk.frequency_hz
        catalog[f"catalog_modal_prom_db_{k}"] = pk.prominence_db
        catalog[f"catalog_modal_bw3db_hz_{k}"] = pk.bandwidth_3db_hz
        catalog[f"catalog_modal_q_{k}"] = pk.q_factor
    for lbl, sl, t20 in zip(("low", "mid", "high"), slopes, t20s):
        catalog[f"catalog_ringdown_slope_db_s_{lbl}"] = sl
        catalog[f"catalog_t20_ms_{lbl}"] = t20
    catalog["catalog_harmonic_ratio_db"] = gates.harmonic_ratio_db
    catalog["catalog_empty_cal_distance_db"] = round(empty_dist_db, 5)
    catalog["catalog_xcorr_stability"] = gates.normalized_xcorr_peak

    # Strictly isolated Nuisance-Only vector: pre-signal background + initial direct-path region
    pre_seg = mono[: max(1, ess_pair.pre_roll_samples)]
    pre_seg = pre_seg - np.mean(pre_seg)
    pre_rms_db = compute_dbfs(float(np.sqrt(np.mean(pre_seg**2))))
    pre_bands = compute_log_band_energies_db(
        pre_seg,
        sample_rate_hz=config.sample_rate_hz,
        f_min_hz=100.0,
        f_max_hz=12_000.0,
        num_bands=config.num_nuisance_bands,
        eps=config.spectral_floor_eps,
    )

    dp_peak_db = compute_dbfs(
        float(np.max(np.abs(gates.h_direct_path))) if gates.h_direct_path.size > 0 else 0.0
    )
    dp_bands = compute_log_band_energies_db(
        gates.h_direct_path,
        sample_rate_hz=config.sample_rate_hz,
        f_min_hz=config.f_band_min_hz,
        f_max_hz=config.f_band_max_hz,
        num_bands=config.num_nuisance_bands,
        eps=config.spectral_floor_eps,
    )

    nuisance_vals = [pre_rms_db, *pre_bands.tolist(), dp_peak_db, *dp_bands.tolist()]
    nuisance_names = (
        ["pre_roll_rms_dbfs"]
        + [f"pre_roll_band_db_{i}" for i in range(config.num_nuisance_bands)]
        + ["direct_path_peak_dbfs"]
        + [f"direct_path_band_db_{i}" for i in range(config.num_nuisance_bands)]
    )

    return ScanFeatureResult(
        compact_features=np.asarray(compact_vals, dtype=np.float64),
        compact_feature_names=tuple(compact_names),
        candidate_catalog=catalog,
        nuisance_features=np.asarray(nuisance_vals, dtype=np.float64),
        nuisance_feature_names=tuple(nuisance_names),
        raw_resonance_bands_db=raw_res_bands,
        modal_peaks=peaks,
        ringdown_slopes_db_per_s=slopes,
        t20_estimates_ms=t20s,
        direct_to_tail_ratio_db=gates.direct_to_tail_ratio_db,
        harmonic_ratio_db=gates.harmonic_ratio_db,
        water_cal_distance_db=round(water_dist_db, 4),
        empty_cal_distance_db=round(empty_dist_db, 4),
        t0_latency_ms=round(1000.0 * gates.latency_samples / float(config.sample_rate_hz), 4),
        alignment_delay_ms=round(
            1000.0 * gates.alignment_delay_samples / float(config.sample_rate_hz), 4
        ),
        normalized_xcorr_peak=gates.normalized_xcorr_peak,
        late_room_snr_db=gates.late_room_snr_db,
        window_bounds=gates.window_bounds,
    )


def aggregate_sample_repetitions(
    scan_results: list[ScanFeatureResult],
    outlier_mad_multiplier: float = 3.5,
) -> dict[str, Any]:
    """Retain repetition-level features and produce robust physical-sample aggregate (Section 19.11)."""
    if not scan_results:
        raise ValueError("Cannot aggregate an empty repetition list.")

    raw_bands = np.vstack([r.raw_resonance_bands_db for r in scan_results])
    rms_dev, is_outlier = detect_intra_batch_outliers(
        raw_bands, outlier_mad_multiplier=outlier_mad_multiplier
    )

    keep_indices = [i for i, bad in enumerate(is_outlier) if not bad]
    if not keep_indices:
        keep_indices = list(range(len(scan_results)))

    kept_compact = np.vstack([scan_results[i].compact_features for i in keep_indices])
    kept_nuisance = np.vstack([scan_results[i].nuisance_features for i in keep_indices])
    kept_bands = raw_bands[keep_indices]

    # Robust dispersion (IQR / MAD) across accepted repetitions
    dispersion_mad = np.median(np.abs(kept_compact - np.median(kept_compact, axis=0)), axis=0) * 1.4826

    pairwise_dists: list[float] = []
    for i in range(kept_bands.shape[0]):
        for j in range(i + 1, kept_bands.shape[0]):
            pairwise_dists.append(float(np.sqrt(np.mean((kept_bands[i] - kept_bands[j]) ** 2))))

    median_pairwise_db = float(np.median(pairwise_dists)) if pairwise_dists else 0.0
    consistency_score = round(1.0 / (1.0 + median_pairwise_db), 5)

    return {
        "compact_features": np.median(kept_compact, axis=0),
        "compact_dispersion_mad": dispersion_mad,
        "repetition_compact_matrix": kept_compact,
        "nuisance_features": np.median(kept_nuisance, axis=0),
        "raw_resonance_bands_db": np.median(kept_bands, axis=0),
        "compact_feature_names": scan_results[0].compact_feature_names,
        "nuisance_feature_names": scan_results[0].nuisance_feature_names,
        "num_total_reps": len(scan_results),
        "num_kept_reps": len(keep_indices),
        "outlier_rep_indices": [int(i) for i, bad in enumerate(is_outlier) if bad],
        "repetition_rms_deviation_db": rms_dev.tolist(),
        "median_pairwise_repeatability_db": round(median_pairwise_db, 4),
        "within_sample_consistency_score": consistency_score,
    }


def evaluate_path_isolation_and_gate_separability(
    path_recordings: dict[str, np.ndarray],
    ess_pair: ESSWaveformPair,
    config: DSPConfig = DSPConfig(),
    min_contact_gain_db: float = 3.0,
    min_fixture_margin_db: float = 4.0,
    min_fluid_shift_db: float = 1.5,
) -> dict[str, Any]:
    """Execute Gate 0A 5-state path-isolation & gate-separability acceptance test (v1.2 Sec 4.2 & 6.3).

    Expected keys in path_recordings:
      - PATH_01_FIXTURE_ONLY
      - PATH_02_EMPTY_ENGAGED
      - PATH_03_WATER_ENGAGED
      - PATH_04_WATER_DISENGAGED
      - PATH_05_AIR_BAFFLE_MOD (optional if baffle test deferred)
    """
    required = (
        "PATH_01_FIXTURE_ONLY",
        "PATH_02_EMPTY_ENGAGED",
        "PATH_03_WATER_ENGAGED",
        "PATH_04_WATER_DISENGAGED",
    )
    missing = [k for k in required if k not in path_recordings]
    if missing:
        raise ValueError(f"Missing required Gate 0A path-isolation recordings: {missing}")

    summaries: dict[str, dict[str, Any]] = {}
    bands_by_key: dict[str, np.ndarray] = {}
    tail_rms_by_key: dict[str, float] = {}

    for key, rec in path_recordings.items():
        gates = deconvolve_ess_recording(rec, ess_pair, config=config)
        feat = extract_scan_features(rec, ess_pair, config=config)
        tail_rms = compute_dbfs(
            float(np.sqrt(np.mean(gates.h_resonance_tail.astype(np.float64) ** 2)))
        )
        bands_by_key[key] = feat.raw_resonance_bands_db
        tail_rms_by_key[key] = tail_rms
        summaries[key] = {
            "resonance_tail_rms_dbfs": round(tail_rms, 3),
            "direct_to_tail_ratio_db": gates.direct_to_tail_ratio_db,
            "late_room_snr_db": gates.late_room_snr_db,
            "dominant_modal_freq_hz": feat.modal_peaks[0].frequency_hz,
        }

    contact_gain_db = tail_rms_by_key["PATH_03_WATER_ENGAGED"] - tail_rms_by_key["PATH_04_WATER_DISENGAGED"]
    fixture_margin_db = tail_rms_by_key["PATH_03_WATER_ENGAGED"] - tail_rms_by_key["PATH_01_FIXTURE_ONLY"]
    fluid_shift_db = float(
        np.sqrt(
            np.mean(
                (bands_by_key["PATH_03_WATER_ENGAGED"] - bands_by_key["PATH_02_EMPTY_ENGAGED"]) ** 2
            )
        )
    )

    baffle_shift_db: float | None = None
    if "PATH_05_AIR_BAFFLE_MOD" in bands_by_key:
        baffle_shift_db = round(
            float(
                np.sqrt(
                    np.mean(
                        (
                            bands_by_key["PATH_03_WATER_ENGAGED"]
                            - bands_by_key["PATH_05_AIR_BAFFLE_MOD"]
                        )
                        ** 2
                    )
                )
            ),
            4,
        )

    gate_ok = (
        contact_gain_db >= min_contact_gain_db
        and fixture_margin_db >= min_fixture_margin_db
        and fluid_shift_db >= min_fluid_shift_db
    )

    return {
        "conditions": summaries,
        "mechanical_contact_gain_db": round(contact_gain_db, 4),
        "fixture_bleed_margin_db": round(fixture_margin_db, 4),
        "fluid_loading_spectral_distance_db": round(fluid_shift_db, 4),
        "airborne_baffle_sensitivity_db": baffle_shift_db,
        "gate_separability_passed": bool(gate_ok),
        "recommended_gating_mode": (
            "SPLIT_TEMPORAL_GATES" if gate_ok else "COMPOSITE_OR_STEPPED_TONE_FALLBACK"
        ),
    }
