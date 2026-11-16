import SwiftUI

public struct CalibrationView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    @ObservedObject private var coordinator: AcquisitionCoordinator
    @ObservedObject private var stateMachine: AcquisitionStateMachine
    @ObservedObject private var calibration: CalibrationManager

    public init(appCoordinator: AppCoordinator) {
        self.appCoordinator = appCoordinator
        self.coordinator = appCoordinator.acquisitionCoordinator
        self.stateMachine = appCoordinator.acquisitionCoordinator.stateMachine
        self.calibration = appCoordinator.acquisitionCoordinator.calibration
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Session Calibration State") {
                    LabeledContent("Acquisition State", value: stateMachine.state.rawValue)
                    LabeledContent("Session Validity", value: calibration.sessionValidityState)
                    if let sil = calibration.silenceBaselineRMSDBFS {
                        LabeledContent("Silence Floor", value: String(format: "%.1f dBFS", sil))
                    }
                    if let failure = stateMachine.lastFailure {
                        Text(failure.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Start-of-Session Calibration (Mandatory)") {
                    ForEach(CalibrationStepKind.requiredStartSteps) { step in
                        calibrationRow(for: step)
                    }

                    Button("Acknowledge Calibration & Unlock Sample Entry") {
                        try? coordinator.acknowledgeCalibration()
                        if stateMachine.state == .readyForSample {
                            appCoordinator.selectedTab = .sample
                        }
                    }
                    .disabled(!calibration.hasPassedInitialCalibration || stateMachine.state != .calibrationPassed)
                }

                Section("Periodic & End-of-Session Drift Checks (CAL_END)") {
                    calibrationRow(for: .periodicWaterCheck)
                    ForEach(CalibrationStepKind.requiredEndSteps) { step in
                        calibrationRow(for: step)
                    }
                }
            }
            .navigationTitle("Calibration")
        }
    }

    @ViewBuilder
    private func calibrationRow(for step: CalibrationStepKind) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(step.rawValue)
                    .font(.subheadline.monospaced())
                Text(calibration.completedSteps.contains(step) ? "Provisionally Accepted" : "Pending")
                    .font(.caption)
                    .foregroundStyle(calibration.completedSteps.contains(step) ? .green : .secondary)
            }
            Spacer()
            Button("Acquire") {
                let meta = appCoordinator.draftMetadata
                Task {
                    await coordinator.runCalibrationStep(
                        step,
                        studyID: meta.studyID,
                        sessionID: meta.sessionID,
                        operatorID: meta.operatorID,
                        roomIdentifier: meta.roomIdentifier,
                        fixtureVersion: meta.fixtureVersion
                    )
                }
            }
            .buttonStyle(.bordered)
            .disabled(stateMachine.state.isActivelyAcquiring || stateMachine.state == .unconfigured)
        }
    }
}
