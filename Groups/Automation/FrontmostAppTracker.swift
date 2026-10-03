import Foundation
import AppKit
import Combine

/// Remembers which app the user was in before they clicked our menu bar icon.
///
/// Every "capture what I'm looking at" feature needs this. `NSWorkspace.frontmostApplication`
/// is useless once the panel is open, because by then the frontmost app is *us*.
@MainActor
final class FrontmostAppTracker: ObservableObject {

    static let shared = FrontmostAppTracker()

    /// Bundle identifier of the last frontmost app that wasn't this one.
    @Published private(set) var previousBundleID: String?
    /// Localized name of that app, for UI like "Capture from Safari".
    @Published private(set) var previousAppName: String?

    private var observer: NSObjectProtocol?
    private let selfBundleID = Bundle.main.bundleIdentifier

    private init() {
        // Seed from whatever is in front at launch, so the first capture works even if the
        // user never switches apps before opening the panel.
        record(NSWorkspace.shared.frontmostApplication)

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.record(app) }
        }
    }

    /// `isolated` so the deinit runs on the main actor and may touch `observer`, which is
    /// neither `Sendable` nor reachable from the nonisolated deinit the compiler would
    /// otherwise synthesise. In practice this never runs — the tracker is a singleton held
    /// for the life of the process — but an unregistered observer on a dead object is the
    /// kind of thing that only bites once the type stops being a singleton.
    isolated deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func record(_ app: NSRunningApplication?) {
        guard let app, let bundleID = app.bundleIdentifier, bundleID != selfBundleID else { return }
        previousBundleID = bundleID
        previousAppName = app.localizedName ?? bundleID
    }

    /// True when the app the user came from is a browser we can read.
    var previousAppIsSupportedBrowser: Bool {
        BrowserTarget.matching(bundleID: previousBundleID) != nil
    }

    /// True when the user came from Finder.
    var previousAppIsFinder: Bool {
        previousBundleID?.caseInsensitiveCompare("com.apple.finder") == .orderedSame
    }
}
