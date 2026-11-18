import SwiftUI

public struct StudySetupView: View {
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
                Section("Research Disclaimer") {
                    Text("Liquid Analyzer is an experimental acoustic response measurement instrument (CS-SPEC-P1-v1.2). It does not determine molecular composition, purity, potability, toxicity, or safety.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Study & Session Identifiers") {
                    TextField("Study ID", text: $appCoordinator.draftMetadata.studyID)
                    TextField("Session ID", text: $appCoordinator.draftMetadata.sessionID)
                    TextField("Operator ID", text: $appCoordinator.draftMetadata.operatorID)
                    TextField("Room Identifier", text: $appCoordinator.draftMetadata.roomIdentifier)
                    TextField("Fixture Version", text: $appCoordinator.draftMetadata.fixtureVersion)
                }

                Section("State & Configuration Control") {
                    LabeledContent("Current State", value: stateMachine.state.rawValue)
                    if let failure = stateMachine.lastFailure {
                        Text(failure.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button("Verify Waveforms & Configure Audio Session") {
                        Task {
                            await coordinator.configure(sessionID: appCoordinator.draftMetadata.sessionID)
                        }
                    }
                    .disabled(!stateMachine.state.permitsAudioSessionReconfiguration)

                    if stateMachine.state == .interrupted {
                        Button("Recover Interrupted Session") {
                            Task {
                                await coordinator.recoverFromInterruption(
                                    sessionID: appCoordinator.draftMetadata.sessionID
                                )
                            }
                        }
                    }

                    Button("Refresh Runtime Hardware Snapshot") {
                        Task { await coordinator.refreshRuntimeProfile() }
                    }
                }

                if let profile = coordinator.latestRuntimeProfile {
                    Section("Milestone 3B: Requested vs. Verified Runtime Profile") {
                        LabeledContent("Device Model", value: "\(profile.commercialModelName) (\(profile.hardwareModelIdentifier))")
                        LabeledContent("Research Device Code", value: profile.deviceCode)
                        LabeledContent("Mode (Req / Act)", value: "\(profile.requestedMode) / \(profile.actualMode)")
                        LabeledContent(
                            "Sample Rate (Req / Act)",
                            value: "\(Int(profile.requestedSampleRate)) / \(Int(profile.actualSampleRate)) Hz"
                        )
                        LabeledContent(
                            "Channels (In / Out)",
                            value: "\(profile.inputChannelCount) / \(profile.outputChannelCount)"
                        )
                        LabeledContent("Active Input Ports", value: profile.inputPortNames.joined(separator: ", "))
                        LabeledContent("Active Output Ports", value: profile.outputPortNames.joined(separator: ", "))
                        LabeledContent("Mic Data Source", value: profile.selectedInputDataSource ?? "Default")
                        LabeledContent("Polar Pattern", value: profile.selectedPolarPattern ?? "Unsupported/Default")
                        LabeledContent(
                            "Latency (In / Out / Buf)",
                            value: String(
                                format: "%.2f / %.2f / %.2f ms",
                                profile.inputLatencySeconds * 1_000,
                                profile.outputLatencySeconds * 1_000,
                                profile.ioBufferDurationSeconds * 1_000
                            )
                        )
                        LabeledContent(
                            "Output Volume (Target \(String(format: "%.2f", coordinator.protocolConfiguration.targetOutputVolume)))",
                            value: String(format: "%.3f", profile.outputVolume)
                        )
                        LabeledContent("Thermal / Charging", value: "\(profile.thermalState) / \(profile.chargingState)")
                    }
                }
            }
            .navigationTitle("Study & Audio Setup")
            .scrollDismissesKeyboard(.interactively)
        }
    }
}
