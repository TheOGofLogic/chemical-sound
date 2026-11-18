import SwiftUI

public struct SampleSetupView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    @ObservedObject private var coordinator: AcquisitionCoordinator
    @ObservedObject private var stateMachine: AcquisitionStateMachine
    @ObservedObject private var timing: TimingController

    @State private var containerIDText: String = "PP_01"
    @State private var formulationIDText: String = "H2O_DIST"
    @State private var batchIDText: String = "B01"
    @State private var blindCodeText: String = ""
    @State private var volumeMLText: String = "15.0"
    @State private var massGText: String = "15.00"
    @State private var fillHeightMMText: String = "42.0"
    @State private var headspaceMMText: String = "15.0"
    @State private var tempCText: String = "22.0"
    @State private var notesText: String = ""
    @State private var validationMessage: String?

    public init(appCoordinator: AppCoordinator) {
        self.appCoordinator = appCoordinator
        self.coordinator = appCoordinator.acquisitionCoordinator
        self.stateMachine = appCoordinator.acquisitionCoordinator.stateMachine
        self.timing = appCoordinator.acquisitionCoordinator.timing
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Stage & Excitation") {
                    Picker("Scan Stage", selection: $appCoordinator.draftMetadata.scanStage) {
                        ForEach(ScanStage.allCases, id: \.self) { st in
                            Text(st.rawValue).tag(st)
                        }
                    }
                    Picker("Excitation Waveform", selection: $appCoordinator.draftMetadata.excitationSignal) {
                        ForEach(ExcitationSignalChoice.allCases, id: \.self) { sig in
                            Text(sig.rawValue).tag(sig)
                        }
                    }
                    TextField("Physical Sample ID", text: $appCoordinator.draftMetadata.sampleID)
                    Toggle("Blinded Run", isOn: $appCoordinator.draftMetadata.isBlindedRun)
                    if appCoordinator.draftMetadata.isBlindedRun {
                        TextField("Opaque Blind Code", text: $blindCodeText)
                    } else {
                        TextField("Formulation ID (e.g. H2O_DIST, OIL_VEG)", text: $formulationIDText)
                        TextField("Preparation Batch ID", text: $batchIDText)
                    }
                }

                Section("Vessel, Boundary & Bubble Controls") {
                    TextField("Container ID", text: $containerIDText)
                    Toggle("Reserved Unseen Holdout Container", isOn: $appCoordinator.draftMetadata.isHeldOutContainer)
                    TextField("Nominal Volume (mL)", text: $volumeMLText)
                    TextField("Measured Mass (g)", text: $massGText)
                    TextField("Fill Height (mm)", text: $fillHeightMMText)
                    TextField("Headspace Height (mm)", text: $headspaceMMText)
                    TextField("Sample Temperature (°C)", text: $tempCText)
                    Picker("Bubble / Foam Inspection", selection: $appCoordinator.draftMetadata.bubbleFoamFlag) {
                        Text("NONE").tag("NONE")
                        Text("TRACE_WALL").tag("TRACE_WALL")
                        Text("VISIBLE_BUBBLES (Reject)").tag("VISIBLE_BUBBLES")
                    }
                }

                Section("Milestone 3C Adjustable Mode B Fixture") {
                    TextField("Coupling Force Setting", text: $appCoordinator.draftMetadata.couplingForceSetting)
                    Toggle("Fixture Seating & Baffle Confirmed", isOn: $appCoordinator.draftMetadata.positionConfirmed)
                    TextField("Pad / Compression / Baffle Notes", text: $notesText)
                }

                Section("Settling & Arming") {
                    if stateMachine.state == .settling {
                        LabeledContent("Settling Countdown", value: "\(timing.remainingSettleSeconds) s")
                    }
                    if let msg = validationMessage {
                        Text(msg).font(.footnote).foregroundStyle(.red)
                    }

                    Button("Start Post-Fill Settling & Arm Instrument") {
                        syncDraftFields()
                        Task {
                            do {
                                validationMessage = nil
                                let localMeta = appCoordinator.draftMetadata
                                let settleOverride = (localMeta.scanStage == .gate0A) ? 0 : nil
                                appCoordinator.draftMetadata = try await coordinator.acceptSampleAndRunSettling(
                                    metadata: localMeta,
                                    overrideSettleSeconds: settleOverride
                                )
                                appCoordinator.selectedTab = .acquisition
                            } catch {
                                validationMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(stateMachine.state != .readyForSample)
                }
            }
            .navigationTitle("Sample & Fixture")
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func syncDraftFields() {
        appCoordinator.draftMetadata.containerID = containerIDText
        appCoordinator.draftMetadata.blindCode = blindCodeText.isEmpty ? nil : blindCodeText
        appCoordinator.draftMetadata.formulationID = appCoordinator.draftMetadata.isBlindedRun ? nil : formulationIDText
        appCoordinator.draftMetadata.preparationBatchID = appCoordinator.draftMetadata.isBlindedRun ? nil : batchIDText
        appCoordinator.draftMetadata.nominalVolumeML = Double(volumeMLText)
        appCoordinator.draftMetadata.measuredMassG = Double(massGText)
        appCoordinator.draftMetadata.fillHeightMM = Double(fillHeightMMText)
        appCoordinator.draftMetadata.headspaceHeightMM = Double(headspaceMMText)
        appCoordinator.draftMetadata.sampleTemperatureC = Double(tempCText)
        appCoordinator.draftMetadata.operatorNotes = notesText.isEmpty ? nil : notesText
    }
}
