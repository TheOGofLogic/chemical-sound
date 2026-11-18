"""Authoritative verification suite covering CS-SPEC-P1-v1.2 and all Section 19.16 requirements."""

from __future__ import annotations

from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import numpy as np

from liquid_analyzer.classification import (
    INVALID_MEASUREMENT_LABEL,
    NO_VALIDATED_MATCH_LABEL,
    REFERENCE_MATCH_STATUS,
    STAGE_FORMULATIONS,
    ClassifierConfig,
    DataLeakageError,
    OpenSetAcousticClassifier,
    SampleSummary,
    evaluate_locked_test,
    run_lobo_cv,
    run_nested_lobo_cv,
    verify_disjoint_sample_and_batch_splits,
)
from liquid_analyzer.cli import evaluate_csrd_directory
from liquid_analyzer.dsp import (
    DSPConfig,
    analyze_stepped_tones,
    deconvolve_ess_recording,
    evaluate_path_isolation_and_gate_separability,
    evaluate_session_calibration_drift,
    extract_modal_peaks,
    extract_scan_features,
    get_primary_feature_registry,
)
from liquid_analyzer.ingestion_alignment import (
    align_recording_to_reference,
    apply_fractional_shift,
    ingest_audio_file,
)
from liquid_analyzer.reporting import process_and_save_recording_bundle
from liquid_analyzer.schema_qc import (
    QCThresholds,
    ScanRecord,
    detect_intra_batch_outliers,
    evaluate_scan_qc,
    read_scans_jsonl,
    resolve_session_scan_validity,
    write_scans_jsonl,
)
from liquid_analyzer.synthetic import (
    LIQUID_PROFILES,
    build_container_liquid_ir,
    simulate_path_isolation_suite,
    simulate_recording,
    simulate_staged_dataset,
    simulate_stepped_tone_response,
)
from liquid_analyzer.waveforms import (
    PILOT_SWEEP_PRESETS,
    ESSConfig,
    SteppedToneConfig,
    export_reference_waveform_bundle,
    generate_diagnostic_waveform,
    generate_ess_pair,
    generate_stepped_tones,
    read_wav_float32,
    write_wav_float32,
)


def _valid_base_record() -> ScanRecord:
    return ScanRecord(
        study_id="CS_PILOT_01",
        session_id="SESS_01",
        operator_id="OP_01",
        scan_stage="P1A",
        sample_id="SMP_0001",
        is_blinded_run=False,
        liquid_class="CLASS_1",
        formulation_id="H2O_DIST",
        preparation_batch_id="H2O_B01",
        sample_rest_duration_sec=240.0,
        container_id="PP_TUBE_01",
        cap_closure_state="CAPPED_TORQUE_MARK",
        bubble_foam_flag="NONE",
        nominal_volume_ml=15.0,
        measured_mass_g=14.98,
        fill_height_mm=42.5,
        headspace_height_mm=14.5,
        sample_temperature_c=22.1,
        temp_measurement_method="CALIBRATED_IMMERSION_WITNESS",
        temp_measurement_timing="PRE_SETTLE",
        fixture_mode="MODE_B",
        coupling_force_setting="NOMINAL",
        expected_coupling_force_setting="NOMINAL",
        iphone_model="iPhone 15 Pro",
        hardware_model_identifier="iPhone16,1",
        device_code="DEV_REF_01",
        requested_sample_rate_hz=48_000,
        verified_sample_rate_hz=48_000,
        requested_audio_mode="measurement",
        verified_audio_mode="measurement",
        selected_input_port="Built-In Microphone",
        verified_input_port="Built-In Microphone",
        selected_mic_datasource="Bottom",
        verified_mic_datasource="Bottom",
        verified_output_port="Built-In Speaker",
        route_profile_verified=True,
        target_hardware_volume=0.65,
        pre_scan_hardware_volume=0.65,
        post_scan_hardware_volume=0.65,
        excitation_signal_id="SIG_ESS_v1",
        repetition_number=1,
        excitation_start_host_time_s=10.0,
        excitation_end_host_time_s=10.2,
        raw_audio_filename="SMP_0001_rep1.wav",
    )


class TestV12PipelineRequirements(unittest.TestCase):
    def test_01_waveform_reproducibility_presets_and_golden_regression(self) -> None:
        with tempfile.TemporaryDirectory() as tmp1, tempfile.TemporaryDirectory() as tmp2:
            m1 = export_reference_waveform_bundle(tmp1)
            m2 = export_reference_waveform_bundle(tmp2)
            self.assertEqual(
                m1["signals"]["SIG_ESS_v1"]["sha256"],
                m2["signals"]["SIG_ESS_v1"]["sha256"],
            )
            self.assertEqual(
                m1["signals"]["SIG_ESS_v1"]["inverse_filter_sha256"],
                m2["signals"]["SIG_ESS_v1"]["inverse_filter_sha256"],
            )
            ess_sum = m1["signals"]["SIG_ESS_v1"]["summary"]
            self.assertEqual(ess_sum["num_samples"], 24_000)
            self.assertAlmostEqual(ess_sum["peak_dbfs"], -6.0, delta=0.05)

            # Pilot sweep presets (200 ms, 500 ms, 1000 ms)
            ess_500 = generate_ess_pair(PILOT_SWEEP_PRESETS["ESS_500MS_LONG_TAIL"])
            self.assertEqual(ess_500.active_samples, 24_000)
            self.assertEqual(ess_500.post_roll_samples, 14_400)

            # CoreAudio 'FLLR' chunk tolerance
            ess_path = Path(tmp1) / "SIG_ESS_v1.wav"
            raw = ess_path.read_bytes()
            data_pos = raw.index(b"data")
            fllr_chunk = struct.pack("<4sI", b"FLLR", 8) + (b"\x00" * 8)
            patched = raw[:data_pos] + fllr_chunk + raw[data_pos:]
            patched = patched[:4] + struct.pack("<I", len(patched) - 8) + patched[8:]
            p_fllr = Path(tmp1) / "fllr.wav"
            p_fllr.write_bytes(patched)
            sr, wav_orig = read_wav_float32(ess_path)
            sr2, wav_fllr = read_wav_float32(p_fllr)
            self.assertEqual(sr, sr2)
            np.testing.assert_array_equal(wav_orig, wav_fllr)

            imp = generate_diagnostic_waveform(mode="impulse")
            self.assertEqual(imp.shape[0], 24_000)

    def test_02_inverse_filter_synthetic_ir_and_5state_path_isolation(self) -> None:
        ess = generate_ess_pair(ESSConfig())
        x = ess.framed_excitation.astype(np.float64)

        ir_true = np.zeros(512, dtype=np.float64)
        ir_true[25] = 0.80
        ir_true[240] = 0.20
        y_lin = np.convolve(x, ir_true)[: x.size].astype(np.float32)

        gates = deconvolve_ess_recording(y_lin, ess, DSPConfig(use_pre_alignment=False))
        self.assertEqual(gates.latency_samples, 25)
        wb = gates.window_bounds
        self.assertEqual(wb.direct_path_bounds[1], wb.resonance_tail_bounds[0])
        self.assertEqual(wb.resonance_tail_bounds[1], wb.late_room_bounds[0])

        echo_offset_in_tail = (wb.t0_index + 215) - wb.resonance_tail_bounds[0]
        peak_in_tail = int(np.argmax(np.abs(gates.h_resonance_tail)))
        self.assertAlmostEqual(peak_in_tail, echo_offset_in_tail, delta=2)

        # Gate 0A 5-state path-isolation & gate-separability acceptance test
        path_recs = simulate_path_isolation_suite(ess)
        path_eval = evaluate_path_isolation_and_gate_separability(path_recs, ess)
        self.assertTrue(path_eval["gate_separability_passed"])
        self.assertEqual(path_eval["recommended_gating_mode"], "SPLIT_TEMPORAL_GATES")
        self.assertGreater(path_eval["mechanical_contact_gain_db"], 6.0)
        self.assertGreater(path_eval["fluid_loading_spectral_distance_db"], 1.5)

    def test_03_known_and_fractional_delay_alignment(self) -> None:
        ess = generate_ess_pair(ESSConfig())
        true_delay = 19.35
        delayed = apply_fractional_shift(ess.framed_excitation, -true_delay)

        res = align_recording_to_reference(
            delayed,
            ess.active_sweep,
            nominal_start_sample=ess.pre_roll_samples,
            sample_rate_hz=48_000,
        )
        self.assertAlmostEqual(res.total_delay_samples, true_delay, delta=0.15)
        self.assertFalse(res.ambiguous_alignment)

        residual = align_recording_to_reference(
            res.aligned_working_copy,
            ess.active_sweep,
            nominal_start_sample=ess.pre_roll_samples,
            sample_rate_hz=48_000,
        )
        self.assertAlmostEqual(residual.total_delay_samples, 0.0, delta=0.15)

    def test_04_provisional_qc_cooldown_and_session_drift_lifecycle(self) -> None:
        ess = generate_ess_pair(ESSConfig())
        rng = np.random.default_rng(7)
        clean_wav = simulate_recording(
            ess.framed_excitation, build_container_liquid_ir(LIQUID_PROFILES["H2O_DIST"]), rng
        )

        with tempfile.TemporaryDirectory() as tmp:
            p_clean = Path(tmp) / "clean.wav"
            write_wav_float32(p_clean, clean_wav, 48_000)
            ing = ingest_audio_file(p_clean)
            self.assertFalse(ing.report.quarantined)
            self.assertFalse(ing.raw_samples.flags.writeable)

            p_44k = Path(tmp) / "wrong_sr.wav"
            write_wav_float32(p_44k, clean_wav, 44_100)
            self.assertIn("SAMPLE_RATE_MISMATCH", ingest_audio_file(p_44k).report.quarantine_reasons)

            clipped = clean_wav.copy()
            clipped[8000:8005] = 0.99
            p_clip = Path(tmp) / "clip.wav"
            write_wav_float32(p_clip, clipped, 48_000)
            self.assertGreaterEqual(ingest_audio_file(p_clip).report.clipped_sample_count, 5)

        # v1.2 Two-stage QC: PROVISIONALLY_ACCEPTED -> FINAL_ACCEPTED vs INVALID_MEASUREMENT
        st, fl, _, _ = evaluate_scan_qc(
            _valid_base_record(), clean_wav, ess.pre_roll_samples, ess.active_samples
        )
        self.assertEqual(st, "PROVISIONALLY_ACCEPTED")
        self.assertEqual(fl, [])
        self.assertEqual(resolve_session_scan_validity(st, "SESSION_VALID"), "FINAL_ACCEPTED")
        self.assertEqual(
            resolve_session_scan_validity(st, "SESSION_DRIFT_INVALIDATED"), "INVALID_MEASUREMENT"
        )

        # Cooldown invariant check (t_next_start < t_prev_end + 2.0s)
        too_soon = _valid_base_record()
        too_soon.excitation_start_host_time_s = 11.1  # Only 0.9s after prev end 10.2s
        st_cd, fl_cd, _, _ = evaluate_scan_qc(
            too_soon,
            clean_wav,
            ess.pre_roll_samples,
            ess.active_samples,
            prev_excitation_end_host_time_s=10.2,
        )
        self.assertEqual(st_cd, "REJECTED")
        self.assertIn("COOLDOWN_VIOLATION", fl_cd)

        missing_temp = _valid_base_record()
        missing_temp.sample_temperature_c = None
        st_m, fl_m, _, _ = evaluate_scan_qc(
            missing_temp, clean_wav, ess.pre_roll_samples, ess.active_samples
        )
        self.assertEqual(st_m, "INCOMPLETE")
        self.assertIn("TEMPERATURE_MISSING", fl_m)

        with tempfile.TemporaryDirectory() as tmp:
            jpath = Path(tmp) / "scans.jsonl"
            write_scans_jsonl(jpath, [_valid_base_record()])
            self.assertIn('"blind_code": null', jpath.read_text(encoding="utf-8"))
            self.assertIsNone(read_scans_jsonl(jpath)[0].blind_code)

        bands = np.array(
            [[-40.0, -42.1], [-40.1, -42.0], [-39.9, -42.2], [-40.0, -42.1], [-26.0, -28.5]]
        )
        _, out_mask = detect_intra_batch_outliers(bands)
        self.assertEqual(out_mask.tolist(), [False, False, False, False, True])

    def test_05_feature_tiers_stepped_tones_and_drift(self) -> None:
        cfg = DSPConfig()
        reg = get_primary_feature_registry(cfg)
        self.assertEqual(len(reg), 25)
        self.assertEqual(reg[0].tier, "TIER_2_FROZEN_VECTOR")

        ess = generate_ess_pair(ESSConfig())
        rng = np.random.default_rng(11)
        wav = simulate_recording(
            ess.framed_excitation, build_container_liquid_ir(LIQUID_PROFILES["H2O_DIST"]), rng
        )
        feat = extract_scan_features(wav, ess, config=cfg)
        self.assertEqual(feat.compact_features.shape[0], 25)

        peaks = extract_modal_peaks(
            0.05
            * np.exp(-90.0 * np.arange(1920) / 48_000.0)
            * np.sin(2.0 * np.pi * 2200.0 * np.arange(1920) / 48_000.0),
            cfg,
        )
        self.assertAlmostEqual(peaks[0].frequency_hz, 2200.0, delta=15.0)

        step = generate_stepped_tones(SteppedToneConfig())
        m_w = analyze_stepped_tones(simulate_stepped_tone_response(step, "H2O_DIST"), step, 18)
        m_o = analyze_stepped_tones(simulate_stepped_tone_response(step, "OIL_VEG"), step, 18)
        self.assertLess(
            float(np.median([m.decay_slope_db_per_s for m in m_o])),
            float(np.median([m.decay_slope_db_per_s for m in m_w])),
        )

        self.assertFalse(
            evaluate_session_calibration_drift(
                feat.raw_resonance_bands_db, feat.raw_resonance_bands_db + 3.0
            )["calibration_valid"]
        )

    def test_06_domain_quarantine_nested_lobo_3state_outputs_and_withheld_unknowns(self) -> None:
        # 1. Batch leakage guard & hardware domain quarantine guard
        s1 = SampleSummary("S1", "H2O_DIST", "B1", True, np.zeros(25), np.zeros(14))
        s2 = SampleSummary("S2", "H2O_DIST", "B1", True, np.ones(25), np.ones(14))
        with self.assertRaises(DataLeakageError):
            verify_disjoint_sample_and_batch_splits([s1], [s2])

        s_ext = SampleSummary(
            "S_EXT",
            "H2O_DIST",
            "B2",
            True,
            np.ones(25),
            np.ones(14),
            hardware_domain="EXTERNAL_TRANSDUCER_DIAGNOSTIC",
        )
        with self.assertRaises(DataLeakageError):
            verify_disjoint_sample_and_batch_splits([s1], [s_ext])

        ess = generate_ess_pair(ESSConfig())

        # 2. Gate 0B: 2-Liquid (Water vs Oil) Nested LOBO-CV
        gate0b_ds = simulate_staged_dataset(
            ess, stage="GATE_0B", reps_per_sample=3, unknown_formulations=(), seed=20261116
        )
        nested_g0b = run_nested_lobo_cv(gate0b_ds["phase1a"], STAGE_FORMULATIONS["GATE_0B"])
        self.assertTrue(nested_g0b["nested_selection_enabled"])
        self.assertGreaterEqual(nested_g0b["open_set_metrics"]["balanced_accuracy"], 0.95)
        self.assertEqual(nested_g0b["per_batch_summary"]["num_independent_batches"], 8)

        # 3. Stage 3 with both UNK_OUTER and withheld UNK_INTERMEDIATE formulations
        clean_ds = simulate_staged_dataset(
            ess,
            stage="STAGE_3",
            reps_per_sample=3,
            unknown_formulations=("GLYCEROL_60", "SYRUP_CORN_DIL", "NACL_040", "SUC_120"),
            inject_nuisance_leakage=False,
            seed=20261116,
        )
        lobo_s1 = run_lobo_cv(
            clean_ds["phase1a"],
            STAGE_FORMULATIONS["STAGE_1"],
            run_permutation_test=True,
            n_permutations=25,
        )
        self.assertGreaterEqual(lobo_s1["open_set_metrics"]["balanced_accuracy"], 0.90)
        self.assertFalse(lobo_s1["nuisance_leakage_diagnostic"]["leakage_warning_triggered"])

        locked_s3 = evaluate_locked_test(
            clean_ds["phase1a"], clean_ds["phase1b"], STAGE_FORMULATIONS["STAGE_3"]
        )
        self.assertGreaterEqual(locked_s3["metrics"]["balanced_accuracy"], 0.85)
        self.assertIn("NACL_040", locked_s3["unknown_evaluation_report"]["per_unknown_liquid"])
        self.assertEqual(
            locked_s3["unknown_evaluation_report"]["per_unknown_liquid"]["NACL_040"][
                "unknown_category"
            ],
            "UNK_INTERMEDIATE",
        )

        # Verify 3-state outcome_statuses (REFERENCE_MATCH, NO_VALIDATED_MATCH, INVALID_MEASUREMENT)
        statuses = {p["outcome_status"] for p in locked_s3["predictions"]}
        self.assertIn(REFERENCE_MATCH_STATUS, statuses)
        self.assertIn(NO_VALIDATED_MATCH_LABEL, statuses)

        with self.assertRaises(RuntimeError):
            evaluate_locked_test(
                clean_ds["phase1a"],
                clean_ds["phase1b"],
                STAGE_FORMULATIONS["STAGE_3"],
                expected_frozen_model_sha256="0" * 64,
            )

        clf = OpenSetAcousticClassifier(ClassifierConfig()).fit(
            np.vstack([s.compact_features for s in clean_ds["phase1a"]]),
            [s.formulation_id for s in clean_ds["phase1a"]],
        )
        bad_qc_sample = SampleSummary(
            "S_BAD",
            "H2O_DIST",
            "B_NEW",
            True,
            clean_ds["phase1b"][0].compact_features,
            np.zeros(14),
            qc_passed=False,
        )
        p_bad = clf.predict_samples([bad_qc_sample])
        self.assertEqual(p_bad["outcome_statuses"][0], INVALID_MEASUREMENT_LABEL)

        leaky_ds = simulate_staged_dataset(
            ess, stage="STAGE_1", reps_per_sample=3, inject_nuisance_leakage=True, seed=99
        )
        self.assertTrue(
            run_lobo_cv(leaky_ds["phase1a"], STAGE_FORMULATIONS["STAGE_1"])[
                "nuisance_leakage_diagnostic"
            ]["leakage_warning_triggered"]
        )

    def test_07_recording_bundle_and_csrd_directory_pipeline(self) -> None:
        ess = generate_ess_pair(ESSConfig())
        rng = np.random.default_rng(123)

        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            records: list[ScanRecord] = []

            sil_wav = rng.normal(0.0, 10.0 ** (-68.0 / 20.0), size=24_000).astype(np.float32)
            write_wav_float32(base / "sil.wav", sil_wav)
            sil_rec = _valid_base_record()
            sil_rec.scan_stage = "BLANK"
            sil_rec.sample_id = "CAL_SIL"
            sil_rec.excitation_signal_id = "SIG_SIL_v1"
            sil_rec.raw_audio_filename = "sil.wav"
            records.append(sil_rec)

            w_wav = simulate_recording(
                ess.framed_excitation, build_container_liquid_ir(LIQUID_PROFILES["H2O_DIST"]), rng
            )
            write_wav_float32(base / "cal_water.wav", w_wav)
            w_rec = _valid_base_record()
            w_rec.scan_stage = "BLANK"
            w_rec.sample_id = "CAL_H2O"
            w_rec.raw_audio_filename = "cal_water.wav"
            records.append(w_rec)

            bundle = process_and_save_recording_bundle(
                base / "cal_water.wav", w_rec, ess, base / "rec_bundle"
            )
            self.assertEqual(bundle["qc_result"]["final_state"], "PROVISIONALLY_ACCEPTED")

            for form_id in STAGE_FORMULATIONS["GATE_0B"]:
                for b in range(2):
                    sid = f"{form_id}_S{b}"
                    ir = build_container_liquid_ir(LIQUID_PROFILES[form_id])
                    for rep in range(3):
                        fname = f"{sid}_r{rep}.wav"
                        write_wav_float32(
                            base / fname, simulate_recording(ess.framed_excitation, ir, rng)
                        )
                        r = _valid_base_record()
                        r.scan_stage = "GATE_0B"
                        r.sample_id = sid
                        r.formulation_id = form_id
                        r.preparation_batch_id = f"{form_id}_B{b}"
                        r.repetition_number = rep + 1
                        r.raw_audio_filename = fname
                        records.append(r)

            write_scans_jsonl(base / "scans.jsonl", records)
            out_rep_dir = base / "exp_reports"
            eval_out = evaluate_csrd_directory(
                base, stage="GATE_0B", output_artifacts_dir=out_rep_dir
            )
            self.assertEqual(eval_out["num_p1a_samples"], 4)
            self.assertGreaterEqual(
                eval_out["phase1a_lobo_cv"]["closed_set_metrics"]["balanced_accuracy"], 0.95
            )
            self.assertTrue((out_rep_dir / "reproducibility_manifest.json").is_file())

    def test_08_swift_milestone3_schema_and_asset_parity(self) -> None:
        from dataclasses import fields
        import json
        import re
        from liquid_analyzer.schema_qc import ALL_QC_FLAGS
        from liquid_analyzer.waveforms import sha256_file

        repo_root = Path(__file__).resolve().parents[1]

        # 1. Verify exact 1-to-1 snake_case field parity between Swift AcquisitionRecord and Python ScanRecord
        swift_rec_text = (
            repo_root / "LiquidAnalyzer" / "Domain" / "AcquisitionRecord.swift"
        ).read_text(encoding="utf-8")
        swift_keys = set(re.findall(r'case\s+\w+\s*=\s*"([^"]+)"', swift_rec_text))
        python_keys = {f.name for f in fields(ScanRecord)}
        self.assertEqual(swift_keys, python_keys)

        # 2. Verify all 22 canonical states in AcquisitionState.swift
        swift_state_text = (
            repo_root / "LiquidAnalyzer" / "Domain" / "AcquisitionState.swift"
        ).read_text(encoding="utf-8")
        state_cases = re.findall(r"^\s*case\s+(\w+)\s*$", swift_state_text, flags=re.MULTILINE)
        self.assertEqual(len(state_cases), 22)

        # 3. Verify all Python QC flags exist in Swift QualityFlag.swift
        swift_flag_text = (
            repo_root / "LiquidAnalyzer" / "Domain" / "QualityFlag.swift"
        ).read_text(encoding="utf-8")
        swift_flags = set(re.findall(r'case\s+\w+\s*=\s*"([^"]+)"', swift_flag_text))
        self.assertTrue(ALL_QC_FLAGS.issubset(swift_flags))

        # 4. Verify Assets/waveform_manifest.json has real SHA-256 digests matching bundled WAVs
        assets_dir = repo_root / "Assets"
        manifest = json.loads((assets_dir / "waveform_manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["protocol_id"], "CS-P1-v1.2")
        self.assertEqual(len(manifest["assets"]), 4)
        for item in manifest["assets"]:
            digest = item["sha256"]
            self.assertEqual(len(digest), 64)
            self.assertNotIn("replace", digest.lower())
            wav_file = assets_dir / item["filename"]
            self.assertTrue(wav_file.is_file())
            self.assertEqual(sha256_file(wav_file), digest)

    def test_09_m3b_bundle_auditor_all_ten_tests(self) -> None:
        from liquid_analyzer.m3b_auditor import audit_m3b_bundle, detect_narrowband_interference
        from liquid_analyzer.waveforms import export_swift_assets_bundle, sha256_file

        # Verify narrowband 60 Hz hum detector
        t = np.arange(24_000, dtype=np.float64) / 48_000.0
        hum_sig = (0.002 * np.sin(2.0 * np.pi * 60.0 * t) + 0.00005 * np.sin(2.0 * np.pi * 900.0 * t)).astype(
            np.float32
        )
        tones = detect_narrowband_interference(hum_sig, sample_rate_hz=48_000)
        self.assertGreaterEqual(len(tones), 1)
        self.assertAlmostEqual(tones[0]["frequency_hz"], 60.0, delta=3.5)

        ess = generate_ess_pair(ESSConfig())
        rng = np.random.default_rng(301)

        with tempfile.TemporaryDirectory() as tmp:
            bdir = Path(tmp)
            wf_manifest = export_swift_assets_bundle(bdir / "reference_waveforms")
            ess_sha = wf_manifest["assets"][0]["sha256"]
            sil_sha = wf_manifest["assets"][3]["sha256"]

            records: list[ScanRecord] = []
            host_cursor = 100.0
            seq = 1

            # 1. Repeated bare-phone silence scans (3B-03, N = 2)
            sil_wav = rng.normal(0.0, 10.0 ** (-70.0 / 20.0), size=24_000).astype(np.float32)
            for sil_rep in (1, 2):
                sil_fname = f"M3B_SIL_rep{sil_rep:02d}.wav"
                sil_rep_wav = rng.normal(0.0, 10.0 ** (-70.0 / 20.0), size=24_000).astype(np.float32)
                sil_hash = write_wav_float32(bdir / sil_fname, sil_rep_wav)
                r_sil = _valid_base_record()
                r_sil.scan_stage = "BLANK"
                r_sil.sample_id = "M3B_SIL"
                r_sil.excitation_signal_id = "SIG_SIL_v1"
                r_sil.excitation_wav_sha256 = sil_sha
                r_sil.repetition_number = sil_rep
                r_sil.scan_timestamp = f"2026-11-16T12:00:{seq:02d}Z"
                r_sil.excitation_start_host_time_s = host_cursor
                r_sil.excitation_end_host_time_s = host_cursor + 0.20
                r_sil.quality_status = "PROVISIONALLY_ACCEPTED"
                r_sil.final_scan_validity = "PROVISIONALLY_ACCEPTED"
                r_sil.quality_flags = []
                r_sil.raw_audio_filename = sil_fname
                r_sil.raw_audio_sha256 = sil_hash
                records.append(r_sil)
                host_cursor += 3.0
                seq += 1

            # 2. Five free-air ESS repetitions (3B-04)
            free_ir = build_container_liquid_ir(None, sample_coupling_scale=0.05)
            for rep in range(1, 6):
                fname = f"M3B_FREE_AIR_rep{rep:02d}.wav"
                w_arr = simulate_recording(ess.framed_excitation, free_ir, rng)
                w_sha = write_wav_float32(bdir / fname, w_arr)
                r = _valid_base_record()
                r.scan_stage = "GATE_0A"
                r.sample_id = "M3B_FREE_AIR"
                r.excitation_signal_id = "SIG_ESS_v1"
                r.excitation_wav_sha256 = ess_sha
                r.repetition_number = rep
                r.scan_timestamp = f"2026-11-16T12:00:{seq:02d}Z"
                r.excitation_start_host_time_s = host_cursor
                r.excitation_end_host_time_s = host_cursor + 0.20
                r.quality_status = "PROVISIONALLY_ACCEPTED"
                r.final_scan_validity = "PROVISIONALLY_ACCEPTED"
                r.quality_flags = []
                r.raw_audio_filename = fname
                r.raw_audio_sha256 = w_sha
                records.append(r)
                host_cursor += 2.5
                seq += 1

            # 3. Occluded port probe Condition B (3B-05)
            occ_ir = build_container_liquid_ir(
                None, sample_coupling_scale=0.02, direct_bleed_scale=0.22
            )
            occ_fname = "M3B_OCCLUDED_BOTTOM_rep01.wav"
            occ_sha = write_wav_float32(
                bdir / occ_fname, simulate_recording(ess.framed_excitation, occ_ir, rng)
            )
            r_occ = _valid_base_record()
            r_occ.scan_stage = "GATE_0A"
            r_occ.sample_id = "M3B_OCCLUDED_BOTTOM"
            r_occ.excitation_signal_id = "SIG_ESS_v1"
            r_occ.excitation_wav_sha256 = ess_sha
            r_occ.repetition_number = 1
            r_occ.scan_timestamp = f"2026-11-16T12:00:{seq:02d}Z"
            r_occ.excitation_start_host_time_s = host_cursor
            r_occ.excitation_end_host_time_s = host_cursor + 0.20
            r_occ.quality_status = "PROVISIONALLY_ACCEPTED"
            r_occ.final_scan_validity = "PROVISIONALLY_ACCEPTED"
            r_occ.quality_flags = []
            r_occ.raw_audio_filename = occ_fname
            r_occ.raw_audio_sha256 = occ_sha
            records.append(r_occ)
            host_cursor += 2.5
            seq += 1

            # 4. Properly rejected out-of-tolerance volume scan (3B-07 & 3B-09)
            rej_fname = "M3B_VOL_ERR_rep01.wav"
            rej_sha = write_wav_float32(
                bdir / rej_fname, simulate_recording(ess.framed_excitation, free_ir, rng)
            )
            r_rej = _valid_base_record()
            r_rej.scan_stage = "GATE_0A"
            r_rej.sample_id = "M3B_VOL_ERR"
            r_rej.excitation_signal_id = "SIG_ESS_v1"
            r_rej.excitation_wav_sha256 = ess_sha
            r_rej.repetition_number = 1
            r_rej.post_scan_hardware_volume = 0.80
            r_rej.scan_timestamp = f"2026-11-16T12:00:{seq:02d}Z"
            r_rej.excitation_start_host_time_s = host_cursor
            r_rej.excitation_end_host_time_s = host_cursor + 0.20
            r_rej.quality_status = "REJECTED"
            r_rej.final_scan_validity = "INVALID_MEASUREMENT"
            r_rej.quality_flags = ["VOLUME_MISMATCH"]
            r_rej.raw_audio_filename = rej_fname
            r_rej.raw_audio_sha256 = rej_sha
            records.append(r_rej)
            host_cursor += 2.5
            seq += 1

            # 5. Subsequent valid post-recovery ESS scan (verifying legal recovery + >=2.0 s cooldown)
            recov_fname = "M3B_FREE_AIR_rep06.wav"
            recov_sha = write_wav_float32(
                bdir / recov_fname, simulate_recording(ess.framed_excitation, free_ir, rng)
            )
            r_recov = _valid_base_record()
            r_recov.scan_stage = "GATE_0A"
            r_recov.sample_id = "M3B_FREE_AIR"
            r_recov.excitation_signal_id = "SIG_ESS_v1"
            r_recov.excitation_wav_sha256 = ess_sha
            r_recov.repetition_number = 6
            r_recov.scan_timestamp = f"2026-11-16T12:00:{seq:02d}Z"
            r_recov.excitation_start_host_time_s = host_cursor
            r_recov.excitation_end_host_time_s = host_cursor + 0.20
            r_recov.quality_status = "PROVISIONALLY_ACCEPTED"
            r_recov.final_scan_validity = "PROVISIONALLY_ACCEPTED"
            r_recov.quality_flags = []
            r_recov.raw_audio_filename = recov_fname
            r_recov.raw_audio_sha256 = recov_sha
            records.append(r_recov)

            write_scans_jsonl(bdir / "scans.jsonl", records)
            out_dir = bdir / "m3b_reports"
            audit = audit_m3b_bundle(bdir, output_report_dir=out_dir)
            self.assertEqual(audit["sop_id"], "CS-SOP-M3B-P1-v1.1")
            self.assertEqual(audit["checklist_id"], "CS-CHK-M3B-P1-v1.0")
            self.assertEqual(audit["operator_sop_id"], "CS-OPS-M3B-P1-v1.0")
            self.assertEqual(audit["acceptance_criteria_id"], "CS-ACC-M3B-P1-v1.0")
            self.assertEqual(audit["disposition"], "PASS")
            self.assertEqual(len(audit["dataset_manifest_sha256"]), 64)
            self.assertEqual(len(audit["threshold_config_sha256"]), 64)
            self.assertIn("build_id", audit["software_build_identity"])
            for test_result in audit["tests"].values():
                self.assertEqual(test_result["status"], "PASS")
            self.assertFalse(audit["tests"]["3B-03_silence_characterization"]["liquid_inference_permitted"])
            self.assertTrue(audit["tests"]["3B-05_port_occlusion_probe"]["material_attenuation_observed"])
            self.assertEqual(
                audit["tests"]["3B-05_port_occlusion_probe"]["physical_path_classification"],
                "DOMINANT_PATH_SUPPORTED",
            )
            self.assertTrue(
                audit["tests"]["3B-09_recoverable_failures"]["subsequent_legal_acquisition_observed"]
            )
            self.assertTrue((out_dir / "m3b_checklist.md").is_file())

            # Verify m3b summarize-audio (Metrics + plots manifest)
            from liquid_analyzer.m3b_auditor import run_m3b_complete_verification, summarize_m3b_audio

            audio_sum = summarize_m3b_audio(bdir, output_report_dir=out_dir)
            self.assertEqual(audio_sum["sop_id"], "CS-SOP-M3B-P1-v1.1")
            self.assertEqual(audio_sum["free_air_ess_summary"]["count"], 6)
            self.assertFalse(audio_sum["silence_summary"]["liquid_inference_permitted"])
            self.assertEqual(len(audio_sum["plots_manifest"]["plots"]), 4)
            self.assertTrue((out_dir / "m3b_audio_metrics.json").is_file())
            self.assertTrue((out_dir / "m3b_plots_manifest.json").is_file())

            # Verify CS-ACC-M3B-P1-v1.0 Section B complete artifact verification (`m3b run-all`)
            full_ver = run_m3b_complete_verification(bdir, out_dir / "complete_set")
            self.assertEqual(full_ver["disposition"], "PASS")
            self.assertTrue(full_ver["required_artifacts_complete"])

            # Verify weak port-occlusion (< 2.0 dB) is recorded as PATH INDETERMINATE without rewriting port identity,
            # and missing recoverable-failure exercise yields CONDITIONAL per CS-ACC-M3B-P1-v1.0 Sections A & D
            weak_occ_ir = build_container_liquid_ir(
                None, sample_coupling_scale=0.05, direct_bleed_scale=0.98
            )
            write_wav_float32(
                bdir / occ_fname, simulate_recording(ess.framed_excitation, weak_occ_ir, rng)
            )
            r_occ.raw_audio_sha256 = sha256_file(bdir / occ_fname)
            rej_bytes = (bdir / rej_fname).read_bytes()
            (bdir / rej_fname).unlink()
            no_failure_records = [rec_i for rec_i in records if rec_i.sample_id != "M3B_VOL_ERR"]
            write_scans_jsonl(bdir / "scans.jsonl", no_failure_records)
            audit_cond = audit_m3b_bundle(bdir)
            self.assertEqual(
                audit_cond["tests"]["3B-05_port_occlusion_probe"]["physical_path_classification"],
                "PATH INDETERMINATE",
            )
            self.assertIsNone(
                audit_cond["tests"]["3B-05_port_occlusion_probe"]["dominant_attenuated_condition"]
            )
            self.assertEqual(audit_cond["tests"]["3B-09_recoverable_failures"]["status"], "NOT_RUN")
            self.assertEqual(audit_cond["disposition"], "CONDITIONAL")

            # Restore rej WAV and full records with updated weak-occlusion hash for remaining negative tests
            (bdir / rej_fname).write_bytes(rej_bytes)
            write_scans_jsonl(bdir / "scans.jsonl", records)

            # Inject a rejected scan violating the >=2.0 s cooldown and verify 3B-08 fails across ALL paths
            r_fast_abort = _valid_base_record()
            r_fast_abort.scan_stage = "GATE_0A"
            r_fast_abort.sample_id = "M3B_ABORT_FAST"
            r_fast_abort.excitation_signal_id = "SIG_ESS_v1"
            r_fast_abort.excitation_wav_sha256 = ess_sha
            r_fast_abort.repetition_number = 1
            r_fast_abort.scan_timestamp = f"2026-11-16T12:00:{seq + 1:02d}Z"
            r_fast_abort.excitation_start_host_time_s = records[-1].excitation_end_host_time_s + 0.75
            r_fast_abort.excitation_end_host_time_s = r_fast_abort.excitation_start_host_time_s + 0.10
            r_fast_abort.quality_status = "INTERRUPTED"
            r_fast_abort.final_scan_validity = "INVALID_MEASUREMENT"
            r_fast_abort.quality_flags = ["OPERATOR_ABORTED"]
            r_fast_abort.raw_audio_filename = None
            r_fast_abort.raw_audio_sha256 = None
            write_scans_jsonl(bdir / "scans.jsonl", records + [r_fast_abort])
            audit_cd_fail = audit_m3b_bundle(bdir)
            self.assertEqual(audit_cd_fail["disposition"], "FAIL")
            self.assertEqual(audit_cd_fail["tests"]["3B-08_cooldown_invariant"]["status"], "FAIL")

            # Restore scans.jsonl, inject an orphan WAV, and verify 3B-10 flags FAIL
            write_scans_jsonl(bdir / "scans.jsonl", records)
            write_wav_float32(bdir / "orphan_untracked.wav", sil_wav)
            audit_fail = audit_m3b_bundle(bdir)
            self.assertEqual(audit_fail["disposition"], "FAIL")
            self.assertEqual(audit_fail["tests"]["3B-10_raw_data_integrity"]["status"], "FAIL")

    def test_10_gate0b_preregistered_decision_engine_and_metadata_nuisance(self) -> None:
        from dataclasses import replace
        from liquid_analyzer.gate0b_decision import (
            SampleOperationalMetadata,
            evaluate_gate0b_decision,
            evaluate_gate0b_metrics,
            validate_gate0b_design,
        )

        ess = generate_ess_pair(ESSConfig())
        sim = simulate_staged_dataset(
            ess, stage="GATE_0B", reps_per_sample=3, unknown_formulations=(), seed=20261116
        )
        # Combine 4 dev batches (phase1a) + 2 unseen-container batches (phase1b) across SESS_01 & SESS_02
        all_samples = sim["phase1a"] + sim["phase1b"]

        # 1. Incomplete dataset (< 4 preparations/class) -> GATE_INCOMPLETE before model scoring
        design_inc = validate_gate0b_design(sim["phase1b"])
        self.assertEqual(design_inc["status"], "GATE_INCOMPLETE")
        self.assertFalse(design_inc["labels_scored"])
        inc = evaluate_gate0b_decision(sim["phase1b"])
        self.assertEqual(inc["sop_id"], "CS-SOP-M3B-P1-v1.1")
        self.assertEqual(inc["disposition"], "GATE_INCOMPLETE")
        self.assertGreaterEqual(len(inc["decision_reasons"]), 1)
        self.assertEqual(len(inc["dataset_manifest_sha256"]), 64)
        self.assertEqual(len(inc["threshold_config_sha256"]), 64)

        # Complete design check
        design_ok = validate_gate0b_design(all_samples)
        self.assertEqual(design_ok["status"], "COMPLETE")
        self.assertFalse(design_ok["labels_scored"])

        # 2. Properly interleaved/randomized acquisition order -> DECISION_A_PROCEED
        rng = np.random.default_rng(42)
        shuffled_indices = list(rng.permutation(len(all_samples)))
        clean_op_meta: dict[str, SampleOperationalMetadata] = {}
        sess_cnt: dict[str, int] = {}
        for seq_idx, orig_i in enumerate(shuffled_indices, start=1):
            s = all_samples[int(orig_i)]
            sc = sess_cnt.get(s.session_id, 0) + 1
            sess_cnt[s.session_id] = sc
            clean_op_meta[s.sample_id] = SampleOperationalMetadata(
                sample_id=s.sample_id,
                acquisition_sequence_index=seq_idx,
                within_session_order_index=sc,
                session_id=s.session_id,
                container_id=s.container_id,
            )

        eval_res = evaluate_gate0b_metrics(
            all_samples,
            gate0a_signal_path_valid=True,
            max_session_drift_db=0.25,
            operational_meta=clean_op_meta,
        )
        self.assertEqual(eval_res["status"], "EVALUATED")
        self.assertEqual(len(eval_res["threshold_matrix"]), 10)

        dec_a = evaluate_gate0b_decision(
            all_samples,
            gate0a_signal_path_valid=True,
            max_session_drift_db=0.25,
            operational_meta=clean_op_meta,
        )
        self.assertEqual(dec_a["sop_id"], "CS-SOP-M3B-P1-v1.1")
        self.assertEqual(dec_a["disposition"], "DECISION_A_PROCEED")
        self.assertTrue(all(dec_a["criteria_checklist"].values()))
        self.assertGreaterEqual(len(dec_a["decision_reasons"]), 1)

        # 3. Deliberate class-order / session confounding (all Water in SESS_01 first, all Oil in SESS_02 second)
        confounded_samples = [
            replace(
                s,
                session_id=("SESS_01" if s.formulation_id == "H2O_DIST" else "SESS_02"),
            )
            for s in all_samples
        ]
        leaky_op_meta: dict[str, SampleOperationalMetadata] = {}
        for idx, s in enumerate(confounded_samples, start=1):
            order_val = idx if s.formulation_id == "H2O_DIST" else (100 + idx)
            leaky_op_meta[s.sample_id] = SampleOperationalMetadata(
                sample_id=s.sample_id,
                acquisition_sequence_index=order_val,
                within_session_order_index=order_val,
                session_id=s.session_id,
                container_id=s.container_id,
            )

        dec_leaky = evaluate_gate0b_decision(
            confounded_samples, operational_meta=leaky_op_meta
        )
        self.assertFalse(dec_leaky["non_acoustic_metadata_nuisance_control"]["passed"])
        self.assertEqual(dec_leaky["disposition"], "DECISION_B_HOLD_AND_REDESIGN")

        # 4. Native SNR inadequate -> DECISION_C vs external failed -> DECISION_D
        dec_c = evaluate_gate0b_decision(
            all_samples, native_snr_adequate=False, operational_meta=clean_op_meta
        )
        self.assertEqual(dec_c["disposition"], "DECISION_C_EXTERNAL_TRANSDUCER_DIAGNOSTIC")

        dec_d = evaluate_gate0b_decision(
            all_samples,
            native_snr_adequate=False,
            external_diagnostic_passed=False,
            operational_meta=clean_op_meta,
        )
        self.assertEqual(dec_d["disposition"], "DECISION_D_PHENOMENON_NOT_ESTABLISHED")

    def test_11_appendix_a_nested_cli_and_provenance_digests(self) -> None:
        from contextlib import redirect_stdout
        import io
        import json
        from liquid_analyzer.cli import main

        ess = generate_ess_pair(ESSConfig())
        rng = np.random.default_rng(777)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            g0b_dir = root / "gate0b_bundle"
            g0b_dir.mkdir(parents=True)
            out_dir = root / "cli_reports"

            # Build a complete interleaved Gate 0B CSRD-P1 bundle (2 sessions, 4 dev preps/class + 1 unseen holdout/class)
            records: list[ScanRecord] = []
            host_t = 50.0
            seq = 1

            for sess_id in ("SESS_01", "SESS_02"):
                sil_w = rng.normal(0.0, 10.0 ** (-68.0 / 20.0), size=24_000).astype(np.float32)
                sil_name = f"{sess_id}_SIL.wav"
                sil_sha = write_wav_float32(g0b_dir / sil_name, sil_w)
                r_s = _valid_base_record()
                r_s.session_id = sess_id
                r_s.scan_stage = "BLANK"
                r_s.sample_id = f"{sess_id}_SIL"
                r_s.excitation_signal_id = "SIG_SIL_v1"
                r_s.repetition_number = 1
                r_s.scan_timestamp = f"2026-11-16T14:00:{seq:02d}Z"
                r_s.excitation_start_host_time_s = host_t
                r_s.excitation_end_host_time_s = host_t + 0.20
                r_s.quality_status = "PROVISIONALLY_ACCEPTED"
                r_s.final_scan_validity = "PROVISIONALLY_ACCEPTED"
                r_s.quality_flags = []
                r_s.raw_audio_filename = sil_name
                r_s.raw_audio_sha256 = sil_sha
                records.append(r_s)
                host_t += 2.5
                seq += 1

                wcal_ir = build_container_liquid_ir(LIQUID_PROFILES["H2O_DIST"])
                wcal_w = simulate_recording(ess.framed_excitation, wcal_ir, rng)
                wcal_name = f"{sess_id}_WCAL.wav"
                wcal_sha = write_wav_float32(g0b_dir / wcal_name, wcal_w)
                r_w = _valid_base_record()
                r_w.session_id = sess_id
                r_w.scan_stage = "BLANK"
                r_w.formulation_id = "H2O_DIST"
                r_w.sample_id = f"{sess_id}_WCAL"
                r_w.excitation_signal_id = "SIG_ESS_v1"
                r_w.repetition_number = 1
                r_w.scan_timestamp = f"2026-11-16T14:00:{seq:02d}Z"
                r_w.excitation_start_host_time_s = host_t
                r_w.excitation_end_host_time_s = host_t + 0.20
                r_w.quality_status = "PROVISIONALLY_ACCEPTED"
                r_w.final_scan_validity = "PROVISIONALLY_ACCEPTED"
                r_w.quality_flags = []
                r_w.raw_audio_filename = wcal_name
                r_w.raw_audio_sha256 = wcal_sha
                records.append(r_w)
                host_t += 2.5
                seq += 1

            # Interleaved sample specifications: 5 preps/class (4 dev on CONT_A/CONT_B + 1 unseen on CONT_HOLD)
            sample_specs = []
            for p_idx in range(5):
                is_hold = p_idx == 4
                sess_id = "SESS_01" if (p_idx % 2 == 0) else "SESS_02"
                cont_id = "CONT_HOLD" if is_hold else ("CONT_A" if p_idx < 2 else "CONT_B")
                for cls_id in ("H2O_DIST", "OIL_VEG"):
                    sample_specs.append((cls_id, p_idx + 1, sess_id, cont_id, is_hold))

            # Randomize acquisition sequence across classes/containers so operational metadata is unconfounded
            rng.shuffle(sample_specs)
            for cls_id, p_num, sess_id, cont_id, is_hold in sample_specs:
                ir = build_container_liquid_ir(
                    LIQUID_PROFILES[cls_id],
                    sample_freq_jitter_pct=float(rng.normal(0.0, 0.004)),
                )
                for rep in (1, 2):
                    sid = f"{cls_id}_P{p_num}"
                    fname = f"{sid}_rep{rep:02d}.wav"
                    w_arr = simulate_recording(ess.framed_excitation, ir, rng)
                    w_sha = write_wav_float32(g0b_dir / fname, w_arr)
                    rec = _valid_base_record()
                    rec.session_id = sess_id
                    rec.scan_stage = "GATE_0B"
                    rec.sample_id = sid
                    rec.formulation_id = cls_id
                    rec.preparation_batch_id = f"{cls_id}_BATCH_{p_num}"
                    rec.container_id = cont_id
                    rec.is_held_out_container = is_hold
                    rec.excitation_signal_id = "SIG_ESS_v1"
                    rec.repetition_number = rep
                    rec.scan_timestamp = f"2026-11-16T14:{5 + (seq // 60):02d}:{seq % 60:02d}Z"
                    rec.excitation_start_host_time_s = host_t
                    rec.excitation_end_host_time_s = host_t + 0.20
                    rec.quality_status = "PROVISIONALLY_ACCEPTED"
                    rec.final_scan_validity = "FINAL_ACCEPTED"
                    rec.quality_flags = []
                    rec.raw_audio_filename = fname
                    rec.raw_audio_sha256 = w_sha
                    records.append(rec)
                    host_t += 2.5
                    seq += 1

            write_scans_jsonl(g0b_dir / "scans.jsonl", records)

            def _run_cli(cli_args: list[str]) -> dict[str, object]:
                buf = io.StringIO()
                with redirect_stdout(buf):
                    rc = main(cli_args)
                self.assertEqual(rc, 0)
                return json.loads(buf.getvalue())

            # 1. m3b audit-bundle & m3b summarize-audio
            m3b_audit = _run_cli(
                ["m3b", "audit-bundle", "--bundle-dir", str(g0b_dir), "--output-dir", str(out_dir)]
            )
            self.assertEqual(m3b_audit["sop_id"], "CS-SOP-M3B-P1-v1.1")
            self.assertEqual(len(str(m3b_audit["dataset_manifest_sha256"])), 64)

            m3b_sum = _run_cli(
                ["m3b", "summarize-audio", "--bundle-dir", str(g0b_dir), "--output-dir", str(out_dir)]
            )
            self.assertIn("plots_manifest", m3b_sum)
            self.assertTrue((out_dir / "m3b_plots_manifest.json").is_file())

            m3b_all = _run_cli(
                ["m3b", "run-all", "--bundle-dir", str(g0b_dir), "--output-dir", str(out_dir / "step10")]
            )
            self.assertTrue(m3b_all["required_artifacts_complete"])
            self.assertEqual(m3b_all["acceptance_criteria_id"], "CS-ACC-M3B-P1-v1.0")

            # 2. gate0b validate-design (COMPLETE, labels_scored == False)
            g0b_val = _run_cli(
                ["gate0b", "validate-design", "--dataset-dir", str(g0b_dir), "--output-dir", str(out_dir)]
            )
            self.assertEqual(g0b_val["status"], "COMPLETE")
            self.assertFalse(g0b_val["labels_scored"])
            self.assertTrue((out_dir / "gate0b_design_validation.json").is_file())

            # 3. gate0b evaluate (Metrics + threshold matrix)
            g0b_eval = _run_cli(
                ["gate0b", "evaluate", "--dataset-dir", str(g0b_dir), "--output-dir", str(out_dir)]
            )
            self.assertEqual(g0b_eval["status"], "EVALUATED")
            self.assertTrue((out_dir / "gate0b_threshold_matrix.md").is_file())

            # 4. gate0b decide (DECISION_A_PROCEED + reasons + provenance digests)
            g0b_dec = _run_cli(
                ["gate0b", "decide", "--dataset-dir", str(g0b_dir), "--output-dir", str(out_dir)]
            )
            self.assertEqual(
                g0b_dec["disposition"],
                "DECISION_A_PROCEED",
                msg=str(g0b_dec.get("decision_reasons")),
            )
            self.assertEqual(
                g0b_dec["dataset_manifest_sha256"], g0b_val["dataset_manifest_sha256"]
            )
            self.assertTrue((out_dir / "gate0b_decision_report.json").is_file())
            self.assertTrue((out_dir / "gate0b_summary.md").is_file())


if __name__ == "__main__":
    unittest.main()
