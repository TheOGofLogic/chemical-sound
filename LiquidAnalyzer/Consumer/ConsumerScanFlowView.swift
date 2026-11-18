import SwiftUI

/// Primary consumer Scan tab implementing AIM -> SCAN -> RESULT -> LISTEN.
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

    // MARK: - 1. AIM Screen

    private var aimScreen: some View {
        VStack(spacing: 0) {
            topBrandHeader(showSettingsGear: true)

            ZStack {
                cameraService.previewLayerView
                    .ignoresSafeArea(edges: .horizontal)

                // Subtle top & bottom vignette for crisp legibility
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.28),
                        Color.clear,
                        Color.clear,
                        Color.black.opacity(0.52)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 18) {
                    Spacer(minLength: 16)

                    // Clean blue targeting frame over the liquid
                    TargetingReticleView()
                        .frame(width: 228, height: 248)

                    // Single simple instruction: "Aim at the liquid"
                    Text("Aim at the liquid")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 11)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.62))
                        )

                    Spacer()

                    // Large primary SCAN button
                    Button(action: {
                        coordinator.beginScan()
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform")
                                .font(.system(size: 20, weight: .bold))
                            Text("SCAN")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .tracking(1.0)
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

                    Text("Camera guides aiming • Sound waves measure the liquid")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.bottom, 18)
                }
                .padding(.horizontal, 20)
            }
        }
        .onAppear {
            cameraService.startCamera()
        }
        .onDisappear {
            cameraService.stopCamera()
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
                topBrandHeader(showSettingsGear: false)

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

                // Clean animated blue progress bar
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
                            .animation(.easeOut(duration: 0.25), value: coordinator.scanProgress)
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
            topBrandHeader(showSettingsGear: true)

            ScrollView {
                VStack(spacing: 16) {
                    // Main Result Card
                    VStack(spacing: 0) {
                        // Top Status Banner (Green for completed result, Amber for unmatched/rescan)
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
                            // Liquid Name & Formula
                            VStack(spacing: 4) {
                                Text(item.title)
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.primary)
                                    .multilineTextAlignment(.center)

                                Text(item.formulaDisplay)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(Color.secondary)

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

                            // Container Visual Thumbnail / Glass Artwork
                            PlatformThumbnailView(jpegData: item.thumbnailJPEGData, size: 118)
                                .padding(.vertical, 2)

                            // Separated Orange-Accented Composition Panel
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
                                                    .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)

                            // Prominent Colorful "♫ Play Chemical Tune" Button
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

                            // Secondary Scan Again Action
                            Button(action: {
                                coordinator.resetToAim()
                            }) {
                                Label(
                                    item.status == .unclearScan ? "Try Scan Again" : "Scan Another Liquid",
                                    systemImage: "arrow.counterclockwise"
                                )
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 16)
                        }
                        .background(Color(red: 0.99, green: 0.99, blue: 1.0))
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

    private func topBrandHeader(showSettingsGear: Bool) -> some View {
        HStack {
            if case .result = coordinator.flowStep {
                Button(action: {
                    coordinator.resetToAim()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
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
