import Foundation

/// Enforces pre-roll, post-roll, 3-minute post-fill settling, and inter-excitation cooldown invariants.
@MainActor
public final class TimingController: ObservableObject {
    @Published public private(set) var remainingSettleSeconds: Int = 0
    @Published public private(set) var remainingCooldownMilliseconds: Int = 0
    public private(set) var lastExcitationEndUptime: Double?

    public init() {}

    public func recordExcitationCompleted(atUptime uptime: Double) {
        lastExcitationEndUptime = uptime
    }

    public func verifyCooldownSatisfied(
        currentUptime: Double = ProcessInfo.processInfo.systemUptime,
        cooldownMs: Int
    ) throws {
        guard let lastEnd = lastExcitationEndUptime else { return }
        let requiredSec = Double(cooldownMs) / 1_000.0
        let elapsed = currentUptime - lastEnd
        if elapsed < (requiredSec - 1e-4) {
            let remMs = Int(ceil((requiredSec - elapsed) * 1_000.0))
            throw AcquisitionFailure.cooldownViolation(remainingMs: max(1, remMs))
        }
    }

    public func sleepMilliseconds(_ milliseconds: Int) async throws {
        guard milliseconds > 0 else { return }
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    public func runCooldown(fromExcitationEndUptime endUptime: Double, cooldownMs: Int) async throws {
        recordExcitationCompleted(atUptime: endUptime)
        let targetUptime = endUptime + Double(cooldownMs) / 1_000.0
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            let rem = targetUptime - now
            if rem <= 0 {
                remainingCooldownMilliseconds = 0
                break
            }
            remainingCooldownMilliseconds = Int(ceil(rem * 1_000.0))
            let stepMs = min(100, max(10, remainingCooldownMilliseconds))
            try await Task.sleep(for: .milliseconds(stepMs))
        }
    }

    public func runSettleCountdown(seconds: Int) async throws -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        remainingSettleSeconds = max(0, seconds)
        while remainingSettleSeconds > 0 {
            try await Task.sleep(for: .seconds(1))
            remainingSettleSeconds -= 1
        }
        return ProcessInfo.processInfo.systemUptime - start
    }

    public func reset() {
        remainingSettleSeconds = 0
        remainingCooldownMilliseconds = 0
        lastExcitationEndUptime = nil
    }
}
