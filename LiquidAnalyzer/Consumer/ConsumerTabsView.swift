import SwiftUI
import UniformTypeIdentifiers

/// Unlocked in-memory UTF-8 CSV document for native `fileExporter` ("Save to Files / Downloads") without sandbox tmp locks.
public struct CSVTextDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    public var text: String

    public init(text: String = "") {
        self.text = text
    }

    public init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let decoded = String(data: data, encoding: .utf8) {
            self.text = decoded
        } else {
            self.text = ""
        }
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

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

private struct R1HistoryCohort: Identifiable, Equatable {
    let id: String
    let label: String
    let items: [ConsumerScanItem]
}

public struct ConsumerHistoryView: View {
    @ObservedObject var coordinator: ConsumerScanCoordinator
    @State private var selectedTuneItem: ConsumerScanItem?
    @State private var selectedCohortID: String = ""
    @State private var exporterPresented: Bool = false
    @State private var exporterDocument: CSVTextDocument = CSVTextDocument()
    @State private var exporterFilename: String = "LiquidAnalyzer_R1_cohort.csv"
    @State private var copyStatusBanner: String?

    public init(coordinator: ConsumerScanCoordinator) {
        self.coordinator = coordinator
    }

    private var isolatedCohorts: [R1HistoryCohort] {
        var cohorts: [R1HistoryCohort] = []
        var seenBatchIDs: Set<String> = []

        // 1. Dedicated R1 multi-scan batches (each strictly fixed-geometry)
        for item in coordinator.history {
            if let bID = item.batchRunID, bID.hasPrefix("R1_"), !seenBatchIDs.contains(bID) {
                seenBatchIDs.insert(bID)
                let members = coordinator.history.filter { $0.batchRunID == bID }
                let geomRaw = item.geometryCondition ?? GeometryTestCondition.stationary15InBaseline.rawValue
                let geomTitle = GeometryTestCondition(rawValue: geomRaw)?.displayLabel ?? geomRaw
                let ctrlRaw = item.controlSeriesTag ?? ControlSeriesTag.unlabeledBlind.rawValue
                let ctrlSuffix: String
                if let tag = ControlSeriesTag(rawValue: ctrlRaw), tag != .unlabeledBlind {
                    ctrlSuffix = " • \(tag.displayLabel)"
                } else {
                    ctrlSuffix = ""
                }
                cohorts.append(
                    R1HistoryCohort(
                        id: "BATCH_\(bID)",
                        label: "\(bID) (\(geomTitle)\(ctrlSuffix), \(members.count) scans)",
                        items: members
                    )
                )
            }
        }

        // 2. Geometry-segregated cohorts (NEVER pools 15-in Stationary Baseline with Close-Range or Handheld!)
        for cond in GeometryTestCondition.allCases {
            let matching = coordinator.history.filter {
                ($0.geometryCondition ?? GeometryTestCondition.handheldGeneral.rawValue) == cond.rawValue
            }
            if matching.count >= 2 {
                cohorts.append(
                    R1HistoryCohort(
                        id: "GEOM_\(cond.rawValue)",
                        label: "All \(cond.displayLabel) (\(matching.count) scans)",
                        items: matching
                    )
                )
            }
        }

        return cohorts
    }

    private var activeCohort: R1HistoryCohort? {
        let all = isolatedCohorts
        if let match = all.first(where: { $0.id == selectedCohortID }) {
            return match
        }
        return all.first
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
                        if let cohort = activeCohort {
                            Section("Repeatability Gate R1 Summary (Geometry-Isolated)") {
                                if isolatedCohorts.count > 1 {
                                    Picker(
                                        "Cohort",
                                        selection: Binding(
                                            get: { cohort.id },
                                            set: { selectedCohortID = $0 }
                                        )
                                    ) {
                                        ForEach(isolatedCohorts) { c in
                                            Text(c.label).tag(c.id)
                                        }
                                    }
                                    .font(.caption)
                                }

                                RepeatabilityGateSummaryCard(
                                    items: cohort.items,
                                    copyStatusBanner: copyStatusBanner,
                                    onSaveBatchBaseline: { targetID, targetLabel in
                                        if let saved = coordinator.teachCalibratedBatchBaseline(items: cohort.items, targetID: targetID) {
                                            let nSweeps = saved.steadyStateSweepCount ?? cohort.items.count
                                            copyStatusBanner = "Saved \(targetLabel) baseline (\(nSweeps) steady-state sweeps) & updated shifts ✓"
                                        }
                                    },
                                    onSaveCohortToFiles: {
                                        _ = coordinator.exportRepeatabilityCSVURL(items: cohort.items, filenameSuffix: cohort.id)
                                        exporterDocument = CSVTextDocument(
                                            text: coordinator.exportRepeatabilityCSVText(items: cohort.items)
                                        )
                                        exporterFilename = ConsumerScanCoordinator.sanitizedCSVFilename(suffix: cohort.id)
                                        exporterPresented = true
                                    },
                                    onCopyCohortCSV: {
                                        let count = coordinator.copyRepeatabilityCSVToClipboard(items: cohort.items)
                                        copyStatusBanner = "Copied \(count) scans to clipboard — paste anywhere ✓"
                                    },
                                    onShareCohortCSV: {
                                        coordinator.presentNativeCSVShareSheet(items: cohort.items, filenameSuffix: cohort.id)
                                    },
                                    onSaveFullHistoryToFiles: coordinator.history.count > cohort.items.count ? {
                                        _ = coordinator.exportRepeatabilityCSVURL(items: nil, filenameSuffix: "full_history")
                                        exporterDocument = CSVTextDocument(
                                            text: coordinator.exportRepeatabilityCSVText(items: nil)
                                        )
                                        exporterFilename = ConsumerScanCoordinator.sanitizedCSVFilename(suffix: "full_history")
                                        exporterPresented = true
                                    } : nil
                                )
                            }

                            if cohort.items.count >= 2 {
                                Section("Peak-Stability Test (\(cohort.items.count) Scans • Modal Only)") {
                                    PeakStabilitySummaryCard(
                                        report: RepeatabilityPeakStabilityAnalyzer.analyze(items: cohort.items)
                                    )
                                }
                            }
                        } else if !coordinator.history.isEmpty {
                            Section("Export Repeatability Gate R1 CSV") {
                                Button {
                                    _ = coordinator.exportRepeatabilityCSVURL(items: nil, filenameSuffix: "single_scan")
                                    exporterDocument = CSVTextDocument(
                                        text: coordinator.exportRepeatabilityCSVText(items: nil)
                                    )
                                    exporterFilename = ConsumerScanCoordinator.sanitizedCSVFilename(suffix: "single_scan")
                                    exporterPresented = true
                                } label: {
                                    Label("Download / Save R1 CSV to Files", systemImage: "arrow.down.doc.fill")
                                        .font(.caption.weight(.bold))
                                }
                                .buttonStyle(.borderless)

                                Button {
                                    let count = coordinator.copyRepeatabilityCSVToClipboard(items: nil)
                                    copyStatusBanner = "Copied \(count) scan(s) to clipboard — paste anywhere ✓"
                                } label: {
                                    Label("Copy R1 CSV to Clipboard", systemImage: "doc.on.doc.fill")
                                        .font(.caption.weight(.bold))
                                }
                                .buttonStyle(.borderless)

                                Button {
                                    coordinator.presentNativeCSVShareSheet(items: nil, filenameSuffix: "single_scan")
                                } label: {
                                    Label("Share R1 CSV...", systemImage: "square.and.arrow.up")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.borderless)

                                if let copyStatusBanner {
                                    Text(copyStatusBanner)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(LiquidAnalyzerPalette.resultGreenStart)
                                }
                            }
                        }

                        Section("Recorded Scans (\(coordinator.history.count))") {
                            ForEach(coordinator.history) { item in
                                Button(action: {
                                    coordinator.openHistoryItem(item)
                                }) {
                                    HStack(spacing: 14) {
                                        ZStack {
                                            Circle()
                                                .fill(
                                                    statusAccentColor(for: item.status).opacity(0.14)
                                                )
                                                .frame(width: 46, height: 46)

                                            Image(systemName: statusIconName(for: item.status))
                                                .font(.system(size: 20, weight: .semibold))
                                                .foregroundStyle(statusAccentColor(for: item.status))
                                        }

                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 6) {
                                                if let seq = item.scanSequenceNumber {
                                                    Text("#\(seq)")
                                                        .font(.caption.weight(.bold).monospaced())
                                                        .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                                                }
                                                Text(item.title)
                                                    .font(.headline)
                                                    .foregroundStyle(.primary)
                                            }
                                            Text(
                                                String(
                                                    format: "%.1f Hz pk • %.0f Hz cent%@ • %@",
                                                    item.measuredPeakHz,
                                                    item.measuredCentroidHz,
                                                    item.topCandidateName.map { " • #1 \($0)" } ?? "",
                                                    item.scannedAt.formatted(date: .omitted, time: .standard)
                                                )
                                            )
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)

                                            if let reason = item.rejectionReason, !reason.isEmpty {
                                                Text(reason)
                                                    .font(.system(size: 9.5, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
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
            }
            .navigationTitle("History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
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
            .fileExporter(
                isPresented: $exporterPresented,
                document: exporterDocument,
                contentType: .commaSeparatedText,
                defaultFilename: exporterFilename
            ) { result in
                switch result {
                case .success(let savedURL):
                    copyStatusBanner = "Saved \(savedURL.lastPathComponent) ✓"
                case .failure(let error):
                    copyStatusBanner = "Use Copy CSV or Files -> Liquid Analyzer -> R1_Exports (\(error.localizedDescription))"
                }
            }
        }
    }

    private func statusIconName(for status: ConsumerMatchStatus) -> String {
        switch status {
        case .referenceMatch:
            return "checkmark.circle.fill"
        case .unmatchedSignature:
            return "waveform"
        case .emptyContainer:
            return "cup.and.saucer.fill"
        case .nonLiquidMaterial:
            return "cube.fill"
        case .unclearScan:
            return "exclamationmark.triangle.fill"
        }
    }

    private func statusAccentColor(for status: ConsumerMatchStatus) -> Color {
        switch status {
        case .referenceMatch:
            return LiquidAnalyzerPalette.resultGreenStart
        case .unmatchedSignature, .emptyContainer:
            return LiquidAnalyzerPalette.scanBlue
        case .nonLiquidMaterial, .unclearScan:
            return LiquidAnalyzerPalette.compositionOrange
        }
    }
}

private struct RepeatabilityGateSummaryCard: View {
    let items: [ConsumerScanItem]
    let copyStatusBanner: String?
    let onSaveBatchBaseline: (String, String) -> Void
    let onSaveCohortToFiles: () -> Void
    let onCopyCohortCSV: () -> Void
    let onShareCohortCSV: () -> Void
    let onSaveFullHistoryToFiles: (() -> Void)?

    var body: some View {
        let validItems = items.filter { $0.status != .unclearScan && $0.status != .nonLiquidMaterial }
        let rejectedCount = items.count - validItems.count
        let statSource = validItems.isEmpty ? items : validItems

        let peaks = statSource.map(\.measuredPeakHz)
        let centroids = statSource.map(\.measuredCentroidHz)
        let amps = statSource.compactMap { $0.measuredFeatures?.activeRMSDBFS }
        let echos = statSource.compactMap { $0.measuredFeatures?.echoReturnDB }
        let tailSNRs = statSource.compactMap { $0.measuredFeatures?.tailSNRDB }

        let (pkMean, pkSD, pkMin, pkMax) = Self.stats(peaks)
        let (ctMean, ctSD, _, _) = Self.stats(centroids)
        let (ampMean, ampSD, _, _) = Self.stats(amps)
        let (ecMean, ecSD, _, _) = Self.stats(echos)
        let (tsMean, _, _, _) = Self.stats(tailSNRs)

        var topCounts: [String: Int] = [:]
        for name in statSource.compactMap(\.topCandidateName) {
            topCounts[name, default: 0] += 1
        }
        let dominantTop = topCounts.max { $0.value < $1.value }

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Valid / Total Scans")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(validItems.count) / \(items.count) valid (\(rejectedCount) rejected)")
                    .fontWeight(.semibold)
            }
            HStack {
                Text("Primary Peak Hz")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f ± %.1f Hz (%.0f–%.0f)", pkMean, pkSD, pkMin, pkMax))
                    .fontWeight(.semibold)
            }
            HStack {
                Text("Centroid Hz")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f ± %.1f Hz", ctMean, ctSD))
                    .fontWeight(.semibold)
            }
            if !amps.isEmpty {
                HStack {
                    Text("Amp / Echo / TailSNR")
                    .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f±%.1f dBFS • %.1f±%.1f dB • %.1f dB", ampMean, ampSD, ecMean, ecSD, tsMean))
                        .fontWeight(.medium)
                }
            }
            if let dom = dominantTop {
                HStack {
                    Text("Top Raw Candidate")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(dom.key) (\(dom.value)/\(statSource.count) valid)")
                        .fontWeight(.semibold)
                }
            }
            VStack(spacing: 6) {
                Menu {
                    Button {
                        onSaveBatchBaseline(CalibratedAcousticPrototype.emptyContainerTargetID, "Empty Container")
                    } label: {
                        Label("Empty Container Baseline (Sweeps 3–20)", systemImage: "cup.and.saucer")
                    }
                    Button {
                        onSaveBatchBaseline(CalibratedAcousticPrototype.waterReferenceTargetID, "Water Reference")
                    } label: {
                        Label("Water Reference Baseline (Sweeps 3–20)", systemImage: "drop.fill")
                    }
                    Button {
                        onSaveBatchBaseline(CalibratedAcousticPrototype.solidSurfaceTargetID, "Solid Surface")
                    } label: {
                        Label("Solid Surface Baseline (Sweeps 3–20)", systemImage: "cube.fill")
                    }
                    Divider()
                    Menu("Known Liquid Standard (Sweeps 3–20)...") {
                        ForEach(ReferenceLiquidProfile.provisionalLibrary) { profile in
                            Button {
                                onSaveBatchBaseline(profile.id, profile.displayName)
                            } label: {
                                Text("\(profile.displayName) (\(profile.formulaDisplay))")
                            }
                        }
                    }
                } label: {
                    Label("Save Steady-State (Sweeps 3–20) as Baseline", systemImage: "scope")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LiquidAnalyzerPalette.resultGreenStart)
                        )
                }
                .buttonStyle(.borderless)

                Button(action: onSaveCohortToFiles) {
                    Label("Download / Save Cohort R1 CSV", systemImage: "arrow.down.doc.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LiquidAnalyzerPalette.scanBlue)
                        )
                }
                .buttonStyle(.borderless)

                HStack(spacing: 8) {
                    Button(action: onCopyCohortCSV) {
                        Label("Copy Cohort CSV", systemImage: "doc.on.doc.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(LiquidAnalyzerPalette.scanBlue.opacity(0.12))
                            )
                    }
                    .buttonStyle(.borderless)

                    Button(action: onShareCohortCSV) {
                        Label("Share CSV...", systemImage: "square.and.arrow.up")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(LiquidAnalyzerPalette.scanBlue.opacity(0.12))
                            )
                    }
                    .buttonStyle(.borderless)
                }

                if let onSaveFullHistoryToFiles {
                    Button(action: onSaveFullHistoryToFiles) {
                        Label("Save Full History CSV", systemImage: "folder.badge.plus")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LiquidAnalyzerPalette.scanBlue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderless)
                }

                if let copyStatusBanner {
                    Text(copyStatusBanner)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(LiquidAnalyzerPalette.resultGreenStart)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Text("Unlocked CSVs are also auto-saved in Files → On My Device → Liquid Analyzer → R1_Exports")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.top, 4)
        }
        .font(.caption.monospaced())
        .padding(.vertical, 4)
    }

    private static func stats(_ values: [Double]) -> (mean: Double, sd: Double, min: Double, max: Double) {
        guard !values.isEmpty else { return (0, 0, 0, 0) }
        let n = Double(values.count)
        let mean = values.reduce(0.0, +) / n
        let variance = values.count > 1
            ? values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1.0)
            : 0.0
        return (mean, sqrt(max(0.0, variance)), values.min() ?? mean, values.max() ?? mean)
    }
}

private struct PeakStabilitySummaryCard: View {
    let report: RepeatabilityPeakStabilityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Modal Stability")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(report.stabilityDisposition) (CV \(String(format: "%.2f%%", report.primaryPeakCVPercent)))")
                    .fontWeight(.bold)
            }

            bandRow(
                title: "A. Persistent",
                bands: report.persistentBands
            )
            bandRow(
                title: "B. Intermittent",
                bands: report.intermittentBands
            )
            bandRow(
                title: "C. Harmonics",
                bands: report.harmonicOrSubharmonicBands
            )
            bandRow(
                title: "D. Transients",
                bands: report.isolatedTransientBands
            )

            HStack(alignment: .top) {
                Text("E. Low-SNR / QC")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(
                    report.lowConfidenceNoisyScans.isEmpty
                        ? "0 scans"
                        : "\(report.lowConfidenceNoisyScans.count) scan(s): " +
                          report.lowConfidenceNoisyScans.prefix(3).map { "#\($0.scanSequenceNumber ?? $0.batchScanIndex ?? 0) (\($0.reason))" }.joined(separator: "; ")
                )
                .multilineTextAlignment(.trailing)
            }

            Text("Modal persistence diagnostic only — never converted into chemical identity.")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .font(.caption2.monospaced())
        .padding(.vertical, 4)
    }

    private func bandRow(title: String, bands: [TrackedSpectralBand]) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            if bands.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    bands.prefix(3).map { b in
                        let extra = b.harmonicRelationNote.map { " [\($0)]" } ?? ""
                        return String(format: "%.0f±%.0f Hz (%d/%d)%@", b.centerMeanHz, b.centerSDHz, b.presenceCount, b.validScanCount, extra)
                    }.joined(separator: "; ")
                )
                .multilineTextAlignment(.trailing)
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
    @State private var showModeBLab = false

    public init(appCoordinator: AppCoordinator, consumer: ConsumerScanCoordinator) {
        self.appCoordinator = appCoordinator
        self.consumer = consumer
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Experience") {
                    Toggle("Voice Result Announcements", isOn: $consumer.voiceAnnouncementsEnabled)
                    Toggle("Auto-Scan When Held Steady", isOn: $consumer.autoScanWhenSteady)
                    Toggle("Auto-Play Chemical Tune on Open", isOn: $consumer.autoPlayTunePreview)
                    Toggle("Vibration Feedback", isOn: $consumer.hapticsEnabled)
                }

                Section("Calibrated Standards") {
                    Picker("Inference Engine", selection: $consumer.selectedInferenceMode) {
                        ForEach(ConsumerInferenceMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayTitle).tag(mode)
                        }
                    }
                    LabeledContent("Saved Acoustic Standards", value: "\(consumer.calibratedPrototypes.count)")
                    Button {
                        consumer.selectedTab = .scan
                        DispatchQueue.main.async {
                            consumer.openGuidedComparatorWizard()
                        }
                    } label: {
                        Label("Open 3-Step Cup Comparator", systemImage: "checklist.checked")
                    }
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
                        showModeBLab = true
                    } label: {
                        Label("MODE_B Ultrasonic A-Scan Lab (Simulator)", systemImage: "waveform.path.ecg.rectangle")
                    }
                    Button {
                        showResearchConfirmation = true
                    } label: {
                        Label("Research & Developer Mode", systemImage: "flask")
                    }
                }

                Section("About") {
                    LabeledContent("Application", value: "Liquid Analyzer")
                    LabeledContent(
                        "Version",
                        value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.5.0") (Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "21") • Multi-Modal Fusion)"
                    )
                }
            }
            .navigationTitle("More")
            .sheet(isPresented: $showModeBLab) {
                ModeBAScanSimulatorView()
            }
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
