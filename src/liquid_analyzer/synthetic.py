"""Physically parameterized fluid-loaded polypropylene container simulator for bench validation.

Generates realistic 48 kHz Float32 ESS and Stepped-Tone recordings containing:
- Strong direct speaker-to-mic chassis/air bleed (+20 to +30 dB over modal tail)
- Speaker 2nd and 3rd order nonlinearities (to validate Farina negative-lag separation)
- Fluid-loaded thin-wall polypropylene structural modes parameterized by (density, sound_speed, viscosity)
- Late room reverberation tail and broadband ambient noise floor
- Independent random variance at the Batch, Physical Sample (repositioning/container), and Repetition levels
- Optional nuisance-leakage injection mode to validate the Nuisance-Only Leakage Classifier
"""

from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Any

import numpy as np

from .classification import STAGE_FORMULATIONS, SampleSummary
from .dsp import DSPConfig, aggregate_sample_repetitions, extract_scan_features
from .waveforms import ESSWaveformPair, SteppedToneWaveform


@dataclass(frozen=True)
class LiquidPhysicalProfile:
    """Bulk physical properties at ~22 C governing fluid-loaded container acoustics."""

    formulation_id: str
    density_g_cm3: float
    sound_speed_m_s: float
    viscosity_mpa_s: float
    is_known_library: bool = True
    unknown_category: str | None = None  # None | 'UNK_OUTER' | 'UNK_INTERMEDIATE'


LIQUID_PROFILES: dict[str, LiquidPhysicalProfile] = {
    # Stage 1 & Stage 2 library formulations
    "H2O_DIST": LiquidPhysicalProfile("H2O_DIST", 0.9978, 1488.0, 0.95, True),
    "NACL_010": LiquidPhysicalProfile("NACL_010", 1.0050, 1499.0, 0.97, True),
    "NACL_100": LiquidPhysicalProfile("NACL_100", 1.0707, 1602.0, 1.19, True),
    "SUC_050": LiquidPhysicalProfile("SUC_050", 1.0179, 1503.0, 1.14, True),
    "SUC_200": LiquidPhysicalProfile("SUC_200", 1.0810, 1558.0, 1.94, True),
    "VIN_WHITE": LiquidPhysicalProfile("VIN_WHITE", 1.0058, 1522.0, 1.12, True),
    "MILK_WHOLE": LiquidPhysicalProfile("MILK_WHOLE", 1.0310, 1528.0, 2.05, True),
    "OIL_VEG": LiquidPhysicalProfile("OIL_VEG", 0.9180, 1462.0, 56.0, True),
    # Category UNK_OUTER: Distinct safe non-library liquids
    "GLYCEROL_60": LiquidPhysicalProfile("GLYCEROL_60", 1.1530, 1780.0, 10.8, False, "UNK_OUTER"),
    "SYRUP_CORN_DIL": LiquidPhysicalProfile(
        "SYRUP_CORN_DIL", 1.2400, 1690.0, 38.0, False, "UNK_OUTER"
    ),
    # Category UNK_INTERMEDIATE: Excluded interpolative concentrations (v1.2 Section 9.3)
    "NACL_040": LiquidPhysicalProfile(
        "NACL_040", 1.0268, 1532.0, 1.04, False, "UNK_INTERMEDIATE"
    ),
    "SUC_120": LiquidPhysicalProfile(
        "SUC_120", 1.0465, 1527.0, 1.42, False, "UNK_INTERMEDIATE"
    ),
}


def build_container_liquid_ir(
    profile: LiquidPhysicalProfile | None,
    sample_rate_hz: int = 48_000,
    ir_duration_s: float = 0.140,
    latency_samples: int = 18,
    batch_density_delta: float = 0.0,
    batch_speed_delta: float = 0.0,
    sample_coupling_scale: float = 1.0,
    sample_freq_jitter_pct: float = 0.0,
    direct_bleed_scale: float = 1.0,
) -> np.ndarray:
    """Synthesize linear impulse response h(t) = direct_bleed + modal_ringdown + late_room.

    When profile is None, synthesizes an empty polypropylene container response.
    """
    n_ir = int(round(ir_duration_s * sample_rate_hz))
    ir = np.zeros(n_ir, dtype=np.float64)

    # 1. Strong direct speaker-to-mic bleed arriving at latency_samples (~0.38 ms)
    ir[latency_samples] += 0.34 * direct_bleed_scale
    if latency_samples + 3 < n_ir:
        ir[latency_samples + 3] -= 0.11 * direct_bleed_scale
    if latency_samples + 9 < n_ir:
        ir[latency_samples + 9] += 0.04 * direct_bleed_scale

    # 2. Fluid-loaded thin-wall polypropylene structural modes + radial cavity mode (onset ~2.2 ms after t0)
    modal_onset = latency_samples + int(round(0.0022 * sample_rate_hz))
    t_modal = np.arange(max(0, n_ir - modal_onset), dtype=np.float64) / float(sample_rate_hz)

    empty_wall_freqs = (1650.0, 3550.0, 6800.0)
    fluid_mass_couplings = (0.72, 0.55, 0.38)

    if profile is None:
        # Empty container: higher modal frequencies, light structural damping
        modes = [
            (empty_wall_freqs[0], 95.0, 0.22 * sample_coupling_scale),
            (empty_wall_freqs[1], 145.0, 0.18 * sample_coupling_scale),
            (empty_wall_freqs[2], 230.0, 0.13 * sample_coupling_scale),
        ]
    else:
        rho = max(0.7, profile.density_g_cm3 + batch_density_delta)
        c_liq = max(1100.0, profile.sound_speed_m_s + batch_speed_delta)
        visc = max(0.5, profile.viscosity_mpa_s)

        modes = []
        for f_empty, beta, peak_gain in zip(
            empty_wall_freqs, fluid_mass_couplings, (0.24, 0.20, 0.14)
        ):
            # Added-mass lowering from density + acoustic stiffness shift from liquid sound speed
            f_loaded = (f_empty / math.sqrt(1.0 + beta * rho)) * (
                1.0 + 0.32 * ((c_liq - 1488.0) / 1488.0)
            )
            f_loaded *= 1.0 + sample_freq_jitter_pct
            decay_rate = (70.0 + 0.018 * f_loaded) + 26.0 * math.sqrt(visc) + 14.0 * (rho - 0.9)
            gain = peak_gain * sample_coupling_scale / (1.0 + 0.06 * math.sqrt(visc))
            modes.append((f_loaded, decay_rate, gain))

        # Additional internal radial acoustic column mode directly proportional to c_liq
        f_cavity = (4350.0 * (c_liq / 1488.0)) * (1.0 + 0.5 * sample_freq_jitter_pct)
        decay_cavity = 85.0 + 34.0 * math.sqrt(visc)
        gain_cavity = 0.22 * sample_coupling_scale * (rho / 1.0) / (1.0 + 0.05 * math.sqrt(visc))
        modes.append((f_cavity, decay_cavity, gain_cavity))

    modal_wave = np.zeros_like(t_modal)
    for f_hz, alpha_s, peak_gain in modes:
        # Normalize discrete-time resonator tap weight by (2 * alpha / fs) so |H(f_peak)| == peak_gain
        tap_amp = peak_gain * (2.0 * alpha_s / float(sample_rate_hz))
        modal_wave += tap_amp * np.exp(-alpha_s * t_modal) * np.sin(2.0 * math.pi * f_hz * t_modal)

    # Smooth 0.4 ms modal buildup envelope
    buildup = 1.0 - np.exp(-t_modal / 0.0004)
    ir[modal_onset:] += modal_wave * buildup

    # 3. Weak late room echo clusters (> 52 ms after t0, outside Resonance-Tail gate)
    for echo_delay_s, echo_gain in ((0.056, 0.00025), (0.079, -0.00016), (0.104, 0.00010)):
        e_idx = latency_samples + int(round(echo_delay_s * sample_rate_hz))
        if e_idx < n_ir:
            ir[e_idx] += echo_gain

    return ir.astype(np.float32)


def simulate_recording(
    excitation: np.ndarray,
    ir: np.ndarray,
    rng: np.random.Generator,
    noise_rms_dbfs: float = -68.0,
    harmonic_2nd: float = 0.012,
    harmonic_3rd: float = 0.004,
    pre_roll_leakage_tone_hz: float | None = None,
) -> np.ndarray:
    """Apply nonlinear speaker distortion, convolve with container IR, and add background noise."""
    x = np.asarray(excitation, dtype=np.float64)
    h = np.asarray(ir, dtype=np.float64)

    # Weak memoryless micro-speaker distortion before acoustic propagation
    x_nl = x + harmonic_2nd * (x**2) + harmonic_3rd * (x**3)

    n_conv = x_nl.size + h.size - 1
    n_fft = 1 << n_conv.bit_length()
    y_full = np.fft.irfft(np.fft.rfft(x_nl, n=n_fft) * np.fft.rfft(h, n=n_fft), n=n_fft)[: x.size]

    noise_std = 10.0 ** (noise_rms_dbfs / 20.0)
    noise = rng.normal(0.0, noise_std, size=x.size)

    if pre_roll_leakage_tone_hz is not None:
        t = np.arange(x.size, dtype=np.float64) / 48_000.0
        noise += (noise_std * 4.5) * np.sin(2.0 * math.pi * pre_roll_leakage_tone_hz * t)

    return np.clip(y_full + noise, -0.98, 0.98).astype(np.float32)


def simulate_staged_dataset(
    ess_pair: ESSWaveformPair,
    stage: str = "STAGE_3",
    num_exploratory_batches: int = 4,
    num_locked_batches: int = 2,
    samples_per_batch: int = 3,
    reps_per_sample: int = 5,
    unknown_formulations: tuple[str, ...] = ("GLYCEROL_60", "SYRUP_CORN_DIL"),
    inject_nuisance_leakage: bool = False,
    dsp_config: DSPConfig = DSPConfig(),
    seed: int = 20261116,
) -> dict[str, list[SampleSummary]]:
    """Generate synthetic Phase 1A (4-batch exploratory) and Phase 1B (2-batch locked + unknowns) datasets."""
    rng = np.random.default_rng(seed)
    known_forms = STAGE_FORMULATIONS[stage]

    # Session water calibration scan
    water_ir = build_container_liquid_ir(
        LIQUID_PROFILES["H2O_DIST"], sample_rate_hz=dsp_config.sample_rate_hz
    )
    water_cal_rec = simulate_recording(ess_pair.framed_excitation, water_ir, rng)
    water_cal_feat = extract_scan_features(water_cal_rec, ess_pair, config=dsp_config)
    water_cal_bands = water_cal_feat.raw_resonance_bands_db

    empty_ir = build_container_liquid_ir(None, sample_rate_hz=dsp_config.sample_rate_hz)
    empty_cal_rec = simulate_recording(ess_pair.framed_excitation, empty_ir, rng)
    empty_cal_feat = extract_scan_features(empty_cal_rec, ess_pair, config=dsp_config)
    empty_cal_bands = empty_cal_feat.raw_resonance_bands_db

    phase1a_samples: list[SampleSummary] = []
    phase1b_samples: list[SampleSummary] = []
    sample_counter = 1

    def _collect_batches(
        formulations: tuple[str, ...],
        n_batches: int,
        batch_prefix: str,
        dest: list[SampleSummary],
    ) -> None:
        nonlocal sample_counter
        for f_idx, form_id in enumerate(formulations):
            prof = LIQUID_PROFILES[form_id]
            for b_idx in range(n_batches):
                batch_id = f"{form_id}_{batch_prefix}_B{b_idx + 1:02d}"
                # Independent preparation batch jitter
                b_rho_delta = float(rng.normal(0.0, 0.0012))
                b_c_delta = float(rng.normal(0.0, 1.4))

                for _ in range(samples_per_batch):
                    sid = f"SMP_{sample_counter:05d}"
                    sample_counter += 1
                    # Physical sample / container / clamping jitter
                    s_coup = float(rng.normal(1.0, 0.020))
                    s_fjit = float(rng.normal(0.0, 0.0008))
                    bleed_scale = (
                        1.0 + 0.08 * f_idx if inject_nuisance_leakage else float(rng.normal(1.0, 0.015))
                    )
                    leak_tone = (400.0 + 550.0 * f_idx) if inject_nuisance_leakage else None

                    ir = build_container_liquid_ir(
                        prof,
                        sample_rate_hz=dsp_config.sample_rate_hz,
                        batch_density_delta=b_rho_delta,
                        batch_speed_delta=b_c_delta,
                        sample_coupling_scale=s_coup,
                        sample_freq_jitter_pct=s_fjit,
                        direct_bleed_scale=bleed_scale,
                    )

                    rep_feats = []
                    for _ in range(reps_per_sample):
                        rec = simulate_recording(
                            ess_pair.framed_excitation,
                            ir,
                            rng,
                            pre_roll_leakage_tone_hz=leak_tone,
                        )
                        rep_feats.append(
                            extract_scan_features(
                                rec,
                                ess_pair,
                                water_cal_bands_db=water_cal_bands,
                                empty_cal_bands_db=empty_cal_bands,
                                config=dsp_config,
                            )
                        )

                    agg = aggregate_sample_repetitions(rep_feats)
                    is_holdout_vessel = batch_prefix.startswith("P1B")
                    vessel_id = (
                        f"PP_HOLDOUT_{(sample_counter % 3) + 1:02d}"
                        if is_holdout_vessel
                        else f"PP_DEV_{(sample_counter % 5) + 1:02d}"
                    )
                    dest.append(
                        SampleSummary(
                            sample_id=sid,
                            formulation_id=form_id,
                            preparation_batch_id=batch_id,
                            is_known_library_class=prof.is_known_library,
                            compact_features=agg["compact_features"],
                            nuisance_features=agg["nuisance_features"],
                            repetition_features=agg["repetition_compact_matrix"],
                            unknown_category=prof.unknown_category,
                            is_held_out_container=is_holdout_vessel,
                            session_id=f"SESS_{(b_idx % 2) + 1:02d}",
                            container_id=vessel_id,
                        )
                    )

    _collect_batches(known_forms, num_exploratory_batches, "P1A", phase1a_samples)
    _collect_batches(known_forms, num_locked_batches, "P1B", phase1b_samples)
    if unknown_formulations:
        _collect_batches(unknown_formulations, 1, "P1B_UNK", phase1b_samples)

    return {
        "phase1a": phase1a_samples,
        "phase1b": phase1b_samples,
    }


def simulate_path_isolation_suite(
    ess_pair: ESSWaveformPair,
    seed: int = 20261116,
) -> dict[str, np.ndarray]:
    """Synthesize the 5 Gate 0A path-isolation configurations (v1.2 Section 4.2)."""
    rng = np.random.default_rng(seed)
    sr = ess_pair.config.sample_rate_hz

    # PATH_01: Fixture only (minimal structural tail, normal direct bleed)
    ir_fix = build_container_liquid_ir(None, sample_rate_hz=sr, sample_coupling_scale=0.05)
    # PATH_02: Empty container engaged
    ir_empty = build_container_liquid_ir(None, sample_rate_hz=sr, sample_coupling_scale=1.0)
    # PATH_03: Water-filled container engaged
    ir_water = build_container_liquid_ir(
        LIQUID_PROFILES["H2O_DIST"], sample_rate_hz=sr, sample_coupling_scale=1.0
    )
    # PATH_04: Water-filled container with contact pad disengaged (strong drop in modal coupling)
    ir_disengaged = build_container_liquid_ir(
        LIQUID_PROFILES["H2O_DIST"], sample_rate_hz=sr, sample_coupling_scale=0.12
    )
    # PATH_05: Engaged + supplemental port baffle (reduces direct airborne bleed while preserving wall tail)
    ir_baffle = build_container_liquid_ir(
        LIQUID_PROFILES["H2O_DIST"],
        sample_rate_hz=sr,
        sample_coupling_scale=0.98,
        direct_bleed_scale=0.55,
    )

    return {
        "PATH_01_FIXTURE_ONLY": simulate_recording(ess_pair.framed_excitation, ir_fix, rng),
        "PATH_02_EMPTY_ENGAGED": simulate_recording(ess_pair.framed_excitation, ir_empty, rng),
        "PATH_03_WATER_ENGAGED": simulate_recording(ess_pair.framed_excitation, ir_water, rng),
        "PATH_04_WATER_DISENGAGED": simulate_recording(
            ess_pair.framed_excitation, ir_disengaged, rng
        ),
        "PATH_05_AIR_BAFFLE_MOD": simulate_recording(ess_pair.framed_excitation, ir_baffle, rng),
    }


def simulate_stepped_tone_response(
    stepped_waveform: SteppedToneWaveform,
    formulation_id: str,
    seed: int = 42,
) -> np.ndarray:
    """Synthesize a stepped-tone recording for a specified formulation."""
    rng = np.random.default_rng(seed)
    prof = LIQUID_PROFILES[formulation_id]
    ir = build_container_liquid_ir(prof, sample_rate_hz=stepped_waveform.config.sample_rate_hz)
    return simulate_recording(stepped_waveform.framed_excitation, ir, rng)
