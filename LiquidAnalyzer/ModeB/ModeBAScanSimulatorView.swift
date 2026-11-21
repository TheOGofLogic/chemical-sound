import SwiftUI

/// Interactive Phase R3 `MODE_B` Ultrasonic Pulse-Echo A-Scan Lab & Virtual Simulator.
/// Visualizes raw 40 MHz RF waveforms, analytic Hilbert envelopes, monitor trigger gates,
/// boundary phase polarity (+R rigid wall vs. -R 180-deg air bubble), and wall-thickness-invariant
/// double-echo velocity (`c = 2D / (t2 - t1)`) piped directly into `MultiModalFusionClassifier`.
public struct ModeBAScanSimulatorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedLiquid: LiquidAnalyzerContactCore.SimulatedLiquid = .water
    @State private var containerDiameterMm: Double = 65.0
    @State private var wallThicknessMm: Double = 3.5
    @State private var temperatureC: Double = 20.0
    @State private var snrDb: Double = 32.0
    @State private var injectAirBubble: Bool = false
    @State private var showRawRF: Bool = true
    @State private var showEnvelope: Bool = true

    @State private var measurement: UltrasonicMeasurement?
    @State private var fusionDecision: MultiModalFusionDecision?

    private let fusionClassifier = MultiModalFusionClassifier()

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    scopeHeaderBanner
                    oscilloscopeCard
                    measurementReadoutCard
                    fusionResultCard
                    controlsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(red: 0.94, green: 0.96, blue: 0.99))
            .navigationTitle("MODE_B A-Scan Lab")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { runSimulation() }
            .onChange(of: selectedLiquid) { _, newValue in
                injectAirBubble = newValue.defaultHasBubbles
                runSimulation()
            }
            .onChange(of: containerDiameterMm) { _, _ in runSimulation() }
            .onChange(of: wallThicknessMm) { _, _ in runSimulation() }
            .onChange(of: temperatureC) { _, _ in runSimulation() }
            .onChange(of: snrDb) { _, _ in runSimulation() }
            .onChange(of: injectAirBubble) { _, _ in runSimulation() }
        }
    }

    // MARK: - 1. Banner

    private var scopeHeaderBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.headline)
                    .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                Text("Virtual Contact Ultrasonic Test Bench (40 MSPS)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.14, blue: 0.24))
            }
            Text("Simulates direct wall-coupled 5 MHz pulse-echo waves (`c = 2D / (t₂ − t₁)`). Vary glass thickness below to confirm wall-thickness invariance and toggle air bubbles to observe 180° phase inversion.")
                .font(.caption)
                .foregroundStyle(Color(red: 0.32, green: 0.38, blue: 0.48))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
        )
    }

    // MARK: - 2. Oscilloscope Canvas

    private var oscilloscopeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("A-Scan Display (RF + Hilbert Envelope)", systemImage: "waveform")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                HStack(spacing: 8) {
                    Toggle("RF", isOn: $showRawRF)
                        .toggleStyle(.button)
                        .font(.caption2.weight(.bold))
                        .tint(.cyan)
                    Toggle("Env", isOn: $showEnvelope)
                        .toggleStyle(.button)
                        .font(.caption2.weight(.bold))
                        .tint(.orange)
                }
            }

            if let meas = measurement {
                AScanCanvasView(
                    measurement: meas,
                    showRawRF: showRawRF,
                    showEnvelope: showEnvelope
                )
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 12) {
                    legendChip(color: .cyan, text: "RF Trace")
                    legendChip(color: .orange, text: "Hilbert |z[n]|")
                    legendChip(color: .green, text: "t₁ / t₂ (+R Wall)")
                    if meas.hasInvertedBubbleEcho {
                        legendChip(color: .pink, text: "Bubble (-R 180°)")
                    }
                }
                .font(.caption2.weight(.semibold))
            } else {
                Text("No double-echo pair detected within current Monitor Gate.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.05, green: 0.09, blue: 0.16))
        )
    }

    private func legendChip(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: - 3. Quantitative Readouts

    private var measurementReadoutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Double-Echo Telemetry", systemImage: "ruler.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                Spacer()
                if let meas = measurement {
                    Text(meas.hasInvertedBubbleEcho ? "-R Bubble Detected" : "+R Rigid Wall")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(meas.hasInvertedBubbleEcho ? .pink : LiquidAnalyzerPalette.resultGreenStart)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill((meas.hasInvertedBubbleEcho ? Color.pink : LiquidAnalyzerPalette.resultGreenStart).opacity(0.14))
                        )
                }
            }

            if let meas = measurement {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    metricTile(
                        label: "Sound Speed (Raw)",
                        value: String(format: "%.1f m/s", meas.soundVelocityMps),
                        accent: LiquidAnalyzerPalette.scanBlue
                    )
                    metricTile(
                        label: "Normalized c (20 °C)",
                        value: String(format: "%.1f m/s", meas.normalizedVelocity20CMps),
                        accent: LiquidAnalyzerPalette.resultGreenStart
                    )
                    metricTile(
                        label: "Gap Δt = t₂ − t₁",
                        value: String(format: "%.2f µs", meas.transitGapMicroseconds),
                        accent: LiquidAnalyzerPalette.compositionOrange
                    )
                    metricTile(
                        label: "Attenuation (A₂/A₁)",
                        value: String(format: "%.2f (%.2f dB/cm)", meas.echoAttenuationRatio, meas.attenuationDBPerCm),
                        accent: LiquidAnalyzerPalette.tunePurple
                    )
                }

                HStack {
                    Text(String(format: "t₁ = %.2f µs (%@)", meas.firstEcho.timeMicroseconds, meas.firstEcho.isPhaseInverted ? "-R" : "+R"))
                    Spacer()
                    Text(String(format: "t₂ = %.2f µs (%@)", meas.secondEcho.timeMicroseconds, meas.secondEcho.isPhaseInverted ? "-R" : "+R"))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
        )
    }

    private func metricTile(label: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.heavy).monospacedDigit())
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.08))
        )
    }

    // MARK: - 4. Fusion Classifier Output

    private var fusionResultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("MultiModalFusionClassifier Output", systemImage: "atom")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(LiquidAnalyzerPalette.compositionOrange)
                Spacer()
                if let dec = fusionDecision {
                    Text("\(dec.confidencePercent)% Match")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(LiquidAnalyzerPalette.resultGreenStart)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(LiquidAnalyzerPalette.resultGreenStart.opacity(0.14))
                        )
                }
            }

            Divider()

            if let dec = fusionDecision {
                HStack(alignment: .firstTextBaseline) {
                    Text(dec.profile.displayName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color(red: 0.08, green: 0.14, blue: 0.24))
                    Spacer()
                    Text(dec.profile.formulaDisplay)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                }

                Text(dec.profile.typicalPHRange)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.24, green: 0.30, blue: 0.42))

                Text(dec.attribution.acousticEvidenceSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(dec.attribution.visionEvidenceSummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(dec.screeningState == .bubbleScatterDetected ? .pink : LiquidAnalyzerPalette.resultGreenStart)
            } else {
                Text("Chemical Profile Unavailable — Velocity or attenuation fell outside validated MODE_B boundaries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LiquidAnalyzerPalette.compositionWarmBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(LiquidAnalyzerPalette.compositionOrange.opacity(0.28), lineWidth: 1)
                )
        )
    }

    // MARK: - 5. Interactive Controls

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Simulation Parameters")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color(red: 0.08, green: 0.14, blue: 0.24))

            VStack(alignment: .leading, spacing: 6) {
                Text("Simulated Liquid")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Liquid", selection: $selectedLiquid) {
                    ForEach(LiquidAnalyzerContactCore.SimulatedLiquid.allCases) { liq in
                        Text(liq.rawValue).tag(liq)
                    }
                }
                .pickerStyle(.menu)
            }

            sliderRow(
                title: "Cup Inner Diameter (D)",
                valueText: String(format: "%.0f mm", containerDiameterMm),
                value: $containerDiameterMm,
                range: 50...90,
                step: 1
            )

            sliderRow(
                title: "Glass Wall Thickness (Invariant Check)",
                valueText: String(format: "%.1f mm", wallThicknessMm),
                value: $wallThicknessMm,
                range: 2.0...6.5,
                step: 0.5
            )

            sliderRow(
                title: "Liquid Temperature",
                valueText: String(format: "%.1f °C", temperatureC),
                value: $temperatureC,
                range: 10...35,
                step: 0.5
            )

            sliderRow(
                title: "Signal-to-Noise Ratio (SNR)",
                valueText: String(format: "%.0f dB", snrDb),
                value: $snrDb,
                range: 18...42,
                step: 1
            )

            Toggle(isOn: $injectAirBubble) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inject Mid-Column Air Bubble (-R 180°)")
                        .font(.caption.weight(.semibold))
                    Text("Simulates a free-boundary gas bubble inside the liquid path")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                runSimulation()
            } label: {
                Label("Fire New Pulse-Echo Burst", systemImage: "bolt.horizontal.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LiquidAnalyzerPalette.scanBlue)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
        )
    }

    private func sliderRow(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(valueText).font(.caption.weight(.bold).monospacedDigit())
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func runSimulation() {
        let diameterM = containerDiameterMm / 1_000.0
        let wallM = wallThicknessMm / 1_000.0
        // Dynamically size gate end so even Ethanol (1,160 m/s) on 90 mm glass captures Echo 2 cleanly
        let maxTwoTripsUs = ((4.0 * diameterM) / 1_050.0) * 1e6 + 30.0
        let core = LiquidAnalyzerContactCore(
            sampleRateHz: 40_000_000.0,
            carrierFrequencyHz: 5_000_000.0,
            containerDiameterMeters: diameterM,
            gateStartUs: 18.0,
            gateEndUs: max(240.0, ceil(maxTwoTripsUs)),
            detectionThreshold: 0.14
        )
        let trace = core.generateSimulatedTrace(
            liquid: selectedLiquid,
            wallThicknessMeters: wallM,
            temperatureCelsius: temperatureC,
            snrDb: Float(snrDb),
            includeAirBubble: injectAirBubble
        )
        let meas = core.processAScan(rfSignal: trace, temperatureCelsius: temperatureC)
        measurement = meas
        fusionDecision = meas.flatMap { fusionClassifier.evaluateModeBContactMeasurement($0) }
    }
}

/// High-speed decimated SwiftUI `Canvas` renderer for 40 MHz RF A-Scans, Hilbert envelopes, trigger gates, & echo markers.
private struct AScanCanvasView: View {
    let measurement: UltrasonicMeasurement
    let showRawRF: Bool
    let showEnvelope: Bool

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let midY = h * 0.56
            let ampScale = h * 0.38
            let count = measurement.rawSignal.count
            guard count > 4, w > 10 else { return }

            let totalUs = (Double(count) / measurement.sampleRateHz) * 1e6
            func xForUs(_ us: Double) -> CGFloat {
                CGFloat(max(0.0, min(1.0, us / max(1.0, totalUs)))) * w
            }

            // 1. Background grid
            var gridPath = Path()
            for frac in [0.2, 0.4, 0.6, 0.8] {
                let x = w * frac
                gridPath.move(to: CGPoint(x: x, y: 0))
                gridPath.addLine(to: CGPoint(x: x, y: h))
            }
            gridPath.move(to: CGPoint(x: 0, y: midY))
            gridPath.addLine(to: CGPoint(x: w, y: midY))
            context.stroke(gridPath, with: .color(.white.opacity(0.10)), lineWidth: 0.8)

            // 2. Shaded Monitor Trigger Gate [gateStartUs .. gateEndUs]
            let gateX1 = xForUs(measurement.gateStartUs)
            let gateX2 = xForUs(measurement.gateEndUs)
            let gateRect = CGRect(x: gateX1, y: 0, width: max(2, gateX2 - gateX1), height: h)
            context.fill(Path(gateRect), with: .color(.green.opacity(0.08)))
            var gateBorders = Path()
            gateBorders.move(to: CGPoint(x: gateX1, y: 0))
            gateBorders.addLine(to: CGPoint(x: gateX1, y: h))
            gateBorders.move(to: CGPoint(x: gateX2, y: 0))
            gateBorders.addLine(to: CGPoint(x: gateX2, y: h))
            context.stroke(
                gateBorders,
                with: .color(.green.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.0, dash: [4, 4])
            )

            // 3. Decimated Raw RF Waveform (peak-preserving min/max buckets per pixel column)
            let buckets = max(120, min(600, Int(w * 1.5)))
            let strideLen = max(1, count / buckets)

            if showRawRF {
                var rfPath = Path()
                for b in 0..<buckets {
                    let s0 = b * strideLen
                    let s1 = min(count, s0 + strideLen)
                    guard s1 > s0 else { continue }
                    var minV: Float = measurement.rawSignal[s0]
                    var maxV: Float = minV
                    for i in s0..<s1 {
                        let v = measurement.rawSignal[i]
                        if v < minV { minV = v }
                        if v > maxV { maxV = v }
                    }
                    let x = (CGFloat(b) / CGFloat(max(1, buckets - 1))) * w
                    let yHi = midY - CGFloat(maxV) * ampScale
                    let yLo = midY - CGFloat(minV) * ampScale
                    rfPath.move(to: CGPoint(x: x, y: yHi))
                    rfPath.addLine(to: CGPoint(x: x, y: yLo))
                }
                context.stroke(rfPath, with: .color(.cyan.opacity(0.75)), lineWidth: 1.0)
            }

            // 4. Positive-Definite Analytic Hilbert Envelope |z[n]|
            if showEnvelope {
                var envPath = Path()
                for b in 0..<buckets {
                    let s0 = b * strideLen
                    let s1 = min(measurement.envelopeSignal.count, s0 + strideLen)
                    guard s1 > s0 else { continue }
                    var peakEnv: Float = 0.0
                    for i in s0..<s1 {
                        let v = measurement.envelopeSignal[i]
                        if v > peakEnv { peakEnv = v }
                    }
                    let x = (CGFloat(b) / CGFloat(max(1, buckets - 1))) * w
                    let y = midY - CGFloat(peakEnv) * ampScale
                    if b == 0 {
                        envPath.move(to: CGPoint(x: x, y: y))
                    } else {
                        envPath.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(envPath, with: .color(.orange), lineWidth: 1.8)
            }

            // 5. Echo Markers (Intermediate Bubble, Back Wall t1, Double Reflection t2)
            func drawMarker(echo: AcousticEcho, label: String, color: Color) {
                let x = xForUs(echo.timeMicroseconds)
                let y = midY - CGFloat(echo.amplitude) * ampScale
                var line = Path()
                line.move(to: CGPoint(x: x, y: 18))
                line.addLine(to: CGPoint(x: x, y: h - 14))
                context.stroke(line, with: .color(color.opacity(0.75)), lineWidth: 1.3)

                let dotRect = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dotRect), with: .color(color))

                context.draw(
                    Text(label)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(color),
                    at: CGPoint(x: min(w - 24, max(24, x)), y: 10)
                )
            }

            for bubble in measurement.intermediateEchoes {
                drawMarker(
                    echo: bubble,
                    label: bubble.isPhaseInverted ? "BUBBLE(-R)" : "SCAT(+R)",
                    color: bubble.isPhaseInverted ? .pink : .yellow
                )
            }
            drawMarker(echo: measurement.firstEcho, label: "t₁", color: .green)
            drawMarker(echo: measurement.secondEcho, label: "t₂", color: .green)
        }
        .background(Color(red: 0.03, green: 0.06, blue: 0.11))
    }
}
