"""Open-set acoustic classification, nested LOBO-CV, 3-state outputs, and leakage diagnostics.

Implements CS-SPEC-P1-v1.2 Sections 3.2, 7, and 9:
- Hardware domain quarantine guard (IPHONE_NATIVE vs. EXTERNAL_TRANSDUCER_DIAGNOSTIC)
- Strict batch-level and sample-level split isolation
- Three-state system output contract:
  (1) INVALID_MEASUREMENT, (2) NO_VALIDATED_MATCH, (3) REFERENCE_MATCH (<formulation_id>)
- Nested batch-grouped cross-validation (inner LOBO selection inside outer LOBO folds)
- Batch-cluster bootstrap 95% CIs and prominent per-batch accuracy reporting
- Batch-respecting label-permutation test and Nuisance-Only Leakage Classifier
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, replace
import hashlib
import importlib.util
import json
import math
from typing import Any

import numpy as np


NO_VALIDATED_MATCH_LABEL = "NO_VALIDATED_MATCH"
UNKNOWN_LABEL = NO_VALIDATED_MATCH_LABEL
INVALID_MEASUREMENT_LABEL = "INVALID_MEASUREMENT"
REFERENCE_MATCH_STATUS = "REFERENCE_MATCH"
MODEL_VERSION = "CLF-P1-v1.2.0"

STAGE_FORMULATIONS: dict[str, tuple[str, ...]] = {
    "GATE_0B": ("H2O_DIST", "OIL_VEG"),
    "STAGE_1": ("H2O_DIST", "OIL_VEG", "MILK_WHOLE", "VIN_WHITE"),
    "STAGE_2": ("H2O_DIST", "NACL_010", "NACL_100", "SUC_050", "SUC_200"),
    "STAGE_3": (
        "H2O_DIST",
        "OIL_VEG",
        "MILK_WHOLE",
        "VIN_WHITE",
        "NACL_010",
        "NACL_100",
        "SUC_050",
        "SUC_200",
    ),
}


class DataLeakageError(RuntimeError):
    """Raised on sample/batch split leakage or prohibited hardware-domain mixing."""


@dataclass(frozen=True)
class SampleSummary:
    """Physical-sample aggregate record (primary statistical unit)."""

    sample_id: str
    formulation_id: str
    preparation_batch_id: str
    is_known_library_class: bool
    compact_features: np.ndarray
    nuisance_features: np.ndarray
    repetition_features: np.ndarray | None = None
    qc_passed: bool = True
    calibration_valid: bool = True
    hardware_domain: str = "IPHONE_NATIVE"
    unknown_category: str | None = None  # None | 'UNK_OUTER' | 'UNK_INTERMEDIATE'
    is_held_out_container: bool = False
    session_id: str = "S0"
    container_id: str = "C0"
    temperature_c: float | None = 22.0
    nominal_volume_ml: float | None = 15.0
    coupling_force_setting: str = "NOMINAL"
    condition_tag: str = "STANDARD"


@dataclass(frozen=True)
class ClassifierConfig:
    """Configuration for Tier-2 feature subset, PCA, baseline model, and rejection gates."""

    classifier_type: str = "ridge_linear"  # 'ridge_linear' | 'knn' | 'mahalanobis' | 'svm' | 'rf'
    feature_indices: tuple[int, ...] | None = None  # Explicit Tier-2 subset indices (None = all <=25)
    max_pca_components: int = 12
    pca_variance_retained: float = 0.998
    covariance_shrinkage: float = 0.08
    unknown_distance_quantile: float = 0.98
    unknown_scale_margin: float = 1.25
    margin_quantile_floor: float = 0.05
    min_repetition_agreement: float = 0.60
    knn_k: int = 3
    ridge_alpha: float = 0.10


def verify_hardware_domain_isolation(
    samples: list[SampleSummary],
    expected_domain: str = "IPHONE_NATIVE",
) -> None:
    """Quarantine EXTERNAL_TRANSDUCER_DIAGNOSTIC from IPHONE_NATIVE sets (v1.2 Section 3.2)."""
    bad = {s.hardware_domain for s in samples if s.hardware_domain != expected_domain}
    if bad:
        raise DataLeakageError(
            f"Hardware domain quarantine violation: expected only {expected_domain}, found {sorted(bad)}"
        )


def verify_disjoint_sample_and_batch_splits(
    train_samples: list[SampleSummary],
    eval_samples: list[SampleSummary],
    expected_domain: str = "IPHONE_NATIVE",
) -> None:
    """Enforce zero sample_id/batch_id overlap AND strict hardware-domain isolation."""
    verify_hardware_domain_isolation(train_samples, expected_domain=expected_domain)
    verify_hardware_domain_isolation(eval_samples, expected_domain=expected_domain)

    overlap_sids = {s.sample_id for s in train_samples} & {s.sample_id for s in eval_samples}
    if overlap_sids:
        raise DataLeakageError(
            f"Sample-level split leakage detected for sample_ids: {sorted(overlap_sids)}"
        )

    overlap_batches = {s.preparation_batch_id for s in train_samples} & {
        s.preparation_batch_id for s in eval_samples
    }
    if overlap_batches:
        raise DataLeakageError(
            f"Batch-level split leakage detected for preparation_batch_ids: {sorted(overlap_batches)}"
        )


def _shrinkage_precision(X_centered: np.ndarray, shrinkage: float = 0.20) -> np.ndarray:
    n, d = X_centered.shape
    if n <= 1:
        return np.eye(d, dtype=np.float64)
    emp_cov = (X_centered.T @ X_centered) / float(n - 1)
    avg_var = max(float(np.trace(emp_cov)) / float(d), 1e-6)
    shrunk = (1.0 - shrinkage) * emp_cov + shrinkage * avg_var * np.eye(d, dtype=np.float64)
    return np.linalg.pinv(shrunk, rcond=1e-8)


class OpenSetAcousticClassifier:
    """Training-isolated Tier-2 Selector + StandardScaler + PCA + 3-State Open-Set Classifier."""

    def __init__(self, config: ClassifierConfig = ClassifierConfig()) -> None:
        self.config = config
        self.model_version = MODEL_VERSION
        self.classes_: tuple[str, ...] = ()
        self.selected_indices_: tuple[int, ...] = ()
        self.mean_: np.ndarray | None = None
        self.scale_: np.ndarray | None = None
        self.pca_components_: np.ndarray | None = None
        self.class_centroids_: np.ndarray | None = None
        self.pooled_precision_: np.ndarray | None = None
        self.unknown_threshold_: float = math.inf
        self.margin_threshold_: float = 0.0
        self._train_z: np.ndarray | None = None
        self._train_y_idx: np.ndarray | None = None
        self._ridge_weights: np.ndarray | None = None
        self._ridge_bias: np.ndarray | None = None
        self._sklearn_model: Any = None

    def _slice_features(self, X: np.ndarray) -> np.ndarray:
        arr = np.asarray(X, dtype=np.float64)
        if self.selected_indices_:
            return arr[:, self.selected_indices_]
        return arr

    def frozen_parameter_sha256(self) -> str:
        """Compute immutable SHA-256 digest of Tier-2 indices, scaler, PCA, weights, and thresholds."""
        assert (
            self.mean_ is not None
            and self.scale_ is not None
            and self.pca_components_ is not None
            and self.class_centroids_ is not None
            and self.pooled_precision_ is not None
        )
        hasher = hashlib.sha256()
        meta = {
            "model_version": self.model_version,
            "classes": list(self.classes_),
            "selected_indices": list(self.selected_indices_),
            "unknown_threshold": round(self.unknown_threshold_, 10),
            "margin_threshold": round(self.margin_threshold_, 10),
            "classifier_type": self.config.classifier_type,
        }
        hasher.update(json.dumps(meta, sort_keys=True).encode("utf-8"))
        for arr in (
            self.mean_,
            self.scale_,
            self.pca_components_,
            self.class_centroids_,
            self.pooled_precision_,
        ):
            hasher.update(np.ascontiguousarray(arr, dtype="<f8").tobytes())
        if self._ridge_weights is not None and self._ridge_bias is not None:
            hasher.update(np.ascontiguousarray(self._ridge_weights, dtype="<f8").tobytes())
            hasher.update(np.ascontiguousarray(self._ridge_bias, dtype="<f8").tobytes())
        return hasher.hexdigest()

    def _transform_pca(self, X: np.ndarray) -> np.ndarray:
        assert self.mean_ is not None and self.scale_ is not None and self.pca_components_ is not None
        X_sub = self._slice_features(X)
        X_std = (X_sub - self.mean_) / self.scale_
        return X_std @ self.pca_components_.T

    def fit(
        self,
        X: np.ndarray,
        labels: list[str] | np.ndarray,
        batch_ids: list[str] | np.ndarray | None = None,
    ) -> "OpenSetAcousticClassifier":
        X_raw = np.asarray(X, dtype=np.float64)
        y_list = [str(lbl) for lbl in labels]
        if X_raw.ndim != 2 or X_raw.shape[0] != len(y_list):
            raise ValueError("Feature matrix X and labels have incompatible shapes.")
        b_arr = (
            np.array([str(b) for b in batch_ids])
            if batch_ids is not None
            else np.array([f"SAMPLE_{i}" for i in range(len(y_list))])
        )

        if self.config.feature_indices is not None:
            if len(self.config.feature_indices) > 25:
                raise ValueError("Tier-2 classifier vector cannot exceed 25 features.")
            self.selected_indices_ = tuple(self.config.feature_indices)
        else:
            if X_raw.shape[1] > 25:
                raise ValueError(f"Primary feature vector exceeds cap of 25 (got {X_raw.shape[1]}).")
            self.selected_indices_ = tuple(range(X_raw.shape[1]))

        X_arr = self._slice_features(X_raw)
        unique_classes = tuple(sorted(set(y_list)))
        if len(unique_classes) < 2:
            raise ValueError("At least 2 known classes are required to fit the classifier.")
        self.classes_ = unique_classes
        class_to_idx = {c: i for i, c in enumerate(unique_classes)}
        y_idx = np.array([class_to_idx[c] for c in y_list], dtype=np.int64)

        self.mean_ = np.mean(X_arr, axis=0)
        std = np.std(X_arr, axis=0)
        scale_floor = np.maximum(0.02 * np.abs(self.mean_), 0.02)
        self.scale_ = np.maximum(std, scale_floor)
        X_std = (X_arr - self.mean_) / self.scale_

        _, s_vals, vt = np.linalg.svd(X_std, full_matrices=False)
        eig_var = s_vals**2
        total_var = float(np.sum(eig_var))
        if total_var > 0:
            cum_var = np.cumsum(eig_var) / total_var
            n_var = int(np.searchsorted(cum_var, self.config.pca_variance_retained) + 1)
        else:
            n_var = 1

        nonzero_rank = max(1, int(np.sum(s_vals > 1e-7)))
        max_allowed = min(
            nonzero_rank,
            max(
                1,
                min(
                    self.config.max_pca_components,
                    X_arr.shape[1],
                    X_arr.shape[0] - len(unique_classes),
                ),
            ),
        )
        min_pca = min(10, max_allowed)
        k_pca = max(min_pca, min(n_var, max_allowed))
        self.pca_components_ = vt[:k_pca]
        Z = X_std @ self.pca_components_.T
        self._train_z = Z
        self._train_y_idx = y_idx

        n_classes = len(unique_classes)
        centroids = np.zeros((n_classes, k_pca), dtype=np.float64)
        residuals = np.zeros_like(Z)
        for c_idx in range(n_classes):
            mask = y_idx == c_idx
            centroids[c_idx] = np.mean(Z[mask], axis=0)
            residuals[mask] = Z[mask] - centroids[c_idx]

        self.class_centroids_ = centroids
        self.pooled_precision_ = _shrinkage_precision(
            residuals, shrinkage=self.config.covariance_shrinkage
        )

        loo_dists = np.empty(Z.shape[0], dtype=np.float64)
        loo_margins = np.empty(Z.shape[0], dtype=np.float64)
        for i in range(Z.shape[0]):
            c_true = int(y_idx[i])
            b_true = b_arr[i]
            has_other_batch = np.any((y_idx == c_true) & (b_arr != b_true))
            keep_mask = (b_arr != b_true) if has_other_batch else (np.arange(Z.shape[0]) != i)

            Z_keep = Z[keep_mask]
            y_keep = y_idx[keep_mask]
            centroids_keep = np.zeros((n_classes, k_pca), dtype=np.float64)
            res_keep = np.zeros_like(Z_keep)
            for c_idx in range(n_classes):
                m_c = y_keep == c_idx
                centroids_keep[c_idx] = np.mean(Z_keep[m_c], axis=0) if np.any(m_c) else centroids[c_idx]
                res_keep[m_c] = Z_keep[m_c] - centroids_keep[c_idx]
            prec_keep = _shrinkage_precision(res_keep, shrinkage=self.config.covariance_shrinkage)

            dists_i = np.empty(n_classes, dtype=np.float64)
            for c_idx in range(n_classes):
                diff = Z[i] - centroids_keep[c_idx]
                dists_i[c_idx] = math.sqrt(max(0.0, float(diff @ prec_keep @ diff)))
            sorted_d = np.sort(dists_i)
            loo_dists[i] = dists_i[c_true]
            loo_margins[i] = float(sorted_d[1] - sorted_d[0])

        q_dist = float(np.quantile(loo_dists, self.config.unknown_distance_quantile))
        chi_floor = math.sqrt(float(k_pca)) + 2.5
        self.unknown_threshold_ = max(q_dist * self.config.unknown_scale_margin, chi_floor)

        q_margin = float(np.quantile(loo_margins, self.config.margin_quantile_floor))
        self.margin_threshold_ = max(0.01, min(0.15, 0.25 * q_margin))

        ctype = self.config.classifier_type.lower()
        if ctype == "ridge_linear":
            # Regularized Linear Discriminant Analysis (prevents indicator-OLS class masking when K >= 3)
            shrink_lda = min(
                0.95, max(0.02, self.config.ridge_alpha / (1.0 + self.config.ridge_alpha))
            )
            prec_lda = _shrinkage_precision(residuals, shrinkage=shrink_lda)
            W_lda = prec_lda @ centroids.T
            b_lda = -0.5 * np.sum(centroids.T * W_lda, axis=0)
            self._ridge_weights = W_lda
            self._ridge_bias = b_lda
        elif ctype in ("svm", "rf"):
            if importlib.util.find_spec("sklearn") is not None:
                if ctype == "svm":
                    from sklearn.svm import SVC

                    model = SVC(kernel="rbf", C=2.0, class_weight="balanced", probability=True)
                else:
                    from sklearn.ensemble import RandomForestClassifier

                    model = RandomForestClassifier(
                        n_estimators=100, random_state=42, class_weight="balanced"
                    )
                model.fit(Z, y_idx)
                self._sklearn_model = model
        elif ctype not in ("knn", "mahalanobis"):
            raise ValueError(f"Unsupported classifier_type: {self.config.classifier_type}")

        return self

    def mahalanobis_distances(self, X: np.ndarray) -> np.ndarray:
        assert self.class_centroids_ is not None and self.pooled_precision_ is not None
        Z = self._transform_pca(X)
        n = Z.shape[0]
        c = self.class_centroids_.shape[0]
        dists = np.empty((n, c), dtype=np.float64)
        for idx in range(c):
            diffs = Z - self.class_centroids_[idx]
            d2 = np.einsum("ij,jk,ik->i", diffs, self.pooled_precision_, diffs)
            dists[:, idx] = np.sqrt(np.maximum(0.0, d2))
        return dists

    def predict_closed_set(self, X: np.ndarray) -> list[str]:
        Z = self._transform_pca(X)
        ctype = self.config.classifier_type.lower()

        if ctype == "ridge_linear" and self._ridge_weights is not None and self._ridge_bias is not None:
            scores = Z @ self._ridge_weights + self._ridge_bias
            best_idx = np.argmax(scores, axis=1)
        elif self._sklearn_model is not None:
            best_idx = self._sklearn_model.predict(Z)
        elif ctype == "knn":
            assert self._train_z is not None and self._train_y_idx is not None
            k = min(self.config.knn_k, self._train_z.shape[0])
            preds_idx = []
            for row in Z:
                d = np.linalg.norm(self._train_z - row, axis=1)
                nn = np.argsort(d)[:k]
                weights = 1.0 / (d[nn] + 1e-6)
                votes = np.bincount(
                    self._train_y_idx[nn], weights=weights, minlength=len(self.classes_)
                )
                preds_idx.append(int(np.argmax(votes)))
            best_idx = np.array(preds_idx, dtype=np.int64)
        else:
            dists = self.mahalanobis_distances(X)
            best_idx = np.argmin(dists, axis=1)

        return [self.classes_[int(i)] for i in best_idx]

    def predict_samples(
        self,
        samples: list[SampleSummary],
        enable_unknown_rejection: bool = True,
    ) -> dict[str, Any]:
        """Produce v1.2 3-state outputs: INVALID_MEASUREMENT | NO_VALIDATED_MATCH | REFERENCE_MATCH."""
        X = np.vstack([s.compact_features for s in samples])
        closed_preds = self.predict_closed_set(X)
        m_dists = self.mahalanobis_distances(X)
        sorted_dists = np.sort(m_dists, axis=1)
        min_dists = sorted_dists[:, 0]
        margins = sorted_dists[:, 1] - sorted_dists[:, 0]
        nearest_mahal = [self.classes_[int(i)] for i in np.argmin(m_dists, axis=1)]

        final_preds: list[str] = []
        outcome_statuses: list[str] = []
        rejection_reasons: list[str] = []
        rep_agreements: list[float] = []

        for idx, s in enumerate(samples):
            if s.repetition_features is not None and s.repetition_features.shape[0] > 0:
                rep_preds = self.predict_closed_set(s.repetition_features)
                agree = sum(1 for rp in rep_preds if rp == closed_preds[idx]) / float(len(rep_preds))
            else:
                agree = 1.0
            rep_agreements.append(round(agree, 4))

            if not s.qc_passed or not s.calibration_valid:
                final_preds.append(INVALID_MEASUREMENT_LABEL)
                outcome_statuses.append(INVALID_MEASUREMENT_LABEL)
                rejection_reasons.append("QC_OR_CALIBRATION_INVALID")
                continue

            if not enable_unknown_rejection:
                final_preds.append(closed_preds[idx])
                outcome_statuses.append(REFERENCE_MATCH_STATUS)
                rejection_reasons.append("ACCEPTED_CLOSED_SET")
                continue

            if min_dists[idx] > self.unknown_threshold_:
                final_preds.append(NO_VALIDATED_MATCH_LABEL)
                outcome_statuses.append(NO_VALIDATED_MATCH_LABEL)
                rejection_reasons.append("DISTANCE_BOUNDARY_EXCEEDED")
            elif margins[idx] < self.margin_threshold_:
                final_preds.append(NO_VALIDATED_MATCH_LABEL)
                outcome_statuses.append(NO_VALIDATED_MATCH_LABEL)
                rejection_reasons.append("INSUFFICIENT_CLASS_MARGIN")
            elif agree < self.config.min_repetition_agreement:
                final_preds.append(NO_VALIDATED_MATCH_LABEL)
                outcome_statuses.append(NO_VALIDATED_MATCH_LABEL)
                rejection_reasons.append("INCONSISTENT_REPETITIONS")
            else:
                final_preds.append(closed_preds[idx])
                outcome_statuses.append(REFERENCE_MATCH_STATUS)
                rejection_reasons.append("REFERENCE_MATCH_ACCEPTED")

        return {
            "model_version": self.model_version,
            "frozen_model_sha256": self.frozen_parameter_sha256(),
            "predictions": final_preds,
            "outcome_statuses": outcome_statuses,
            "closest_references": closed_preds,
            "nearest_mahalanobis_classes": nearest_mahal,
            "min_mahalanobis_distances": [round(float(d), 4) for d in min_dists],
            "nearest_class_margins": [round(float(m), 4) for m in margins],
            "repetition_agreements": rep_agreements,
            "rejection_reasons": rejection_reasons,
            "unknown_threshold": round(self.unknown_threshold_, 4),
            "margin_threshold": round(self.margin_threshold_, 4),
        }

    def predict(self, X: np.ndarray, enable_unknown_rejection: bool = True) -> dict[str, Any]:
        X_arr = np.asarray(X, dtype=np.float64)
        dummy_samples = [
            SampleSummary(f"ROW_{i}", "NA", "B0", True, X_arr[i], np.zeros(1))
            for i in range(X_arr.shape[0])
        ]
        res = self.predict_samples(dummy_samples, enable_unknown_rejection=enable_unknown_rejection)
        res["is_unknown"] = [p == NO_VALIDATED_MATCH_LABEL for p in res["predictions"]]
        return res


def compute_classification_metrics(
    true_labels: list[str],
    predicted_labels: list[str],
    known_classes: tuple[str, ...],
    is_known_flags: list[bool] | None = None,
) -> dict[str, Any]:
    """Compute v1.2 classification, precision/recall, and NO_VALIDATED_MATCH / INVALID metrics."""
    if len(true_labels) != len(predicted_labels):
        raise ValueError("true_labels and predicted_labels must have equal length.")

    if is_known_flags is None:
        known_set = set(known_classes)
        is_known_flags = [lbl in known_set for lbl in true_labels]

    qc_invalid_count = sum(1 for p in predicted_labels if p == INVALID_MEASUREMENT_LABEL)
    valid_indices = [i for i, p in enumerate(predicted_labels) if p != INVALID_MEASUREMENT_LABEL]

    known_indices = [i for i in valid_indices if is_known_flags[i]]
    unknown_indices = [i for i in valid_indices if not is_known_flags[i]]

    all_eval_labels = list(known_classes) + [NO_VALIDATED_MATCH_LABEL]
    label_to_col = {lbl: idx for idx, lbl in enumerate(all_eval_labels)}
    conf_matrix = np.zeros((len(known_classes), len(all_eval_labels)), dtype=int)

    for i in known_indices:
        row = known_classes.index(true_labels[i])
        col = label_to_col.get(predicted_labels[i], label_to_col[NO_VALIDATED_MATCH_LABEL])
        conf_matrix[row, col] += 1

    per_class: dict[str, dict[str, float]] = {}
    sensitivities: list[float] = []
    for r_idx, cls_name in enumerate(known_classes):
        tp = int(conf_matrix[r_idx, r_idx])
        fn = int(np.sum(conf_matrix[r_idx, :]) - tp)
        fp_known = int(np.sum(conf_matrix[:, r_idx]) - tp)
        fp_from_unk = sum(1 for i in unknown_indices if predicted_labels[i] == cls_name)
        fp_total = fp_known + fp_from_unk
        tn = int(len(known_indices) - tp - fn - fp_known)

        sens = tp / float(tp + fn) if (tp + fn) > 0 else 0.0
        spec = tn / float(tn + fp_known) if (tn + fp_known) > 0 else 0.0
        prec = tp / float(tp + fp_total) if (tp + fp_total) > 0 else 0.0
        sensitivities.append(sens)
        per_class[cls_name] = {
            "sensitivity": round(sens, 4),
            "recall": round(sens, 4),
            "specificity": round(spec, 4),
            "precision": round(prec, 4),
            "support": int(tp + fn),
        }

    known_correct = sum(1 for i in known_indices if true_labels[i] == predicted_labels[i])
    overall_known_acc = known_correct / float(len(known_indices)) if known_indices else 0.0
    balanced_acc = float(np.mean(sensitivities)) if sensitivities else 0.0
    accepted_known_rate = (
        sum(1 for i in known_indices if predicted_labels[i] != NO_VALIDATED_MATCH_LABEL)
        / float(len(known_indices))
        if known_indices
        else 0.0
    )

    if unknown_indices:
        unk_rejected = sum(
            1 for i in unknown_indices if predicted_labels[i] == NO_VALIDATED_MATCH_LABEL
        )
        unknown_rejection_rate: float | None = round(unk_rejected / float(len(unknown_indices)), 4)
        false_known_rate: float | None = round(
            1.0 - (unk_rejected / float(len(unknown_indices))), 4
        )
    else:
        unknown_rejection_rate = None
        false_known_rate = None

    return {
        "known_classes": list(known_classes),
        "matrix_columns": all_eval_labels,
        "confusion_matrix": conf_matrix.tolist(),
        "overall_known_accuracy": round(overall_known_acc, 4),
        "balanced_accuracy": round(balanced_acc, 4),
        "accepted_known_rate": round(accepted_known_rate, 4),
        "false_no_match_rate_on_known": round(1.0 - accepted_known_rate, 4),
        "unknown_rejection_rate": unknown_rejection_rate,
        "false_known_rate_on_unknown": false_known_rate,
        "qc_invalid_measurement_count": qc_invalid_count,
        "per_class": per_class,
        "num_known_samples": len(known_indices),
        "num_unknown_samples": len(unknown_indices),
    }


def summarize_per_batch_performance(
    samples: list[SampleSummary],
    predictions: list[str],
    known_classes: tuple[str, ...],
) -> dict[str, Any]:
    """Prominent hierarchical batch-level reporting (v1.2 Section 9.1)."""
    known_set = set(known_classes)
    by_batch: dict[str, list[bool]] = defaultdict(list)
    batch_formulation: dict[str, str] = {}

    for s, pred in zip(samples, predictions):
        if s.formulation_id not in known_set or pred == INVALID_MEASUREMENT_LABEL:
            continue
        by_batch[s.preparation_batch_id].append(pred == s.formulation_id)
        batch_formulation[s.preparation_batch_id] = s.formulation_id

    batch_table: dict[str, dict[str, Any]] = {}
    batch_accs: list[float] = []
    for bid in sorted(by_batch.keys()):
        hits = by_batch[bid]
        acc = sum(hits) / float(len(hits))
        batch_accs.append(acc)
        batch_table[bid] = {
            "formulation_id": batch_formulation[bid],
            "num_physical_samples": len(hits),
            "batch_accuracy": round(acc, 4),
        }

    return {
        "num_independent_batches": len(batch_accs),
        "mean_batch_accuracy": round(float(np.mean(batch_accs)), 4) if batch_accs else 0.0,
        "sd_batch_accuracy": round(float(np.std(batch_accs)), 4) if batch_accs else 0.0,
        "min_batch_accuracy": round(float(np.min(batch_accs)), 4) if batch_accs else 0.0,
        "per_batch": batch_table,
    }


def bootstrap_batch_hierarchical_ci(
    samples: list[SampleSummary],
    predicted_labels: list[str],
    known_classes: tuple[str, ...],
    n_resamples: int = 400,
    confidence_level: float = 0.95,
    seed: int = 20261116,
) -> dict[str, Any]:
    """Hierarchical cluster bootstrap resampling entire batches within each formulation (v1.2 Sec 9.1)."""
    rng = np.random.default_rng(seed)
    known_set = set(known_classes)

    # Map class -> batch_id -> list of sample correctness booleans
    clusters: dict[str, dict[str, list[bool]]] = {c: defaultdict(list) for c in known_classes}
    for s, pred in zip(samples, predicted_labels):
        if s.formulation_id in known_set and pred != INVALID_MEASUREMENT_LABEL:
            clusters[s.formulation_id][s.preparation_batch_id].append(pred == s.formulation_id)

    if any(len(clusters[c]) == 0 for c in known_classes):
        return {"method": "hierarchical_batch_cluster_bootstrap", "ci_low": 0.0, "ci_high": 0.0}

    boot_scores = np.empty(n_resamples, dtype=np.float64)
    for b in range(n_resamples):
        recalls: list[float] = []
        for c in known_classes:
            batch_ids = list(clusters[c].keys())
            drawn_batches = rng.choice(batch_ids, size=len(batch_ids), replace=True)
            pooled_hits: list[bool] = []
            for bid in drawn_batches:
                pooled_hits.extend(clusters[c][str(bid)])
            recalls.append(sum(pooled_hits) / float(max(1, len(pooled_hits))))
        boot_scores[b] = float(np.mean(recalls))

    alpha = 0.5 * (1.0 - confidence_level)
    return {
        "method": "hierarchical_batch_cluster_bootstrap",
        "n_resamples": n_resamples,
        "confidence_level": confidence_level,
        "ci_low": round(float(np.quantile(boot_scores, alpha)), 4),
        "ci_high": round(float(np.quantile(boot_scores, 1.0 - alpha)), 4),
    }


def build_unknown_evaluation_report(
    samples: list[SampleSummary],
    pred_bundle: dict[str, Any],
    known_classes: tuple[str, ...],
) -> dict[str, Any]:
    """Build v1.2 Section 9.3 unknown evaluation report separating UNK_OUTER and UNK_INTERMEDIATE."""
    known_set = set(known_classes)
    per_unk: dict[str, dict[str, Any]] = defaultdict(
        lambda: {
            "unknown_category": None,
            "total": 0,
            "qc_invalid": 0,
            "no_validated_match": 0,
            "false_reference_match": 0,
            "nearest_brackets": [],
        }
    )
    known_dists: list[float] = []
    unk_dists: list[float] = []
    known_margins: list[float] = []
    unk_margins: list[float] = []

    for s, pred, close_ref, d_min, marg in zip(
        samples,
        pred_bundle["predictions"],
        pred_bundle["closest_references"],
        pred_bundle["min_mahalanobis_distances"],
        pred_bundle["nearest_class_margins"],
    ):
        if s.formulation_id in known_set:
            if pred != INVALID_MEASUREMENT_LABEL:
                known_dists.append(d_min)
                known_margins.append(marg)
        else:
            entry = per_unk[s.formulation_id]
            entry["unknown_category"] = s.unknown_category or "UNSPECIFIED"
            entry["total"] += 1
            entry["nearest_brackets"].append(close_ref)
            if pred == INVALID_MEASUREMENT_LABEL:
                entry["qc_invalid"] += 1
            elif pred == NO_VALIDATED_MATCH_LABEL:
                entry["no_validated_match"] += 1
                unk_dists.append(d_min)
                unk_margins.append(marg)
            else:
                entry["false_reference_match"] += 1
                unk_dists.append(d_min)
                unk_margins.append(marg)

    def _dist_summary(vals: list[float]) -> dict[str, float | None]:
        if not vals:
            return {"median": None, "min": None, "max": None}
        arr = np.asarray(vals, dtype=np.float64)
        return {
            "median": round(float(np.median(arr)), 4),
            "min": round(float(np.min(arr)), 4),
            "max": round(float(np.max(arr)), 4),
        }

    return {
        "per_unknown_liquid": dict(per_unk),
        "known_distance_distribution": _dist_summary(known_dists),
        "unknown_distance_distribution": _dist_summary(unk_dists),
        "known_margin_distribution": _dist_summary(known_margins),
        "unknown_margin_distribution": _dist_summary(unk_margins),
    }


def stratify_errors_by_confounders(
    samples: list[SampleSummary],
    predictions: list[str],
    known_classes: tuple[str, ...],
) -> dict[str, dict[str, dict[str, float | int]]]:
    known_set = set(known_classes)

    def _temp_bucket(t_c: float | None) -> str:
        if t_c is None:
            return "MISSING"
        if t_c < 18.0:
            return "COOL_<18C"
        if t_c > 26.0:
            return "WARM_>26C"
        return "ROOM_18_26C"

    strata: dict[str, dict[str, list[bool]]] = {
        "by_batch": defaultdict(list),
        "by_session": defaultdict(list),
        "by_container": defaultdict(list),
        "by_held_out_container_flag": defaultdict(list),
        "by_temperature": defaultdict(list),
        "by_volume_ml": defaultdict(list),
        "by_coupling_force": defaultdict(list),
    }

    for s, pred in zip(samples, predictions):
        if s.formulation_id not in known_set or pred == INVALID_MEASUREMENT_LABEL:
            continue
        ok = pred == s.formulation_id
        strata["by_batch"][s.preparation_batch_id].append(ok)
        strata["by_session"][s.session_id].append(ok)
        strata["by_container"][s.container_id].append(ok)
        strata["by_held_out_container_flag"][str(s.is_held_out_container)].append(ok)
        strata["by_temperature"][_temp_bucket(s.temperature_c)].append(ok)
        strata["by_volume_ml"][str(s.nominal_volume_ml)].append(ok)
        strata["by_coupling_force"][s.coupling_force_setting].append(ok)

    return {
        group_name: {
            k: {
                "n": len(v),
                "accuracy": round(sum(v) / float(len(v)), 4),
                "error_rate": round(1.0 - (sum(v) / float(len(v))), 4),
            }
            for k, v in sorted(mapping.items())
            if v
        }
        for group_name, mapping in strata.items()
    }


def _one_sided_binomial_pvalue(k_success: int, n_trials: int, p_chance: float) -> float:
    if n_trials <= 0 or k_success <= 0:
        return 1.0
    prob = 0.0
    for k in range(k_success, n_trials + 1):
        prob += math.comb(n_trials, k) * (p_chance**k) * ((1.0 - p_chance) ** (n_trials - k))
    return min(1.0, prob)


def run_batch_label_permutation_test(
    known_samples: list[SampleSummary],
    target_formulations: tuple[str, ...],
    observed_balanced_accuracy: float,
    config: ClassifierConfig = ClassifierConfig(),
    n_permutations: int = 40,
    seed: int = 20261116,
) -> dict[str, Any]:
    """Permute labels strictly at the independent-batch level (v1.2 Section 9.1)."""
    rng = np.random.default_rng(seed)
    batches_by_class = {
        cls: sorted({s.preparation_batch_id for s in known_samples if s.formulation_id == cls})
        for cls in target_formulations
    }
    n_folds = min(len(v) for v in batches_by_class.values())
    fold_batches = [
        [batches_by_class[cls][f] for cls in target_formulations] for f in range(n_folds)
    ]

    null_accs = np.empty(n_permutations, dtype=np.float64)
    for p_idx in range(n_permutations):
        batch_to_perm_label: dict[str, str] = {}
        for f_b in fold_batches:
            perm_classes = list(rng.permutation(target_formulations))
            for bid, p_cls in zip(f_b, perm_classes):
                batch_to_perm_label[bid] = str(p_cls)

        perm_true: list[str] = []
        perm_pred: list[str] = []
        for fold in range(n_folds):
            held = set(fold_batches[fold])
            tr = [
                s
                for s in known_samples
                if s.preparation_batch_id not in held
                and s.preparation_batch_id in batch_to_perm_label
            ]
            ev = [s for s in known_samples if s.preparation_batch_id in held]
            X_tr = np.vstack([s.compact_features for s in tr])
            y_tr = [batch_to_perm_label[s.preparation_batch_id] for s in tr]
            X_ev = np.vstack([s.compact_features for s in ev])
            y_ev = [batch_to_perm_label[s.preparation_batch_id] for s in ev]
            clf = OpenSetAcousticClassifier(config=config).fit(X_tr, y_tr)
            preds = clf.predict_closed_set(X_ev)
            perm_true.extend(y_ev)
            perm_pred.extend(preds)

        m = compute_classification_metrics(
            perm_true, perm_pred, target_formulations, [True] * len(perm_true)
        )
        null_accs[p_idx] = m["balanced_accuracy"]

    exceed_count = int(np.sum(null_accs >= observed_balanced_accuracy))
    empirical_p = (exceed_count + 1.0) / float(n_permutations + 1.0)
    return {
        "n_permutations": n_permutations,
        "null_mean_balanced_accuracy": round(float(np.mean(null_accs)), 4),
        "null_max_balanced_accuracy": round(float(np.max(null_accs)), 4),
        "empirical_pvalue": round(empirical_p, 5),
    }


def _select_best_config_inner_lobo(
    outer_train_samples: list[SampleSummary],
    target_formulations: tuple[str, ...],
    candidate_configs: tuple[ClassifierConfig, ...],
) -> tuple[ClassifierConfig, float]:
    """Select optimal Tier-2 feature/model config strictly inside outer training batches."""
    batches_by_class = {
        cls: sorted(
            {s.preparation_batch_id for s in outer_train_samples if s.formulation_id == cls}
        )
        for cls in target_formulations
    }
    n_inner_folds = min(len(v) for v in batches_by_class.values())
    if n_inner_folds < 2 or len(candidate_configs) == 1:
        return candidate_configs[0], 0.0

    best_cfg = candidate_configs[0]
    best_score = -1.0

    for cand in candidate_configs:
        y_true_in: list[str] = []
        y_pred_in: list[str] = []
        for f_in in range(n_inner_folds):
            held_in = {batches_by_class[cls][f_in] for cls in target_formulations}
            tr_in = [s for s in outer_train_samples if s.preparation_batch_id not in held_in]
            ev_in = [s for s in outer_train_samples if s.preparation_batch_id in held_in]
            clf_in = OpenSetAcousticClassifier(config=cand).fit(
                np.vstack([s.compact_features for s in tr_in]),
                [s.formulation_id for s in tr_in],
                batch_ids=[s.preparation_batch_id for s in tr_in],
            )
            out_in = clf_in.predict_samples(ev_in, enable_unknown_rejection=True)
            y_true_in.extend([s.formulation_id for s in ev_in])
            y_pred_in.extend(out_in["predictions"])

        m_in = compute_classification_metrics(
            y_true_in, y_pred_in, target_formulations, [True] * len(y_true_in)
        )
        if m_in["balanced_accuracy"] > best_score:
            best_score = m_in["balanced_accuracy"]
            best_cfg = cand

    return best_cfg, round(best_score, 4)


def default_nested_candidate_grid(num_features: int = 25) -> tuple[ClassifierConfig, ...]:
    """Default candidate Tier-2 feature subsets & regularization grid for nested LOBO-CV."""
    bands_only = tuple(range(min(16, num_features)))
    modal_plus_decay = tuple(range(min(16, num_features), num_features))
    full_25 = tuple(range(num_features))
    candidates = [
        ClassifierConfig(classifier_type="ridge_linear", feature_indices=full_25, ridge_alpha=0.5),
        ClassifierConfig(classifier_type="ridge_linear", feature_indices=bands_only, ridge_alpha=1.0),
        ClassifierConfig(classifier_type="knn", feature_indices=full_25, knn_k=3),
    ]
    if len(modal_plus_decay) >= 3:
        candidates.append(
            ClassifierConfig(
                classifier_type="ridge_linear", feature_indices=modal_plus_decay, ridge_alpha=0.5
            )
        )
    return tuple(candidates)


def run_lobo_cv(
    samples: list[SampleSummary],
    target_formulations: tuple[str, ...],
    config: ClassifierConfig = ClassifierConfig(),
    candidate_configs: tuple[ClassifierConfig, ...] | None = None,
    enable_unknown_rejection: bool = True,
    run_permutation_test: bool = False,
    n_permutations: int = 40,
    expected_domain: str = "IPHONE_NATIVE",
) -> dict[str, Any]:
    """Run (Nested) Leave-One-Batch-Out Cross-Validation with prominent batch-level metrics."""
    verify_hardware_domain_isolation(samples, expected_domain=expected_domain)
    target_set = set(target_formulations)
    known_samples = [s for s in samples if s.formulation_id in target_set]
    unknown_probes = [s for s in samples if s.formulation_id not in target_set]

    batches_by_class: dict[str, list[str]] = {}
    for cls in target_formulations:
        cls_batches = sorted(
            {s.preparation_batch_id for s in known_samples if s.formulation_id == cls}
        )
        if len(cls_batches) < 2:
            raise ValueError(
                f"LOBO-CV requires >= 2 independent batches for {cls}, found {len(cls_batches)}."
            )
        batches_by_class[cls] = cls_batches

    n_folds = min(len(b) for b in batches_by_class.values())

    eval_samples_ordered: list[SampleSummary] = []
    all_true: list[str] = []
    all_pred_open: list[str] = []
    all_pred_closed: list[str] = []
    all_nuisance_pred: list[str] = []
    fold_balanced_accs: list[float] = []
    selected_configs_per_fold: list[dict[str, Any]] = []

    for fold in range(n_folds):
        held_out_batches = {batches_by_class[cls][fold] for cls in target_formulations}
        train_fold = [s for s in known_samples if s.preparation_batch_id not in held_out_batches]
        eval_fold = [s for s in known_samples if s.preparation_batch_id in held_out_batches]

        verify_disjoint_sample_and_batch_splits(
            train_fold, eval_fold, expected_domain=expected_domain
        )

        if candidate_configs is not None and len(candidate_configs) > 1:
            chosen_cfg, inner_score = _select_best_config_inner_lobo(
                train_fold, target_formulations, candidate_configs
            )
        else:
            chosen_cfg, inner_score = config, 0.0

        selected_configs_per_fold.append(
            {
                "fold": fold,
                "classifier_type": chosen_cfg.classifier_type,
                "num_tier2_features": len(chosen_cfg.feature_indices)
                if chosen_cfg.feature_indices
                else int(train_fold[0].compact_features.shape[0]),
                "inner_lobo_score": inner_score,
            }
        )

        X_train = np.vstack([s.compact_features for s in train_fold])
        y_train = [s.formulation_id for s in train_fold]
        b_train = [s.preparation_batch_id for s in train_fold]
        y_eval = [s.formulation_id for s in eval_fold]

        clf = OpenSetAcousticClassifier(config=chosen_cfg).fit(X_train, y_train, batch_ids=b_train)
        out = clf.predict_samples(eval_fold, enable_unknown_rejection=enable_unknown_rejection)

        # Nuisance-only classifier uses all nuisance features without Tier-2 subsetting
        nuis_cfg = replace(chosen_cfg, feature_indices=None)
        N_train = np.vstack([s.nuisance_features for s in train_fold])
        N_eval = np.vstack([s.nuisance_features for s in eval_fold])
        nuis_clf = OpenSetAcousticClassifier(config=nuis_cfg).fit(N_train, y_train)
        nuis_preds = nuis_clf.predict_closed_set(N_eval)

        fold_metrics = compute_classification_metrics(
            y_eval, out["predictions"], target_formulations, [True] * len(y_eval)
        )
        fold_balanced_accs.append(fold_metrics["balanced_accuracy"])

        eval_samples_ordered.extend(eval_fold)
        all_true.extend(y_eval)
        all_pred_open.extend(out["predictions"])
        all_pred_closed.extend(out["closest_references"])
        all_nuisance_pred.extend(nuis_preds)

    unknown_eval: dict[str, Any] | None = None
    if unknown_probes:
        verify_disjoint_sample_and_batch_splits(
            known_samples, unknown_probes, expected_domain=expected_domain
        )
        final_dev_cfg = (
            _select_best_config_inner_lobo(known_samples, target_formulations, candidate_configs)[0]
            if candidate_configs is not None and len(candidate_configs) > 1
            else config
        )
        full_clf = OpenSetAcousticClassifier(config=final_dev_cfg).fit(
            np.vstack([s.compact_features for s in known_samples]),
            [s.formulation_id for s in known_samples],
            batch_ids=[s.preparation_batch_id for s in known_samples],
        )
        unk_out = full_clf.predict_samples(unknown_probes, enable_unknown_rejection=True)
        unknown_eval = build_unknown_evaluation_report(
            unknown_probes, unk_out, target_formulations
        )

    open_metrics = compute_classification_metrics(
        all_true, all_pred_open, target_formulations, [True] * len(all_true)
    )
    closed_metrics = compute_classification_metrics(
        all_true, all_pred_closed, target_formulations, [True] * len(all_true)
    )
    nuisance_metrics = compute_classification_metrics(
        all_true, all_nuisance_pred, target_formulations, [True] * len(all_true)
    )
    per_batch = summarize_per_batch_performance(
        eval_samples_ordered, all_pred_open, target_formulations
    )
    ci_95 = bootstrap_batch_hierarchical_ci(
        eval_samples_ordered, all_pred_open, target_formulations
    )
    confounder_report = stratify_errors_by_confounders(
        eval_samples_ordered, all_pred_open, target_formulations
    )

    chance = 1.0 / float(len(target_formulations))
    nuisance_correct = sum(1 for t, p in zip(all_true, all_nuisance_pred) if t == p)
    nuisance_pval = _one_sided_binomial_pvalue(nuisance_correct, len(all_true), chance)
    leakage_flag = (nuisance_pval < 0.01) and (
        nuisance_metrics["balanced_accuracy"] > (chance + 0.15)
    )

    perm_report = (
        run_batch_label_permutation_test(
            known_samples,
            target_formulations,
            open_metrics["balanced_accuracy"],
            config=config,
            n_permutations=n_permutations,
        )
        if run_permutation_test
        else None
    )

    return {
        "nested_selection_enabled": bool(candidate_configs is not None and len(candidate_configs) > 1),
        "selected_configs_per_fold": selected_configs_per_fold,
        "num_folds": n_folds,
        "fold_balanced_accuracies": [round(x, 4) for x in fold_balanced_accs],
        "fold_balanced_accuracy_std": round(float(np.std(fold_balanced_accs)), 4),
        "per_batch_summary": per_batch,
        "balanced_accuracy_ci_95": ci_95,
        "open_set_metrics": open_metrics,
        "closed_set_metrics": closed_metrics,
        "unknown_probe_evaluation": unknown_eval,
        "confounder_error_analysis": confounder_report,
        "permutation_test": perm_report,
        "nuisance_leakage_diagnostic": {
            "chance_level": round(chance, 4),
            "nuisance_balanced_accuracy": nuisance_metrics["balanced_accuracy"],
            "nuisance_overall_accuracy": nuisance_metrics["overall_known_accuracy"],
            "one_sided_pvalue_vs_chance": round(nuisance_pval, 6),
            "leakage_warning_triggered": leakage_flag,
        },
    }


def run_nested_lobo_cv(
    samples: list[SampleSummary],
    target_formulations: tuple[str, ...],
    candidate_configs: tuple[ClassifierConfig, ...] | None = None,
    enable_unknown_rejection: bool = True,
) -> dict[str, Any]:
    """Explicit convenience entrypoint enforcing inner-loop model/feature selection."""
    n_feat = int(samples[0].compact_features.shape[0]) if samples else 25
    grid = candidate_configs if candidate_configs is not None else default_nested_candidate_grid(n_feat)
    return run_lobo_cv(
        samples,
        target_formulations,
        candidate_configs=grid,
        enable_unknown_rejection=enable_unknown_rejection,
    )


def evaluate_locked_test(
    phase1a_train_samples: list[SampleSummary],
    phase1b_test_samples: list[SampleSummary],
    target_formulations: tuple[str, ...],
    config: ClassifierConfig = ClassifierConfig(),
    expected_frozen_model_sha256: str | None = None,
    expected_domain: str = "IPHONE_NATIVE",
) -> dict[str, Any]:
    """Evaluate frozen Phase 1A model once on Phase 1B batches + unseen containers + withheld unknowns."""
    target_set = set(target_formulations)
    train_known = [
        s for s in phase1a_train_samples if s.formulation_id in target_set and s.qc_passed
    ]
    if not train_known or not phase1b_test_samples:
        raise ValueError("Both Phase 1A training samples and Phase 1B test samples are required.")

    verify_disjoint_sample_and_batch_splits(
        train_known, phase1b_test_samples, expected_domain=expected_domain
    )

    X_train = np.vstack([s.compact_features for s in train_known])
    y_train = [s.formulation_id for s in train_known]
    b_train = [s.preparation_batch_id for s in train_known]
    clf = OpenSetAcousticClassifier(config=config).fit(X_train, y_train, batch_ids=b_train)

    model_hash = clf.frozen_parameter_sha256()
    if expected_frozen_model_sha256 is not None and model_hash != expected_frozen_model_sha256:
        raise RuntimeError(
            f"Locked-test model immutability violation: expected {expected_frozen_model_sha256}, got {model_hash}"
        )

    y_test = [s.formulation_id for s in phase1b_test_samples]
    is_known = [s.formulation_id in target_set for s in phase1b_test_samples]

    out = clf.predict_samples(phase1b_test_samples, enable_unknown_rejection=True)
    metrics = compute_classification_metrics(y_test, out["predictions"], target_formulations, is_known)
    per_batch = summarize_per_batch_performance(
        phase1b_test_samples, out["predictions"], target_formulations
    )
    ci_95 = bootstrap_batch_hierarchical_ci(
        phase1b_test_samples, out["predictions"], target_formulations
    )
    unk_report = build_unknown_evaluation_report(phase1b_test_samples, out, target_formulations)
    confounder_report = stratify_errors_by_confounders(
        phase1b_test_samples, out["predictions"], target_formulations
    )

    known_test = [
        s for s in phase1b_test_samples if s.formulation_id in target_set and s.qc_passed
    ]
    nuisance_diag: dict[str, Any] = {}
    if known_test:
        nuis_cfg = replace(config, feature_indices=None)
        nuis_clf = OpenSetAcousticClassifier(config=nuis_cfg).fit(
            np.vstack([s.nuisance_features for s in train_known]), y_train
        )
        nuis_preds = nuis_clf.predict_closed_set(
            np.vstack([s.nuisance_features for s in known_test])
        )
        y_known_test = [s.formulation_id for s in known_test]
        nuis_m = compute_classification_metrics(
            y_known_test, nuis_preds, target_formulations, [True] * len(y_known_test)
        )
        chance = 1.0 / float(len(target_formulations))
        n_corr = sum(1 for t, p in zip(y_known_test, nuis_preds) if t == p)
        pval = _one_sided_binomial_pvalue(n_corr, len(y_known_test), chance)
        nuisance_diag = {
            "chance_level": round(chance, 4),
            "nuisance_balanced_accuracy": nuis_m["balanced_accuracy"],
            "one_sided_pvalue_vs_chance": round(pval, 6),
            "leakage_warning_triggered": (pval < 0.01) and (nuis_m["balanced_accuracy"] > chance + 0.15),
        }

    return {
        "model_version": clf.model_version,
        "frozen_model_sha256": model_hash,
        "metrics": metrics,
        "per_batch_summary": per_batch,
        "balanced_accuracy_ci_95": ci_95,
        "unknown_threshold": out["unknown_threshold"],
        "margin_threshold": out["margin_threshold"],
        "unknown_evaluation_report": unk_report,
        "confounder_error_analysis": confounder_report,
        "predictions": [
            {
                "sample_id": s.sample_id,
                "true_formulation": s.formulation_id,
                "outcome_status": status,
                "predicted_label": pred,
                "closest_reference": close_ref,
                "min_mahalanobis_distance": dist,
                "nearest_class_margin": marg,
                "repetition_agreement": rep_ag,
                "decision_reason": reason,
            }
            for s, status, pred, close_ref, dist, marg, rep_ag, reason in zip(
                phase1b_test_samples,
                out["outcome_statuses"],
                out["predictions"],
                out["closest_references"],
                out["min_mahalanobis_distances"],
                out["nearest_class_margins"],
                out["repetition_agreements"],
                out["rejection_reasons"],
            )
        ],
        "nuisance_leakage_diagnostic": nuisance_diag,
    }
