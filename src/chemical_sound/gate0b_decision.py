"""Pre-registered Gate 0B Acceptance Thresholds & Stop/Go Decision Engine (CS-SOP-M3B-P1-v1.1).

Enforces the governing scientific progression:
  Instrument validity -> Signal-path validity -> Phenomenon validity -> Classification validity

Implements CS-SOP-M3B-P1-v1.1 Sections 5-7 (Sections 16-18) and Appendix A.2 / A.3:
- `validate_gate0b_design`: Pre-scoring study-structure & yield validation (`COMPLETE` / `GATE_INCOMPLETE`)
  before labels or acoustic models are scored.
- `evaluate_gate0b_metrics`: Frozen sample-level aggregation, grouped/nested partitions, unseen-container
  transfer, cross-session transfer, per-class sensitivities, non-acoustic metadata nuisance control (< 60%
  and chance-compatible), acoustic pre-roll/bleed control, repositioning ratio (>= 2.0x), and session drift
  ratio (<= 25%), emitting metrics + threshold matrix without exploratory promotion.
- `evaluate_gate0b_decision`: Deterministic mapping to `DECISION_A_PROCEED`, `DECISION_B_HOLD_AND_REDESIGN`,
  `DECISION_C_EXTERNAL_TRANSDUCER_DIAGNOSTIC`, `DECISION_D_PHENOMENON_NOT_ESTABLISHED`, or `GATE_INCOMPLETE`
  with explicit `decision_reasons`, software commit/build identity, and SHA-256 digests of the dataset
  manifest and threshold configuration.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import json
import math
from pathlib import Path
from typing import Any

import numpy as np

from . import SOP_M3B_VERSION
from .classification import (
    ClassifierConfig,
    OpenSetAcousticClassifier,
    SampleSummary,
    bootstrap_batch_hierarchical_ci,
    compute_classification_metrics,
    run_lobo_cv,
    verify_disjoint_sample_and_batch_splits,
    verify_hardware_domain_isolation,
)
from .reporting import (
    compute_canonical_json_sha256,
    compute_dataset_manifest_digest,
    compute_software_build_identity,
)


GATE0B_CLASSES: tuple[str, str] = ("H2O_DIST", "OIL_VEG")

FINAL_CONTROL_STATEMENT = (
    "A failed Gate 0B does not establish that acoustic liquid discrimination is impossible. "
    "It establishes only that the specified Chemical Sound instrument and experiment did not "
    "demonstrate the required phenomenon under these frozen criteria."
)

# Frozen preregistered primary classifier configuration (Appendix A.2: no exploratory feature/threshold promotion)
FROZEN_GATE0B_CLASSIFIER_CONFIG = ClassifierConfig(
    classifier_type="ridge_linear",
    feature_indices=None,
    ridge_alpha=0.5,
)


@dataclass(frozen=True)
class Gate0BThresholds:
    """Frozen engineering acceptance criteria (CS-SOP-M3B-P1-v1.1 Section 5 / Section 16)."""

    min_preparations_per_class: int = 4
    min_sessions: int = 2
    min_unseen_containers_per_class: int = 1
    min_primary_balanced_accuracy: float = 0.80
    min_ci95_lower_bound_strict: float = 0.50  # strictly > 0.50
    min_unseen_container_balanced_accuracy: float = 0.70
    min_cross_session_balanced_accuracy: float = 0.70
    min_per_class_sensitivity: float = 0.70
    max_metadata_nuisance_balanced_accuracy: float = 0.60
    min_separation_to_repositioning_ratio: float = 2.0
    max_drift_to_separation_ratio: float = 0.25
    max_confounder_fraction_of_separation: float = 0.50


@dataclass(frozen=True)
class SampleOperationalMetadata:
    """Non-acoustic operational variables for nuisance-leakage auditing."""

    sample_id: str
    acquisition_sequence_index: int
    within_session_order_index: int
    session_id: str
    container_id: str
    coupling_force_setting: str = "NOMINAL"
    ambient_temperature_c: float = 22.0


def _compute_threshold_digest(thresholds: Gate0BThresholds) -> str:
    return compute_canonical_json_sha256(
        {
            "sop_id": SOP_M3B_VERSION,
            "thresholds": asdict(thresholds),
            "frozen_classifier_config": asdict(FROZEN_GATE0B_CLASSIFIER_CONFIG),
        }
    )


def _fit_and_encode_operational_features(
    train_meta: list[SampleOperationalMetadata],
    eval_meta: list[SampleOperationalMetadata],
) -> tuple[np.ndarray, np.ndarray]:
    """Encode non-acoustic variables using ONLY categories observed in train_meta."""
    sessions = sorted({m.session_id for m in train_meta})
    containers = sorted({m.container_id for m in train_meta})
    forces = sorted({m.coupling_force_setting for m in train_meta})

    max_seq = max(1.0, float(max(m.acquisition_sequence_index for m in train_meta)))
    max_ord = max(1.0, float(max(m.within_session_order_index for m in train_meta)))

    def _encode(items: list[SampleOperationalMetadata]) -> np.ndarray:
        dim = 3 + len(sessions) + len(containers) + len(forces)
        mat = np.zeros((len(items), dim), dtype=np.float64)
        for row_idx, m in enumerate(items):
            col = 0
            mat[row_idx, col] = float(m.acquisition_sequence_index) / max_seq
            col += 1
            mat[row_idx, col] = float(m.within_session_order_index) / max_ord
            col += 1
            mat[row_idx, col] = float(m.ambient_temperature_c)
            col += 1
            for s_val in sessions:
                mat[row_idx, col] = 1.0 if m.session_id == s_val else 0.0
                col += 1
            for c_val in containers:
                mat[row_idx, col] = 1.0 if m.container_id == c_val else 0.0
                col += 1
            for f_val in forces:
                mat[row_idx, col] = 1.0 if m.coupling_force_setting == f_val else 0.0
                col += 1
        return mat

    return _encode(train_meta), _encode(eval_meta)


def evaluate_non_acoustic_metadata_nuisance(
    samples: list[SampleSummary],
    operational_meta: dict[str, SampleOperationalMetadata] | None = None,
    thresholds: Gate0BThresholds = Gate0BThresholds(),
) -> dict[str, Any]:
    """Run prespecified non-acoustic metadata nuisance-only negative control."""
    target_set = set(GATE0B_CLASSES)
    known = [s for s in samples if s.formulation_id in target_set and s.qc_passed]

    if operational_meta is None:
        operational_meta = {}
        sess_counters: dict[str, int] = {}
        for idx, s in enumerate(known):
            s_ord = sess_counters.get(s.session_id, 0) + 1
            sess_counters[s.session_id] = s_ord
            operational_meta[s.sample_id] = SampleOperationalMetadata(
                sample_id=s.sample_id,
                acquisition_sequence_index=idx + 1,
                within_session_order_index=s_ord,
                session_id=s.session_id,
                container_id=s.container_id,
                coupling_force_setting=s.coupling_force_setting,
            )

    batches_by_class = {
        cls: sorted({s.preparation_batch_id for s in known if s.formulation_id == cls})
        for cls in GATE0B_CLASSES
    }
    n_folds = min(len(v) for v in batches_by_class.values())
    if n_folds < 2:
        return {
            "balanced_accuracy": 0.5,
            "ci_95": {"ci_low": 0.0, "ci_high": 1.0},
            "compatible_with_chance": True,
            "passed": True,
        }

    eval_ordered: list[SampleSummary] = []
    y_true_all: list[str] = []
    y_pred_all: list[str] = []

    for fold in range(n_folds):
        held = {batches_by_class[cls][fold] for cls in GATE0B_CLASSES}
        tr = [s for s in known if s.preparation_batch_id not in held]
        ev = [s for s in known if s.preparation_batch_id in held]

        tr_meta = [operational_meta[s.sample_id] for s in tr]
        ev_meta = [operational_meta[s.sample_id] for s in ev]
        X_tr, X_ev = _fit_and_encode_operational_features(tr_meta, ev_meta)

        mu = np.mean(X_tr, axis=0)
        sd = np.maximum(np.std(X_tr, axis=0), 0.05)
        Z_tr = (X_tr - mu) / sd
        Z_ev = (X_ev - mu) / sd

        y_tr = [s.formulation_id for s in tr]
        centroids = np.vstack(
            [
                np.mean(Z_tr[[i for i, lbl in enumerate(y_tr) if lbl == c]], axis=0)
                for c in GATE0B_CLASSES
            ]
        )
        dists = np.vstack(
            [np.linalg.norm(Z_ev - centroids[c_i], axis=1) for c_i in range(len(GATE0B_CLASSES))]
        ).T
        preds = [GATE0B_CLASSES[int(i)] for i in np.argmin(dists, axis=1)]

        eval_ordered.extend(ev)
        y_true_all.extend([s.formulation_id for s in ev])
        y_pred_all.extend(preds)

    m = compute_classification_metrics(
        y_true_all, y_pred_all, GATE0B_CLASSES, [True] * len(y_true_all)
    )
    ci = bootstrap_batch_hierarchical_ci(eval_ordered, y_pred_all, GATE0B_CLASSES)
    bal_acc = m["balanced_accuracy"]

    n_tot = len(y_true_all)
    n_corr = sum(1 for t, p in zip(y_true_all, y_pred_all) if t == p)
    prob_ge = sum(math.comb(n_tot, k) * (0.5**n_tot) for k in range(n_corr, n_tot + 1))
    chance_compatible = (ci["ci_low"] <= 0.55) or (prob_ge >= 0.05)
    passed = (bal_acc < thresholds.max_metadata_nuisance_balanced_accuracy) and chance_compatible

    return {
        "variables_included": [
            "acquisition_sequence_index",
            "within_session_order_index",
            "session_id",
            "container_id",
            "coupling_force_setting",
            "ambient_temperature_c",
        ],
        "balanced_accuracy": bal_acc,
        "max_allowed_balanced_accuracy": thresholds.max_metadata_nuisance_balanced_accuracy,
        "ci_95": ci,
        "one_sided_pvalue_vs_chance": round(min(1.0, prob_ge), 5),
        "compatible_with_chance": bool(chance_compatible),
        "passed": bool(passed),
    }


def _evaluate_partition(
    train_samples: list[SampleSummary],
    eval_samples: list[SampleSummary],
    config: ClassifierConfig = FROZEN_GATE0B_CLASSIFIER_CONFIG,
) -> tuple[dict[str, Any], dict[str, Any]]:
    verify_disjoint_sample_and_batch_splits(train_samples, eval_samples)
    clf = OpenSetAcousticClassifier(config=config).fit(
        np.vstack([s.compact_features for s in train_samples]),
        [s.formulation_id for s in train_samples],
        batch_ids=[s.preparation_batch_id for s in train_samples],
    )
    preds = clf.predict_closed_set(np.vstack([s.compact_features for s in eval_samples]))
    y_true = [s.formulation_id for s in eval_samples]
    metrics = compute_classification_metrics(
        y_true, preds, GATE0B_CLASSES, [True] * len(y_true)
    )
    ci = bootstrap_batch_hierarchical_ci(eval_samples, preds, GATE0B_CLASSES)
    return metrics, ci


def validate_gate0b_design(
    samples: list[SampleSummary],
    scan_yield_counts: dict[str, Any] | None = None,
    thresholds: Gate0BThresholds = Gate0BThresholds(),
    dataset_dir: Path | str | None = None,
    output_report_dir: Path | str | None = None,
) -> dict[str, Any]:
    """Validate Gate 0B independent preparations, classes, sessions, groups, and holdouts BEFORE scoring labels."""
    verify_hardware_domain_isolation(samples, expected_domain="IPHONE_NATIVE")
    build_identity = compute_software_build_identity()
    dataset_manifest_sha256, _ = compute_dataset_manifest_digest(
        dataset_dir=dataset_dir, samples=samples
    )
    threshold_config_sha256 = _compute_threshold_digest(thresholds)

    valid_samples = [
        s
        for s in samples
        if s.formulation_id in GATE0B_CLASSES and s.qc_passed and s.calibration_valid
    ]

    preps_by_class = {
        cls: sorted({s.preparation_batch_id for s in valid_samples if s.formulation_id == cls})
        for cls in GATE0B_CLASSES
    }
    sessions = sorted({s.session_id for s in valid_samples})
    unseen_by_class = {
        cls: [
            s.sample_id
            for s in valid_samples
            if s.formulation_id == cls and s.is_held_out_container
        ]
        for cls in GATE0B_CLASSES
    }
    dev_samples = [s for s in valid_samples if not s.is_held_out_container]
    dev_containers_by_class = {
        cls: sorted({s.container_id for s in dev_samples if s.formulation_id == cls})
        for cls in GATE0B_CLASSES
    }

    missing_prereqs: list[str] = []
    for cls in GATE0B_CLASSES:
        if len(preps_by_class[cls]) < thresholds.min_preparations_per_class:
            missing_prereqs.append(
                f"{cls}_preparations={len(preps_by_class[cls])}<{thresholds.min_preparations_per_class}"
            )
        if len(unseen_by_class[cls]) < thresholds.min_unseen_containers_per_class:
            missing_prereqs.append(
                f"{cls}_unseen_containers={len(unseen_by_class[cls])}<{thresholds.min_unseen_containers_per_class}"
            )
    if len(sessions) < thresholds.min_sessions:
        missing_prereqs.append(f"sessions={len(sessions)}<{thresholds.min_sessions}")

    dev_batches_ok = all(
        len({s.preparation_batch_id for s in dev_samples if s.formulation_id == cls}) >= 2
        for cls in GATE0B_CLASSES
    )
    if not dev_batches_ok:
        missing_prereqs.append("insufficient_dev_container_batches_for_nested_cv")

    dev_containers_balanced = (
        len(dev_containers_by_class["H2O_DIST"]) >= 1
        and dev_containers_by_class["H2O_DIST"] == dev_containers_by_class["OIL_VEG"]
    )
    if not dev_containers_balanced and not missing_prereqs:
        missing_prereqs.append(
            f"unbalanced_development_containers(water={dev_containers_by_class['H2O_DIST']},oil={dev_containers_by_class['OIL_VEG']})"
        )

    status = "COMPLETE" if not missing_prereqs else "GATE_INCOMPLETE"
    yield_summary = scan_yield_counts or {
        "attempted_scans": len(samples),
        "PROVISIONALLY_ACCEPTED": len(valid_samples),
        "FINAL_ACCEPTED": len(valid_samples),
        "INVALID_MEASUREMENT_by_reason": {},
    }

    study_structure_table = {
        "water_preparations": {
            "required": f">={thresholds.min_preparations_per_class} independent",
            "observed": len(preps_by_class["H2O_DIST"]),
            "passed": len(preps_by_class["H2O_DIST"]) >= thresholds.min_preparations_per_class,
        },
        "oil_preparations": {
            "required": f">={thresholds.min_preparations_per_class} independent",
            "observed": len(preps_by_class["OIL_VEG"]),
            "passed": len(preps_by_class["OIL_VEG"]) >= thresholds.min_preparations_per_class,
        },
        "sessions_days": {
            "required": f">={thresholds.min_sessions}",
            "observed": len(sessions),
            "passed": len(sessions) >= thresholds.min_sessions,
        },
        "unseen_containers_per_class": {
            "required": f">={thresholds.min_unseen_containers_per_class} per class",
            "observed": {k: len(v) for k, v in unseen_by_class.items()},
            "passed": all(
                len(v) >= thresholds.min_unseen_containers_per_class
                for v in unseen_by_class.values()
            ),
        },
        "development_containers_balanced": {
            "required": "Balanced development containers across classes",
            "observed": dev_containers_by_class,
            "passed": dev_containers_balanced,
        },
        "scan_yield": yield_summary,
        "gate_completeness": status,
    }

    design_report: dict[str, Any] = {
        "sop_id": SOP_M3B_VERSION,
        "status": status,
        "disposition": status,
        "labels_scored": False,
        "num_valid_samples": len(valid_samples),
        "missing_dataset_requirements": missing_prereqs,
        "study_structure_table": study_structure_table,
        "software_build_identity": build_identity,
        "dataset_manifest_sha256": dataset_manifest_sha256,
        "threshold_config_sha256": threshold_config_sha256,
    }

    if output_report_dir is not None:
        out = Path(output_report_dir)
        out.mkdir(parents=True, exist_ok=True)
        (out / "gate0b_design_validation.json").write_text(
            json.dumps(design_report, indent=2) + "\n", encoding="utf-8"
        )
        md_lines = [
            f"# Gate 0B Pre-Scoring Study Design Validation (`{SOP_M3B_VERSION}`)",
            "",
            f"- **Design Status:** **`{status}`**",
            f"- **Labels / Acoustic Models Scored:** `False`",
            f"- **Valid Samples:** `{len(valid_samples)}`",
            f"- **Software Build Identity:** `{build_identity['package_name']}=={build_identity['package_version']}` (`{build_identity['build_id']}`)",
            f"- **Dataset Manifest SHA-256:** `{dataset_manifest_sha256}`",
            f"- **Threshold Config SHA-256:** `{threshold_config_sha256}`",
            "",
        ]
        if missing_prereqs:
            md_lines.append("## Missing Preregistered Structure Requirements (`GATE_INCOMPLETE`)")
            for req in missing_prereqs:
                md_lines.append(f"- `{req}`")
        else:
            md_lines.extend(
                [
                    "## Study Structure Verification",
                    f"- **Water Preparations:** `{len(preps_by_class['H2O_DIST'])}` (`PASS`)",
                    f"- **Oil Preparations:** `{len(preps_by_class['OIL_VEG'])}` (`PASS`)",
                    f"- **Sessions / Days:** `{len(sessions)}` (`PASS`)",
                    f"- **Unseen Holdout Containers:** `H2O_DIST={len(unseen_by_class['H2O_DIST'])}`, `OIL_VEG={len(unseen_by_class['OIL_VEG'])}` (`PASS`)",
                ]
            )
        (out / "gate0b_design_validation.md").write_text(
            "\n".join(md_lines) + "\n", encoding="utf-8"
        )

    return design_report


def evaluate_gate0b_metrics(
    samples: list[SampleSummary],
    gate0a_signal_path_valid: bool = True,
    native_snr_adequate: bool = True,
    repositioning_variability_db: float | None = None,
    max_session_drift_db: float = 0.0,
    max_confounder_shift_db: float = 0.0,
    operational_meta: dict[str, SampleOperationalMetadata] | None = None,
    scan_yield_counts: dict[str, Any] | None = None,
    thresholds: Gate0BThresholds = Gate0BThresholds(),
    dataset_dir: Path | str | None = None,
    output_report_dir: Path | str | None = None,
) -> dict[str, Any]:
    """Run frozen grouped Gate 0B evaluation and nuisance controls (Appendix A.2 & A.3 `gate0b evaluate`)."""
    design = validate_gate0b_design(
        samples,
        scan_yield_counts=scan_yield_counts,
        thresholds=thresholds,
        dataset_dir=dataset_dir,
    )
    if design["status"] == "GATE_INCOMPLETE":
        incomplete_eval: dict[str, Any] = {
            "sop_id": SOP_M3B_VERSION,
            "status": "GATE_INCOMPLETE",
            "disposition": "GATE_INCOMPLETE",
            "labels_scored": False,
            "missing_dataset_requirements": design["missing_dataset_requirements"],
            "study_structure_table": design["study_structure_table"],
            "num_valid_samples": design["num_valid_samples"],
            "software_build_identity": design["software_build_identity"],
            "dataset_manifest_sha256": design["dataset_manifest_sha256"],
            "threshold_config_sha256": design["threshold_config_sha256"],
        }
        if output_report_dir is not None:
            out = Path(output_report_dir)
            out.mkdir(parents=True, exist_ok=True)
            (out / "gate0b_evaluation_metrics.json").write_text(
                json.dumps(incomplete_eval, indent=2) + "\n", encoding="utf-8"
            )
            (out / "gate0b_threshold_matrix.md").write_text(
                f"# Gate 0B Frozen Evaluation (`{SOP_M3B_VERSION}`)\n\n"
                f"- **Status:** **`GATE_INCOMPLETE`** (scoring halted prior to model evaluation)\n",
                encoding="utf-8",
            )
        return incomplete_eval

    valid_samples = [
        s
        for s in samples
        if s.formulation_id in GATE0B_CLASSES and s.qc_passed and s.calibration_valid
    ]
    dev_samples = [s for s in valid_samples if not s.is_held_out_container]
    holdout_container_samples = [s for s in valid_samples if s.is_held_out_container]
    sessions = sorted({s.session_id for s in valid_samples})
    preps_by_class = {
        cls: {s.preparation_batch_id for s in valid_samples if s.formulation_id == cls}
        for cls in GATE0B_CLASSES
    }

    # 1. Primary Frozen Grouped Development Evaluation (zero exploratory promotion)
    dev_lobo = run_lobo_cv(
        dev_samples,
        GATE0B_CLASSES,
        config=FROZEN_GATE0B_CLASSIFIER_CONFIG,
        candidate_configs=None,
        enable_unknown_rejection=False,
    )
    prim_metrics = dev_lobo["closed_set_metrics"]
    prim_bal_acc = prim_metrics["balanced_accuracy"]
    prim_ci = dev_lobo["balanced_accuracy_ci_95"]
    prim_ci_low = prim_ci["ci_low"]
    sens_water = prim_metrics["per_class"]["H2O_DIST"]["sensitivity"]
    sens_oil = prim_metrics["per_class"]["OIL_VEG"]["sensitivity"]

    # 2. Unseen-Container Holdout Evaluation
    heldout_batches = {s.preparation_batch_id for s in holdout_container_samples}
    train_for_unseen = [
        s for s in dev_samples if s.preparation_batch_id not in heldout_batches
    ]
    unseen_metrics, unseen_ci = _evaluate_partition(
        train_for_unseen, holdout_container_samples, config=FROZEN_GATE0B_CLASSIFIER_CONFIG
    )
    unseen_bal_acc = unseen_metrics["balanced_accuracy"]

    # 3. Cross-Session / Cross-Day Transfer Evaluation (Leave-One-Session-Out with batch disjointness)
    sess_eval_samples: list[SampleSummary] = []
    sess_true: list[str] = []
    sess_pred: list[str] = []
    for sess in sessions:
        ev_sess = [s for s in valid_samples if s.session_id == sess]
        ev_batches = {s.preparation_batch_id for s in ev_sess}
        tr_sess = [
            s
            for s in valid_samples
            if s.session_id != sess and s.preparation_batch_id not in ev_batches
        ]
        if any(
            sum(1 for x in tr_sess if x.formulation_id == c) == 0 for c in GATE0B_CLASSES
        ):
            continue
        clf_s = OpenSetAcousticClassifier(config=FROZEN_GATE0B_CLASSIFIER_CONFIG).fit(
            np.vstack([s.compact_features for s in tr_sess]),
            [s.formulation_id for s in tr_sess],
            batch_ids=[s.preparation_batch_id for s in tr_sess],
        )
        preds_s = clf_s.predict_closed_set(np.vstack([s.compact_features for s in ev_sess]))
        sess_eval_samples.extend(ev_sess)
        sess_true.extend([s.formulation_id for s in ev_sess])
        sess_pred.extend(preds_s)

    cross_sess_metrics = compute_classification_metrics(
        sess_true, sess_pred, GATE0B_CLASSES, [True] * len(sess_true)
    )
    cross_sess_ci = bootstrap_batch_hierarchical_ci(
        sess_eval_samples, sess_pred, GATE0B_CLASSES
    )
    cross_sess_bal_acc = cross_sess_metrics["balanced_accuracy"]

    # 4. Nuisance Controls (Non-Acoustic Metadata + Pre-Roll/Bleed Acoustic Diagnostic)
    meta_nuisance = evaluate_non_acoustic_metadata_nuisance(
        valid_samples, operational_meta=operational_meta, thresholds=thresholds
    )
    acoustic_nuisance = dev_lobo["nuisance_leakage_diagnostic"]
    acoustic_nuisance_ok = not acoustic_nuisance["leakage_warning_triggered"]

    # 5. Physical Repeatability, Drift, and Confounder Ratios
    water_bands = np.vstack(
        [s.compact_features[:16] for s in valid_samples if s.formulation_id == "H2O_DIST"]
    )
    oil_bands = np.vstack(
        [s.compact_features[:16] for s in valid_samples if s.formulation_id == "OIL_VEG"]
    )
    med_water = np.median(water_bands, axis=0)
    med_oil = np.median(oil_bands, axis=0)
    sep_db = float(np.sqrt(np.mean((med_water - med_oil) ** 2)))

    if repositioning_variability_db is None:
        w_spread = np.sqrt(np.mean((water_bands - med_water) ** 2, axis=1))
        o_spread = np.sqrt(np.mean((oil_bands - med_oil) ** 2, axis=1))
        repo_db = float(np.median(np.concatenate([w_spread, o_spread])))
    else:
        repo_db = float(repositioning_variability_db)

    sep_to_repo_ratio = sep_db / max(repo_db, 1e-6)
    drift_to_sep_ratio = max_session_drift_db / max(sep_db, 1e-6)
    confounder_to_sep_ratio = max_confounder_shift_db / max(sep_db, 1e-6)

    repeatability_ok = (
        sep_to_repo_ratio >= thresholds.min_separation_to_repositioning_ratio
        and drift_to_sep_ratio <= thresholds.max_drift_to_separation_ratio
    )
    confounders_ok = confounder_to_sep_ratio < thresholds.max_confounder_fraction_of_separation

    primary_performance_record = {
        "nested_grouped_development_validation": {
            "independent_samples": len(dev_samples),
            "balanced_accuracy": prim_bal_acc,
            "ci_95": prim_ci,
            "water_sensitivity": sens_water,
            "oil_sensitivity": sens_oil,
            "threshold_met": bool(
                prim_bal_acc >= thresholds.min_primary_balanced_accuracy
                and prim_ci_low > thresholds.min_ci95_lower_bound_strict
                and sens_water >= thresholds.min_per_class_sensitivity
                and sens_oil >= thresholds.min_per_class_sensitivity
            ),
        },
        "unseen_container_holdout": {
            "independent_samples": len(holdout_container_samples),
            "balanced_accuracy": unseen_bal_acc,
            "ci_95": unseen_ci,
            "water_sensitivity": unseen_metrics["per_class"]["H2O_DIST"]["sensitivity"],
            "oil_sensitivity": unseen_metrics["per_class"]["OIL_VEG"]["sensitivity"],
            "threshold_met": bool(
                unseen_bal_acc >= thresholds.min_unseen_container_balanced_accuracy
            ),
        },
        "cross_session_day_transfer": {
            "independent_samples": len(sess_eval_samples),
            "balanced_accuracy": cross_sess_bal_acc,
            "ci_95": cross_sess_ci,
            "water_sensitivity": cross_sess_metrics["per_class"]["H2O_DIST"]["sensitivity"],
            "oil_sensitivity": cross_sess_metrics["per_class"]["OIL_VEG"]["sensitivity"],
            "threshold_met": bool(
                cross_sess_bal_acc >= thresholds.min_cross_session_balanced_accuracy
            ),
        },
    }

    threshold_matrix = [
        {
            "criterion_id": "01_gate0a_signal_path_valid",
            "criterion": "Path isolation Gate 0A",
            "frozen_rule": "Acceptable physical signal path",
            "observed": bool(gate0a_signal_path_valid),
            "passed": bool(gate0a_signal_path_valid),
            "fail_consequence": "Decision A prohibited",
        },
        {
            "criterion_id": "02_measurement_qc_and_snr_valid",
            "criterion": "Native iPhone measurement QC and SNR",
            "frozen_rule": "Native SNR adequate; volume +-0.01; cooldown >=2.0 s",
            "observed": bool(native_snr_adequate),
            "passed": bool(native_snr_adequate),
            "fail_consequence": "Decision C/D diagnostic review",
        },
        {
            "criterion_id": "03_independent_preparations_satisfied",
            "criterion": "Independent sample structure",
            "frozen_rule": f">={thresholds.min_preparations_per_class} preps/class; >={thresholds.min_sessions} sessions; >={thresholds.min_unseen_containers_per_class} unseen container/class",
            "observed": "COMPLETE",
            "passed": True,
            "fail_consequence": "GATE_INCOMPLETE",
        },
        {
            "criterion_id": "04_primary_balanced_accuracy_ge_80pct",
            "criterion": "Primary sample-level balanced accuracy",
            "frozen_rule": f">={thresholds.min_primary_balanced_accuracy:.0%}",
            "observed": prim_bal_acc,
            "passed": bool(prim_bal_acc >= thresholds.min_primary_balanced_accuracy),
            "fail_consequence": "Decision A prohibited",
        },
        {
            "criterion_id": "05_ci95_lower_bound_gt_50pct",
            "criterion": "Uncertainty 95% CI lower bound",
            "frozen_rule": f">{thresholds.min_ci95_lower_bound_strict:.0%}",
            "observed": prim_ci_low,
            "passed": bool(prim_ci_low > thresholds.min_ci95_lower_bound_strict),
            "fail_consequence": "Decision A prohibited",
        },
        {
            "criterion_id": "06_unseen_container_accuracy_ge_70pct",
            "criterion": "Unseen containers balanced accuracy",
            "frozen_rule": f">={thresholds.min_unseen_container_balanced_accuracy:.0%}",
            "observed": unseen_bal_acc,
            "passed": bool(unseen_bal_acc >= thresholds.min_unseen_container_balanced_accuracy),
            "fail_consequence": "Decision A prohibited",
        },
        {
            "criterion_id": "07_cross_session_accuracy_ge_70pct",
            "criterion": "Cross-session/day balanced accuracy",
            "frozen_rule": f">={thresholds.min_cross_session_balanced_accuracy:.0%}",
            "observed": cross_sess_bal_acc,
            "passed": bool(cross_sess_bal_acc >= thresholds.min_cross_session_balanced_accuracy),
            "fail_consequence": "Decision A prohibited",
        },
        {
            "criterion_id": "08_both_class_sensitivities_ge_70pct",
            "criterion": "Per-class sensitivity (Water & Oil)",
            "frozen_rule": f"Neither class sensitivity <{thresholds.min_per_class_sensitivity:.0%}",
            "observed": {"H2O_DIST": sens_water, "OIL_VEG": sens_oil},
            "passed": bool(
                sens_water >= thresholds.min_per_class_sensitivity
                and sens_oil >= thresholds.min_per_class_sensitivity
            ),
            "fail_consequence": "Decision A prohibited",
        },
        {
            "criterion_id": "09_nuisance_controls_clean",
            "criterion": "Nuisance-only metadata & acoustic pre-roll controls",
            "frozen_rule": f"Metadata <{thresholds.max_metadata_nuisance_balanced_accuracy:.0%} & chance-compatible; no acoustic pre-roll leakage",
            "observed": {
                "metadata_balanced_accuracy": meta_nuisance["balanced_accuracy"],
                "acoustic_leakage_warning": acoustic_nuisance["leakage_warning_triggered"],
            },
            "passed": bool(meta_nuisance["passed"] and acoustic_nuisance_ok),
            "fail_consequence": "Confounder investigation / Decision B",
        },
        {
            "criterion_id": "10_repeatability_drift_and_confounders_clean",
            "criterion": "Repositioning ratio, session drift ratio, and confounders",
            "frozen_rule": f"Separation >={thresholds.min_separation_to_repositioning_ratio:.1f}x repositioning; drift <={thresholds.max_drift_to_separation_ratio:.0%}",
            "observed": {
                "separation_to_repositioning_ratio": round(sep_to_repo_ratio, 4),
                "drift_to_separation_ratio": round(drift_to_sep_ratio, 4),
                "confounder_to_separation_ratio": round(confounder_to_sep_ratio, 4),
            },
            "passed": bool(repeatability_ok and confounders_ok),
            "fail_consequence": "Decision A prohibited",
        },
    ]

    checklist = {row["criterion_id"]: bool(row["passed"]) for row in threshold_matrix}

    eval_report: dict[str, Any] = {
        "sop_id": SOP_M3B_VERSION,
        "status": "EVALUATED",
        "labels_scored": True,
        "feature_selection_policy": "FROZEN_PREREGISTERED_PRIMARY_25_FEATURES_NO_EXPLORATORY_PROMOTION",
        "software_build_identity": design["software_build_identity"],
        "dataset_manifest_sha256": design["dataset_manifest_sha256"],
        "threshold_config_sha256": design["threshold_config_sha256"],
        "thresholds": asdict(thresholds),
        "study_structure_table": design["study_structure_table"],
        "primary_performance_record": primary_performance_record,
        "threshold_matrix": threshold_matrix,
        "criteria_checklist": checklist,
        "summary_metrics": {
            "num_independent_preparations": sum(len(v) for v in preps_by_class.values()),
            "num_valid_samples": len(valid_samples),
            "num_sessions": len(sessions),
            "primary_balanced_accuracy": prim_bal_acc,
            "primary_ci95": prim_ci,
            "water_sensitivity": sens_water,
            "vegetable_oil_sensitivity": sens_oil,
            "unseen_container_balanced_accuracy": unseen_bal_acc,
            "cross_session_balanced_accuracy": cross_sess_bal_acc,
            "water_vs_oil_separation_db": round(sep_db, 4),
            "repositioning_variability_db": round(repo_db, 4),
            "separation_to_repositioning_ratio": round(sep_to_repo_ratio, 4),
            "max_session_drift_db": round(max_session_drift_db, 4),
            "drift_to_separation_ratio": round(drift_to_sep_ratio, 4),
            "confounder_to_separation_ratio": round(confounder_to_sep_ratio, 4),
        },
        "non_acoustic_metadata_nuisance_control": meta_nuisance,
        "acoustic_nuisance_control": acoustic_nuisance,
        "primary_confusion_matrix": prim_metrics["confusion_matrix"],
    }

    if output_report_dir is not None:
        out = Path(output_report_dir)
        out.mkdir(parents=True, exist_ok=True)
        (out / "gate0b_evaluation_metrics.json").write_text(
            json.dumps(eval_report, indent=2) + "\n", encoding="utf-8"
        )
        md_lines = [
            f"# Gate 0B Frozen Evaluation & Threshold Matrix (`{SOP_M3B_VERSION}`)",
            "",
            f"- **Software Build Identity:** `{design['software_build_identity']['package_name']}=={design['software_build_identity']['package_version']}` (`{design['software_build_identity']['build_id']}`)",
            f"- **Dataset Manifest SHA-256:** `{design['dataset_manifest_sha256']}`",
            f"- **Threshold Config SHA-256:** `{design['threshold_config_sha256']}`",
            "",
            "## Threshold Matrix",
            "| Criterion | Frozen Rule | Observed | Pass? |",
            "| :--- | :--- | :--- | :-: |",
        ]
        for row in threshold_matrix:
            obs_str = (
                json.dumps(row["observed"])
                if isinstance(row["observed"], dict)
                else str(row["observed"])
            )
            md_lines.append(
                f"| {row['criterion']} | `{row['frozen_rule']}` | `{obs_str}` | `{'PASS' if row['passed'] else 'FAIL'}` |"
            )
        (out / "gate0b_threshold_matrix.md").write_text(
            "\n".join(md_lines) + "\n", encoding="utf-8"
        )

    return eval_report


def evaluate_gate0b_decision(
    samples: list[SampleSummary],
    gate0a_signal_path_valid: bool = True,
    native_snr_adequate: bool = True,
    repositioning_variability_db: float | None = None,
    max_session_drift_db: float = 0.0,
    max_confounder_shift_db: float = 0.0,
    operational_meta: dict[str, SampleOperationalMetadata] | None = None,
    external_diagnostic_passed: bool | None = None,
    scan_yield_counts: dict[str, Any] | None = None,
    thresholds: Gate0BThresholds = Gate0BThresholds(),
    dataset_dir: Path | str | None = None,
    output_report_dir: Path | str | None = None,
) -> dict[str, Any]:
    """Execute full Section 5-7 (Sections 16-17) pre-registered Gate 0B Stop/Go decision without threshold editing."""
    eval_report = evaluate_gate0b_metrics(
        samples,
        gate0a_signal_path_valid=gate0a_signal_path_valid,
        native_snr_adequate=native_snr_adequate,
        repositioning_variability_db=repositioning_variability_db,
        max_session_drift_db=max_session_drift_db,
        max_confounder_shift_db=max_confounder_shift_db,
        operational_meta=operational_meta,
        scan_yield_counts=scan_yield_counts,
        thresholds=thresholds,
        dataset_dir=dataset_dir,
    )

    if eval_report["status"] == "GATE_INCOMPLETE":
        reasons = [
            f"Minimum preregistered study-structure requirement unmet: {req}"
            for req in eval_report["missing_dataset_requirements"]
        ]
        reasons.append(
            "Collect only the missing preregistered evidence before model scoring; do not score as failure or success."
        )
        incomplete_decision: dict[str, Any] = {
            "sop_id": SOP_M3B_VERSION,
            "disposition": "GATE_INCOMPLETE",
            "decision_reasons": reasons,
            "missing_dataset_requirements": eval_report["missing_dataset_requirements"],
            "study_structure_table": eval_report["study_structure_table"],
            "num_valid_samples": eval_report["num_valid_samples"],
            "software_build_identity": eval_report["software_build_identity"],
            "dataset_manifest_sha256": eval_report["dataset_manifest_sha256"],
            "threshold_config_sha256": eval_report["threshold_config_sha256"],
            "final_control_statement": FINAL_CONTROL_STATEMENT,
        }
        if output_report_dir is not None:
            _write_gate0b_outputs(Path(output_report_dir), incomplete_decision)
        return incomplete_decision

    checklist: dict[str, bool] = eval_report["criteria_checklist"]
    sm = eval_report["summary_metrics"]
    prim_bal_acc = sm["primary_balanced_accuracy"]
    failed_keys = [k for k, v in checklist.items() if not v]

    decision_reasons: list[str] = []
    if all(checklist.values()):
        disposition = "DECISION_A_PROCEED"
        decision_reasons.append(
            "Gate 0A signal-path validity and all 10 frozen Gate 0B study-structure, accuracy, uncertainty, transfer, nuisance, repositioning, and drift criteria passed."
        )
        decision_reasons.append("Authorized to proceed to Milestone 5 / Phase 1A.")
    elif not native_snr_adequate:
        if external_diagnostic_passed is False:
            disposition = "DECISION_D_PHENOMENON_NOT_ESTABLISHED"
            decision_reasons.append(
                "Native iPhone SNR/quality was inadequate AND the segregated external-transducer diagnostic failed to demonstrate reproducible liquid-dependent separation."
            )
            decision_reasons.append("Suspend classification development.")
        else:
            disposition = "DECISION_C_EXTERNAL_TRANSDUCER_DIAGNOSTIC"
            decision_reasons.append(
                "Native iPhone SNR/quality remained inadequate (`02_measurement_qc_and_snr_valid=False`)."
            )
            decision_reasons.append(
                "Conduct segregated EXTERNAL_TRANSDUCER_DIAGNOSTIC; never merge external-transducer data into IPHONE_NATIVE datasets."
            )
    elif external_diagnostic_passed is False and prim_bal_acc < 0.60:
        disposition = "DECISION_D_PHENOMENON_NOT_ESTABLISHED"
        decision_reasons.append(
            f"Neither native iPhone (`primary_balanced_accuracy={prim_bal_acc:.4f}`) nor segregated external diagnostic established reproducible liquid-dependent separation."
        )
        decision_reasons.append("Suspend classification development.")
    else:
        disposition = "DECISION_B_HOLD_AND_REDESIGN"
        for fk in failed_keys:
            decision_reasons.append(f"Mandatory Gate 0B criterion failed: `{fk}`.")
        decision_reasons.append(
            "Hold progression to Phase 1A; redesign Mode B fixture/coupling/controls and repeat Gate 0A/0B."
        )

    report: dict[str, Any] = {
        "sop_id": SOP_M3B_VERSION,
        "disposition": disposition,
        "decision_reasons": decision_reasons,
        "software_build_identity": eval_report["software_build_identity"],
        "dataset_manifest_sha256": eval_report["dataset_manifest_sha256"],
        "threshold_config_sha256": eval_report["threshold_config_sha256"],
        "criteria_checklist": checklist,
        "threshold_matrix": eval_report["threshold_matrix"],
        "thresholds": eval_report["thresholds"],
        "study_structure_table": eval_report["study_structure_table"],
        "primary_performance_record": eval_report["primary_performance_record"],
        "summary_metrics": sm,
        "non_acoustic_metadata_nuisance_control": eval_report[
            "non_acoustic_metadata_nuisance_control"
        ],
        "acoustic_nuisance_control": eval_report["acoustic_nuisance_control"],
        "primary_confusion_matrix": eval_report["primary_confusion_matrix"],
        "final_control_statement": FINAL_CONTROL_STATEMENT,
    }

    if output_report_dir is not None:
        _write_gate0b_outputs(Path(output_report_dir), report)

    return report


def _write_gate0b_outputs(out_dir: Path, report: dict[str, Any]) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "gate0b_decision_report.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    b_id = report["software_build_identity"]
    lines = [
        f"# Chemical Sound — Gate 0B Pre-Registered Decision Report (`{SOP_M3B_VERSION}`)",
        "",
        f"- **Formal Disposition:** **`{report['disposition']}`**",
        f"- **Software Build Identity:** `{b_id['package_name']}=={b_id['package_version']}` (`{b_id['build_id']}`)",
        f"- **Dataset Manifest SHA-256:** `{report['dataset_manifest_sha256']}`",
        f"- **Threshold Config SHA-256:** `{report['threshold_config_sha256']}`",
        "",
        "## Decision Basis & Reasons",
    ]
    for r_line in report.get("decision_reasons", []):
        lines.append(f"- {r_line}")
    lines.append("")

    if "criteria_checklist" in report:
        sm = report["summary_metrics"]
        lines.extend(
            [
                "## Primary & Stratified Metrics",
                f"- **Primary Sample-Level Balanced Accuracy:** `{sm['primary_balanced_accuracy']:.4f}` (95% Batch CI: `[{sm['primary_ci95']['ci_low']:.4f}, {sm['primary_ci95']['ci_high']:.4f}]`)",
                f"- **Sensitivities:** Water `{sm['water_sensitivity']:.4f}` | Vegetable Oil `{sm['vegetable_oil_sensitivity']:.4f}`",
                f"- **Unseen-Container Balanced Accuracy:** `{sm['unseen_container_balanced_accuracy']:.4f}`",
                f"- **Cross-Session Balanced Accuracy:** `{sm['cross_session_balanced_accuracy']:.4f}`",
                f"- **Separation / Repositioning Ratio:** `{sm['separation_to_repositioning_ratio']:.2f}x` (Req `>= 2.0x`)",
                f"- **Session Drift / Separation Ratio:** `{sm['drift_to_separation_ratio']:.2%}` (Req `<= 25%`)",
                f"- **Non-Acoustic Metadata Nuisance Accuracy:** `{report['non_acoustic_metadata_nuisance_control']['balanced_accuracy']:.4f}` (Req `< 0.60`)",
                "",
                "## Section 17 Ten-Criterion Checklist",
            ]
        )
        for k, passed in report["criteria_checklist"].items():
            mark = "PASS" if passed else "FAIL"
            lines.append(f"- **[{mark}]** `{k}`")
    else:
        lines.append("## Missing Dataset Prerequisites (`GATE_INCOMPLETE`)")
        for item in report.get("missing_dataset_requirements", []):
            lines.append(f"- `{item}`")

    lines.extend(
        [
            "",
            "---",
            f"> **Final Control Statement:** {report.get('final_control_statement', FINAL_CONTROL_STATEMENT)}",
        ]
    )
    (out_dir / "gate0b_summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
