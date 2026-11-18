"""Command-line interface for the Liquid Analyzer Phase 1 (v1.2 / CS-SOP-M3B-P1-v1.1) reference pipeline.

Provides the controlled Appendix A.3 nested CLI surface:
- `m3b audit-bundle`
- `m3b summarize-audio`
- `gate0b validate-design`
- `gate0b evaluate`
- `gate0b decide`
as well as reference waveform generation, single-recording inspection, CSRD-P1 evaluation, and synthetic validation.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
from typing import Any

import numpy as np

from .classification import (
    STAGE_FORMULATIONS,
    ClassifierConfig,
    SampleSummary,
    evaluate_locked_test,
    run_lobo_cv,
)
from .dsp import (
    DSPConfig,
    aggregate_sample_repetitions,
    evaluate_session_calibration_drift,
    extract_scan_features,
)
from .gate0b_decision import (
    GATE0B_CLASSES,
    SampleOperationalMetadata,
    evaluate_gate0b_decision,
    evaluate_gate0b_metrics,
    validate_gate0b_design,
)
from .m3b_auditor import audit_m3b_bundle, run_m3b_complete_verification, summarize_m3b_audio
from .reporting import write_experiment_artifacts
from .schema_qc import QCThresholds, evaluate_scan_qc, read_scans_jsonl
from .synthetic import simulate_staged_dataset
from .waveforms import (
    ESSConfig,
    export_reference_waveform_bundle,
    export_swift_assets_bundle,
    generate_ess_pair,
    read_wav_float32,
    sha256_file,
)


def _cmd_generate_waveforms(args: argparse.Namespace) -> int:
    manifest = export_reference_waveform_bundle(Path(args.output_dir))
    print(json.dumps(manifest, indent=2))
    return 0


def _cmd_generate_swift_assets(args: argparse.Namespace) -> int:
    manifest = export_swift_assets_bundle(Path(args.output_dir))
    print(json.dumps(manifest, indent=2))
    return 0


def _cmd_inspect_recording(args: argparse.Namespace) -> int:
    ess_pair = generate_ess_pair(ESSConfig())
    sr, rec = read_wav_float32(args.recording)
    if sr != ess_pair.config.sample_rate_hz:
        raise SystemExit(
            f"Sample rate mismatch: expected {ess_pair.config.sample_rate_hz} Hz, got {sr} Hz."
        )

    water_bands = None
    if args.water_cal:
        w_sr, w_rec = read_wav_float32(args.water_cal)
        if w_sr != sr:
            raise SystemExit("Water calibration WAV sample rate does not match recording.")
        water_bands = extract_scan_features(w_rec, ess_pair).raw_resonance_bands_db

    res = extract_scan_features(rec, ess_pair, water_cal_bands_db=water_bands)
    summary = {
        "recording": str(args.recording),
        "sample_rate_hz": sr,
        "t0_latency_ms": res.t0_latency_ms,
        "alignment_delay_ms": res.alignment_delay_ms,
        "normalized_xcorr_peak": res.normalized_xcorr_peak,
        "late_room_snr_db": res.late_room_snr_db,
        "direct_to_tail_ratio_db": res.direct_to_tail_ratio_db,
        "harmonic_ratio_db": res.harmonic_ratio_db,
        "ringdown_slopes_db_per_s": list(res.ringdown_slopes_db_per_s),
        "t20_estimates_ms": list(res.t20_estimates_ms),
        "modal_peaks": [
            {
                "frequency_hz": p.frequency_hz,
                "magnitude_db": p.magnitude_db,
                "prominence_db": p.prominence_db,
                "bandwidth_3db_hz": p.bandwidth_3db_hz,
                "q_factor": p.q_factor,
            }
            for p in res.modal_peaks
        ],
        "compact_features": dict(
            zip(res.compact_feature_names, [round(float(v), 5) for v in res.compact_features])
        ),
    }
    print(json.dumps(summary, indent=2))
    return 0


def evaluate_csrd_directory(
    dataset_dir: Path | str,
    stage: str = "STAGE_1",
    classifier_type: str = "ridge_linear",
    output_artifacts_dir: Path | str | None = None,
) -> dict[str, Any]:
    """Load a CSRD-P1 directory (scans.jsonl + WAVs), enforce QC, check drift, and evaluate."""
    base = Path(dataset_dir)
    jsonl_path = base / "scans.jsonl"
    records = read_scans_jsonl(jsonl_path)
    ess_pair = generate_ess_pair(ESSConfig())
    dsp_cfg = DSPConfig()
    qc_cfg = QCThresholds()

    input_hashes: dict[str, str] = {"scans.jsonl": sha256_file(jsonl_path)}

    session_silence_db: dict[str, float] = {}
    session_water_scans: dict[str, list[np.ndarray]] = defaultdict(list)

    for rec in records:
        if rec.raw_audio_filename and (base / rec.raw_audio_filename).is_file():
            input_hashes[rec.raw_audio_filename] = sha256_file(base / rec.raw_audio_filename)
        if rec.excitation_signal_id == "SIG_SIL_v1" and rec.raw_audio_filename and rec.session_id:
            _, wav = read_wav_float32(base / rec.raw_audio_filename)
            _, _, _, pre_rms = evaluate_scan_qc(
                rec,
                wav,
                pre_roll_samples=wav.shape[0],
                active_samples=0,
                thresholds=qc_cfg,
                is_silence_control=True,
                is_liquid_sample=False,
            )
            session_silence_db[rec.session_id] = pre_rms

        if (
            rec.scan_stage == "BLANK"
            and rec.formulation_id == "H2O_DIST"
            and rec.excitation_signal_id == "SIG_ESS_v1"
            and rec.raw_audio_filename
            and rec.session_id
        ):
            _, wav = read_wav_float32(base / rec.raw_audio_filename)
            feat = extract_scan_features(wav, ess_pair, config=dsp_cfg)
            session_water_scans[rec.session_id].append(feat.raw_resonance_bands_db)

    water_cal_lookup: dict[str, np.ndarray] = {}
    drift_by_session: dict[str, Any] = {}
    session_cal_valid: dict[str, bool] = {}

    for sess, w_list in session_water_scans.items():
        water_cal_lookup[sess] = np.median(np.vstack(w_list), axis=0)
        if len(w_list) >= 2:
            drift = evaluate_session_calibration_drift(
                w_list[0], w_list[-1], drift_limit_db=qc_cfg.calibration_drift_limit_db
            )
        else:
            drift = {
                "water_rms_drift_db": 0.0,
                "calibration_valid": True,
                "flag": "SINGLE_POINT_CALIBRATION",
            }
        drift_by_session[sess] = drift
        session_cal_valid[sess] = bool(drift["calibration_valid"])

    grouped_scans: dict[tuple[str, str], list[tuple[Any, Any]]] = defaultdict(list)
    qc_counts: dict[str, int] = {
        "PROVISIONALLY_ACCEPTED": 0,
        "REJECTED": 0,
        "INTERRUPTED": 0,
        "INCOMPLETE": 0,
    }

    for rec in records:
        if rec.scan_stage not in ("GATE_0B", "P1A", "P1B") or rec.excitation_signal_id != "SIG_ESS_v1":
            continue
        if not rec.raw_audio_filename or not rec.sample_id:
            qc_counts["INCOMPLETE"] += 1
            continue

        audio_file = base / rec.raw_audio_filename
        if not audio_file.is_file():
            qc_counts["INCOMPLETE"] += 1
            continue

        _, wav = read_wav_float32(audio_file)
        state, _, _, _ = evaluate_scan_qc(
            rec,
            wav,
            pre_roll_samples=ess_pair.pre_roll_samples,
            active_samples=ess_pair.active_samples,
            thresholds=qc_cfg,
            silence_baseline_rms_dbfs=session_silence_db.get(rec.session_id or ""),
            is_silence_control=False,
            is_liquid_sample=True,
        )
        effective_state = (
            rec.quality_status
            if rec.quality_status in qc_counts and rec.quality_status != "PROVISIONALLY_ACCEPTED"
            else state
        )
        qc_counts[effective_state] = qc_counts.get(effective_state, 0) + 1
        if effective_state != "PROVISIONALLY_ACCEPTED":
            continue

        w_cal = water_cal_lookup.get(rec.session_id or "")
        feat = extract_scan_features(wav, ess_pair, water_cal_bands_db=w_cal, config=dsp_cfg)
        grouped_scans[(rec.scan_stage, rec.sample_id)].append((rec, feat))

    target_forms = STAGE_FORMULATIONS[stage]
    p1a_samples: list[SampleSummary] = []
    p1b_samples: list[SampleSummary] = []

    for (st_name, sample_id), items in grouped_scans.items():
        first_rec = items[0][0]
        agg = aggregate_sample_repetitions([it[1] for it in items])
        sess_id = first_rec.session_id or "S0"
        summary = SampleSummary(
            sample_id=sample_id,
            formulation_id=first_rec.formulation_id or "UNKNOWN_SOURCE",
            preparation_batch_id=first_rec.preparation_batch_id or f"BATCH_{sample_id}",
            is_known_library_class=(first_rec.formulation_id in target_forms),
            compact_features=agg["compact_features"],
            nuisance_features=agg["nuisance_features"],
            repetition_features=agg["repetition_compact_matrix"],
            qc_passed=True,
            calibration_valid=session_cal_valid.get(sess_id, True),
            hardware_domain=first_rec.hardware_domain,
            is_held_out_container=bool(first_rec.is_held_out_container),
            session_id=sess_id,
            container_id=first_rec.container_id or "C0",
            temperature_c=first_rec.sample_temperature_c,
            nominal_volume_ml=first_rec.nominal_volume_ml,
            coupling_force_setting=first_rec.coupling_force_setting or "NOMINAL",
        )
        if st_name in ("GATE_0B", "P1A"):
            p1a_samples.append(summary)
        elif st_name == "P1B":
            p1b_samples.append(summary)

    clf_cfg = ClassifierConfig(classifier_type=classifier_type)
    lobo_res = run_lobo_cv(p1a_samples, target_forms, config=clf_cfg) if p1a_samples else None
    locked_res = (
        evaluate_locked_test(p1a_samples, p1b_samples, target_forms, config=clf_cfg)
        if (p1a_samples and p1b_samples)
        else None
    )

    report: dict[str, Any] = {
        "stage": stage,
        "qc_scan_counts": qc_counts,
        "calibration_drift_by_session": drift_by_session,
        "num_p1a_samples": len(p1a_samples),
        "num_p1b_samples": len(p1b_samples),
        "phase1a_lobo_cv": lobo_res,
        "phase1b_locked_test": locked_res,
    }

    if output_artifacts_dir is not None:
        dataset_manifest = {
            "dataset_dir": str(base),
            "qc_scan_counts": qc_counts,
            "num_p1a_samples": len(p1a_samples),
            "num_p1b_samples": len(p1b_samples),
        }
        split_manifest = {
            "p1a_batches": sorted({s.preparation_batch_id for s in p1a_samples}),
            "p1b_batches": sorted({s.preparation_batch_id for s in p1b_samples}),
        }
        report["written_artifacts"] = write_experiment_artifacts(
            output_dir=output_artifacts_dir,
            stage=stage,
            dataset_manifest=dataset_manifest,
            split_manifest=split_manifest,
            lobo_report=lobo_res,
            locked_report=locked_res,
            calibration_drift_report=drift_by_session,
            input_checksums=input_hashes,
        )

    return report


def _cmd_evaluate_dataset(args: argparse.Namespace) -> int:
    report = evaluate_csrd_directory(
        args.dataset_dir,
        stage=args.stage,
        classifier_type=args.classifier,
        output_artifacts_dir=args.output_dir,
    )
    print(json.dumps(report, indent=2))
    return 0


def _cmd_run_synthetic_validation(args: argparse.Namespace) -> int:
    ess_pair = generate_ess_pair(ESSConfig())
    results: dict[str, Any] = {}
    for stage_name in ("STAGE_1", "STAGE_2", "STAGE_3"):
        sim = simulate_staged_dataset(ess_pair, stage=stage_name, seed=args.seed)
        target_forms = STAGE_FORMULATIONS[stage_name]
        lobo = run_lobo_cv(sim["phase1a"], target_forms)
        locked = evaluate_locked_test(sim["phase1a"], sim["phase1b"], target_forms)
        results[stage_name] = {
            "lobo_balanced_accuracy": lobo["open_set_metrics"]["balanced_accuracy"],
            "lobo_ci_95": lobo["balanced_accuracy_ci_95"],
            "lobo_closed_balanced_accuracy": lobo["closed_set_metrics"]["balanced_accuracy"],
            "nuisance_balanced_accuracy": lobo["nuisance_leakage_diagnostic"][
                "nuisance_balanced_accuracy"
            ],
            "leakage_warning": lobo["nuisance_leakage_diagnostic"]["leakage_warning_triggered"],
            "locked_balanced_accuracy": locked["metrics"]["balanced_accuracy"],
            "locked_unknown_rejection_rate": locked["metrics"]["unknown_rejection_rate"],
            "frozen_model_sha256": locked["frozen_model_sha256"],
        }
    print(json.dumps(results, indent=2))
    return 0


def _cmd_m3b_audit_bundle(args: argparse.Namespace) -> int:
    report = audit_m3b_bundle(args.bundle_dir, output_report_dir=args.output_dir)
    print(json.dumps(report, indent=2))
    return 0


def _cmd_m3b_summarize_audio(args: argparse.Namespace) -> int:
    report = summarize_m3b_audio(args.bundle_dir, output_report_dir=args.output_dir)
    print(json.dumps(report, indent=2))
    return 0


def _cmd_m3b_run_all(args: argparse.Namespace) -> int:
    report = run_m3b_complete_verification(args.bundle_dir, output_report_dir=args.output_dir)
    print(json.dumps(report, indent=2))
    return 0


def _load_gate0b_bundle(
    dataset_dir: Path | str,
    extract_acoustic_features: bool = True,
) -> tuple[list[SampleSummary], dict[str, SampleOperationalMetadata], float, dict[str, Any]]:
    """Load a Gate 0B CSRD-P1 directory into SampleSummary records.

    When `extract_acoustic_features=False` (`gate0b validate-design`), only QC and design structure
    are inspected and placeholder zero vectors are attached so zero acoustic feature/model scoring occurs.
    """
    base = Path(dataset_dir)
    records = read_scans_jsonl(base / "scans.jsonl")
    ess_pair = generate_ess_pair(ESSConfig())
    dsp_cfg = DSPConfig()
    qc_cfg = QCThresholds()

    session_silence_db: dict[str, float] = {}
    session_water_scans: dict[str, list[np.ndarray]] = defaultdict(list)

    for rec in records:
        if (
            rec.excitation_signal_id == "SIG_SIL_v1"
            and rec.raw_audio_filename
            and rec.session_id
            and (base / rec.raw_audio_filename).is_file()
        ):
            _, wav = read_wav_float32(base / rec.raw_audio_filename)
            _, _, _, pre_rms = evaluate_scan_qc(
                rec,
                wav,
                pre_roll_samples=wav.shape[0],
                active_samples=0,
                thresholds=qc_cfg,
                is_silence_control=True,
                is_liquid_sample=False,
            )
            session_silence_db[rec.session_id] = pre_rms

        if (
            extract_acoustic_features
            and rec.scan_stage == "BLANK"
            and rec.formulation_id == "H2O_DIST"
            and rec.excitation_signal_id == "SIG_ESS_v1"
            and rec.raw_audio_filename
            and rec.session_id
            and (base / rec.raw_audio_filename).is_file()
        ):
            _, wav = read_wav_float32(base / rec.raw_audio_filename)
            feat = extract_scan_features(wav, ess_pair, config=dsp_cfg)
            session_water_scans[rec.session_id].append(feat.raw_resonance_bands_db)

    water_cal_lookup: dict[str, np.ndarray] = {}
    max_drift_db = 0.0
    session_cal_valid: dict[str, bool] = {}

    for sess, w_list in session_water_scans.items():
        water_cal_lookup[sess] = np.median(np.vstack(w_list), axis=0)
        if len(w_list) >= 2:
            drift = evaluate_session_calibration_drift(
                w_list[0], w_list[-1], drift_limit_db=qc_cfg.calibration_drift_limit_db
            )
            max_drift_db = max(max_drift_db, float(drift["water_rms_drift_db"]))
            session_cal_valid[sess] = bool(drift["calibration_valid"])
        else:
            session_cal_valid[sess] = True

    grouped_scans: dict[str, list[tuple[Any, Any]]] = defaultdict(list)
    sample_first_seq: dict[str, int] = {}
    seq_counter = 0

    attempted_scans = 0
    prov_accepted_scans = 0
    final_accepted_scans = 0
    invalid_by_reason: Counter[str] = Counter()

    for rec in records:
        if rec.scan_stage not in ("GATE_0B", "P1A", "P1B") or rec.excitation_signal_id != "SIG_ESS_v1":
            continue
        attempted_scans += 1
        if (
            not rec.raw_audio_filename
            or not rec.sample_id
            or not (base / rec.raw_audio_filename).is_file()
        ):
            invalid_by_reason["MISSING_AUDIO_OR_SAMPLE_ID"] += 1
            continue

        _, wav = read_wav_float32(base / rec.raw_audio_filename)
        state, flags, _, _ = evaluate_scan_qc(
            rec,
            wav,
            pre_roll_samples=ess_pair.pre_roll_samples,
            active_samples=ess_pair.active_samples,
            thresholds=qc_cfg,
            silence_baseline_rms_dbfs=session_silence_db.get(rec.session_id or ""),
        )
        effective_state = (
            rec.quality_status
            if rec.quality_status in ("REJECTED", "INTERRUPTED", "INCOMPLETE")
            else state
        )
        if effective_state != "PROVISIONALLY_ACCEPTED":
            for fl in (rec.quality_flags or flags or [effective_state]):
                invalid_by_reason[fl] += 1
            continue

        prov_accepted_scans += 1
        if rec.final_scan_validity in ("FINAL_ACCEPTED", "PROVISIONALLY_ACCEPTED", None):
            final_accepted_scans += 1

        seq_counter += 1
        if rec.sample_id not in sample_first_seq:
            sample_first_seq[rec.sample_id] = seq_counter

        feat = (
            extract_scan_features(
                wav, ess_pair, water_cal_lookup.get(rec.session_id or ""), config=dsp_cfg
            )
            if extract_acoustic_features
            else None
        )
        grouped_scans[rec.sample_id].append((rec, feat))

    samples: list[SampleSummary] = []
    op_meta: dict[str, SampleOperationalMetadata] = {}
    sess_ord_counter: dict[str, int] = defaultdict(int)

    for sample_id, items in grouped_scans.items():
        first_rec = items[0][0]
        sess_id = first_rec.session_id or "S0"
        sess_ord_counter[sess_id] += 1
        if extract_acoustic_features:
            agg = aggregate_sample_repetitions([it[1] for it in items])
            compact_vec = agg["compact_features"]
            nuis_vec = agg["nuisance_features"]
            rep_mat = agg["repetition_compact_matrix"]
        else:
            compact_vec = np.zeros(25, dtype=np.float64)
            nuis_vec = np.zeros(4, dtype=np.float64)
            rep_mat = np.zeros((len(items), 25), dtype=np.float64)

        samples.append(
            SampleSummary(
                sample_id=sample_id,
                formulation_id=first_rec.formulation_id or "UNKNOWN_SOURCE",
                preparation_batch_id=first_rec.preparation_batch_id or f"BATCH_{sample_id}",
                is_known_library_class=(first_rec.formulation_id in GATE0B_CLASSES),
                compact_features=compact_vec,
                nuisance_features=nuis_vec,
                repetition_features=rep_mat,
                qc_passed=True,
                calibration_valid=session_cal_valid.get(sess_id, True),
                hardware_domain=first_rec.hardware_domain,
                is_held_out_container=bool(first_rec.is_held_out_container),
                session_id=sess_id,
                container_id=first_rec.container_id or "C0",
                temperature_c=first_rec.sample_temperature_c,
                nominal_volume_ml=first_rec.nominal_volume_ml,
                coupling_force_setting=first_rec.coupling_force_setting or "NOMINAL",
            )
        )
        op_meta[sample_id] = SampleOperationalMetadata(
            sample_id=sample_id,
            acquisition_sequence_index=sample_first_seq[sample_id],
            within_session_order_index=sess_ord_counter[sess_id],
            session_id=sess_id,
            container_id=first_rec.container_id or "C0",
            coupling_force_setting=first_rec.coupling_force_setting or "NOMINAL",
            ambient_temperature_c=first_rec.ambient_temperature_c or 22.0,
        )

    yield_counts = {
        "attempted_scans": attempted_scans,
        "PROVISIONALLY_ACCEPTED": prov_accepted_scans,
        "FINAL_ACCEPTED": final_accepted_scans,
        "INVALID_MEASUREMENT_by_reason": dict(invalid_by_reason),
    }
    return samples, op_meta, max_drift_db, yield_counts


def validate_gate0b_directory(
    dataset_dir: Path | str,
    output_report_dir: Path | str | None = None,
) -> dict[str, Any]:
    """Validate Gate 0B CSRD-P1 directory study structure and yield BEFORE scoring labels."""
    base = Path(dataset_dir)
    samples, _, _, yield_counts = _load_gate0b_bundle(base, extract_acoustic_features=False)
    return validate_gate0b_design(
        samples,
        scan_yield_counts=yield_counts,
        dataset_dir=base,
        output_report_dir=output_report_dir,
    )


def evaluate_gate0b_metrics_directory(
    dataset_dir: Path | str,
    gate0a_signal_path_valid: bool = True,
    native_snr_adequate: bool = True,
    output_report_dir: Path | str | None = None,
) -> dict[str, Any]:
    """Run frozen grouped Gate 0B evaluation and nuisance controls on a CSRD-P1 directory."""
    base = Path(dataset_dir)
    samples, op_meta, max_drift_db, yield_counts = _load_gate0b_bundle(
        base, extract_acoustic_features=True
    )
    return evaluate_gate0b_metrics(
        samples,
        gate0a_signal_path_valid=gate0a_signal_path_valid,
        native_snr_adequate=native_snr_adequate,
        max_session_drift_db=max_drift_db,
        operational_meta=op_meta,
        scan_yield_counts=yield_counts,
        dataset_dir=base,
        output_report_dir=output_report_dir,
    )


def evaluate_gate0b_directory(
    dataset_dir: Path | str,
    gate0a_signal_path_valid: bool = True,
    native_snr_adequate: bool = True,
    external_diagnostic_passed: bool | None = None,
    output_report_dir: Path | str | None = None,
) -> dict[str, Any]:
    """Load a Gate 0B CSRD-P1 directory and execute the pre-registered Section 16-17 Decision Engine."""
    base = Path(dataset_dir)
    samples, op_meta, max_drift_db, yield_counts = _load_gate0b_bundle(
        base, extract_acoustic_features=True
    )
    return evaluate_gate0b_decision(
        samples,
        gate0a_signal_path_valid=gate0a_signal_path_valid,
        native_snr_adequate=native_snr_adequate,
        max_session_drift_db=max_drift_db,
        operational_meta=op_meta,
        external_diagnostic_passed=external_diagnostic_passed,
        scan_yield_counts=yield_counts,
        dataset_dir=base,
        output_report_dir=output_report_dir,
    )


def _cmd_gate0b_validate_design(args: argparse.Namespace) -> int:
    report = validate_gate0b_directory(args.dataset_dir, output_report_dir=args.output_dir)
    print(json.dumps(report, indent=2))
    return 0


def _cmd_gate0b_evaluate(args: argparse.Namespace) -> int:
    report = evaluate_gate0b_metrics_directory(
        args.dataset_dir,
        gate0a_signal_path_valid=not args.gate0a_failed,
        native_snr_adequate=not getattr(args, "native_snr_inadequate", False),
        output_report_dir=args.output_dir,
    )
    print(json.dumps(report, indent=2))
    return 0


def _cmd_gate0b_decide(args: argparse.Namespace) -> int:
    ext_arg = getattr(args, "external_diagnostic_result", None)
    ext_passed: bool | None = None
    if ext_arg == "pass":
        ext_passed = True
    elif ext_arg == "fail":
        ext_passed = False

    report = evaluate_gate0b_directory(
        args.dataset_dir,
        gate0a_signal_path_valid=not args.gate0a_failed,
        native_snr_adequate=not getattr(args, "native_snr_inadequate", False),
        external_diagnostic_passed=ext_passed,
        output_report_dir=args.output_dir,
    )
    print(json.dumps(report, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="liquid-analyzer",
        description="Liquid Analyzer Phase 1 (v1.2 / CS-SOP-M3B-P1-v1.1) Controlled CLI",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # Appendix A.3: `m3b` nested CLI group
    p_m3b_grp = sub.add_parser(
        "m3b", help="Milestone 3B Bare-Phone Bench Audio Characterization commands (CS-SOP-M3B-P1-v1.1)"
    )
    m3b_sub = p_m3b_grp.add_subparsers(dest="m3b_subcommand", required=True)

    p_m3b_audit = m3b_sub.add_parser(
        "audit-bundle", help="Run 3B-01 through 3B-10 automated checks (JSON + Markdown audit)"
    )
    p_m3b_audit.add_argument("--bundle-dir", required=True, help="Exported M3B session directory")
    p_m3b_audit.add_argument("--output-dir", default=None, help="Optional directory for M3B reports")
    p_m3b_audit.set_defaults(func=_cmd_m3b_audit_bundle)

    p_m3b_sum = m3b_sub.add_parser(
        "summarize-audio",
        help="Silence, ESS, timing, hum and occlusion summaries (Metrics + plots manifest)",
    )
    p_m3b_sum.add_argument("--bundle-dir", required=True, help="Exported M3B session directory")
    p_m3b_sum.add_argument("--output-dir", default=None, help="Optional directory for audio summaries")
    p_m3b_sum.set_defaults(func=_cmd_m3b_summarize_audio)

    p_m3b_all = m3b_sub.add_parser(
        "run-all",
        help="Execute CS-OPS-M3B-P1-v1.0 Step 10 (audit-bundle + summarize-audio) and verify CS-ACC-M3B-P1-v1.0 artifacts",
    )
    p_m3b_all.add_argument("--bundle-dir", required=True, help="Exported M3B session directory")
    p_m3b_all.add_argument("--output-dir", required=True, help="Target directory for complete M3B artifact set")
    p_m3b_all.set_defaults(func=_cmd_m3b_run_all)

    # Appendix A.3: `gate0b` nested CLI group
    p_g0b_grp = sub.add_parser(
        "gate0b", help="Pre-registered Gate 0B study-structure, evaluation & Stop/Go decision commands"
    )
    g0b_sub = p_g0b_grp.add_subparsers(dest="gate0b_subcommand", required=True)

    p_g0b_val = g0b_sub.add_parser(
        "validate-design",
        help="Check preparations, classes, sessions, groups and holdouts before labels are scored",
    )
    p_g0b_val.add_argument("--dataset-dir", required=True, help="Gate 0B CSRD-P1 directory")
    p_g0b_val.add_argument("--output-dir", default=None, help="Optional directory for design validation")
    p_g0b_val.set_defaults(func=_cmd_gate0b_validate_design)

    p_g0b_eval = g0b_sub.add_parser(
        "evaluate", help="Run frozen grouped evaluation and nuisance controls (Metrics + threshold matrix)"
    )
    p_g0b_eval.add_argument("--dataset-dir", required=True, help="Gate 0B CSRD-P1 directory")
    p_g0b_eval.add_argument("--gate0a-failed", action="store_true", help="Mark Gate 0A signal path invalid")
    p_g0b_eval.add_argument("--native-snr-inadequate", action="store_true", help="Mark native iPhone SNR inadequate")
    p_g0b_eval.add_argument("--output-dir", default=None, help="Optional directory for evaluation outputs")
    p_g0b_eval.set_defaults(func=_cmd_gate0b_evaluate)

    p_g0b_dec = g0b_sub.add_parser(
        "decide", help="Apply Sections 16-17 without threshold editing (A/B/C/D/GATE_INCOMPLETE + reasons)"
    )
    p_g0b_dec.add_argument("--dataset-dir", required=True, help="Gate 0B CSRD-P1 directory")
    p_g0b_dec.add_argument("--gate0a-failed", action="store_true", help="Mark Gate 0A signal path invalid")
    p_g0b_dec.add_argument("--native-snr-inadequate", action="store_true", help="Mark native iPhone SNR inadequate")
    p_g0b_dec.add_argument(
        "--external-diagnostic-result",
        choices=["pass", "fail"],
        default=None,
        help="Optional segregated external-transducer diagnostic result",
    )
    p_g0b_dec.add_argument("--output-dir", default=None, help="Optional directory for decision outputs")
    p_g0b_dec.set_defaults(func=_cmd_gate0b_decide)

    # Waveform & general reference commands (+ backward-compatible aliases)
    p_gen = sub.add_parser(
        "generate-waveforms", help="Generate versioned Float32 WAVs and SHA-256 manifest"
    )
    p_gen.add_argument("--output-dir", default="reference_waveforms", help="Target directory")
    p_gen.set_defaults(func=_cmd_generate_waveforms)

    p_sw = sub.add_parser(
        "generate-swift-assets", help="Generate unpadded active WAVs + manifest for Swift Assets/"
    )
    p_sw.add_argument("--output-dir", default="Assets", help="Swift Assets target directory")
    p_sw.set_defaults(func=_cmd_generate_swift_assets)

    p_m3b_legacy = sub.add_parser(
        "audit-m3b", help="Alias for `m3b audit-bundle`"
    )
    p_m3b_legacy.add_argument("--bundle-dir", required=True, help="Exported M3B session directory")
    p_m3b_legacy.add_argument("--output-dir", default=None, help="Optional directory for M3B reports")
    p_m3b_legacy.set_defaults(func=_cmd_m3b_audit_bundle)

    p_g0b_legacy = sub.add_parser(
        "evaluate-gate0b", help="Alias for `gate0b decide`"
    )
    p_g0b_legacy.add_argument("--dataset-dir", required=True, help="Gate 0B CSRD-P1 directory")
    p_g0b_legacy.add_argument("--gate0a-failed", action="store_true", help="Mark Gate 0A signal path invalid")
    p_g0b_legacy.add_argument("--output-dir", default=None, help="Optional directory for Gate 0B reports")
    p_g0b_legacy.set_defaults(func=_cmd_gate0b_decide)

    p_ins = sub.add_parser("inspect-recording", help="Deconvolve and inspect a recorded ESS WAV")
    p_ins.add_argument("--recording", required=True, help="Path to 48 kHz WAV recording")
    p_ins.add_argument("--water-cal", default=None, help="Optional session water calibration WAV")
    p_ins.set_defaults(func=_cmd_inspect_recording)

    p_eval = sub.add_parser("evaluate-dataset", help="Run CSRD-P1 LOBO-CV & Locked Test evaluation")
    p_eval.add_argument("--dataset-dir", required=True, help="Directory with scans.jsonl and WAVs")
    p_eval.add_argument("--stage", choices=list(STAGE_FORMULATIONS.keys()), default="STAGE_1")
    p_eval.add_argument(
        "--classifier",
        choices=["ridge_linear", "knn", "mahalanobis", "svm", "rf"],
        default="ridge_linear",
    )
    p_eval.add_argument("--output-dir", default=None, help="Optional experiment report output dir")
    p_eval.set_defaults(func=_cmd_evaluate_dataset)

    p_syn = sub.add_parser(
        "run-synthetic-validation",
        help="Run Stage 1-3 synthetic modal benchmark, unknown rejection, and leakage test",
    )
    p_syn.add_argument("--seed", type=int, default=20261116)
    p_syn.set_defaults(func=_cmd_run_synthetic_validation)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
