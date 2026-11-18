# LIQUID ANALYZER

## Phase 1 v1.1 Master Specification

**Document status:** Controlled development specification  
**Version:** 1.1  
**System classification:** Experimental acoustic liquid-response classifier  
**Primary platform:** Apple iPhone  
**Primary measurement mode:** Controlled contact coupling  
**Analysis model:** Offline-first reference implementation  
**Intended use:** Research and feasibility testing only

---

# 1. Purpose

Liquid Analyzer is an experimental iPhone-based system designed to determine whether controlled liquid samples can be distinguished through repeatable acoustic-response measurements.

The system shall emit a standardized acoustic excitation, record the resulting container-liquid response, extract a compact acoustic fingerprint, and compare that fingerprint with a calibrated reference dataset.

Phase 1 shall evaluate:

1. Measurement repeatability.
2. Sensitivity to liquid-dependent response differences.
3. Sensitivity to container, fixture, volume, temperature, contact force, and environmental confounders.
4. Closed-set classification among known references.
5. Rejection of samples that do not reliably match a known reference.
6. Transferability across sessions, batches, containers, and eventually devices.

Liquid Analyzer Phase 1 shall not claim to determine:

- Complete molecular composition.
- Chemical purity.
- Toxicity or safety.
- Drinkability.
- Medical condition.
- Pharmaceutical identity or strength.
- Universal identification of arbitrary liquids.
- Trace-level contamination without separate validation.
- Laboratory-grade chemical analysis.

---

# 2. Governing scientific statement

Liquid Analyzer is a controlled acoustic-response measurement system.

It measures the combined mechanical and acoustic behavior of:

- The liquid.
- The sample container.
- The fill level.
- The fixture.
- The coupling interface.
- The iPhone speaker and microphone system.
- The surrounding environment.

The purpose of the Phase 1 controls is to determine whether liquid-dependent information remains detectable after these other influences are measured and constrained.

Classification shall be expressed as similarity to validated references, not as definitive chemical proof.

---

# 3. Phase structure

## 3.1 Phase 1A: Contact-coupled feasibility
Phase 1A shall determine whether a repeatable, liquid-dependent response can be measured using one baseline iPhone, one standardized container system, and one controlled fixture.

## 3.2 Phase 1B: Locked independent test
Phase 1B shall evaluate the frozen measurement and analysis pipeline on newly prepared batches that were not used during development.

## 3.3 Phase 1C: Near-field noncontact comparison
Phase 1C shall evaluate whether useful discrimination remains possible without direct mechanical coupling.

## 3.4 Phase 1D: Device transferability
Phase 1D shall determine whether a model developed on the baseline iPhone transfers to another physical iPhone or requires device-specific calibration.

---

# 4. Fixed Phase 1 decisions

1. One physical iPhone shall serve as the Phase 1A baseline instrument.
2. Thin-walled polypropylene containers shall be screened before final container selection.
3. Controlled contact coupling, Mode B, shall be the primary measurement configuration.
4. Near-field noncontact Mode A shall be deferred until contact-coupled feasibility is established.
5. The exploratory study shall use four independent batches and leave-one-batch-out cross-validation.
6. Two newly prepared batches per formulation shall be reserved for the locked Phase 1B test.
7. The primary excitation shall be an exponential sine sweep.
8. Stepped tones with silent decay intervals shall serve as a secondary excitation.
9. Raw unwrapped phase shall not be a primary classification feature.
10. A compact feature vector shall be used instead of unrestricted raw spectral bins.
11. Unknown rejection shall be mandatory.
12. The DSP reference implementation shall be developed before on-device classification.
13. The initial iPhone app shall be an acquisition and export instrument, not a complete classifier.
14. Requested audio settings shall be distinguished from verified runtime audio settings.
15. Final thresholds shall be derived from pilot data rather than invented in advance.

---

# 5–22. Authoritative Sections

See full Section 5–22 requirements governed by Version 1.1:
- **Sections 5–10**: Baseline iPhone, PP container screening, Mode B fixture + Controls K1/K2, requested vs. verified `AVAudioSession` configuration, `400 Hz–14 kHz` pilot ESS + matched inverse filter + stepped tones + silence control, `0.65 ± 0.01` provisional hardware volume & `2.0 s` thermal cooldown, gravimetric `% w/w` prep & 30-min mix / 3-min post-pour settle controls.
- **Sections 11–18**: Four-level CSRD-P1 hierarchy, 4-batch LOBO-CV + 2-batch locked test, Section 13 metadata fields, Section 14 QC states (`PASS`, `REJECTED`, `INTERRUPTED`, `INCOMPLETE`), session calibration drift checks, compact feature vector ($d \le 25$), Mahalanobis distance + nearest-class margin unknown rejection, and nuisance-only leakage diagnostic classifier.
- **Section 19**: Authoritative Python DSP Reference Pipeline (`liquid_analyzer` package).
- **Section 20**: Minimal Swift Acquisition Architecture (22-state acquisition state machine, 8 architectural layers, lossless bundle export).
- **Section 21**: Milestones 1 through 7.
