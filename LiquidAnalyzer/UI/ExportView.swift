import SwiftUI

public struct ExportView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    @ObservedObject private var coordinator: AcquisitionCoordinator
    @ObservedObject private var stateMachine: AcquisitionStateMachine

    public init(appCoordinator: AppCoordinator) {
        self.appCoordinator = appCoordinator
        self.coordinator = appCoordinator.acquisitionCoordinator
        self.stateMachine = appCoordinator.acquisitionCoordinator.stateMachine
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Bundle Readiness") {
                    LabeledContent("Acquisition State", value: stateMachine.state.rawValue)
                    LabeledContent("Session Validity", value: coordinator.calibration.sessionValidityState)
                    LabeledContent("Recorded Scans", value: "\(coordinator.sessionRecords.count)")

                    if !coordinator.calibration.hasCompletedFinalCalibration {
                        Text("Tip: Complete CAL_END water & empty-container checks in the Calibration tab before final export so provisional scans can be promoted to SESSION_VALID.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Package & Verify CSRD-P1 Bundle") {
                    Button("Build & SHA-256-Verify Export Bundle") {
                        let meta = appCoordinator.draftMetadata
                        Task {
                            await coordinator.exportSession(
                                studyID: meta.studyID,
                                sessionID: meta.sessionID
                            )
                        }
                    }
                    .disabled(
                        coordinator.sessionRecords.isEmpty ||
                        (stateMachine.state != .batchComplete && stateMachine.state != .readyForSample)
                    )

                    if let bundleURL = coordinator.lastExportedBundleURL {
                        LabeledContent("Verified Bundle", value: bundleURL.lastPathComponent)
                        ShareLink(item: bundleURL) {
                            Label("Share / AirDrop CSRD-P1 Bundle to Python", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle("Export")
        }
    }
}
