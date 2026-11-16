import SwiftUI

public struct AcquisitionView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    @ObservedObject private var coordinator: AcquisitionCoordinator
    @ObservedObject private var stateMachine: AcquisitionStateMachine
    @ObservedObject private var repetitions: RepetitionManager
    @ObservedObject private var timing: TimingController

    public init(appCoordinator: AppCoordinator) {
        self.appCoordinator = appCoordinator
        self.coordinator = appCoordinator.acquisitionCoordinator
        self.stateMachine = appCoordinator.acquisitionCoordinator.stateMachine
        self.repetitions = appCoordinator.acquisitionCoordinator.repetitions
        self.timing = appCoordinator.acquisitionCoordinator.timing
    }

    public var body: some View {
        NavigationStack {
            List {
                if stateMachine.state.isActivelyAcquiring {
                    Section {
                        Label("MICROPHONE ACTIVE — Remain silent and stationary", systemImage: "mic.fill")
                            .foregroundStyle(.red)
                            .font(.headline)
                    }
                }

                Section("Batch Progress (\(appCoordinator.draftMetadata.sampleID))") {
                    LabeledContent("State Machine", value: stateMachine.state.rawValue)
                    LabeledContent("Excitation Asset", value: appCoordinator.draftMetadata.excitationSignal.rawValue)
                    LabeledContent(
                        "Provisionally Accepted",
                        value: "\(repetitions.acceptedRepetitions) / \(coordinator.protocolConfiguration.requiredAcceptedRepetitions)"
                    )
                    LabeledContent("Total Attempted", value: "\(repetitions.attemptedRepetitions)")
                    if timing.remainingCooldownMilliseconds > 0 {
                        LabeledContent("Thermal Cooldown", value: "\(timing.remainingCooldownMilliseconds) ms")
                    }
                }

                if !stateMachine.activeQualityFlags.isEmpty || stateMachine.lastFailure != nil {
                    Section("Immediate QC Status") {
                        if let failure = stateMachine.lastFailure {
                            Text(failure.localizedDescription)
                                .foregroundStyle(.red)
                        }
                        ForEach(Array(stateMachine.activeQualityFlags), id: \.rawValue) { flag in
                            Text("Flag: \(flag.rawValue)")
                                .font(.footnote.monospaced())
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Acquisition Controls") {
                    Button("Acquire Single Repetition") {
                        Task {
                            await coordinator.acquireRepetition(metadata: appCoordinator.draftMetadata)
                        }
                    }
                    .disabled(stateMachine.state != .armed)

                    if stateMachine.state == .repetitionAccepted || stateMachine.state == .repetitionRejected {
                        Button("Arm Next Repetition") {
                            try? coordinator.requestNextRepetition()
                        }
                    }

                    if stateMachine.state == .batchComplete || stateMachine.state == .repetitionAccepted {
                        Button("Prepare Next Physical Sample") {
                            try? coordinator.prepareForAnotherSample()
                            appCoordinator.selectedTab = .sample
                        }
                    }
                }

                Section("Scientific Notice") {
                    Text("On-device liquid classification is intentionally disabled in Milestone 3. Export the completed session bundle for Python reference analysis.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Acquisition")
        }
    }
}
