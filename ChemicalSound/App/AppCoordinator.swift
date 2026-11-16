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
    private let notificationMonitor = AudioNotificationMonitor()

    public init(acquisitionCoordinator: AcquisitionCoordinator? = nil) {
        let initialDraft = SampleMetadata(
            studyID: "CS_M3B_BENCH",
            sessionID: "SESS_001",
            operatorID: "OP_01",
            sampleID: "SMP_0001"
        )
        self.draftMetadata = initialDraft

        if let acquisitionCoordinator {
            self.acquisitionCoordinator = acquisitionCoordinator
        } else {
            let logger = AuditLogger()
            let machine = AcquisitionStateMachine(auditLogger: logger)
            self.acquisitionCoordinator = AcquisitionCoordinator(
                stateMachine: machine,
                auditLogger: logger
            )
        }

        bindNotifications()
    }

    public func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase != .active {
            acquisitionCoordinator.handleAppBackgrounded()
        }
    }

    private func bindNotifications() {
        notificationMonitor.onRouteChange = { [weak self] in
            self?.acquisitionCoordinator.handleRouteChange()
        }
        notificationMonitor.onInterruptionBegan = { [weak self] in
            self?.acquisitionCoordinator.handleAudioInterruption()
        }
        notificationMonitor.onMediaServicesReset = { [weak self] in
            self?.acquisitionCoordinator.handleAudioInterruption()
        }
        notificationMonitor.start()
    }
}
