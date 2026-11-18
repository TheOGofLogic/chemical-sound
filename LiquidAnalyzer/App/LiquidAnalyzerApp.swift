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
            ConsumerRootView(appCoordinator: appCoordinator)
                .onChange(of: scenePhase) { _, newPhase in
                    appCoordinator.handleScenePhaseChange(newPhase)
                }
        }
    }
}
