import Foundation
import SwiftUI // ObservableObject + @Published only
import os

/// Backs the "Cleaning Rules" section in Settings: shows the current
/// catalog versions and last-checked time, and drives the manual and
/// launch-time update checks. All work routes through `CatalogUpdater`
/// (network) and `CatalogStore` (versions); this type only holds state.
@MainActor
final class CatalogUpdateViewModel: ObservableObject {

    private let logger = Logger(subsystem: "fun.burrow", category: "CatalogUpdateViewModel")
    private let store: CatalogStore
    private let defaults: UserDefaults
    private static let lastCheckedKey = "catalogLastChecked"

    /// Once-per-day throttle for the best-effort launch check (mirrors
    /// Sparkle's daily interval).
    private static let launchThrottle: TimeInterval = 86_400

    @Published private(set) var cleanRulesVersion: Int = 0
    @Published private(set) var appLeftoversVersion: Int = 0
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var statusMessage: String?

    init(store: CatalogStore = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
        refreshDisplayedVersions()
    }

    func refreshDisplayedVersions() {
        cleanRulesVersion = store.effectiveVersion(for: .cleanRules)
        appLeftoversVersion = store.effectiveVersion(for: .appLeftovers)
    }

    /// Manual "Check Now" action.
    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let results = await CatalogUpdater.checkForUpdates(store: store)
        lastChecked = Date()
        defaults.set(lastChecked, forKey: Self.lastCheckedKey)
        refreshDisplayedVersions()
        statusMessage = Self.summarize(results)
    }

    /// Best-effort check fired on launch, throttled to once per 24h so it
    /// never nags. Silent — updates state but shows no status on success.
    func checkOnLaunchIfDue() async {
        if let last = lastChecked, Date().timeIntervalSince(last) < Self.launchThrottle {
            return
        }
        let results = await CatalogUpdater.checkForUpdates(store: store)
        // Only stamp lastChecked if we actually reached the server, so a
        // launch offline retries next time instead of waiting a full day.
        if !results.isEmpty {
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastCheckedKey)
        }
        refreshDisplayedVersions()
    }

    private static func summarize(_ results: [CatalogKind: CatalogUpdater.UpdateOutcome]) -> String {
        guard !results.isEmpty else { return "Couldn't reach the update server." }

        let installed = results.values.contains { if case .installed = $0 { return true } else { return false } }
        if installed { return "Rules updated to the latest version." }

        let failed = results.values.contains { if case .failed = $0 { return true } else { return false } }
        if failed { return "Some rule updates couldn't be applied." }

        return "Rules are up to date."
    }
}
