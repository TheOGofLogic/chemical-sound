import SwiftUI

/// Guided 3-step comparative protocol stages for clear-liquid discrimination (Water vs. Vinegar vs. Saline vs. Seltzer).
public enum GuidedComparatorStep: Int, CaseIterable, Identifiable, Sendable {
    case emptyCup = 1
    case waterBlank = 2
    case testSample = 3

    public var id: Int { rawValue }

    public var stepTitle: String {
        switch self {
        case .emptyCup:
            return "Step 1 • Scan Empty Cup"
        case .waterBlank:
            return "Step 2 • Scan Water Blank"
        case .testSample:
            return "Step 3 • Scan Test Liquid"
        }
    }

    public var instructionText: String {
        switch self {
        case .emptyCup:
            return "Place the dry empty glass at your fixed aiming position so Liquid Analyzer locks its dry shell resonances (EMPTY_CONTAINER)."
        case .waterBlank:
            return "Pour clean tap or distilled water to a repeatable fill mark and scan to lock the aqueous mass-loading & meniscus baseline (WATER_REFERENCE)."
        case .testSample:
            return "Empty, dry, and pour your test liquid to the same fill line. Liquid Analyzer fuses ΔF/F_water, meniscus geometry, colorimetry, and bubble scatter."
        }
    }

    public var buttonLabel: String {
        switch self {
        case .emptyCup:
            return "Scan & Lock Empty Cup"
        case .waterBlank:
            return "Scan & Lock Water Blank"
        case .testSample:
            return "Scan & Identify Test Liquid"
        }
    }
}

/// Displays transparent Acoustic + Vision + Comparative sensor provenance on v0.5.0 Result cards.
public struct MultiModalAttributionCardView: View {
    public let attribution: MultiModalAttribution
    public let onOpenComparator: () -> Void

    public init(attribution: MultiModalAttribution, onOpenComparator: @escaping () -> Void) {
        self.attribution = attribution
        self.onOpenComparator = onOpenComparator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Multi-Modal Sensor Fusion", systemImage: "cpu.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                Spacer()
                Text(attribution.recommendsGuidedComparator ? "Calibration Needed" : "v0.5.0 Fusion")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(
                        attribution.recommendsGuidedComparator
                            ? LiquidAnalyzerPalette.compositionOrange
                            : LiquidAnalyzerPalette.resultGreenStart
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                (attribution.recommendsGuidedComparator
                                    ? LiquidAnalyzerPalette.compositionOrange
                                    : LiquidAnalyzerPalette.resultGreenStart
                                ).opacity(0.14)
                            )
                    )
            }

            Divider()

            channelRow(
                icon: "waveform.path.ecg",
                color: LiquidAnalyzerPalette.scanBlue,
                label: "Acoustic Channel",
                detail: attribution.acousticEvidenceSummary
            )

            channelRow(
                icon: "camera.aperture",
                color: LiquidAnalyzerPalette.tunePurple,
                label: "Optical Vision Channel",
                detail: attribution.visionEvidenceSummary
            )

            if let comp = attribution.comparatorEvidenceSummary, !comp.isEmpty {
                channelRow(
                    icon: "ruler.fill",
                    color: LiquidAnalyzerPalette.resultGreenStart,
                    label: "Cup Comparator",
                    detail: comp
                )
            }

            if attribution.recommendsGuidedComparator {
                Button(action: onOpenComparator) {
                    HStack(spacing: 8) {
                        Image(systemName: "checklist.checked")
                            .font(.subheadline.weight(.bold))
                        Text("Open 3-Step Cup Comparator")
                            .font(.subheadline.weight(.bold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        LiquidAnalyzerPalette.scanBlue,
                                        LiquidAnalyzerPalette.resultGreenStart
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.95, green: 0.98, blue: 1.00))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(LiquidAnalyzerPalette.scanBlue.opacity(0.24), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    private func channelRow(icon: String, color: Color, label: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(red: 0.14, green: 0.18, blue: 0.28))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.34, green: 0.40, blue: 0.50))
            }
        }
    }
}

/// Guided 3-Step Cup Comparator Sheet (Step 1: Empty Cup -> Step 2: Water Blank -> Step 3: Test Sample).
public struct LiquidComparatorWizardView: View {
    @ObservedObject var coordinator: ConsumerScanCoordinator
    @Environment(\.dismiss) private var dismiss

    public init(coordinator: ConsumerScanCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("3-Step Cup Comparator")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color(red: 0.06, green: 0.12, blue: 0.24))

                        Text("Separates clear colorless liquids (Water vs. Vinegar vs. Saline vs. Seltzer) by locking your container's Empty & Water reference modes.")
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0.30, green: 0.36, blue: 0.46))
                    }

                    // Precision Mode Selector (Quick 6x vs. Lab 20x, both K_cond = 2 purged)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Burst Precision (K_cond = 2 Purged)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(red: 0.22, green: 0.28, blue: 0.38))

                        Picker("Burst Count", selection: $coordinator.comparatorBurstCount) {
                            Text("Quick 6× (~10s)").tag(6)
                            Text("Lab 20× (~36s)").tag(20)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(red: 0.96, green: 0.97, blue: 0.99))
                    )

                    ForEach(GuidedComparatorStep.allCases) { step in
                        stepCard(for: step)
                    }

                    if coordinator.hasEmptyBaselineForSelectedGeometry || coordinator.hasWaterBaselineForSelectedGeometry {
                        Button(role: .destructive) {
                            coordinator.clearCalibratedStandards()
                            coordinator.comparatorActiveStep = .emptyCup
                        } label: {
                            Label("Reset Saved Cup Baselines", systemImage: "arrow.counterclockwise")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Guided Comparator")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func isStepCompleted(_ step: GuidedComparatorStep) -> Bool {
        switch step {
        case .emptyCup:
            return coordinator.hasEmptyBaselineForSelectedGeometry
        case .waterBlank:
            return coordinator.hasWaterBaselineForSelectedGeometry
        case .testSample:
            return false
        }
    }

    private func stepCard(for step: GuidedComparatorStep) -> some View {
        let completed = isStepCompleted(step)
        let isActive = coordinator.comparatorActiveStep == step

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: completed ? "checkmark.circle.fill" : "\(step.rawValue).circle.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(
                        completed
                            ? LiquidAnalyzerPalette.resultGreenStart
                            : (isActive ? LiquidAnalyzerPalette.scanBlue : Color.gray)
                    )

                Text(step.stepTitle)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.24))

                Spacer()

                if completed {
                    Text("LOCKED")
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

            Text(step.instructionText)
                .font(.caption)
                .foregroundStyle(Color(red: 0.32, green: 0.38, blue: 0.48))

            Button(action: {
                dismiss()
                coordinator.executeGuidedComparatorStep(step)
            }) {
                HStack {
                    Image(systemName: step == .testSample ? "waveform.badge.magnifyingglass" : "target")
                        .font(.subheadline.weight(.bold))
                    Text(completed ? "Re-Scan \(step.stepTitle)" : step.buttonLabel)
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                }
                .foregroundStyle(isActive || !completed ? .white : LiquidAnalyzerPalette.scanBlue)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            (isActive || !completed)
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [
                                            LiquidAnalyzerPalette.scanBlue,
                                            step == .testSample ? LiquidAnalyzerPalette.resultGreenStart : LiquidAnalyzerPalette.scanCyan
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                : AnyShapeStyle(LiquidAnalyzerPalette.scanBlue.opacity(0.10))
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isActive
                                ? LiquidAnalyzerPalette.scanBlue.opacity(0.55)
                                : Color.black.opacity(0.08),
                            lineWidth: isActive ? 1.6 : 1.0
                        )
                )
                .shadow(color: Color.black.opacity(0.04), radius: 6, y: 3)
        )
    }
}
