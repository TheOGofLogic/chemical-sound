"""
Synthetic ultrasonic pulse-echo A-Scan generator mirroring `LiquidAnalyzerContactCore.swift`.

Generates 40 MSPS dual-channel tensors `[2, L]` (Channel 0: signed RF waveform x[n],
Channel 1: analytic Hilbert envelope |z[n]|) with zero-phase Gabor wavelets, true double-echo
pulse-echo timing (`t1 = t_wall + 2D/c`, `t2 = t_wall + 4D/c`), 180-degree inverted air
micro-bubble scatterers (-R), thermal sound-speed shifts, and empty-vessel OOD negative samples.
"""

from __future__ import annotations

from typing import Dict, Optional, Tuple
import numpy as np
from scipy.signal import hilbert


class SyntheticAScanGenerator:
    """Closed-form ultrasonic pulse-echo simulator synchronized with `LA-R3-SPEC-001` v1.0.0."""

    def __init__(self, sample_rate_hz: float = 40.0e6, center_freq_hz: float = 5.0e6):
        self.fs = float(sample_rate_hz)
        self.f0 = float(center_freq_hz)

        # Reference liquid dictionary: (c_20C [m/s], dc/dT [m/(s*C)], round-trip A2/A1 nominal)
        self.liquid_db: Dict[str, Tuple[float, float, float]] = {
            "H2O_DIST": (1482.0, 2.9, 0.72),
            "NACL_AQ": (1538.0, 2.4, 0.66),
            "VIN_WHITE": (1500.0, 2.6, 0.68),
            "OIL_VEG": (1455.0, -3.2, 0.36),
            "ISOPROPYL_ALC": (1210.0, -3.4, 0.56),
            "SELTZER_CARBONATED": (1482.0, 2.9, 0.58),
        }

    def _add_gabor_pulse(
        self,
        signal: np.ndarray,
        arrival_sec: float,
        amp: float,
        invert: bool,
        cycles: float = 4.0,
    ) -> None:
        total_samples = signal.shape[0]
        center_sample = arrival_sec * self.fs
        center_idx = int(round(center_sample))
        samples_per_cycle = self.fs / self.f0
        half_width = int(np.ceil(cycles * samples_per_cycle))

        idx_range = np.arange(-half_width, half_width + 1, dtype=np.int64)
        target_indices = center_idx + idx_range
        valid = (target_indices >= 0) & (target_indices < total_samples)
        if not np.any(valid):
            return

        valid_targets = target_indices[valid]
        dt_samples = valid_targets.astype(np.float64) - center_sample
        t = dt_samples / self.fs
        # Zero-phase Gabor wavelet matching LiquidAnalyzerContactCore.swift
        window = np.exp(-((dt_samples / (samples_per_cycle * 1.15)) ** 2))
        carrier = np.cos(2.0 * np.pi * self.f0 * t) * (-1.0 if invert else 1.0)
        signal[valid_targets] += (amp * window * carrier).astype(np.float32)

    def generate_single_trace(
        self,
        liquid_name: str,
        container_diameter_m: float = 0.060,
        wall_thickness_m: float = 0.0035,
        wall_velocity_mps: float = 5600.0,
        temp_c: float = 20.0,
        snr_db: float = 32.0,
        inject_bubble: bool = False,
        total_samples: int = 8800,
        rng: Optional[np.random.Generator] = None,
    ) -> Tuple[np.ndarray, Dict[str, np.float32]]:
        rng = rng or np.random.default_rng()
        base_c, dc_dt, base_a2_a1 = self.liquid_db[liquid_name]
        c_liquid = max(900.0, base_c + dc_dt * (temp_c - 20.0))

        signal = np.zeros(total_samples, dtype=np.float32)

        # True pulse-echo round-trip arrival times:
        # Echo 1 = front wall delay + 1 complete liquid round-trip (2D / c)
        # Echo 2 = Echo 1 + 1 complete liquid round-trip (cancels wall thickness via t2 - t1 = 2D / c)
        t_wall = (2.0 * wall_thickness_m) / max(1000.0, wall_velocity_mps)
        t_liquid_rt = (2.0 * container_diameter_m) / c_liquid
        t1 = t_wall + t_liquid_rt
        t2 = t1 + t_liquid_rt

        # 0. Initial excitation pulse / dead-zone front-wall ring-down (< 8 us)
        self._add_gabor_pulse(signal, arrival_sec=1.8e-6, amp=0.95, invert=False, cycles=3.0)

        # 1. Optional mid-column air micro-bubble scatterer (-R, 180-degree phase flip)
        bubble_present = bool(
            inject_bubble or (liquid_name == "SELTZER_CARBONATED" and rng.random() > 0.15)
        )
        if bubble_present:
            depth_frac = float(rng.uniform(0.22, 0.78))
            t_bubble = t_wall + depth_frac * t_liquid_rt
            a_bubble = float(rng.uniform(0.20, 0.44))
            self._add_gabor_pulse(signal, arrival_sec=t_bubble, amp=a_bubble, invert=True, cycles=3.5)

        # 2. Echo 1 (+R, rigid opposite glass wall)
        a1 = float(rng.uniform(0.78, 0.90))
        self._add_gabor_pulse(signal, arrival_sec=t1, amp=a1, invert=False)

        # 3. Echo 2 (+R, double-reflection across liquid column, scaled by diameter & fluid attenuation)
        diameter_scale = container_diameter_m / 0.065
        atten_ratio = float(np.clip(base_a2_a1 ** diameter_scale * rng.uniform(0.92, 1.08), 0.12, 0.90))
        a2 = a1 * atten_ratio
        self._add_gabor_pulse(signal, arrival_sec=t2, amp=a2, invert=False)

        # 4. Additive Gaussian receiver noise floor
        noise_sigma = 10.0 ** (-snr_db / 20.0)
        rf_trace = signal + rng.normal(0.0, noise_sigma, total_samples).astype(np.float32)

        # 5. Analytic Hilbert envelope |z[n]|
        envelope = np.abs(hilbert(rf_trace)).astype(np.float32)
        tensor = np.stack([rf_trace, envelope], axis=0)

        round_trip_cm = max(0.5, 2.0 * container_diameter_m * 100.0)
        atten_db_per_cm = float(max(0.0, (-20.0 * np.log10(max(1e-5, atten_ratio))) / round_trip_cm))

        meta: Dict[str, np.float32] = {
            "c_20": np.float32(base_c),
            "temp_c": np.float32(temp_c),
            "attenuation": np.float32(atten_ratio),
            "atten_db_per_cm": np.float32(atten_db_per_cm),
            "has_inverted_bubble": np.float32(1.0 if bubble_present else 0.0),
            "is_ood": np.float32(0.0),
        }
        return tensor, meta

    def generate_ood_empty_trace(
        self,
        wall_thickness_m: float = 0.0035,
        snr_db: float = 28.0,
        total_samples: int = 8800,
        rng: Optional[np.random.Generator] = None,
    ) -> Tuple[np.ndarray, Dict[str, np.float32]]:
        """Synthesizes an Out-of-Distribution empty glass / uncoupled air-gap negative control (zero liquid echoes)."""
        rng = rng or np.random.default_rng()
        signal = np.zeros(total_samples, dtype=np.float32)

        # Strong front-wall ring-down + 1-2 short glass wall reverberations (inside < 10 us), then pure air-gap silence
        self._add_gabor_pulse(signal, arrival_sec=1.8e-6, amp=0.95, invert=False, cycles=3.0)
        t_wall = (2.0 * wall_thickness_m) / 5600.0
        for mult in (1, 2):
            self._add_gabor_pulse(
                signal,
                arrival_sec=1.8e-6 + mult * t_wall,
                amp=float(0.45 * (0.5 ** mult)),
                invert=True,  # Glass -> Air free boundary inversion!
                cycles=3.0,
            )

        noise_sigma = 10.0 ** (-snr_db / 20.0)
        rf_trace = signal + rng.normal(0.0, noise_sigma, total_samples).astype(np.float32)
        envelope = np.abs(hilbert(rf_trace)).astype(np.float32)
        tensor = np.stack([rf_trace, envelope], axis=0)

        meta: Dict[str, np.float32] = {
            "c_20": np.float32(0.0),
            "temp_c": np.float32(20.0),
            "attenuation": np.float32(0.0),
            "atten_db_per_cm": np.float32(0.0),
            "has_inverted_bubble": np.float32(0.0),
            "is_ood": np.float32(1.0),
        }
        return tensor, meta
