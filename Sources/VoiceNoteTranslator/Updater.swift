import AppKit
import Sparkle
import VNTCore

/// Automatic updates through Sparkle.
///
/// The feed (`SUFeedURL`) and the public key that update archives are checked
/// against (`SUPublicEDKey`) are written into Info.plist by scripts/build-app.sh.
/// Because this is a menu bar app, scheduled checks don't pop a window over
/// whatever the person is doing: an available update shows up in the menu bar
/// instead ("gentle reminders"), and the update window opens when they ask.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    /// A newer version was found by a scheduled check and is waiting to be shown.
    @Published private(set) var updateAvailable: String?
    @Published private(set) var lastCheck: Date?

    private var controller: SPUStandardUpdaterController?

    var updater: SPUUpdater? { controller?.updater }

    /// Builds without a feed (e.g. `swift run`) have no updater.
    var isConfigured: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.isEmpty == false
            && (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false
    }

    func start() {
        guard isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        lastCheck = updater?.lastUpdateCheckDate
        // `checkForUpdatesInBackground` notification: lets scripts trigger a silent check (used to test updates).
        DistributedNotificationCenter.default().addObserver(forName: .init("\(VNT.bundleID).checkForUpdates"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Updater.shared.updater?.checkForUpdatesInBackground() }
        }
    }

    var canCheck: Bool { updater?.canCheckForUpdates ?? false }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var automaticallyInstalls: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    /// "Check for Updates…": shows Sparkle's window, in front.
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        MainActor.assumeIsolated { lastCheck = updater.lastUpdateCheckDate }
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders for a menu bar app)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Only take over the screen if the person is already looking at this app.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if handleShowingUpdate {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                updateAvailable = version
                AppDelegate.shared?.updateIcon()
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            updateAvailable = nil
            AppDelegate.shared?.updateIcon()
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            updateAvailable = nil
            AppDelegate.shared?.updateIcon()
            // Back to a menu bar app unless Settings is open.
            if NSApp.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel || $0.className.contains("Status") }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
