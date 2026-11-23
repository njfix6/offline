import Foundation

/// The auto-lock rules, kept free of timers and UI so they can be tested.
public struct LockPolicy: Equatable, Sendable {
    public static let minimumMinutes = 1
    public static let maximumMinutes = 60
    public static let defaultMinutes = 5

    /// Idle minutes before the app locks. Always within 1...60: there is no
    /// way to turn auto-lock off.
    public let timeoutMinutes: Int

    public init(timeoutMinutes: Int = LockPolicy.defaultMinutes) {
        self.timeoutMinutes = Self.clamp(timeoutMinutes)
    }

    public static func clamp(_ minutes: Int) -> Int {
        min(max(minutes, minimumMinutes), maximumMinutes)
    }

    public var timeout: TimeInterval { TimeInterval(timeoutMinutes * 60) }

    /// Seconds left before locking, never negative.
    public func remaining(lastActivity: Date, now: Date) -> TimeInterval {
        max(0, timeout - now.timeIntervalSince(lastActivity))
    }

    public func shouldLock(lastActivity: Date, now: Date) -> Bool {
        // A clock that jumped backwards also locks, to be safe.
        now < lastActivity || now.timeIntervalSince(lastActivity) >= timeout
    }

    /// "Locks in 4 min", "Locks in under a minute".
    public func statusText(lastActivity: Date, now: Date) -> String {
        let seconds = remaining(lastActivity: lastActivity, now: now)
        if seconds < 60 { return "Locks in under a minute" }
        return "Locks in \(Int((seconds / 60).rounded(.up))) min"
    }
}
