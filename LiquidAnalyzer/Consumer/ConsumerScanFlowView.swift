import SwiftUI

/// Primary consumer Scan tab implementing HOME -> AIM -> SCAN -> RESULT -> LISTEN.
public struct ConsumerScanFlowView: View {
    @ObservedObject var coordinator: ConsumerScanCoordinator
    @ObservedObject private var cameraService: CameraTargetingService
    @State private var activeTuneItem: ConsumerScanItem?
    @State private var activeCompositionItem: ConsumerScanItem?
    private enum ActiveScanSheet: Identifiable {
        case calibration(ConsumerScanItem)
        case comparator

        var id: String {
            switch self {
            case .calibration(let item): return "calibration-\(item.id.uuidString)"
            case .comparator: return "comparator"
            }
        }
    }

    @State private var activeSheet: ActiveScanSheet?
    @State private var copiedSingleScanID: UUID?

    public init(coordinator: ConsumerScanCoordinator) {
        self.coordinator = coordinator
        self.cameraService = coordinator.cameraService
    }

    public var body: some View {
        ZStack {
            if let tuneItem = activeTuneItem {
                ChemicalTuneView(
                    item: tuneItem,
                    tunePlayer: coordinator.tunePlayer,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            activeTuneItem = nil
                        }
                    }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let compItem = activeCompositionItem {
                chemicalCompositionScreen(for: compItem)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                switch coordinator.flowStep {
                case .home:
                    homeDashboardScreen
                        .transition(.opacity)
                case .aim:
                    aimScreen
                        .transition(.opacity)
                case .scanning:
                    scanningScreen
                        .transition(.opacity)
                case .result(let item):
                    resultScreen(for: item)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.flowStep)
        .alert(
            "Scan Notice",
            isPresented: Binding(
                get: { coordinator.consumerAlertMessage != nil },
                set: { if !$0 { coordinator.consumerAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                coordinator.consumerAlertMessage = nil
            }
        } message: {
            Text(coordinator.consumerAlertMessage ?? "")
        }
        .onAppear {
            if coordinator.isComparatorWizardPresented {
                activeSheet = .comparator
            }
        }
        .onChange(of: coordinator.isComparatorWizardPresented) { _, presented in
            if presented {
                activeSheet = .comparator
            } else if case .comparator = activeSheet {
                activeSheet = nil
            }
        }
        .sheet(item: $activeSheet, onDismiss: {
            if coordinator.isComparatorWizardPresented {
                coordinator.isComparatorWizardPresented = false
            }
        }) { sheet in
            switch sheet {
            case .calibration(let targetItem):
                CalibrateKnownStandardSheet(
                    item: targetItem,
                    onSelectTarget: { chosenID in
                        coordinator.teachCalibratedStandard(from: targetItem, targetID: chosenID)
                        activeSheet = nil
                    },
                    onCancel: {
                        activeSheet = nil
                    }
                )
            case .comparator:
                LiquidComparatorWizardView(coordinator: coordinator)
            }
        }
    }

    // MARK: - 0. HOME Dashboard (Matches Visual Reference Poster — Camera OFF Until Requested)

    private var homeDashboardScreen: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Hero Logo + Title + Subtitle
                VStack(spacing: 10) {
                    HStack(spacing: 14) {
                        WaterDropSoundLogoView(size: 60)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Liquid Analyzer")
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color(red: 0.05, green: 0.13, blue: 0.28))

                            Text("See the liquid. Hear the science.")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.22, green: 0.42, blue: 0.62))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)

                    Text("Phone-only optical + acoustic screening for colored, cloudy, and fizzy beverages, plus experimental cup comparison.")
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 0.20, green: 0.26, blue: 0.36))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)

                // 4 Colorful Step Badges (1 AIM • 2 SCAN • 3 SEE • 4 LISTEN)
                HStack(alignment: .top, spacing: 8) {
                    posterStepBadge(
                        number: "1",
                        color: LiquidAnalyzerPalette.scanBlue,
                        title: "AIM",
                        subtitle: "Point at liquid",
                        action: { coordinator.openCameraAiming(graceDelaySeconds: 0.9) }
                    )
                    posterStepBadge(
                        number: "2",
                        color: LiquidAnalyzerPalette.resultGreenStart,
                        title: "SCAN",
                        subtitle: "Sound waves",
                        action: { coordinator.openCameraAiming(graceDelaySeconds: 0.9) }
                    )
                    posterStepBadge(
                        number: "3",
                        color: LiquidAnalyzerPalette.compositionOrange,
                        title: "SEE",
                        subtitle: "Composition",
                        action: { openLatestResultOrHistory() }
                    )
                    posterStepBadge(
                        number: "4",
                        color: LiquidAnalyzerPalette.tunePurple,
                        title: "LISTEN",
                        subtitle: "Chemical tune",
                        action: { openLatestChemicalTune() }
                    )
                }
                .padding(.horizontal, 16)

                // Primary Hero CTA Button (Opens Camera Scanner)
                Button(action: {
                    coordinator.openCameraAiming(graceDelaySeconds: 0.9)
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 22, weight: .bold))
                        Text("Start Liquid Scan")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        Spacer()
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        LiquidAnalyzerPalette.scanBlue,
                                        LiquidAnalyzerPalette.scanCyan
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                    .shadow(color: LiquidAnalyzerPalette.scanBlue.opacity(0.38), radius: 14, y: 6)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)

                // Guided 3-Step Cup Comparator Card (Empty -> Water Blank -> Clear Liquid Identification)
                Button(action: {
                    coordinator.openGuidedComparatorWizard()
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "checklist.checked")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(LiquidAnalyzerPalette.resultGreenStart)
                            .frame(width: 38, height: 38)
                            .background(
                                Circle()
                                    .fill(LiquidAnalyzerPalette.resultGreenStart.opacity(0.14))
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("3-Step Cup Comparator")
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color(red: 0.06, green: 0.13, blue: 0.26))

                                if coordinator.hasEmptyBaselineForSelectedGeometry && coordinator.hasWaterBaselineForSelectedGeometry {
                                    Text("READY")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(LiquidAnalyzerPalette.resultGreenStart)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(LiquidAnalyzerPalette.resultGreenStart.opacity(0.14))
                                        )
                                }
                            }
                            Text("Experimental stationary same-cup comparator (Empty → Water → Sample) for clear liquids.")
                                .font(.caption)
                                .foregroundStyle(Color(red: 0.30, green: 0.36, blue: 0.46))
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(red: 0.40, green: 0.46, blue: 0.56))
                    }
                    .padding(15)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(LiquidAnalyzerPalette.resultGreenStart.opacity(0.28), lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.05), radius: 8, y: 3)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)

                // Dedicated Repeatability Gate R1 (20x) & Control A-G Card (Visible directly on Home!)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Repeatability Gate R1 (20×)", systemImage: "repeat.circle.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color(red: 0.06, green: 0.16, blue: 0.32))
                        Spacer()
                        Text(coordinator.autoScanWhenSteady ? "Auto-Scan ON" : "Auto-Scan OFF")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(coordinator.autoScanWhenSteady ? LiquidAnalyzerPalette.compositionOrange : LiquidAnalyzerPalette.resultGreenStart)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill((coordinator.autoScanWhenSteady ? LiquidAnalyzerPalette.compositionOrange : LiquidAnalyzerPalette.resultGreenStart).opacity(0.14))
                            )
                    }

                    HStack(spacing: 8) {
                        Menu {
                            ForEach(ControlSeriesTag.allCases, id: \.rawValue) { tag in
                                Button {
                                    coordinator.selectedControlSeriesTag = tag
                                } label: {
                                    if coordinator.selectedControlSeriesTag == tag {
                                        Label(tag.displayLabel, systemImage: "checkmark")
                                    } else {
                                        Text(tag.displayLabel)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "tag.fill")
                                Text(coordinator.selectedControlSeriesTag.displayLabel)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                Image(systemName: "chevron.up.chevron.down")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(LiquidAnalyzerPalette.scanBlue.opacity(0.10))
                            )
                        }

                        Menu {
                            ForEach(GeometryTestCondition.allCases, id: \.rawValue) { cond in
                                Button {
                                    coordinator.selectedGeometryCondition = cond
                                } label: {
                                    if coordinator.selectedGeometryCondition == cond {
                                        Label(cond.displayLabel, systemImage: "checkmark")
                                    } else {
                                        Text(cond.displayLabel)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "ruler")
                                Text(coordinator.selectedGeometryCondition.displayLabel)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                Image(systemName: "chevron.up.chevron.down")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(LiquidAnalyzerPalette.scanBlue.opacity(0.10))
                            )
                        }
                    }

                    Toggle("Auto-Scan When Held Steady", isOn: $coordinator.autoScanWhenSteady)
                        .font(.caption.weight(.semibold))

                    Button(action: {
                        coordinator.startRepeatabilityGateR1Batch(count: 20)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "repeat.circle.fill")
                                .font(.system(size: 18, weight: .bold))
                            Text("RUN R1 (20×) BATCH")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [LiquidAnalyzerPalette.resultGreenStart, LiquidAnalyzerPalette.scanBlue],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.06), radius: 10, y: 4)
                )
                .padding(.horizontal, 18)

                // 2x2 Pastel Feature Grid (Matches Bottom of Poster)
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    posterFeatureTile(
                        icon: "camera.fill",
                        iconColor: LiquidAnalyzerPalette.scanBlue,
                        bgColor: Color(red: 0.90, green: 0.95, blue: 1.00),
                        title: "Camera + Sound",
                        subtitle: "Uses iPhone camera & audio system",
                        action: { coordinator.openCameraAiming(graceDelaySeconds: 0.9) }
                    )
                    posterFeatureTile(
                        icon: "flask.fill",
                        iconColor: LiquidAnalyzerPalette.resultGreenStart,
                        bgColor: Color(red: 0.90, green: 0.98, blue: 0.93),
                        title: "Identify Liquids",
                        subtitle: "Milk, oil, coffee, cola, juice & fizzy drinks",
                        action: { coordinator.openCameraAiming(graceDelaySeconds: 0.9) }
                    )
                    posterFeatureTile(
                        icon: "chart.bar.fill",
                        iconColor: LiquidAnalyzerPalette.compositionOrange,
                        bgColor: Color(red: 1.00, green: 0.95, blue: 0.89),
                        title: "See Composition",
                        subtitle: "Formula, pH range & chemical constituents",
                        action: { openLatestResultOrHistory() }
                    )
                    posterFeatureTile(
                        icon: "music.note",
                        iconColor: LiquidAnalyzerPalette.tunePurple,
                        bgColor: Color(red: 0.95, green: 0.91, blue: 1.00),
                        title: "Hear the Signature",
                        subtitle: "Play the rainbow Chemical Tune",
                        action: { openLatestChemicalTune() }
                    )
                }
                .padding(.horizontal, 18)

                // Quick Resume Card if user has a recent scan
                if let latest = coordinator.history.first {
                    Button(action: {
                        coordinator.openHistoryItem(latest)
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(LiquidAnalyzerPalette.resultGreenStart)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Last Scan: \(latest.title)")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.22))
                                Text("\(latest.formulaDisplay) • Tap to view or play tune")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white)
                                .shadow(color: Color.black.opacity(0.05), radius: 8, y: 3)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                }

                // Bottom Poster Banner
                VStack(spacing: 4) {
                    Text("REAL SCIENCE. A SIMPLER WAY.")
                        .font(.caption.weight(.heavy))
                        .tracking(0.8)
                        .foregroundStyle(Color(red: 0.10, green: 0.20, blue: 0.36))
                    Text("For Research and Education")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                .padding(.bottom, 84)
            }
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.98, blue: 1.00),
                    Color.white,
                    Color(red: 0.91, green: 0.96, blue: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private func posterStepBadge(
        number: String,
        color: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(number)
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(color))

                Text(title)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Color(red: 0.08, green: 0.14, blue: 0.25))

                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func posterFeatureTile(
        icon: String,
        iconColor: Color,
        bgColor: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(iconColor)
                    .frame(height: 28)

                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(iconColor)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.25, green: 0.30, blue: 0.38))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(bgColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openLatestResultOrHistory() {
        if let latest = coordinator.history.first {
            coordinator.stopVoiceAnnouncement()
            withAnimation(.easeInOut(duration: 0.24)) {
                activeCompositionItem = latest
            }
        } else {
            coordinator.openCameraAiming(graceDelaySeconds: 0.9)
        }
    }

    private func openLatestChemicalTune() {
        if let latest = coordinator.history.first {
            coordinator.stopVoiceAnnouncement()
            coordinator.tunePlayer.stop()
            withAnimation(.easeInOut(duration: 0.24)) {
                activeTuneItem = latest
            }
            coordinator.tunePlayer.togglePlayPause(for: latest)
        } else {
            coordinator.openCameraAiming(graceDelaySeconds: 0.9)
        }
    }

    // MARK: - 1. AIM Screen (`< Liquid Analyzer ⚙` — Auto-Locks on Steady Target OR Tap SCAN)

    private var aimScreen: some View {
        VStack(spacing: 0) {
            topBrandHeader(showBackButton: true, showSettingsGear: true) {
                coordinator.returnToHome()
            }

            ZStack {
                cameraService.previewLayerView
                    .ignoresSafeArea(edges: .horizontal)

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.28),
                        Color.clear,
                        Color.clear,
                        Color.black.opacity(0.56)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 8) {
                    if let armedStep = coordinator.armedComparatorStep {
                        HStack(spacing: 8) {
                            Image(systemName: "checklist.checked")
                                .font(.caption.weight(.bold))
                            Text("3-Step Comparator • \(armedStep.stepTitle)")
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                            Spacer()
                            Button(action: {
                                coordinator.cancelArmedComparatorStep()
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.88))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(LiquidAnalyzerPalette.resultGreenStart.opacity(0.92))
                        )
                        .padding(.top, 8)
                    }

                    HStack(spacing: 8) {
                        Button(action: {
                            coordinator.autoScanWhenSteady.toggle()
                        }) {
                            Label(
                                coordinator.autoScanWhenSteady ? "Auto-Scan: ON" : "Auto-Scan: OFF",
                                systemImage: coordinator.autoScanWhenSteady ? "bolt.circle.fill" : "hand.raised.fill"
                            )
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        coordinator.autoScanWhenSteady
                                            ? LiquidAnalyzerPalette.compositionOrange.opacity(0.90)
                                            : Color.black.opacity(0.65)
                                    )
                            )
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button(action: {
                            cameraService.toggleOpticsLock()
                        }) {
                            Label(
                                cameraService.isOpticsLocked ? "AE/AF/WB Locked" : "Lock AE/AF/WB",
                                systemImage: cameraService.isOpticsLocked ? "lock.fill" : "lock.open"
                            )
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        cameraService.isOpticsLocked
                                            ? LiquidAnalyzerPalette.resultGreenStart.opacity(0.90)
                                            : Color.black.opacity(0.65)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)

                    // Controlled Geometry & Blind Audit Series Tag (never passed to classifier)
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(GeometryTestCondition.allCases, id: \.rawValue) { cond in
                                Button {
                                    coordinator.selectedGeometryCondition = cond
                                } label: {
                                    if coordinator.selectedGeometryCondition == cond {
                                        Label(cond.displayLabel, systemImage: "checkmark")
                                    } else {
                                        Text(cond.displayLabel)
                                    }
                                }
                            }
                        } label: {
                            Label(coordinator.selectedGeometryCondition.displayLabel, systemImage: "ruler")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.black.opacity(0.62))
                                )
                        }

                        Spacer()

                        Menu {
                            ForEach(ControlSeriesTag.allCases, id: \.rawValue) { tag in
                                Button {
                                    coordinator.selectedControlSeriesTag = tag
                                } label: {
                                    if coordinator.selectedControlSeriesTag == tag {
                                        Label(tag.displayLabel, systemImage: "checkmark")
                                    } else {
                                        Text(tag.displayLabel)
                                    }
                                }
                            }
                        } label: {
                            Label(coordinator.selectedControlSeriesTag.displayLabel, systemImage: "tag")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.black.opacity(0.62))
                                )
                        }
                    }

                    Spacer(minLength: 4)

                    // Compact targeting reticle fits cleanly on both iPhone and iPad compatibility viewports
                    TargetingReticleView(lockProgress: cameraService.targetLockProgress)
                        .frame(width: 158, height: 170)

                    HStack(spacing: 8) {
                        if cameraService.targetLockProgress >= 0.25 && coordinator.autoScanWhenSteady {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        }
                        Text(cameraService.aimInstructionText)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                cameraService.targetLockProgress >= 0.50
                                    ? LiquidAnalyzerPalette.resultGreenStart.opacity(0.86)
                                    : Color.black.opacity(0.64)
                            )
                    )
                    .animation(.easeInOut(duration: 0.18), value: cameraService.aimInstructionText)

                    Spacer(minLength: 4)

                    // Side-by-side SCAN 1x and RUN R1 (20x) buttons seated cleanly above the floating tab bar
                    HStack(spacing: 10) {
                        Button(action: {
                            coordinator.beginScan()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 16, weight: .bold))
                                Text(primaryAimScanButtonTitle)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                LiquidAnalyzerPalette.scanBlue,
                                                LiquidAnalyzerPalette.scanCyan
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                            )
                            .shadow(color: LiquidAnalyzerPalette.scanBlue.opacity(0.45), radius: 10, y: 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if coordinator.armedComparatorStep == nil {
                            Button(action: {
                                coordinator.startRepeatabilityGateR1Batch(count: 20)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "repeat.circle.fill")
                                        .font(.system(size: 16, weight: .bold))
                                    Text("RUN R1 (20×)")
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    LiquidAnalyzerPalette.resultGreenStart,
                                                    LiquidAnalyzerPalette.scanBlue
                                                ],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                )
                                .shadow(color: LiquidAnalyzerPalette.resultGreenStart.opacity(0.45), radius: 10, y: 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 76)
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var primaryAimScanButtonTitle: String {
        switch coordinator.armedComparatorStep {
        case .emptyCup:
            return "SCAN EMPTY CUP"
        case .waterBlank:
            return "SCAN WATER BLANK"
        case .testSample:
            return "SCAN TEST LIQUID"
        case nil:
            return "SCAN 1×"
        }
    }

    // MARK: - 2. SCANNING Screen

    private var scanningScreen: some View {
        ZStack {
            LinearGradient(
                colors: [
                    LiquidAnalyzerPalette.deepSpaceStart,
                    LiquidAnalyzerPalette.deepSpaceEnd,
                    LiquidAnalyzerPalette.deepSpaceStart
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBrandHeader(showBackButton: false, showSettingsGear: false, onBack: nil)

                Spacer()

                BlueScanningSonarView()
                    .frame(height: 250)

                VStack(spacing: 8) {
                    Text(coordinator.scanningStatusTitle)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text(coordinator.scanningStatusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.74))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 16)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.14))
                            .frame(height: 12)

                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [LiquidAnalyzerPalette.scanBlue, LiquidAnalyzerPalette.scanCyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(
                                width: max(22, geo.size.width * CGFloat(min(1.0, max(0.05, coordinator.scanProgress)))),
                                height: 12
                            )
                            .animation(.easeOut(duration: 0.22), value: coordinator.scanProgress)
                    }
                }
                .frame(height: 12)
                .padding(.horizontal, 44)
                .padding(.top, 28)

                Spacer()

                Button(action: {
                    coordinator.cancelActiveScan()
                }) {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.90))
                        .padding(.horizontal, 34)
                        .padding(.vertical, 12)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: - 3A. Dedicated Chemical Composition Screen & Card (Photo-Free)

    private func chemicalCompositionScreen(for item: ConsumerScanItem) -> some View {
        VStack(spacing: 0) {
            topBrandHeader(showBackButton: true, showSettingsGear: true) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    activeCompositionItem = nil
                }
            }

            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Chemical Composition")
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color(red: 0.06, green: 0.11, blue: 0.22))

                            Button(action: {
                                coordinator.speakResultAnnouncement(for: item)
                            }) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                                    .padding(8)
                                    .background(
                                        Circle()
                                            .fill(LiquidAnalyzerPalette.scanBlue.opacity(0.12))
                                    )
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Speak Chemical Result")
                        }

                        Text(
                            item.status == .referenceMatch
                                ? "\(item.title) • \(item.formulaDisplay)"
                                : "Latest Scan Status: \(item.title)"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.30, green: 0.36, blue: 0.46))
                        .multilineTextAlignment(.center)
                    }
                    .padding(.top, 14)
                    .padding(.horizontal, 18)

                    chemicalCompositionCard(for: item)

                    HStack(spacing: 10) {
                        Button(action: {
                            activeCompositionItem = nil
                            coordinator.openGuidedComparatorWizard()
                        }) {
                            Label("3-Step Comparator", systemImage: "checklist.checked")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(LiquidAnalyzerPalette.resultGreenStart)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            activeCompositionItem = nil
                            coordinator.openCameraAiming(graceDelaySeconds: 0.9)
                        }) {
                            Label("Scan Again", systemImage: "camera.viewfinder")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(LiquidAnalyzerPalette.scanBlue.opacity(0.12))
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
            }
            .background(Color(red: 0.95, green: 0.97, blue: 1.00))
        }
    }

    @ViewBuilder
    private func chemicalCompositionCard(for item: ConsumerScanItem) -> some View {
        let matchedProfile = ReferenceLiquidProfile.matchingProfile(for: item)
        let effectiveConstituents = !item.constituents.isEmpty
            ? item.constituents
            : (matchedProfile?.constituents ?? [])

        if item.status == .referenceMatch {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Chemical Composition", systemImage: "atom")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(LiquidAnalyzerPalette.compositionOrange)
                    Spacer()
                    Text("Reference Profile")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LiquidAnalyzerPalette.resultGreenStart)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(LiquidAnalyzerPalette.resultGreenStart.opacity(0.14))
                        )
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Molecular Formula")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(red: 0.34, green: 0.40, blue: 0.50))
                        Spacer()
                        Text(item.formulaDisplay)
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Color(red: 0.08, green: 0.14, blue: 0.24))
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text("Typical pH Range")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(red: 0.34, green: 0.40, blue: 0.50))
                        Spacer()
                        Text(matchedProfile?.typicalPHRange ?? "Experimental Reference")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 0.14, green: 0.22, blue: 0.36))
                            .multilineTextAlignment(.trailing)
                    }

                    if let category = matchedProfile?.categorySummary {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Molecular Class")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color(red: 0.34, green: 0.40, blue: 0.50))
                            Spacer()
                            Text(category)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color(red: 0.26, green: 0.32, blue: 0.42))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.85))
                )

                if !effectiveConstituents.isEmpty {
                    Text("Key Constituents")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(red: 0.30, green: 0.36, blue: 0.46))

                    ForEach(effectiveConstituents) { constituent in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(constituent.symbol)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(Color(red: 0.10, green: 0.15, blue: 0.24))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(constituent.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color(red: 0.16, green: 0.20, blue: 0.28))
                                Text(constituent.roleDescription)
                                    .font(.caption2)
                                    .foregroundStyle(Color(red: 0.40, green: 0.45, blue: 0.54))
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LiquidAnalyzerPalette.compositionWarmBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(LiquidAnalyzerPalette.compositionOrange.opacity(0.30), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.status == .emptyContainer ? "cup.and.saucer" : "flask")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(LiquidAnalyzerPalette.compositionOrange)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(LiquidAnalyzerPalette.compositionOrange.opacity(0.14))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Chemical Profile Unavailable — Scan Inconclusive")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.24))
                        Text(inconclusiveCompositionSubtitle(for: item))
                            .font(.caption)
                            .foregroundStyle(Color(red: 0.36, green: 0.42, blue: 0.52))
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    compositionGuidanceRow(
                        icon: "drop.halffull",
                        title: "Best Phone-Only Targets",
                        detail: "Colored, cloudy, viscous, or fizzy liquids (Milk, Cooking Oil, Coffee, Cola, Red Wine, Citrus Juice, Iced Tea, Sparkling Water)."
                    )
                    compositionGuidanceRow(
                        icon: "checklist.checked",
                        title: "Clear Liquids Require Stationary Comparison",
                        detail: "Airborne phone audio cannot identify clear liquids cold. Keep the phone and identical cup stationary and lock Empty Cup → Water Blank → Sample."
                    )
                    compositionGuidanceRow(
                        icon: "sun.max.fill",
                        title: "Check Lighting & Calibration",
                        detail: "Use even lighting without harsh reflections, keep the container steady, and re-run Step 1 (Empty Cup) if the glass was moved."
                    )
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.99, green: 0.97, blue: 0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(LiquidAnalyzerPalette.compositionOrange.opacity(0.28), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
        }
    }

    private func inconclusiveCompositionSubtitle(for item: ConsumerScanItem) -> String {
        switch item.status {
        case .emptyContainer:
            return "Empty Container / Low Coupling — no liquid load detected above dry shell baseline."
        case .nonLiquidMaterial:
            return "Solid or non-liquid surface detected — aim directly into an open liquid container."
        case .unclearScan:
            return "Audio reflection was too quiet, noisy, or clipped to compute a reliable profile."
        case .unmatchedSignature:
            if item.modeAScreeningState == .rejectedBaselineMismatch {
                return "Saved Empty Cup baseline drifted — re-run Step 1 (Empty Cup) in your current setup."
            }
            if item.modeAScreeningState == .liquidLoaded {
                return "Liquid load detected above Empty Cup, but chemical class was not matched."
            }
            return "No validated chemical match — uncalibrated clear glass and clear liquids cannot be separated cold."
        case .referenceMatch:
            return item.formulaDisplay
        }
    }

    private func compositionGuidanceRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(LiquidAnalyzerPalette.compositionOrange)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(red: 0.14, green: 0.18, blue: 0.28))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.36, green: 0.42, blue: 0.52))
            }
        }
    }

    // MARK: - 3. RESULT Screen

    private func resultScreen(for item: ConsumerScanItem) -> some View {
        VStack(spacing: 0) {
            topBrandHeader(showBackButton: true, showSettingsGear: true) {
                coordinator.returnToHome()
            }

            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 0) {
                        HStack {
                            Text(resultBannerTitle(for: item.status))
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: resultBannerIcon(for: item.status))
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 15)
                        .background(resultBannerGradient(for: item.status))

                        VStack(spacing: 14) {
                            VStack(spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(item.title)
                                        .font(.system(size: 28, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color(red: 0.06, green: 0.10, blue: 0.18))
                                        .multilineTextAlignment(.center)

                                    Button(action: {
                                        coordinator.speakResultAnnouncement(for: item)
                                    }) {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                                            .padding(8)
                                            .background(
                                                Circle()
                                                    .fill(LiquidAnalyzerPalette.scanBlue.opacity(0.12))
                                            )
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Speak Result")
                                }

                                Text(item.formulaDisplay)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(Color(red: 0.30, green: 0.36, blue: 0.45))

                                Text(item.statusBadgeText)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(
                                        item.status == .referenceMatch
                                            ? LiquidAnalyzerPalette.resultGreenStart
                                            : LiquidAnalyzerPalette.compositionOrange
                                    )
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(
                                                (item.status == .referenceMatch
                                                    ? LiquidAnalyzerPalette.resultGreenStart
                                                    : LiquidAnalyzerPalette.compositionOrange
                                                ).opacity(0.12)
                                            )
                                    )
                                    .padding(.top, 4)
                            }
                            .padding(.top, 16)

                            chemicalCompositionCard(for: item)

                            if let attr = item.fusionAttribution {
                                MultiModalAttributionCardView(
                                    attribution: attr,
                                    onOpenComparator: {
                                        coordinator.openGuidedComparatorWizard()
                                    }
                                )
                            }

                            Text(item.scientificNote)
                                .font(.caption)
                                .foregroundStyle(Color(red: 0.36, green: 0.42, blue: 0.50))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)

                            if let feat = item.measuredFeatures {
                                DisclosureGroup("Repeatability Gate R1 Telemetry") {
                                    r1TelemetryContent(item: item, feat: feat)
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(red: 0.24, green: 0.30, blue: 0.42))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color(red: 0.96, green: 0.97, blue: 0.99))
                                )
                                .padding(.horizontal, 16)
                            }

                            if item.status != .unclearScan && item.status != .nonLiquidMaterial && item.status != .emptyContainer {
                                Button(action: {
                                    coordinator.stopVoiceAnnouncement()
                                    withAnimation(.easeInOut(duration: 0.24)) {
                                        activeTuneItem = item
                                    }
                                    if coordinator.autoPlayTunePreview {
                                        coordinator.tunePlayer.togglePlayPause(for: item)
                                    }
                                }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "music.note")
                                            .font(.system(size: 19, weight: .bold))
                                        Text("Play Chemical Tune")
                                            .font(.system(size: 18, weight: .bold, design: .rounded))
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        LiquidAnalyzerPalette.scanBlue,
                                                        LiquidAnalyzerPalette.tunePurple,
                                                        LiquidAnalyzerPalette.tuneMagenta
                                                    ],
                                                    startPoint: .leading,
                                                    endPoint: .trailing
                                                )
                                            )
                                    )
                                    .shadow(color: LiquidAnalyzerPalette.tunePurple.opacity(0.38), radius: 10, y: 4)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                            }

                            VStack(spacing: 10) {
                                // Direct R1 (20x) Batch launcher right on the Result screen
                                VStack(spacing: 8) {
                                    HStack(spacing: 8) {
                                        Menu {
                                            ForEach(ControlSeriesTag.allCases, id: \.rawValue) { tag in
                                                Button {
                                                    coordinator.selectedControlSeriesTag = tag
                                                } label: {
                                                    if coordinator.selectedControlSeriesTag == tag {
                                                        Label(tag.displayLabel, systemImage: "checkmark")
                                                    } else {
                                                        Text(tag.displayLabel)
                                                    }
                                                }
                                            }
                                        } label: {
                                            HStack(spacing: 5) {
                                                Image(systemName: "tag.fill")
                                                Text(coordinator.selectedControlSeriesTag.displayLabel)
                                                    .lineLimit(1)
                                                Spacer(minLength: 2)
                                                Image(systemName: "chevron.up.chevron.down")
                                            }
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(LiquidAnalyzerPalette.scanBlue.opacity(0.10))
                                            )
                                        }

                                        Button(action: {
                                            coordinator.startRepeatabilityGateR1Batch(count: 20)
                                        }) {
                                            Label("RUN R1 (20×)", systemImage: "repeat.circle.fill")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 9)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                        .fill(LiquidAnalyzerPalette.resultGreenStart)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)

                                Button(action: {
                                    coordinator.resetToAim()
                                }) {
                                    Label(
                                        (item.status == .unclearScan || item.status == .nonLiquidMaterial)
                                            ? "Aim at a Liquid & Scan Again"
                                            : "Open Camera (Auto-Scan OFF)",
                                        systemImage: "camera.viewfinder"
                                    )
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if let bID = item.batchRunID, !bID.isEmpty, (item.batchTotalCount ?? 1) > 1 {
                                    let batchMembers = coordinator.history.filter { $0.batchRunID == bID }
                                    if batchMembers.count >= 2 {
                                        Menu {
                                            Button {
                                                _ = coordinator.teachCalibratedBatchBaseline(
                                                    items: batchMembers,
                                                    targetID: CalibratedAcousticPrototype.emptyContainerTargetID
                                                )
                                            } label: {
                                                Label("Empty Container Baseline (Sweeps 3–20)", systemImage: "cup.and.saucer")
                                            }
                                            Button {
                                                _ = coordinator.teachCalibratedBatchBaseline(
                                                    items: batchMembers,
                                                    targetID: CalibratedAcousticPrototype.waterReferenceTargetID
                                                )
                                            } label: {
                                                Label("Water Reference Baseline (Sweeps 3–20)", systemImage: "drop.fill")
                                            }
                                            Button {
                                                _ = coordinator.teachCalibratedBatchBaseline(
                                                    items: batchMembers,
                                                    targetID: CalibratedAcousticPrototype.solidSurfaceTargetID
                                                )
                                            } label: {
                                                Label("Solid Surface Baseline (Sweeps 3–20)", systemImage: "cube.fill")
                                            }
                                            Divider()
                                            Menu("Known Liquid Standard (Sweeps 3–20)...") {
                                                ForEach(ReferenceLiquidProfile.provisionalLibrary) { profile in
                                                    Button {
                                                        _ = coordinator.teachCalibratedBatchBaseline(
                                                            items: batchMembers,
                                                            targetID: profile.id
                                                        )
                                                    } label: {
                                                        Text("\(profile.displayName) (\(profile.formulaDisplay))")
                                                    }
                                                }
                                            }
                                        } label: {
                                            Label("Save 20× Steady-State (Sweeps 3–20) as Baseline", systemImage: "scope")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 9)
                                                .background(
                                                    Capsule(style: .continuous)
                                                        .fill(LiquidAnalyzerPalette.resultGreenStart)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                if item.measuredFeatures != nil && item.status != .unclearScan {
                                    Button(action: {
                                        activeSheet = .calibration(item)
                                    }) {
                                        Label("Calibrate Setup (Empty / Water / Salt...)", systemImage: "scope")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(LiquidAnalyzerPalette.scanBlue.opacity(0.12))
                                            )
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.bottom, 16)
                        }
                        .background(Color.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Color.black.opacity(0.10), radius: 16, y: 6)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 88)
                }
            }
            .background(Color(red: 0.94, green: 0.96, blue: 0.99))
        }
    }

    // MARK: - Shared Header & Styling Helpers

    private func topBrandHeader(
        showBackButton: Bool,
        showSettingsGear: Bool,
        onBack: (() -> Void)?
    ) -> some View {
        HStack {
            if showBackButton, let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 32, height: 32)
            }

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: "drop.fill")
                    .font(.subheadline)
                    .foregroundStyle(LiquidAnalyzerPalette.scanCyan)
                Text("Liquid Analyzer")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }

            Spacer()

            if showSettingsGear {
                Button(action: {
                    coordinator.cameraService.stopCamera()
                    coordinator.selectedTab = .more
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(LiquidAnalyzerPalette.headerNavy)
    }

    private func r1TelemetryContent(item: ConsumerScanItem, feat: ExtractedConsumerFeatures) -> some View {
        let secondarySummary: String = {
            guard !feat.secondaryPeaksHz.isEmpty else { return "None" }
            var parts: [String] = []
            for (idx, hz) in feat.secondaryPeaksHz.enumerated() {
                if idx < feat.secondaryPeakAmplitudesDB.count {
                    parts.append(String(format: "%.0f Hz (%.1f dB)", hz, feat.secondaryPeakAmplitudesDB[idx]))
                } else {
                    parts.append(String(format: "%.0f Hz", hz))
                }
            }
            return parts.joined(separator: ", ")
        }()
        let lockSummary = "\(item.aeAfWbLockState ?? (feat.opticsLocked ? "LOCKED" : "UNLOCKED")) • \(item.targetLockState ?? "CAPTURED")"
        let vectorText = "[\(feat.subBandShapeDB.map { String(format: "%+.1f", $0) }.joined(separator: ","))] • \(feat.featureVectorChecksum)"

        return VStack(alignment: .leading, spacing: 5) {
            Group {
                if let seq = item.scanSequenceNumber {
                    let batchLabel = (item.batchScanIndex != nil && item.batchTotalCount != nil)
                        ? " (\(item.batchScanIndex!)/\(item.batchTotalCount!))"
                        : ""
                    r1Row("Scan #", "#\(seq)\(batchLabel)")
                }
                if let geom = item.geometryCondition {
                    r1Row("Geometry Cohort", geom)
                }
                if let tag = item.controlSeriesTag, tag != ControlSeriesTag.unlabeledBlind.rawValue {
                    r1Row("Control Tag (Audit)", tag)
                }
                r1Row("Lock State", lockSummary)
                r1Row(
                    "Primary Peak",
                    String(
                        format: "%.1f Hz (%.1f dB • persist %.0f%%)",
                        feat.dominantPeakHz,
                        feat.primaryPeakAmplitudeDB,
                        feat.intraScanPersistenceRatio * 100.0
                    )
                )
                r1Row("Secondary Peaks", secondarySummary)
                r1Row(
                    "Amplitude / SNR",
                    String(format: "%.1f dBFS (pk %.1f) • SNR %.1f dB", feat.activeRMSDBFS, feat.peakDBFS, feat.activeSNRDB)
                )
                r1Row(
                    "Echo / Tail SNR",
                    String(format: "Echo %.1f dB (%.1f dBFS) • Tail SNR %.1f dB", feat.echoReturnDB, feat.echoRMSDBFS, feat.tailSNRDB)
                )
                r1Row(
                    "Sync / TOF / HF",
                    String(format: "Sync %+d smp • TOF %.2f ms • HF %.1f dB", feat.alignmentOffsetSamples, feat.echoArrivalDelayMs, feat.highFreqBubbleScatterDB)
                )
            }
            Group {
                r1Row(
                    "Container Mode",
                    String(format: "Cent %.0f Hz • Decay %.0f dB/s • Cav %.1f dB", feat.spectralCentroidHz, feat.decaySlopeDBPerSec, feat.cavityMultipathDB)
                )
                r1Row("Vector / Checksum", vectorText)
                if let de = item.deltaEmptyBaseline, de.compatible {
                    let sText = de.relativeFrequencyShifts.map { $0.map { String(format: "%+.1f%%", $0 * 100.0) } ?? "NaN" }.joined(separator: "; ")
                    r1Row("Δf / f_empty", "[\(sText)]")
                }
                if let dw = item.deltaWaterBaseline, dw.compatible {
                    let wText = dw.relativeFrequencyShifts.map { $0.map { String(format: "%+.1f%%", $0 * 100.0) } ?? "NaN" }.joined(separator: "; ")
                    r1Row("Δf / f_water", "[\(wText)]")
                }
                if let gateDec = item.gateDecision {
                    r1Row("Gate Decision", gateDec)
                }
                if let reason = item.rejectionReason, !reason.isEmpty {
                    r1Row("Hold / Reject Why", reason)
                }
                if let top = item.topCandidateName, let td = item.topCandidateDistance {
                    r1Row("Top Candidate", String(format: "%@ (d=%.3f)", top, td))
                }
                if let sec = item.runnerUpTitle, let sd = item.secondCandidateDistance {
                    r1Row("Second Candidate", String(format: "%@ (d=%.3f)", sec, sd))
                }
                if let margin = item.winningMargin {
                    r1Row("Winning Margin", String(format: "+%.3f", margin))
                }
                if let allScores = item.allCandidateDistances, !allScores.isEmpty {
                    Text("Raw Scores: " + allScores.prefix(6).map { "\($0.displayName)=\(String(format: "%.2f", $0.distance))" }.joined(separator: " | "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                HStack(spacing: 8) {
                    Button {
                        _ = coordinator.copyRepeatabilityCSVToClipboard(items: [item])
                        copiedSingleScanID = item.id
                    } label: {
                        Label(
                            copiedSingleScanID == item.id ? "Copied CSV ✓" : "Copy Scan CSV",
                            systemImage: copiedSingleScanID == item.id ? "checkmark.circle.fill" : "doc.on.doc.fill"
                        )
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(LiquidAnalyzerPalette.scanBlue.opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        let suffix = item.scanSequenceNumber.map { "scan_\($0)" } ?? "scan"
                        coordinator.presentNativeCSVShareSheet(items: [item], filenameSuffix: suffix)
                    } label: {
                        Label("Share Scan CSV", systemImage: "square.and.arrow.up")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(LiquidAnalyzerPalette.scanBlue.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
        }
        .font(.caption2)
        .padding(.top, 6)
    }

    private func r1Row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }

    private func resultBannerTitle(for status: ConsumerMatchStatus) -> String {
        switch status {
        case .referenceMatch:
            return "Result"
        case .unmatchedSignature:
            return "Acoustic Profile"
        case .emptyContainer:
            return "Empty Container"
        case .nonLiquidMaterial:
            return "Non-Liquid Surface"
        case .unclearScan:
            return "Scan Unclear"
        }
    }

    private func resultBannerIcon(for status: ConsumerMatchStatus) -> String {
        switch status {
        case .referenceMatch:
            return "checkmark.circle.fill"
        case .unmatchedSignature:
            return "waveform.circle.fill"
        case .emptyContainer:
            return "cup.and.saucer"
        case .nonLiquidMaterial:
            return "cube.fill"
        case .unclearScan:
            return "exclamationmark.circle.fill"
        }
    }

    private func resultBannerGradient(for status: ConsumerMatchStatus) -> LinearGradient {
        switch status {
        case .referenceMatch:
            return LinearGradient(
                colors: [LiquidAnalyzerPalette.resultGreenStart, LiquidAnalyzerPalette.resultGreenEnd],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .unmatchedSignature:
            return LinearGradient(
                colors: [LiquidAnalyzerPalette.scanBlue, LiquidAnalyzerPalette.tunePurple],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .emptyContainer:
            return LinearGradient(
                colors: [Color(red: 0.22, green: 0.48, blue: 0.68), Color(red: 0.34, green: 0.56, blue: 0.72)],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .nonLiquidMaterial:
            return LinearGradient(
                colors: [Color(red: 0.32, green: 0.39, blue: 0.50), Color(red: 0.55, green: 0.38, blue: 0.22)],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .unclearScan:
            return LinearGradient(
                colors: [LiquidAnalyzerPalette.compositionOrange, Color(red: 0.85, green: 0.32, blue: 0.12)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

/// Simple consumer calibration sheet allowing one-tap teaching of known liquids or solid surfaces
/// for calibrated indirect acoustic inference and blind testing.
private struct CalibrateKnownStandardSheet: View {
    let item: ConsumerScanItem
    let onSelectTarget: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Save this scan's real acoustic + optical signature as a known standard for your setup. Calibrating Empty Glass, Water Blank, and Salt Solution lets you run shuffled blind tests on the same glass.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Container & Blank Controls (Phase 1)") {
                    Button {
                        onSelectTarget(CalibratedAcousticPrototype.emptyContainerTargetID)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Empty Glass / Container")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Dry container control (no liquid fill)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "cup.and.saucer")
                                .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                        }
                    }
                }

                Section("Known Liquids") {
                    ForEach(ReferenceLiquidProfile.provisionalLibrary) { profile in
                        Button {
                            onSelectTarget(profile.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(profile.formulaDisplay)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "waveform.badge.plus")
                                    .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                            }
                        }
                    }
                }

                Section("Non-Liquid Reference") {
                    Button {
                        onSelectTarget(CalibratedAcousticPrototype.solidSurfaceTargetID)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Solid / Non-Liquid Material")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Wall, desk, countertop, or empty surface")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "cube.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Calibrate Standard")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
    }
}
