import SwiftUI

#if canImport(UIKit)
@main
#endif
public struct LiquidAnalyzerApp: App {
    @StateObject private var appCoordinator = AppCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some Scene {
        WindowGroup {
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
            .onChange(of: scenePhase) { _, newPhase in
                appCoordinator.handleScenePhaseChange(newPhase)
            }
        }
    }
}
