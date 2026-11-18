import Combine
import Foundation
import SwiftUI

@MainActor
public final class AppCoordinator: ObservableObject {
    public enum TabSelection: Hashable {
        case setup
        case calibration
        case sample
        case acquisition
        case audit
        case export
    }

    @Published public var selectedTab: TabSelection = .setup
    @Published public var draftMetadata: SampleMetadata

    public let acquisitionCoordinator: AcquisitionCoordinator
    public let consumerCoordinator: ConsumerScanCoordinator
    private let notificationMonitor = AudioNotificationMonitor()

    public init(
        acquisitionCoordinator: AcquisitionCoordinator? = nil,
        consumerCoordinator: ConsumerScanCoordinator? = nil
    ) {
        let initialDraft = SampleMetadata(
            studyID: "LA_M3B_BENCH",
            sessionID: "SESS_001",
            operatorID: "OP_01",
            sampleID: "SMP_0001"
        )
        self.draftMetadata = initialDraft

        let resolvedAcquisition: AcquisitionCoordinator
        if let acquisitionCoordinator {
            resolvedAcquisition = acquisitionCoordinator
        } else {
            let logger = AuditLogger()
            let machine = AcquisitionStateMachine(auditLogger: logger)
            resolvedAcquisition = AcquisitionCoordinator(
                stateMachine: machine,
                auditLogger: logger
            )
        }
        self.acquisitionCoordinator = resolvedAcquisition
        self.consumerCoordinator = consumerCoordinator ?? ConsumerScanCoordinator(
            researchCoordinator: resolvedAcquisition
        )

        bindNotifications()
    }

    public func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase != .active {
            acquisitionCoordinator.handleAppBackgrounded()
            if case .scanning = consumerCoordinator.flowStep {
                consumerCoordinator.cancelActiveScan()
            }
            consumerCoordinator.tunePlayer.stop()
        }
    }

    private func bindNotifications() {
        notificationMonitor.onRouteChange = { [weak self] in
            guard let self else { return }
            self.acquisitionCoordinator.handleRouteChange()
            if case .scanning = self.consumerCoordinator.flowStep {
                self.consumerCoordinator.cancelActiveScan()
            }
        }
        notificationMonitor.onInterruptionBegan = { [weak self] in
            guard let self else { return }
            self.acquisitionCoordinator.handleAudioInterruption()
            if case .scanning = self.consumerCoordinator.flowStep {
                self.consumerCoordinator.cancelActiveScan()
            }
            self.consumerCoordinator.tunePlayer.stop()
        }
        notificationMonitor.onMediaServicesReset = { [weak self] in
            guard let self else { return }
            self.acquisitionCoordinator.handleAudioInterruption()
            if case .scanning = self.consumerCoordinator.flowStep {
                self.consumerCoordinator.cancelActiveScan()
            }
            self.consumerCoordinator.tunePlayer.stop()
        }
        notificationMonitor.start()
    }
}
