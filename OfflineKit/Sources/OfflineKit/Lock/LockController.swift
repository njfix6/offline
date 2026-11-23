import AppKit
import OfflineCore

/// Decides when the app must lock.
///
/// It locks after a period with no input to Offline, when the Mac or its
/// displays go to sleep, when the screen is locked or the screen saver
/// starts, and when another user switches in. None of this can be disabled;
/// only the idle period can be changed, within 1 to 60 minutes.
@MainActor
final class LockController {
    /// Called when the app has to lock.
    var onLock: () -> Void = {}
    /// Called about every 15 seconds so the "Locks in N min" hint stays fresh.
    var onTick: () -> Void = {}

    var policy = LockPolicy()
    private(set) var lastActivity = Date()

    private var timer: Timer?
    private var eventMonitor: Any?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var tickCount = 0

    func start() {
        guard timer == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .scrollWheel, .magnify, .swipe,
        ]) { [weak self] event in
            self?.lastActivity = Date()
            return event
        }

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            observe(workspace, name)
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observe(distributed, Notification.Name(name))
        }

        // Timers can be delayed while the app is in the background, so the
        // deadline is checked again the moment the app comes forward.
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        observers.append((NotificationCenter.default, token))
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onLock() }
        }
        observers.append((center, token))
    }

    /// Restarts the idle countdown, for example right after unlocking.
    func noteActivity() {
        lastActivity = Date()
    }

    var statusText: String {
        policy.statusText(lastActivity: lastActivity, now: Date())
    }

    private func check() {
        if policy.shouldLock(lastActivity: lastActivity, now: Date()) {
            onLock()
        }
        tickCount += 1
        if tickCount % 3 == 0 { onTick() }
    }
}
