import SwiftUI

/// Primary consumer Scan tab implementing HOME -> AIM -> SCAN -> RESULT -> LISTEN.
public struct ConsumerScanFlowView: View {
    @ObservedObject var coordinator: ConsumerScanCoordinator
    @ObservedObject private var cameraService: CameraTargetingService
    @State private var activeTuneItem: ConsumerScanItem?

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

                    Text("Use sound waves and your iPhone to explore liquids and hear their mapped composition tune.")
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
                        subtitle: "Point at liquid"
                    )
                    posterStepBadge(
                        number: "2",
                        color: LiquidAnalyzerPalette.resultGreenStart,
                        title: "SCAN",
                        subtitle: "Sound waves"
                    )
                    posterStepBadge(
                        number: "3",
                        color: LiquidAnalyzerPalette.compositionOrange,
                        title: "SEE",
                        subtitle: "Composition"
                    )
                    posterStepBadge(
                        number: "4",
                        color: LiquidAnalyzerPalette.tunePurple,
                        title: "LISTEN",
                        subtitle: "Chemical tune"
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
                        subtitle: "Uses iPhone camera & audio system"
                    )
                    posterFeatureTile(
                        icon: "flask.fill",
                        iconColor: LiquidAnalyzerPalette.resultGreenStart,
                        bgColor: Color(red: 0.90, green: 0.98, blue: 0.93),
                        title: "Identify Liquids",
                        subtitle: "Water, beverages & reference profiles"
                    )
                    posterFeatureTile(
                        icon: "chart.bar.fill",
                        iconColor: LiquidAnalyzerPalette.compositionOrange,
                        bgColor: Color(red: 1.00, green: 0.95, blue: 0.89),
                        title: "See Composition",
                        subtitle: "Simple, clear experimental cards"
                    )
                    posterFeatureTile(
                        icon: "music.note",
                        iconColor: LiquidAnalyzerPalette.tunePurple,
                        bgColor: Color(red: 0.95, green: 0.91, blue: 1.00),
                        title: "Hear the Signature",
                        subtitle: "Play the rainbow Chemical Tune"
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
                .padding(.bottom, 22)
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
        subtitle: String
    ) -> some View {
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
    }

    private func posterFeatureTile(
        icon: String,
        iconColor: Color,
        bgColor: Color,
        title: String,
        subtitle: String
    ) -> some View {
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

                VStack(spacing: 18) {
                    Spacer(minLength: 14)

                    // Live targeting reticle turns Emerald-Cyan as user holds steady on liquid
                    TargetingReticleView(lockProgress: cameraService.targetLockProgress)
                        .frame(width: 228, height: 248)

                    // Dynamic instruction pill ("Aim at the liquid" -> "Hold steady..." -> Auto-scans!)
                    HStack(spacing: 8) {
                        if cameraService.targetLockProgress >= 0.25 {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        }
                        Text(cameraService.aimInstructionText)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                cameraService.targetLockProgress >= 0.25
                                    ? LiquidAnalyzerPalette.resultGreenStart.opacity(0.86)
                                    : Color.black.opacity(0.64)
                            )
                    )
                    .animation(.easeInOut(duration: 0.18), value: cameraService.aimInstructionText)

                    Spacer()

                    // Manual one-tap SCAN button (can also tap immediately without waiting for auto-lock)
                    Button(action: {
                        coordinator.beginScan()
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform")
                                .font(.system(size: 20, weight: .bold))
                            Text("SCAN NOW")
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                                .tracking(0.8)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: 280)
                        .padding(.vertical, 16)
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
                        .shadow(color: LiquidAnalyzerPalette.scanBlue.opacity(0.55), radius: 14, y: 5)
                    }
                    .buttonStyle(.plain)

                    Text("Hold steady to auto-scan or tap SCAN NOW")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.bottom, 16)
                }
                .padding(.horizontal, 20)
            }
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
                    Text("Analyzing Liquid...")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Listening to sound-wave reflections")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.70))
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
                                Text(item.title)
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color(red: 0.06, green: 0.10, blue: 0.18))
                                    .multilineTextAlignment(.center)

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

                            PlatformThumbnailView(jpegData: item.thumbnailJPEGData, size: 118)
                                .padding(.vertical, 2)

                            if !item.constituents.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Label("Composition", systemImage: "chart.bar.fill")
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(LiquidAnalyzerPalette.compositionOrange)
                                        Spacer()
                                        Text("Experimental")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(LiquidAnalyzerPalette.compositionOrange)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(LiquidAnalyzerPalette.compositionOrange.opacity(0.14))
                                            )
                                    }

                                    Divider()

                                    ForEach(item.constituents) { constituent in
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(constituent.symbol)
                                                .font(.headline.weight(.bold))
                                                .foregroundStyle(Color(red: 0.12, green: 0.15, blue: 0.22))
                                            Spacer()
                                            VStack(alignment: .trailing, spacing: 2) {
                                                Text(constituent.name)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(Color(red: 0.16, green: 0.20, blue: 0.28))
                                                Text(constituent.roleDescription)
                                                    .font(.caption2)
                                                    .foregroundStyle(Color(red: 0.40, green: 0.45, blue: 0.54))
                                            }
                                        }
                                    }
                                }
                                .padding(16)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(LiquidAnalyzerPalette.compositionWarmBg)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .stroke(LiquidAnalyzerPalette.compositionOrange.opacity(0.28), lineWidth: 1)
                                        )
                                )
                                .padding(.horizontal, 16)
                            }

                            Text(item.scientificNote)
                                .font(.caption)
                                .foregroundStyle(Color(red: 0.36, green: 0.42, blue: 0.50))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)

                            if item.status != .unclearScan {
                                Button(action: {
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

                            HStack(spacing: 24) {
                                Button(action: {
                                    coordinator.resetToAim()
                                }) {
                                    Label(
                                        item.status == .unclearScan ? "Try Scan Again" : "Scan Another Liquid",
                                        systemImage: "camera.viewfinder"
                                    )
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.bottom, 16)
                        }
                        .background(Color.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Color.black.opacity(0.10), radius: 16, y: 6)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
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

    private func resultBannerTitle(for status: ConsumerMatchStatus) -> String {
        switch status {
        case .referenceMatch:
            return "Result"
        case .unmatchedSignature:
            return "Acoustic Profile"
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
        case .unclearScan:
            return LinearGradient(
                colors: [LiquidAnalyzerPalette.compositionOrange, Color(red: 0.85, green: 0.32, blue: 0.12)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}
