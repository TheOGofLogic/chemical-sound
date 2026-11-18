import AVFAudio
import Foundation

@MainActor
public final class AudioNotificationMonitor {
    private var observers: [NSObjectProtocol] = []

    public var onRouteChange: (() -> Void)?
    public var onInterruptionBegan: (() -> Void)?
    public var onMediaServicesReset: (() -> Void)?

    public init() {}

    public func start() {
        stop()
        #if os(iOS)
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // Only treat physical device plug/unplug as an external route change;
                // ignore programmatic .categoryChange, .override, and .routeConfigurationChange.
                let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let reason = rawReason.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
                guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else {
                    return
                }
                MainActor.assumeIsolated {
                    self?.onRouteChange?()
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                    AVAudioSession.InterruptionType(rawValue: value) == .began
                else {
                    return
                }
                MainActor.assumeIsolated {
                    self?.onInterruptionBegan?()
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onMediaServicesReset?()
                }
            }
        )
        #endif
    }

    public func stop() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }
}
