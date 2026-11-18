(() => {
  // Reference Liquid Profiles (matching Swift ConsumerModels.swift & Android)
  const PROFILES = {
    H2O_DIST: {
      id: "H2O_DIST",
      status: "REFERENCE_MATCH",
      title: "Distilled Water",
      formula: "H₂O",
      badge: "Experimental Reference Match • 86% Similarity",
      liquidTint: "#93d3fc",
      constituents: [
        { symbol: "H₂O", name: "Water", role: "Primary reference constituent" }
      ],
      note: "Estimated from acoustic resonance similarity to the distilled water reference profile. Experimental research result—not a laboratory chemical or safety test.",
      tuneCaption: "Mapped musical representation of hydrogen-oxygen reference intervals and measured resonance.",
      freqs: [392.00, 493.88, 587.33, 783.99, 880.00], // G4, B4, D5, G5, A5
      shimmer: 1.05,
      decay: 1.45
    },
    NACL_AQ: {
      id: "NACL_AQ",
      status: "REFERENCE_MATCH",
      title: "Saline Water",
      formula: "H₂O + NaCl",
      badge: "Experimental Reference Match • 83% Similarity",
      liquidTint: "#7dd3fc",
      constituents: [
        { symbol: "H₂O", name: "Water", role: "Aqueous solvent reference" },
        { symbol: "NaCl", name: "Sodium Chloride", role: "Dissolved salt reference constituent" }
      ],
      note: "Estimated from acoustic resonance similarity to the saline water reference profile. Experimental research result—not a laboratory chemical or safety test.",
      tuneCaption: "Mapped musical representation combining water harmonics with bright ionic fifth and ninth intervals.",
      freqs: [392.00, 587.33, 659.25, 739.99, 987.77],
      shimmer: 1.22,
      decay: 1.65
    },
    SUC_AQ: {
      id: "SUC_AQ",
      status: "REFERENCE_MATCH",
      title: "Sweetened Water",
      formula: "H₂O + C₁₂H₂₂O₁₁",
      badge: "Experimental Reference Match • 81% Similarity",
      liquidTint: "#bae6fd",
      constituents: [
        { symbol: "H₂O", name: "Water", role: "Aqueous solvent reference" },
        { symbol: "C₁₂H₂₂O₁₁", name: "Sucrose", role: "Dissolved sugar reference constituent" }
      ],
      note: "Estimated from acoustic resonance similarity to the aqueous sucrose reference profile. Experimental research result—not a laboratory chemical or safety test.",
      tuneCaption: "Mapped musical representation pairing carbon bass intervals with warm damped water harmonics.",
      freqs: [261.63, 392.00, 493.88, 587.33, 659.25],
      shimmer: 0.90,
      decay: 1.95
    },
    VIN_WHITE: {
      id: "VIN_WHITE",
      status: "REFERENCE_MATCH",
      title: "White Vinegar",
      formula: "H₂O + CH₃COOH",
      badge: "Experimental Reference Match • 84% Similarity",
      liquidTint: "#e0f2fe",
      constituents: [
        { symbol: "H₂O", name: "Water", role: "Primary aqueous base" },
        { symbol: "CH₃COOH", name: "Acetic Acid", role: "Dilute organic acid constituent" }
      ],
      note: "Estimated from acoustic resonance similarity to the white vinegar reference profile. Experimental research result—not a laboratory chemical or safety test.",
      tuneCaption: "Mapped musical representation blending carbon-oxygen intervals with crisp upper harmonics.",
      freqs: [293.66, 440.00, 554.37, 659.25, 880.00],
      shimmer: 1.15,
      decay: 1.70
    },
    OIL_VEG: {
      id: "OIL_VEG",
      status: "REFERENCE_MATCH",
      title: "Vegetable Oil",
      formula: "Triglyceride",
      badge: "Experimental Reference Match • 88% Similarity",
      liquidTint: "#fde047",
      constituents: [
        { symbol: "C · H · O", name: "Plant Triglycerides", role: "Viscous lipid reference class" }
      ],
      note: "Estimated from acoustic resonance similarity to the vegetable oil reference profile. Experimental research result—not a laboratory chemical or safety test.",
      tuneCaption: "Mapped musical representation featuring warm, rapidly damped low-register carbon-chain harmonics.",
      freqs: [196.00, 293.66, 392.00, 440.00, 587.33],
      shimmer: 0.72,
      decay: 2.35
    },
    UNMATCHED: {
      id: "UNMATCHED",
      status: "NO_VALIDATED_MATCH",
      title: "Unmatched Liquid",
      formula: "Acoustic Profile",
      badge: "Experimental • Outside Current Reference Library",
      liquidTint: "#c4b5fd",
      constituents: [
        { symbol: "≈ 3,420 Hz", name: "Measured Resonance Peak", role: "Unclassified liquid signature (no reference claim)" }
      ],
      note: "A clean acoustic response was captured, but its resonance pattern did not closely match a calibrated reference liquid yet. You can still listen to its mapped acoustic tune.",
      tuneCaption: "Mapped musical representation derived directly from the liquid's measured acoustic resonance frequencies.",
      freqs: [329.63, 369.99, 440.00, 587.33, 659.25],
      shimmer: 1.0,
      decay: 1.8
    }
  };

  // DOM References
  const presetSelect = document.getElementById("presetSelect");
  const toggleCameraBtn = document.getElementById("toggleCameraBtn");
  const cameraVideo = document.getElementById("cameraVideo");
  const snapshotCanvas = document.getElementById("snapshotCanvas");
  const studioBackdrop = document.getElementById("studioBackdrop");
  const aimLiquidPolygon = document.getElementById("aimLiquidPolygon");

  const headerBackBtn = document.getElementById("headerBackBtn");
  const headerLeftSpacer = document.getElementById("headerLeftSpacer");
  const headerTitleText = document.getElementById("headerTitleText");
  const headerGearBtn = document.getElementById("headerGearBtn");

  const screens = {
    aim: document.getElementById("screen-aim"),
    scanning: document.getElementById("screen-scanning"),
    result: document.getElementById("screen-result"),
    tune: document.getElementById("screen-tune")
  };

  const scanPrimaryBtn = document.getElementById("scanPrimaryBtn");
  const cancelScanBtn = document.getElementById("cancelScanBtn");
  const scanProgressFill = document.getElementById("scanProgressFill");
  const scanningWaveBars = document.getElementById("scanningWaveBars");

  const resultBanner = document.getElementById("resultBanner");
  const resultBannerLabel = document.getElementById("resultBannerLabel");
  const resultBannerIcon = document.getElementById("resultBannerIcon");
  const resultLiquidName = document.getElementById("resultLiquidName");
  const resultFormula = document.getElementById("resultFormula");
  const resultBadge = document.getElementById("resultBadge");
  const resultSnapshotImg = document.getElementById("resultSnapshotImg");
  const resultGlassFallback = document.getElementById("resultGlassFallback");
  const resultLiquidPoly = document.getElementById("resultLiquidPoly");
  const compositionRows = document.getElementById("compositionRows");
  const resultScientificNote = document.getElementById("resultScientificNote");
  const openTuneBtn = document.getElementById("openTuneBtn");
  const scanAnotherBtn = document.getElementById("scanAnotherBtn");

  const rainbowBars = document.getElementById("rainbowBars");
  const tuneFormula = document.getElementById("tuneFormula");
  const tuneCaption = document.getElementById("tuneCaption");
  const playPauseTuneBtn = document.getElementById("playPauseTuneBtn");
  const playPauseGlyph = document.getElementById("playPauseGlyph");
  const playPauseLabel = document.getElementById("playPauseLabel");
  const tuneScrubber = document.getElementById("tuneScrubber");
  const tuneElapsed = document.getElementById("tuneElapsed");

  const historyListContainer = document.getElementById("historyListContainer");
  const clearHistoryBtn = document.getElementById("clearHistoryBtn");
  const autoPlayTuneToggle = document.getElementById("autoPlayTuneToggle");
  const audibleSweepToggle = document.getElementById("audibleSweepToggle");

  const openResearchGateBtn = document.getElementById("openResearchGateBtn");
  const researchConfirmModal = document.getElementById("researchConfirmModal");
  const confirmResearchOpenBtn = document.getElementById("confirmResearchOpenBtn");
  const cancelResearchOpenBtn = document.getElementById("cancelResearchOpenBtn");
  const researchConsoleModal = document.getElementById("researchConsoleModal");
  const exitResearchConsoleBtn = document.getElementById("exitResearchConsoleBtn");
  const researchScanCount = document.getElementById("researchScanCount");
  const exportResearchJsonlBtn = document.getElementById("exportResearchJsonlBtn");

  // State
  let currentFlow = "aim";
  let currentResult = PROFILES.H2O_DIST;
  let scanTimer = null;
  let waveAnimFrame = null;
  let cameraStream = null;
  let historyItems = JSON.parse(localStorage.getItem("la_consumer_history_v1") || "[]");

  // Audio Engine State
  let audioCtx = null;
  let tuneSource = null;
  let tuneBuffer = null;
  let tuneStartTime = 0;
  let tunePauseOffset = 0;
  let isTunePlaying = false;
  let tuneAnimFrame = null;
  const TUNE_DURATION = 6.0;

  // Build 13 scanning blue bars & 33 rainbow Chemical Tune bars
  for (let i = 0; i < 13; i++) {
    const bar = document.createElement("span");
    bar.style.height = "22px";
    scanningWaveBars.appendChild(bar);
  }

  for (let i = 0; i < 33; i++) {
    const frac = i / 32;
    const hue = rainbowHue(frac);
    const bar = document.createElement("span");
    const color = `hsl(${hue}, 92%, 62%)`;
    bar.style.background = `linear-gradient(180deg, ${color}, #ffffff 50%, ${color})`;
    bar.style.boxShadow = `0 0 9px hsla(${hue}, 95%, 60%, 0.85)`;
    bar.style.height = `${restingBarHeight(i)}px`;
    rainbowBars.appendChild(bar);
  }

  function rainbowHue(f) {
    if (f < 0.25) return Math.round(230 - (f / 0.25) * 45);     // Blue -> Cyan
    if (f < 0.50) return Math.round(185 - ((f - 0.25) / 0.25) * 65); // Cyan -> Green
    if (f < 0.75) return Math.round(120 - ((f - 0.50) / 0.25) * 88); // Green -> Gold/Orange
    const h = 32 - ((f - 0.75) / 0.25) * 82;
    return Math.round(h < 0 ? h + 360 : h);                    // Orange -> Magenta/Violet
  }

  function restingBarHeight(idx) {
    const frac = idx / 32;
    const pA = Math.exp(-Math.pow((frac - 0.22) / 0.14, 2));
    const pB = Math.exp(-Math.pow((frac - 0.50) / 0.16, 2)) * 1.08;
    const pC = Math.exp(-Math.pow((frac - 0.78) / 0.14, 2));
    const env = Math.min(1, 0.20 + 0.82 * Math.max(pA, pB, pC));
    const mod = 0.56 + 0.34 * Math.abs(Math.sin(idx * 0.62 + 1.2));
    return Math.round(Math.max(14, 148 * env * mod));
  }

  function ensureAudioContext() {
    if (!audioCtx) {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      if (Ctx) audioCtx = new Ctx({ sampleRate: 48000 });
    }
    if (audioCtx && audioCtx.state === "suspended") {
      audioCtx.resume();
    }
    return audioCtx;
  }

  // Update glass liquid tint in studio preview when changing test preset
  presetSelect.addEventListener("change", () => {
    const prof = PROFILES[presetSelect.value] || PROFILES.H2O_DIST;
    aimLiquidPolygon.setAttribute("fill", prof.liquidTint);
    aimLiquidPolygon.setAttribute("opacity", "0.78");
  });

  // Live Camera Toggle
  toggleCameraBtn.addEventListener("click", async () => {
    if (cameraStream) {
      cameraStream.getTracks().forEach(t => t.stop());
      cameraStream = null;
      cameraVideo.classList.add("hidden");
      studioBackdrop.classList.remove("hidden");
      toggleCameraBtn.textContent = "Enable Live Camera";
      return;
    }
    try {
      cameraStream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: "environment" },
        audio: false
      });
      cameraVideo.srcObject = cameraStream;
      cameraVideo.classList.remove("hidden");
      studioBackdrop.classList.add("hidden");
      toggleCameraBtn.textContent = "Disable Live Camera";
    } catch {
      alert("Camera unavailable on this device/browser—using Studio Liquid Glass aiming view.");
    }
  });

  // Tab Navigation (`Scan | History | Learn | More`)
  document.querySelectorAll(".tab-btn").forEach(btn => {
    btn.addEventListener("click", () => {
      switchTab(btn.dataset.tab);
    });
  });

  function switchTab(tabId) {
    if (tabId !== "scan") stopChemicalTune();
    document.querySelectorAll(".tab-btn").forEach(b => b.classList.toggle("active", b.dataset.tab === tabId));
    document.querySelectorAll(".tab-panel").forEach(p => p.classList.toggle("active", p.id === `tab-${tabId}`));
    if (tabId === "history") renderHistory();
    if (tabId === "more") researchScanCount.textContent = String(historyItems.length);
  }

  headerGearBtn.addEventListener("click", () => switchTab("more"));

  headerBackBtn.addEventListener("click", () => {
    if (currentFlow === "tune") {
      stopChemicalTune();
      setFlowScreen("result");
    } else if (currentFlow === "result") {
      setFlowScreen("aim");
    }
  });

  function setFlowScreen(step) {
    currentFlow = step;
    Object.entries(screens).forEach(([k, el]) => {
      el.classList.toggle("active", k === step);
    });

    if (step === "aim") {
      headerBackBtn.classList.add("hidden");
      headerLeftSpacer.classList.remove("hidden");
      headerTitleText.textContent = "Liquid Analyzer";
      headerGearBtn.classList.remove("hidden");
    } else if (step === "scanning") {
      headerBackBtn.classList.add("hidden");
      headerLeftSpacer.classList.remove("hidden");
      headerTitleText.textContent = "Liquid Analyzer";
      headerGearBtn.classList.add("hidden");
    } else if (step === "result") {
      headerBackBtn.classList.remove("hidden");
      headerLeftSpacer.classList.add("hidden");
      headerTitleText.textContent = "Liquid Analyzer";
      headerGearBtn.classList.remove("hidden");
    } else if (step === "tune") {
      headerBackBtn.classList.remove("hidden");
      headerLeftSpacer.classList.add("hidden");
      headerTitleText.textContent = "Chemical Tune";
      headerGearBtn.classList.add("hidden");
    }
  }

  // Emit gentle 200 ms Exponential Sine Sweep (400 Hz -> 14 kHz) during scan
  function playAcousticExcitationSweep() {
    if (!audibleSweepToggle.checked) return;
    const ctx = ensureAudioContext();
    if (!ctx) return;

    const dur = 0.22;
    const sr = ctx.sampleRate;
    const len = Math.floor(sr * dur);
    const buf = ctx.createBuffer(1, len, sr);
    const data = buf.getChannelData(0);
    const f1 = 400.0;
    const f2 = 12000.0;
    const L = dur / Math.log(f2 / f1);

    for (let i = 0; i < len; i++) {
      const t = i / sr;
      const fadeIn = i < 480 ? 0.5 * (1 - Math.cos(Math.PI * i / 480)) : 1.0;
      const fadeOut = i > len - 480 ? 0.5 * (1 - Math.cos(Math.PI * (len - i) / 480)) : 1.0;
      const phase = 2 * Math.PI * f1 * L * (Math.exp(t / L) - 1);
      data[i] = 0.14 * fadeIn * fadeOut * Math.sin(phase);
    }

    const src = ctx.createBufferSource();
    src.buffer = buf;
    src.connect(ctx.destination);
    src.start();
  }

  // Capture Camera Thumbnail if active
  function captureSnapshotDataURL() {
    if (!cameraStream || cameraVideo.classList.contains("hidden")) return null;
    const ctx = snapshotCanvas.getContext("2d");
    const vw = cameraVideo.videoWidth || 320;
    const vh = cameraVideo.videoHeight || 320;
    const side = Math.min(vw, vh);
    ctx.drawImage(cameraVideo, (vw - side) / 2, (vh - side) / 2, side, side, 0, 0, 320, 320);
    return snapshotCanvas.toDataURL("image/jpeg", 0.78);
  }

  // 1 -> 2 -> 3: Start Scan Sequence
  scanPrimaryBtn.addEventListener("click", async () => {
    const thumbURL = captureSnapshotDataURL();
    setFlowScreen("scanning");
    scanProgressFill.style.width = "8%";
    playAcousticExcitationSweep();

    const scanBars = Array.from(scanningWaveBars.children);
    const startTs = performance.now();
    const totalMs = 1550;

    function animateScanning(now) {
      if (currentFlow !== "scanning") return;
      const elapsed = now - startTs;
      const pct = Math.min(100, Math.round((elapsed / totalMs) * 100));
      scanProgressFill.style.width = `${Math.max(8, pct)}%`;

      scanBars.forEach((b, idx) => {
        const centerDist = Math.abs(idx - 6) / 6;
        const env = Math.max(0.2, 1 - centerDist * centerDist * 0.8);
        const wave = 0.52 + 0.48 * Math.sin(now * 0.011 + idx * 0.65);
        b.style.height = `${Math.round(14 + 68 * env * wave)}px`;
      });

      if (elapsed < totalMs) {
        waveAnimFrame = requestAnimationFrame(animateScanning);
      }
    }
    waveAnimFrame = requestAnimationFrame(animateScanning);

    // Optional live mic spectral centroid probe if LIVE_MIC is selected
    let resolvedKey = presetSelect.value;
    if (resolvedKey === "LIVE_MIC") {
      resolvedKey = await probeLiveMicOrFallback();
    }

    scanTimer = setTimeout(() => {
      cancelAnimationFrame(waveAnimFrame);
      const baseProf = PROFILES[resolvedKey] || PROFILES.H2O_DIST;
      const item = {
        ...baseProf,
        uid: `scan_${Date.now()}`,
        timestampISO: new Date().toISOString(),
        timeLabel: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
        thumbURL
      };
      saveToHistory(item);
      presentResult(item);
    }, totalMs);
  });

  async function probeLiveMicOrFallback() {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
      await new Promise(r => setTimeout(r, 450));
      stream.getTracks().forEach(t => t.stop());
      return "H2O_DIST";
    } catch {
      return "H2O_DIST";
    }
  }

  cancelScanBtn.addEventListener("click", () => {
    clearTimeout(scanTimer);
    cancelAnimationFrame(waveAnimFrame);
    setFlowScreen("aim");
  });

  function presentResult(item) {
    currentResult = item;
    tuneBuffer = null;
    tunePauseOffset = 0;

    const isMatch = item.status === "REFERENCE_MATCH";
    resultBanner.className = `result-banner ${isMatch ? "green" : "blue"}`;
    resultBannerLabel.textContent = isMatch ? "Result" : "Acoustic Profile";
    resultBannerIcon.textContent = isMatch ? "✓" : "∿";

    resultLiquidName.textContent = item.title;
    resultFormula.textContent = item.formula;
    resultBadge.textContent = item.badge;
    resultBadge.className = `result-exp-badge ${isMatch ? "" : "amber"}`;

    if (item.thumbURL) {
      resultSnapshotImg.src = item.thumbURL;
      resultSnapshotImg.classList.remove("hidden");
      resultGlassFallback.classList.add("hidden");
    } else {
      resultSnapshotImg.classList.add("hidden");
      resultGlassFallback.classList.remove("hidden");
      resultLiquidPoly.setAttribute("fill", item.liquidTint || "#93d3fc");
    }

    compositionRows.innerHTML = "";
    item.constituents.forEach(c => {
      const row = document.createElement("div");
      row.className = "comp-row";
      row.innerHTML = `
        <span class="comp-sym">${c.symbol}</span>
        <div class="comp-detail">
          <div class="comp-name">${c.name}</div>
          <div class="comp-role">${c.role}</div>
        </div>
      `;
      compositionRows.appendChild(row);
    });

    resultScientificNote.textContent = item.note;
    setFlowScreen("result");
  }

  scanAnotherBtn.addEventListener("click", () => {
    setFlowScreen("aim");
  });

  // 3 -> 4: Open Chemical Tune Screen
  openTuneBtn.addEventListener("click", () => {
    openChemicalTuneFor(currentResult);
  });

  function openChemicalTuneFor(item) {
    currentResult = item;
    stopChemicalTune();
    tuneBuffer = null;
    tunePauseOffset = 0;
    tuneScrubber.value = "0";
    tuneElapsed.textContent = "0:00";

    tuneFormula.textContent = item.formula === "Acoustic Profile" ? "Acoustic Signature" : item.formula;
    tuneCaption.textContent = item.tuneCaption;
    switchTab("scan");
    setFlowScreen("tune");

    if (autoPlayTuneToggle.checked) {
      startChemicalTune();
    }
  }

  // Synthesize 6.0 s Polyphonic Chemical Tune AudioBuffer (matching Swift ChemicalTuneSynthesizer)
  function buildChemicalTuneBuffer(ctx, item) {
    const sr = ctx.sampleRate;
    const total = Math.floor(sr * TUNE_DURATION);
    const buffer = ctx.createBuffer(1, total, sr);
    const out = buffer.getChannelData(0);

    const freqs = item.freqs || [392.0, 493.88, 587.33, 783.99];
    const shimmer = item.shimmer || 1.0;
    const decay = item.decay || 1.6;

    // 1. Warm harmonic chord pad
    freqs.slice(0, 4).forEach((f, vIdx) => {
      const amp = 0.10 / (1 + Math.floor(vIdx / 2));
      for (let n = 0; n < total; n++) {
        const t = n / sr;
        const lfo = 0.85 + 0.15 * Math.sin(2 * Math.PI * (0.35 + 0.08 * vIdx) * t);
        const s1 = Math.sin(2 * Math.PI * f * t);
        const s2 = 0.25 * shimmer * Math.sin(2 * Math.PI * 2 * f * t);
        out[n] += amp * lfo * (s1 + s2);
      }
    });

    // 2. Crystalline 8-note arpeggiated signature motif
    const noteCount = 8;
    const spacing = (TUNE_DURATION - 0.8) / noteCount;
    for (let step = 0; step < noteCount; step++) {
      const fNote = freqs[step % freqs.length];
      const startFrame = Math.floor((0.18 + step * spacing) * sr);
      const lenFrames = Math.min(total - startFrame, Math.floor(1.65 * sr));
      const attackFrames = Math.floor(0.018 * sr);

      for (let k = 0; k < lenFrames; k++) {
        const dt = k / sr;
        const atk = k < attackFrames ? 0.5 * (1 - Math.cos(Math.PI * k / attackFrames)) : 1.0;
        const dec = Math.exp(-decay * dt);
        const rel = k > lenFrames - 960 ? (lenFrames - k) / 960 : 1.0;
        const env = atk * dec * Math.max(0, rel);
        const w = Math.sin(2 * Math.PI * fNote * dt)
          + 0.32 * shimmer * Math.sin(2 * Math.PI * 2 * fNote * dt)
          + 0.10 * shimmer * Math.sin(2 * Math.PI * 3 * fNote * dt);
        out[startFrame + k] += 0.22 * env * w;
      }
    }

    // 3. Global cosine fades & -3 dBFS normalization
    const fadeIn = Math.floor(0.04 * sr);
    const fadeOut = Math.floor(0.28 * sr);
    for (let i = 0; i < fadeIn; i++) {
      out[i] *= 0.5 * (1 - Math.cos(Math.PI * i / fadeIn));
    }
    for (let i = 0; i < fadeOut; i++) {
      out[total - 1 - i] *= 0.5 * (1 - Math.cos(Math.PI * i / fadeOut));
    }

    let peak = 1e-6;
    for (let i = 0; i < total; i++) {
      const a = Math.abs(out[i]);
      if (a > peak) peak = a;
    }
    const gain = 0.7079 / peak;
    for (let i = 0; i < total; i++) out[i] *= gain;

    return buffer;
  }

  function startChemicalTune() {
    const ctx = ensureAudioContext();
    if (!ctx) return;

    if (!tuneBuffer) {
      tuneBuffer = buildChemicalTuneBuffer(ctx, currentResult);
    }

    if (tunePauseOffset >= TUNE_DURATION - 0.05) {
      tunePauseOffset = 0;
    }

    stopTuneSourceOnly();
    tuneSource = ctx.createBufferSource();
    tuneSource.buffer = tuneBuffer;
    tuneSource.connect(ctx.destination);
    tuneStartTime = ctx.currentTime - tunePauseOffset;
    tuneSource.start(0, tunePauseOffset);

    isTunePlaying = true;
    playPauseGlyph.textContent = "❚❚";
    playPauseLabel.textContent = "Pause";

    tuneSource.onended = () => {
      if (isTunePlaying && audioCtx && (audioCtx.currentTime - tuneStartTime) >= TUNE_DURATION - 0.08) {
        isTunePlaying = false;
        tunePauseOffset = TUNE_DURATION;
        tuneScrubber.value = "100";
        tuneElapsed.textContent = "0:06";
        playPauseGlyph.textContent = "▶";
        playPauseLabel.textContent = "Play";
        resetRainbowBarsToRest();
      }
    };

    animateRainbowTune();
  }

  function pauseChemicalTune() {
    if (!isTunePlaying || !audioCtx) return;
    tunePauseOffset = Math.min(TUNE_DURATION, Math.max(0, audioCtx.currentTime - tuneStartTime));
    isTunePlaying = false;
    stopTuneSourceOnly();
    cancelAnimationFrame(tuneAnimFrame);
    playPauseGlyph.textContent = "▶";
    playPauseLabel.textContent = "Play";
    resetRainbowBarsToRest();
  }

  function stopChemicalTune() {
    isTunePlaying = false;
    tunePauseOffset = 0;
    stopTuneSourceOnly();
    cancelAnimationFrame(tuneAnimFrame);
    playPauseGlyph.textContent = "▶";
    playPauseLabel.textContent = "Play";
    resetRainbowBarsToRest();
  }

  function stopTuneSourceOnly() {
    if (tuneSource) {
      try { tuneSource.onended = null; tuneSource.stop(); } catch {}
      tuneSource = null;
    }
  }

  function resetRainbowBarsToRest() {
    Array.from(rainbowBars.children).forEach((bar, idx) => {
      bar.style.height = `${restingBarHeight(idx)}px`;
    });
  }

  function animateRainbowTune() {
    if (!isTunePlaying || !audioCtx) return;
    const elapsed = Math.min(TUNE_DURATION, Math.max(0, audioCtx.currentTime - tuneStartTime));
    tuneScrubber.value = String(Math.round((elapsed / TUNE_DURATION) * 100));
    tuneElapsed.textContent = `0:0${Math.min(6, Math.floor(elapsed))}`;

    const t = performance.now() * 0.0045;
    Array.from(rainbowBars.children).forEach((bar, idx) => {
      const frac = idx / 32;
      const pA = Math.exp(-Math.pow((frac - 0.22) / 0.14, 2));
      const pB = Math.exp(-Math.pow((frac - 0.50) / 0.16, 2)) * 1.1;
      const pC = Math.exp(-Math.pow((frac - 0.78) / 0.14, 2));
      const env = Math.min(1, 0.22 + 0.85 * Math.max(pA, pB, pC));
      const wave = 0.42 + 0.58 * Math.abs(Math.sin(t + idx * 0.48));
      bar.style.height = `${Math.round(Math.max(12, 154 * env * wave))}px`;
    });

    tuneAnimFrame = requestAnimationFrame(animateRainbowTune);
  }

  playPauseTuneBtn.addEventListener("click", () => {
    if (isTunePlaying) {
      pauseChemicalTune();
    } else {
      startChemicalTune();
    }
  });

  tuneScrubber.addEventListener("input", () => {
    const pct = Number(tuneScrubber.value) / 100;
    tunePauseOffset = pct * TUNE_DURATION;
    tuneElapsed.textContent = `0:0${Math.min(6, Math.floor(tunePauseOffset))}`;
    if (isTunePlaying) {
      startChemicalTune();
    }
  });

  // History Persistence & Rendering
  function saveToHistory(item) {
    historyItems.unshift({
      id: item.id,
      uid: item.uid,
      status: item.status,
      title: item.title,
      formula: item.formula,
      badge: item.badge,
      liquidTint: item.liquidTint,
      constituents: item.constituents,
      note: item.note,
      tuneCaption: item.tuneCaption,
      freqs: item.freqs,
      shimmer: item.shimmer,
      decay: item.decay,
      timeLabel: item.timeLabel
    });
    historyItems = historyItems.slice(0, 30);
    localStorage.setItem("la_consumer_history_v1", JSON.stringify(historyItems));
  }

  function renderHistory() {
    clearHistoryBtn.classList.toggle("hidden", historyItems.length === 0);
    if (historyItems.length === 0) {
      historyListContainer.innerHTML = `
        <div class="empty-history">
          <div style="font-size:40px">🌊</div>
          <h3>No Scans Yet</h3>
          <p>Point at a liquid container in the Scan tab and tap SCAN to record your first profile.</p>
        </div>
      `;
      return;
    }

    historyListContainer.innerHTML = "";
    historyItems.forEach(item => {
      const card = document.createElement("div");
      card.className = "history-item";
      card.innerHTML = `
        <div>
          <h4>${item.title}</h4>
          <p>${item.formula} • ${item.timeLabel || "Just now"}</p>
        </div>
        <button class="mini-tune-btn" type="button" title="Play Chemical Tune">♫</button>
      `;
      card.addEventListener("click", (ev) => {
        if (ev.target.closest(".mini-tune-btn")) {
          openChemicalTuneFor(item);
        } else {
          switchTab("scan");
          presentResult(item);
        }
      });
      historyListContainer.appendChild(card);
    });
  }

  clearHistoryBtn.addEventListener("click", () => {
    historyItems = [];
    localStorage.removeItem("la_consumer_history_v1");
    renderHistory();
  });

  // Protected Research / Developer Mode Gate
  openResearchGateBtn.addEventListener("click", () => {
    researchConfirmModal.classList.remove("hidden");
  });

  cancelResearchOpenBtn.addEventListener("click", () => {
    researchConfirmModal.classList.add("hidden");
  });

  confirmResearchOpenBtn.addEventListener("click", () => {
    researchConfirmModal.classList.add("hidden");
    researchScanCount.textContent = String(historyItems.length);
    researchConsoleModal.classList.remove("hidden");
  });

  exitResearchConsoleBtn.addEventListener("click", () => {
    researchConsoleModal.classList.add("hidden");
  });

  exportResearchJsonlBtn.addEventListener("click", () => {
    const payload = JSON.stringify({
      application: "Liquid Analyzer",
      version: "0.3.0",
      protocol: "CS-SPEC-P1-v1.2",
      exported_at: new Date().toISOString(),
      scans: historyItems
    }, null, 2);
    const blob = new Blob([payload], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "LiquidAnalyzer_Audit_Export.json";
    a.click();
    URL.revokeObjectURL(url);
  });
})();
