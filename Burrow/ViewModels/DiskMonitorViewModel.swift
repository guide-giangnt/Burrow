import Foundation
import ServiceManagement
import SwiftUI // ObservableObject + @Published only
import UserNotifications
import os

/// Backs the Monitoring tab. While enabled it checks the configured volumes
/// on a timer, raises a macOS notification when one drops to or below the
/// threshold, and — if the user filled in Slack — posts a report to their
/// channel. Runs while Burrow is running; "Open at login" keeps it running
/// across restarts. Report logic lives in `DiskMonitorReport`, delivery in
/// `SlackClient`; I/O is injected so `check()` can be unit-tested.
@MainActor
final class DiskMonitorViewModel: ObservableObject {

    /// Side effects, swappable in tests.
    struct Dependencies {
        var read: @Sendable (String) -> DiskMonitorReport.Reading = DiskMonitorReport.read
        var scanTopFolders: () async -> [DiskMonitorReport.Folder]? = { await DiskMonitorReport.scanTopFolders() }
        var post: (SlackClient.Message, _ token: String, _ channel: String) async throws -> Void = { message, token, channel in
            try await SlackClient(token: token).post(message, to: channel)
        }
        var notify: ([DiskMonitorReport.Reading], Double) -> Void = DiskMonitorNotifier.notify
    }

    private let logger = Logger(subsystem: "fun.burrow", category: "DiskMonitorViewModel")
    private let defaults: UserDefaults
    private let keychain: Keychain
    private let deps: Dependencies
    private let recheckDelay: UInt64
    private static let tokenAccount = "bot-token"

    @Published var settings: DiskMonitorSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: defaults)
            if settings.enabled != oldValue.enabled || settings.intervalMinutes != oldValue.intervalMinutes {
                reschedule()
            } else if settings.enabled,
                      settings.thresholdPercent != oldValue.thresholdPercent || settings.paths != oldValue.paths {
                recheckSoon()
            }
        }
    }
    @Published private(set) var hasSlackToken: Bool
    @Published private(set) var lastReadings: [DiskMonitorReport.Reading] = []
    @Published private(set) var lastChecked: Date?
    /// When the timer fires next; nil while the monitor is off.
    @Published private(set) var nextCheck: Date?
    @Published private(set) var isChecking = false
    @Published private(set) var slackStatus: String?
    @Published private(set) var loginItemError: String?

    private var loop: Task<Void, Never>?
    private var pendingRecheck: Task<Void, Never>?
    /// Set when a re-check was asked for while a check (possibly a long
    /// top-folder scan) was running; that check runs one more afterwards.
    private var recheckQueued = false
    /// Paths that were alerting at the previous check. A notification fires
    /// when this set grows, not on every check while a disk stays low.
    private var alertingPaths: Set<String> = []

    init(defaults: UserDefaults = .standard, keychain: Keychain = .slack,
         dependencies: Dependencies = Dependencies(), recheckDelay: UInt64 = 1_000_000_000) {
        self.defaults = defaults
        self.keychain = keychain
        self.deps = dependencies
        self.recheckDelay = recheckDelay
        self.settings = DiskMonitorSettings.load(from: defaults)
        self.hasSlackToken = keychain.read(Self.tokenAccount) != nil
    }

    // MARK: - Scheduling

    /// Starts the timer if enabled. Safe to call more than once (each new
    /// window runs the launch `.task`).
    func start() {
        guard loop == nil else { return }
        reschedule()
    }

    private func reschedule() {
        loop?.cancel()
        loop = nil
        pendingRecheck?.cancel()
        pendingRecheck = nil
        nextCheck = nil
        guard settings.enabled else {
            // Start fresh next time: a disk still low on re-enable notifies again.
            alertingPaths = []
            lastReadings = []
            recheckQueued = false
            return
        }
        DiskMonitorNotifier.requestPermission()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let minutes: Int
                do {
                    guard let self else { return }
                    // Unstructured, so cancelling the loop (interval change)
                    // never cancels a Slack post that's already in flight.
                    Task { await self.check() }
                    minutes = self.settings.intervalMinutes
                    self.nextCheck = Date().addingTimeInterval(TimeInterval(max(1, minutes) * 60))
                }
                try? await Task.sleep(nanoseconds: UInt64(max(1, minutes)) * 60 * 1_000_000_000)
            }
        }
    }

    /// A new threshold or volume list takes effect right away instead of at
    /// the next timer tick — otherwise the tab shows "Low disk space" while
    /// notifications and Slack still reflect the old values for up to an
    /// interval. Debounced so a burst of edits sends one report.
    private func recheckSoon() {
        pendingRecheck?.cancel()
        pendingRecheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.recheckDelay ?? 0)
            guard !Task.isCancelled, let self, self.settings.enabled else { return }
            if self.isChecking {
                self.recheckQueued = true
            } else {
                await self.check()
            }
        }
    }

    // MARK: - Checking

    var isSlackConfigured: Bool { hasSlackToken && !settings.slackChannel.isEmpty }

    var isAlert: Bool {
        DiskMonitorReport.isAlert(lastReadings, threshold: settings.thresholdPercent)
    }

    /// Reads every path, notifies on a new alert and posts to Slack when
    /// configured. Called by the timer and by "Check Now".
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer {
            isChecking = false
            if recheckQueued {
                recheckQueued = false
                if settings.enabled { Task { await self.check() } }
            }
        }

        let s = settings
        // Off the main actor: a stale network mount can block for seconds.
        let read = deps.read
        let readings = await Task.detached { s.paths.map(read) }.value
        let alert = DiskMonitorReport.isAlert(readings, threshold: s.thresholdPercent)
        lastReadings = readings
        lastChecked = Date()

        let alerting = Set(readings.filter { $0.failed || $0.freePercent <= s.thresholdPercent }.map(\.path))
        if !alerting.isSubset(of: alertingPaths) { deps.notify(readings, s.thresholdPercent) }
        alertingPaths = alerting

        guard isSlackConfigured, alert || !s.alertOnly,
              let token = keychain.read(Self.tokenAccount)
        else { return }

        let wantTop = alert && s.includeTopFolders
        let top = wantTop ? await deps.scanTopFolders() : nil
        let message = DiskMonitorReport.message(
            host: s.displayName, readings: readings, threshold: s.thresholdPercent,
            topFolders: top, includeTopSection: wantTop, mentions: s.slackMentions
        )
        await post(message, token: token, channel: s.slackChannel, success: "Report sent to Slack.")
    }

    /// "Send Test Message" — verifies token, channel and bot membership.
    func sendTestMessage() async {
        guard let token = keychain.read(Self.tokenAccount), !settings.slackChannel.isEmpty else {
            slackStatus = "Fill in the bot token and channel, then Save."
            return
        }
        let message = DiskMonitorReport.testMessage(host: settings.displayName)
        await post(message, token: token, channel: settings.slackChannel, success: "Test message sent.")
    }

    private func post(_ message: SlackClient.Message, token: String, channel: String, success: String) async {
        do {
            try await deps.post(message, token, channel)
            slackStatus = success
        } catch {
            logger.error("Slack post failed: \(error.localizedDescription, privacy: .public)")
            slackStatus = Self.explain(error)
        }
    }

    /// Turns the common Slack error codes into something actionable.
    nonisolated static func explain(_ error: Error) -> String {
        guard case SlackClient.SlackError.api(let code) = error else {
            return error.localizedDescription
        }
        switch code {
        case "not_in_channel": return "The bot isn't in that channel. Run /invite @your-bot in Slack."
        case "channel_not_found": return "Channel not found. Check the channel ID."
        case "invalid_auth", "not_authed", "token_revoked": return "The bot token was rejected. Check it and save again."
        case "missing_scope": return "The Slack app needs the chat:write scope."
        default: return "Slack error: \(code)."
        }
    }

    // MARK: - Slack token (Keychain)

    func saveSlackToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if keychain.write(trimmed, for: Self.tokenAccount) {
            hasSlackToken = !trimmed.isEmpty
            slackStatus = trimmed.isEmpty ? "Token removed." : "Token saved to the Keychain."
        } else {
            slackStatus = "Couldn't save the token to the Keychain."
        }
    }

    // MARK: - Open at login (macOS 13+)

    var supportsOpenAtLogin: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    var openAtLogin: Bool {
        get {
            guard #available(macOS 13.0, *) else { return false }
            let status = SMAppService.mainApp.status
            return status == .enabled || status == .requiresApproval
        }
        set {
            guard #available(macOS 13.0, *) else { return }
            objectWillChange.send()
            loginItemError = nil
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                logger.error("Open at login failed: \(error.localizedDescription, privacy: .public)")
                loginItemError = error.localizedDescription
            }
            if SMAppService.mainApp.status == .requiresApproval {
                loginItemError = "Allow Burrow in System Settings → General → Login Items."
            }
        }
    }
}

/// Local notifications for low disk space. Also the notification-center
/// delegate, so banners still show while Burrow is the frontmost app.
final class DiskMonitorNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DiskMonitorNotifier()

    static func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(_ readings: [DiskMonitorReport.Reading], threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Low disk space"
        content.body = readings
            .filter { $0.failed || $0.freePercent <= threshold }
            .map { r in
                r.failed
                    ? "\(r.path): couldn't be read"
                    : "\(r.path): \(DiskMonitorReport.gb(r.free)) free (\(String(format: "%.1f", r.freePercent))%)"
            }
            .joined(separator: "\n")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "fun.burrow.diskmonitor.low", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
