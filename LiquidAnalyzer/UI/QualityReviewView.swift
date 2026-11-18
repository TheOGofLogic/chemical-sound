import SwiftUI

public struct QualityReviewView: View {
    @ObservedObject var appCoordinator: AppCoordinator
    @ObservedObject private var coordinator: AcquisitionCoordinator

    public init(appCoordinator: AppCoordinator) {
        self.appCoordinator = appCoordinator
        self.coordinator = appCoordinator.acquisitionCoordinator
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Session Summary (\(appCoordinator.draftMetadata.sessionID))") {
                    let total = coordinator.sessionRecords.count
                    let accepted = coordinator.sessionRecords.filter { $0.qualityStatus == "PROVISIONALLY_ACCEPTED" }.count
                    LabeledContent("Total Recorded Scans", value: "\(total)")
                    LabeledContent("Provisionally Accepted", value: "\(accepted)")
                    LabeledContent("Rejected / Invalid (Preserved in Audit)", value: "\(total - accepted)")
                    LabeledContent("Session Drift Validity", value: coordinator.calibration.sessionValidityState)
                }

                Section("Immutable Scan Audit Log") {
                    if coordinator.sessionRecords.isEmpty {
                        Text("No recordings committed in this session yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(coordinator.sessionRecords) { rec in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(rec.sampleID) [Rep \(rec.repetitionNumber)]")
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text(rec.qualityStatus)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(rec.qualityStatus == "PROVISIONALLY_ACCEPTED" ? .green : .red)
                                }
                                Text(
                                    String(
                                        format: "Signal: %@ | Peak: %.1f dBFS | Pre-roll: %.1f dBFS | Final: %@",
                                        rec.excitationSignalID ?? "-",
                                        rec.peakDBFS ?? -120.0,
                                        rec.preRollRMSDBFS ?? -120.0,
                                        rec.finalScanValidity
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                if !rec.qualityFlags.isEmpty {
                                    Text("Flags: \(rec.qualityFlags.joined(separator: ", "))")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("QC Audit")
        }
    }
}
