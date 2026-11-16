"""Reproducibility manifests, per-recording bundles, and experiment reporting (Sections 19.2 & 19.15)."""

from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import sys
from typing import Any

import numpy as np

from . import DATASET_VERSION, SOP_M3B_VERSION, SPEC_VERSION, __version__
from .classification import OpenSetAcousticClassifier, SampleSummary
from .dsp import (
    DSPConfig,
    deconvolve_ess_recording,
    extract_scan_features,
    get_primary_feature_registry,
)
from .ingestion_alignment import align_recording_to_reference, ingest_audio_file
from .schema_qc import QCThresholds, ScanRecord, evaluate_scan_qc
from .waveforms import ESSWaveformPair, sha256_file, write_wav_float32


def compute_canonical_json_sha256(payload: Any) -> str:
    """Compute a deterministic SHA-256 hex digest over canonicalized JSON."""
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _resolve_git_commit(start_dir: Path) -> str | None:
    """Resolve git HEAD commit hash directly from .git metadata without spawning subprocesses."""
    curr = start_dir.resolve()
    for parent in (curr, *curr.parents):
        git_dir = parent / ".git"
        if git_dir.is_dir():
            head_file = git_dir / "HEAD"
            if not head_file.is_file():
                return None
            head_val = head_file.read_text(encoding="utf-8").strip()
            if head_val.startswith("ref: "):
                ref_rel = head_val[5:].strip()
                ref_file = git_dir / ref_rel
                if ref_file.is_file():
                    return ref_file.read_text(encoding="utf-8").strip()
                packed = git_dir / "packed-refs"
                if packed.is_file():
                    for ln in packed.read_text(encoding="utf-8").splitlines():
                        if ln and not ln.startswith("#") and not ln.startswith("^"):
                            parts = ln.split()
                            if len(parts) >= 2 and parts[1] == ref_rel:
                                return parts[0]
                return None
            return head_val
    return None


def compute_software_build_identity() -> dict[str, Any]:
    """Return software commit/build identity and deterministic package source SHA-256 (CS-SOP-M3B-P1-v1.1 App A)."""
    pkg_dir = Path(__file__).resolve().parent
    py_hashes = {
        p.name: sha256_file(p)
        for p in sorted(pkg_dir.glob("*.py"))
        if p.is_file()
    }
    pkg_source_sha256 = compute_canonical_json_sha256(py_hashes)
    git_commit = _resolve_git_commit(pkg_dir)
    return {
        "package_name": "chemical-sound",
        "package_version": __version__,
        "spec_version": SPEC_VERSION,
        "sop_version": SOP_M3B_VERSION,
        "dataset_version": DATASET_VERSION,
        "git_commit": git_commit,
        "package_source_sha256": pkg_source_sha256,
        "build_id": git_commit[:12] if git_commit else f"src-{pkg_source_sha256[:12]}",
    }


def compute_dataset_manifest_digest(
    dataset_dir: Path | str | None = None,
    samples: list[SampleSummary] | None = None,
) -> tuple[str, dict[str, Any]]:
    """Compute a deterministic SHA-256 digest of a bundle/dataset directory or in-memory sample collection."""
    if dataset_dir is not None:
        base = Path(dataset_dir)
        scans_path = base / "scans.jsonl"
        scans_sha = sha256_file(scans_path) if scans_path.is_file() else None
        wav_hashes = {
            p.name: sha256_file(p)
            for p in sorted(base.glob("*.wav"))
            if p.is_file()
        }
        wf_hashes: dict[str, str] = {}
        for cand in (
            base / "reference_waveforms" / "waveform_manifest.json",
            base / "waveform_manifest.json",
        ):
            if cand.is_file():
                wf_hashes[str(cand.relative_to(base)).replace("\\", "/")] = sha256_file(cand)
                break
        manifest_payload: dict[str, Any] = {
            "source_type": "directory_bundle",
            "scans_jsonl_sha256": scans_sha,
            "wav_count": len(wav_hashes),
            "wav_sha256_by_file": wav_hashes,
            "waveform_manifest_sha256": wf_hashes,
        }
        return compute_canonical_json_sha256(manifest_payload), manifest_payload

    sample_entries = []
    for s in sorted(samples or [], key=lambda x: x.sample_id):
        feat_bytes = np.asarray(s.compact_features, dtype=np.float64).round(8).tobytes()
        sample_entries.append(
            {
                "sample_id": s.sample_id,
                "preparation_batch_id": s.preparation_batch_id,
                "session_id": s.session_id,
                "container_id": s.container_id,
                "is_held_out_container": bool(s.is_held_out_container),
                "hardware_domain": s.hardware_domain,
                "qc_passed": bool(s.qc_passed),
                "calibration_valid": bool(s.calibration_valid),
                "compact_features_sha256": hashlib.sha256(feat_bytes).hexdigest(),
            }
        )
    manifest_payload = {
        "source_type": "in_memory_samples",
        "sample_count": len(sample_entries),
        "samples": sample_entries,
    }
    return compute_canonical_json_sha256(manifest_payload), manifest_payload


def build_reproducibility_manifest(
    random_seed: int,
    input_checksums: dict[str, str],
    output_files: list[Path],
) -> dict[str, Any]:
    """Generate Section 19.2 environment, seed, and input/output SHA-256 manifest."""
    output_checksums = {p.name: sha256_file(p) for p in output_files if p.is_file()}
    return {
        "spec_version": SPEC_VERSION,
        "dataset_version": DATASET_VERSION,
        "package_version": __version__,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "random_seed": random_seed,
        "environment": {
            "python_version": sys.version.split()[0],
            "platform": platform.platform(),
            "numpy_version": np.__version__,
        },
        "input_checksums_sha256": input_checksums,
        "output_checksums_sha256": output_checksums,
    }


def process_and_save_recording_bundle(
    audio_path: Path | str,
    record: ScanRecord,
    ess_pair: ESSWaveformPair,
    output_dir: Path | str,
    water_cal_bands_db: np.ndarray | None = None,
    empty_cal_bands_db: np.ndarray | None = None,
    water_calibration_id: str | None = None,
    empty_calibration_id: str | None = None,
    silence_baseline_rms_dbfs: float | None = None,
    dsp_config: DSPConfig = DSPConfig(),
    qc_thresholds: QCThresholds = QCThresholds(),
    trained_classifier: OpenSetAcousticClassifier | None = None,
) -> dict[str, Any]:
    """Produce complete Section 19.15 per-recording artifact bundle."""
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)

    ingested = ingest_audio_file(
        audio_path,
        expected_sample_rate_hz=dsp_config.sample_rate_hz,
        pre_roll_samples=ess_pair.pre_roll_samples,
        active_samples=ess_pair.active_samples,
        post_roll_samples=ess_pair.post_roll_samples,
        clipping_ceiling_dbfs=qc_thresholds.clipping_ceiling_dbfs,
    )

    alignment = align_recording_to_reference(
        ingested.raw_samples,
        ess_pair.active_sweep,
        nominal_start_sample=ess_pair.pre_roll_samples,
        sample_rate_hz=dsp_config.sample_rate_hz,
        max_positive_latency_s=dsp_config.max_causal_latency_s,
    )

    qc_state, qc_flags, peak_db, pre_rms_db = evaluate_scan_qc(
        record,
        ingested.raw_samples if not ingested.report.quarantined else None,
        pre_roll_samples=ess_pair.pre_roll_samples,
        active_samples=ess_pair.active_samples,
        thresholds=qc_thresholds,
        silence_baseline_rms_dbfs=silence_baseline_rms_dbfs,
    )
    if ingested.report.quarantined:
        qc_state = "REJECTED"
        for q_flag in ingested.report.quarantine_reasons:
            if q_flag not in qc_flags:
                qc_flags.append(q_flag)

    gates = deconvolve_ess_recording(ingested.raw_samples, ess_pair, config=dsp_config)
    feat = extract_scan_features(
        ingested.raw_samples,
        ess_pair,
        water_cal_bands_db=water_cal_bands_db,
        empty_cal_bands_db=empty_cal_bands_db,
        config=dsp_config,
    )

    stem = Path(audio_path).stem
    ir_wav_path = out / f"{stem}_deconvolved_ir.wav"
    ir_sha = write_wav_float32(ir_wav_path, gates.impulse_full, dsp_config.sample_rate_hz)

    prediction_block: dict[str, Any] | None = None
    if trained_classifier is not None:
        s_obj = SampleSummary(
            sample_id=record.sample_id or stem,
            formulation_id=record.formulation_id or "UNBLINDED_PENDING",
            preparation_batch_id=record.preparation_batch_id or "NA",
            is_known_library_class=True,
            compact_features=feat.compact_features,
            nuisance_features=feat.nuisance_features,
            qc_passed=(qc_state == "PROVISIONALLY_ACCEPTED"),
        )
        pred_out = trained_classifier.predict_samples([s_obj], enable_unknown_rejection=True)
        prediction_block = {
            "model_version": pred_out["model_version"],
            "frozen_model_sha256": pred_out["frozen_model_sha256"],
            "outcome_status": pred_out["outcome_statuses"][0],
            "prediction": pred_out["predictions"][0],
            "closest_reference": pred_out["closest_references"][0],
            "min_mahalanobis_distance": pred_out["min_mahalanobis_distances"][0],
            "nearest_class_margin": pred_out["nearest_class_margins"][0],
            "decision_reason": pred_out["rejection_reasons"][0],
        }

    bundle: dict[str, Any] = {
        "spec_version": SPEC_VERSION,
        "ingestion_report": ingested.report.to_dict(),
        "alignment_result": alignment.to_report_dict(),
        "qc_result": {
            "final_state": qc_state,
            "quality_flags": qc_flags,
            "peak_dbfs": peak_db,
            "pre_roll_rms_dbfs": pre_rms_db,
        },
        "deconvolved_response": {
            "ir_filename": ir_wav_path.name,
            "ir_sha256": ir_sha,
            "t0_index": gates.t0_index,
            "latency_samples": gates.latency_samples,
            "analysis_windows": asdict(gates.window_bounds),
        },
        "spectral_summary": {
            "raw_resonance_bands_db": [round(float(v), 4) for v in feat.raw_resonance_bands_db],
            "modal_peaks": [asdict(p) for p in feat.modal_peaks],
            "ringdown_slopes_db_per_s": list(feat.ringdown_slopes_db_per_s),
            "t20_estimates_ms": list(feat.t20_estimates_ms),
            "direct_to_tail_ratio_db": feat.direct_to_tail_ratio_db,
            "harmonic_ratio_db": feat.harmonic_ratio_db,
            "late_room_snr_db": feat.late_room_snr_db,
        },
        "feature_vector": {
            "schema_version": get_primary_feature_registry(dsp_config)[0].version,
            "primary_compact": dict(
                zip(feat.compact_feature_names, [round(float(x), 5) for x in feat.compact_features])
            ),
            "candidate_catalog": feat.candidate_catalog,
        },
        "calibration_references_used": {
            "water_calibration_id": water_calibration_id,
            "empty_container_calibration_id": empty_calibration_id,
            "water_cal_distance_db": feat.water_cal_distance_db,
            "empty_cal_distance_db": feat.empty_cal_distance_db,
        },
        "prediction_summary": prediction_block,
        "audit_trail": {
            "raw_audio_sha256": ingested.report.file_sha256,
            "protocol_version": record.protocol_version,
            "waveform_version": record.waveform_version,
            "dsp_config": asdict(dsp_config),
        },
    }

    report_json_path = out / f"{stem}_recording_report.json"
    report_json_path.write_text(json.dumps(bundle, indent=2) + "\n", encoding="utf-8")
    return bundle


def write_experiment_artifacts(
    output_dir: Path | str,
    stage: str,
    dataset_manifest: dict[str, Any],
    split_manifest: dict[str, Any],
    lobo_report: dict[str, Any] | None,
    locked_report: dict[str, Any] | None,
    calibration_drift_report: dict[str, Any],
    random_seed: int = 20261116,
    input_checksums: dict[str, str] | None = None,
) -> dict[str, str]:
    """Write all Section 19.15 machine-readable experiment JSONs and human-readable Markdown summary."""
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []

    def _dump(filename: str, payload: Any) -> Path:
        p = out / filename
        p.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        written.append(p)
        return p

    _dump("dataset_manifest.json", dataset_manifest)
    _dump("split_manifest.json", split_manifest)
    _dump("calibration_drift_report.json", calibration_drift_report)

    primary = locked_report if locked_report is not None else lobo_report
    if primary is not None:
        metrics_block = primary.get("metrics") or primary.get("open_set_metrics", {})
        _dump(
            "aggregate_metrics.json",
            {
                "stage": stage,
                "lobo_cv": lobo_report,
                "locked_test": locked_report,
            },
        )
        _dump(
            "confusion_matrix.json",
            {
                "known_classes": metrics_block.get("known_classes"),
                "columns": metrics_block.get("matrix_columns"),
                "matrix": metrics_block.get("confusion_matrix"),
            },
        )
        _dump(
            "unknown_rejection_report.json",
            locked_report.get("unknown_evaluation_report")
            if locked_report is not None
            else (lobo_report.get("unknown_probe_evaluation") if lobo_report else {}),
        )
        _dump(
            "nuisance_leakage_report.json",
            {
                "lobo_nuisance": lobo_report.get("nuisance_leakage_diagnostic") if lobo_report else None,
                "locked_nuisance": locked_report.get("nuisance_leakage_diagnostic")
                if locked_report
                else None,
            },
        )
        _dump(
            "confounder_report.json",
            {
                "lobo_confounders": lobo_report.get("confounder_error_analysis") if lobo_report else None,
                "locked_confounders": locked_report.get("confounder_error_analysis")
                if locked_report
                else None,
            },
        )

    # Human-readable Markdown summary report (Section 19.2)
    lines = [
        f"# Chemical Sound Phase 1 Experiment Summary ({stage})",
        "",
        f"- **Specification:** `{SPEC_VERSION}`",
        f"- **Dataset Version:** `{DATASET_VERSION}`",
        "- **Scientific Disclaimer:** Similarity classification against calibrated reference dataset only; does not establish molecular composition, purity, or safety.",
        "",
    ]
    if lobo_report is not None:
        om = lobo_report["open_set_metrics"]
        nd = lobo_report["nuisance_leakage_diagnostic"]
        ci = lobo_report["balanced_accuracy_ci_95"]
        lines.extend(
            [
                "## Phase 1A Exploratory (4-Batch LOBO-CV)",
                f"- **Open-Set Balanced Accuracy:** `{om['balanced_accuracy']:.4f}` (95% CI: `[{ci['ci_low']:.4f}, {ci['ci_high']:.4f}]`)",
                f"- **Closed-Set Balanced Accuracy:** `{lobo_report['closed_set_metrics']['balanced_accuracy']:.4f}`",
                f"- **Nuisance-Only Balanced Accuracy:** `{nd['nuisance_balanced_accuracy']:.4f}` (Chance: `{nd['chance_level']:.4f}`, Leakage Warning: `{nd['leakage_warning_triggered']}`)",
                "",
            ]
        )
    if locked_report is not None:
        lm = locked_report["metrics"]
        lci = locked_report["balanced_accuracy_ci_95"]
        lines.extend(
            [
                "## Phase 1B Locked Independent Test",
                f"- **Frozen Model SHA-256:** `{locked_report['frozen_model_sha256']}`",
                f"- **Balanced Accuracy:** `{lm['balanced_accuracy']:.4f}` (95% CI: `[{lci['ci_low']:.4f}, {lci['ci_high']:.4f}]`)",
                f"- **Unknown Rejection Rate:** `{lm['unknown_rejection_rate']}`",
                f"- **False-Known Rate on Unknowns:** `{lm['false_known_rate_on_unknown']}`",
                "",
            ]
        )

    md_path = out / "experiment_summary.md"
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    written.append(md_path)

    repro = build_reproducibility_manifest(
        random_seed=random_seed,
        input_checksums=input_checksums or {},
        output_files=written,
    )
    repro_path = out / "reproducibility_manifest.json"
    repro_path.write_text(json.dumps(repro, indent=2) + "\n", encoding="utf-8")
    written.append(repro_path)

    return {p.name: str(p) for p in written}
