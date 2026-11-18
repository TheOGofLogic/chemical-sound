import SwiftUI

/// Primary consumer navigation shell (`Scan | History | Learn | More`).
public struct ConsumerRootView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    @ObservedObject private var consumer: ConsumerScanCoordinator

    public init(appCoordinator: AppCoordinator) {
        self.appCoordinator = appCoordinator
        self.consumer = appCoordinator.consumerCoordinator
    }

    public var body: some View {
        TabView(selection: $consumer.selectedTab) {
            ConsumerScanFlowView(coordinator: consumer)
                .tabItem {
                    Label("Scan", systemImage: "camera.fill")
                }
                .tag(ConsumerTab.scan)

            ConsumerHistoryView(coordinator: consumer)
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(ConsumerTab.history)

            ConsumerLearnView()
                .tabItem {
                    Label("Learn", systemImage: "book.pages")
                }
                .tag(ConsumerTab.learn)

            ConsumerMoreView(appCoordinator: appCoordinator, consumer: consumer)
                .tabItem {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .tag(ConsumerTab.more)
        }
        .tint(LiquidAnalyzerPalette.scanBlue)
        .sheet(isPresented: $consumer.isResearchConsolePresented) {
            ResearchConsoleView(
                appCoordinator: appCoordinator,
                onClose: { consumer.isResearchConsolePresented = false }
            )
        }
    }
}

// MARK: - Tab 2: History

public struct ConsumerHistoryView: View {
    @ObservedObject var coordinator: ConsumerScanCoordinator
    @State private var selectedTuneItem: ConsumerScanItem?

    public init(coordinator: ConsumerScanCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        NavigationStack {
            Group {
                if coordinator.history.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "waveform.and.magnifyingglass")
                            .font(.system(size: 46))
                            .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                        Text("No Scans Yet")
                            .font(.title3.weight(.bold))
                        Text("Point your iPhone at a liquid container in the Scan tab and tap SCAN to record your first acoustic profile.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(coordinator.history) { item in
                            Button(action: {
                                coordinator.openHistoryItem(item)
                            }) {
                                HStack(spacing: 14) {
                                    ZStack {
                                        Circle()
                                            .fill(
                                                (item.status == .referenceMatch
                                                    ? LiquidAnalyzerPalette.resultGreenStart
                                                    : LiquidAnalyzerPalette.scanBlue
                                                ).opacity(0.14)
                                            )
                                            .frame(width: 46, height: 46)

                                        Image(
                                            systemName: item.status == .referenceMatch
                                                ? "checkmark.circle.fill"
                                                : "waveform"
                                        )
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(
                                            item.status == .referenceMatch
                                                ? LiquidAnalyzerPalette.resultGreenStart
                                                : LiquidAnalyzerPalette.scanBlue
                                        )
                                    }

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text("\(item.formulaDisplay) • \(item.scannedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button(action: {
                                        selectedTuneItem = item
                                    }) {
                                        Image(systemName: "music.note")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 34, height: 34)
                                            .background(
                                                Circle()
                                                    .fill(
                                                        LinearGradient(
                                                            colors: [
                                                                LiquidAnalyzerPalette.scanBlue,
                                                                LiquidAnalyzerPalette.tunePurple
                                                            ],
                                                            startPoint: .topLeading,
                                                            endPoint: .bottomTrailing
                                                        )
                                                    )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Play Chemical Tune for \(item.title)")
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !coordinator.history.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Button("Clear", role: .destructive) {
                            coordinator.clearHistory()
                        }
                    }
                }
            }
            .sheet(item: $selectedTuneItem) { tuneItem in
                ChemicalTuneView(
                    item: tuneItem,
                    tunePlayer: coordinator.tunePlayer,
                    onBack: { selectedTuneItem = nil }
                )
            }
        }
    }
}

// MARK: - Tab 3: Learn

public struct ConsumerLearnView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("See the liquid. Hear the science.")
                        .font(.title2.weight(.bold))
                        .padding(.top, 4)

                    Text("Liquid Analyzer is an experimental acoustic research and educational tool that explores how different liquids respond to sound waves.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    learnCard(
                        icon: "camera.fill",
                        accent: LiquidAnalyzerPalette.scanBlue,
                        title: "1. Camera + Sound",
                        bodyText: "Your camera helps you frame the container and saves a visual reference. The actual measurement comes from calibrated sound waves emitted by your speaker and recorded by your microphone—the camera photo itself never determines composition."
                    )

                    learnCard(
                        icon: "checkmark.seal.fill",
                        accent: LiquidAnalyzerPalette.resultGreenStart,
                        title: "2. Indirect Acoustic Inference",
                        bodyText: "Like radar and acoustic resonance sensors, Liquid Analyzer transmits a known sound sweep and analyzes the returned echo across multiple frequency bands, cavity ring-down, and scatter—comparing that signature against reference and calibrated standards."
                    )

                    learnCard(
                        icon: "chart.bar.fill",
                        accent: LiquidAnalyzerPalette.compositionOrange,
                        title: "3. Reference Composition",
                        bodyText: "When a scan resembles a reference profile, the Composition card lists that reference's known constituents. Outputs are experimental estimates for education and research—never a test of purity, potability, toxicity, or safety."
                    )

                    learnCard(
                        icon: "music.note",
                        accent: LiquidAnalyzerPalette.tunePurple,
                        title: "4. Chemical Tune",
                        bodyText: "Chemical Tune translates mapped reference constituents and measured resonance frequencies into musical intervals and harmonic timbres through a defined audio mapping, letting you hear differences between profiles."
                    )
                }
                .padding(18)
            }
            .background(Color(red: 0.95, green: 0.97, blue: 0.99))
            .navigationTitle("Learn")
        }
    }

    private func learnCard(
        icon: String,
        accent: Color,
        title: String,
        bodyText: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(accent.opacity(0.14))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(bodyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.05), radius: 8, y: 3)
        )
    }
}

// MARK: - Tab 4: More (Settings, Scope & Protected Research Mode)

public struct ConsumerMoreView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    @ObservedObject var consumer: ConsumerScanCoordinator
    @State private var showResearchConfirmation = false

    public init(appCoordinator: AppCoordinator, consumer: ConsumerScanCoordinator) {
        self.appCoordinator = appCoordinator
        self.consumer = consumer
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Experience") {
                    Toggle("Auto-Scan When Held Steady", isOn: $consumer.autoScanWhenSteady)
                    Toggle("Auto-Play Chemical Tune on Open", isOn: $consumer.autoPlayTunePreview)
                    Toggle("Vibration Feedback", isOn: $consumer.hapticsEnabled)
                }

                Section("Calibrated Standards") {
                    LabeledContent("Saved Acoustic Standards", value: "\(consumer.calibratedPrototypes.count)")
                    if !consumer.calibratedPrototypes.isEmpty {
                        Button("Reset Calibrated Standards", role: .destructive) {
                            consumer.clearCalibratedStandards()
                        }
                    }
                }

                Section("For Research & Education") {
                    Text("Liquid Analyzer is an experimental acoustic liquid-analysis platform. Results reflect empirical similarity to reference profiles and must not be used to judge drinkability, chemical purity, medical suitability, or safety.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Advanced") {
                    Button {
                        showResearchConfirmation = true
                    } label: {
                        Label("Research & Developer Mode", systemImage: "flask")
                    }
                }

                Section("About") {
                    LabeledContent("Application", value: "Liquid Analyzer")
                    LabeledContent("Version", value: "0.3.3 (Build 8)")
                }
            }
            .navigationTitle("More")
            .confirmationDialog(
                "Open Research & Developer Mode?",
                isPresented: $showResearchConfirmation,
                titleVisibility: .visible
            ) {
                Button("Open Research Console") {
                    consumer.isResearchConsolePresented = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Research Mode exposes controlled bench calibration, fixture metadata, signal-quality diagnostics, and raw session export intended for laboratory validation studies.")
            }
        }
    }
}

// MARK: - Protected Layer 2 Research / Developer Mode Console

public struct ResearchConsoleView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    public let onClose: () -> Void

    public init(appCoordinator: AppCoordinator, onClose: @escaping () -> Void) {
        self.appCoordinator = appCoordinator
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Research & Bench Mode", systemImage: "flask.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Exit") {
                    onClose()
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(LiquidAnalyzerPalette.scanCyan)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(LiquidAnalyzerPalette.headerNavy)

            TabView(selection: $appCoordinator.selectedTab) {
                StudySetupView(appCoordinator: appCoordinator)
                    .tabItem { Label("Setup & Audio", systemImage: "slider.horizontal.3") }
                    .tag(AppCoordinator.TabSelection.setup)

                CalibrationView(appCoordinator: appCoordinator)
                    .tabItem { Label("Calibration", systemImage: "checkmark.shield") }
                    .tag(AppCoordinator.TabSelection.calibration)

                SampleSetupView(appCoordinator: appCoordinator)
                    .tabItem { Label("Sample", systemImage: "testtube.2") }
                    .tag(AppCoordinator.TabSelection.sample)

                AcquisitionView(appCoordinator: appCoordinator)
                    .tabItem { Label("Acquire", systemImage: "waveform.circle") }
                    .tag(AppCoordinator.TabSelection.acquisition)

                QualityReviewView(appCoordinator: appCoordinator)
                    .tabItem { Label("QC Audit", systemImage: "list.bullet.clipboard") }
                    .tag(AppCoordinator.TabSelection.audit)

                ExportView(appCoordinator: appCoordinator)
                    .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
                    .tag(AppCoordinator.TabSelection.export)
            }
        }
    }
}
