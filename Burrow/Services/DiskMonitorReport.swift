import Foundation

/// Pure report logic for the disk monitor: readings in, alert decision and
/// Slack message out. Kept free of I/O so it can be unit-tested.
enum DiskMonitorReport {

    /// Free space for one monitored path, or why it couldn't be read.
    struct Reading: Equatable {
        let path: String
        let total: Int64
        let free: Int64
        let failed: Bool

        var freePercent: Double {
            total > 0 ? Double(free) / Double(total) * 100 : 0
        }
        var usedPercent: Double { 100 - freePercent }

        static func unreadable(_ path: String) -> Reading {
            Reading(path: path, total: 0, free: 0, failed: true)
        }
    }

    /// One row of the "Top space consumers" list.
    struct Folder: Equatable {
        let path: String
        let bytes: Int64
    }

    static let alertColor = "#E01E5A"
    static let okColor = "#31E5C5"

    static func read(_ path: String) -> Reading {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let cap = VolumeInfo.capacity(of: url), cap.total > 0 else {
            return .unreadable(path)
        }
        return Reading(path: path, total: cap.total, free: cap.free, failed: false)
    }

    /// True when any path is unreadable or at/below the threshold.
    static func isAlert(_ readings: [Reading], threshold: Double) -> Bool {
        readings.contains { $0.failed || $0.freePercent <= threshold }
    }

    /// Decimal gigabytes with one decimal, the unit macOS uses for disks.
    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }

    static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func message(
        host: String,
        readings: [Reading],
        threshold: Double,
        topFolders: [Folder]?,
        includeTopSection: Bool? = nil,
        mentions: [String],
        now: Date = Date(),
        version: String = appVersion
    ) -> SlackClient.Message {
        let alert = isAlert(readings, threshold: threshold)
        let thresholdText = threshold.formatted(.number.precision(.fractionLength(0...2)))

        let host = escape(host)
        var lines = ["Host: *\(host)*"]
        for r in readings {
            if r.failed {
                lines.append("Free space `\(escape(r.path))`: *not measured* - couldn't read this volume")
                continue
            }
            let state = r.freePercent <= threshold ? ", *below threshold*" : ""
            lines.append(String(
                format: "Free space `%@`: *%@* of %@ (%.1f%% free, threshold %@%%%@)",
                escape(r.path), gb(r.free), gb(r.total), r.freePercent, thresholdText, state
            ))
        }
        if alert { lines.append("The disk is running low - this needs a look.") }

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.dateFormat = "yyyy-MM-dd HH:mm zzz"
        lines.append("Checked: \(stamp.string(from: now))")

        var blocks = [SlackClient.Block(text: lines.joined(separator: "\n"))]
        // A requested scan that returned nil timed out; say so rather than
        // dropping the section silently.
        if let topFolders {
            blocks.append(SlackClient.Block(text: formatTop(topFolders)))
        } else if includeTopSection == true {
            blocks.append(SlackClient.Block(text: "*Top space consumers*\n_Scan didn't finish in time; list omitted._"))
        }
        if alert && !mentions.isEmpty {
            blocks.append(SlackClient.Block(text: mentions.map(SlackClient.mention).joined(separator: " ")))
        }
        blocks.append(.context(signature(version: version)))

        return SlackClient.Message(
            text: alert ? ":warning: Low disk space - \(host)" : ":file_folder: Disk report - \(host)",
            attachments: [.init(color: alert ? alertColor : okColor, blocks: blocks)]
        )
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// Footer on every message, so the channel can tell Burrow's reports
    /// apart from other bots posting as the same Slack app.
    static func signature(version: String = appVersion) -> String {
        "Sent from <https://github.com/guide-vinh/Burrow|Burrow> v\(version)"
    }

    /// The "Send Test Message" payload, signed like a real report.
    static func testMessage(host: String, version: String = appVersion) -> SlackClient.Message {
        // Short title as `text`, details in the attachment — like a report,
        // so Slack doesn't show the same sentence twice.
        let body = "Host: *\(escape(host))*\nSlack is set up correctly. Disk reports and alerts will be posted to this channel."
        return SlackClient.Message(
            text: ":white_check_mark: Slack test - \(escape(host))",
            attachments: [.init(color: okColor, blocks: [SlackClient.Block(text: body), .context(signature(version: version))])]
        )
    }

    static func formatTop(_ folders: [Folder]) -> String {
        guard !folders.isEmpty else { return "*Top space consumers*\nNothing measurable found." }
        let rows = folders.map { f -> String in
            let size = gb(f.bytes)
            return String(repeating: " ", count: max(0, 9 - size.count)) + size + "  " + escape(tilde(f.path))
        }
        return "*Top space consumers*\n```\n" + rows.joined(separator: "\n") + "\n```"
    }

    /// Escapes the three characters Slack treats as markup, so a typed
    /// machine name or path like `<!channel>` can't ping anyone.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `scanFolders` bounded by `timeout`; nil when it didn't finish.
    /// Keeps a slow home-directory walk from holding up the Slack report.
    /// Not a task group: `du` ignores cancellation, and a group would wait
    /// for it anyway. On timeout the walk finishes in the background.
    static func scanTopFolders(timeout: TimeInterval = 120) async -> [Folder]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[Folder]?, Never>) in
            let once = ResumeOnce(cont)
            Task { once.resume(await scanFolders()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                once.resume(nil)
            }
        }
    }

    /// Resumes a continuation with whichever result arrives first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<[Folder]?, Never>?

        init(_ cont: CheckedContinuation<[Folder]?, Never>) { self.cont = cont }

        func resume(_ value: [Folder]?) {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    /// Largest folders under the home directory: one `du` level, with the
    /// biggest few expanded one level deeper so ~/Library doesn't swallow
    /// the whole list.
    static func scanFolders(limit: Int = 8, expand: Int = 3) async -> [Folder] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let first = await DiskUsageScanner.scan(home).children.sorted { $0.size > $1.size }

        var result = first.dropFirst(expand).map { Folder(path: $0.url.path, bytes: $0.size) }
        for entry in first.prefix(expand) {
            let deeper = await DiskUsageScanner.scan(entry.url).children
            if deeper.isEmpty {
                result.append(Folder(path: entry.url.path, bytes: entry.size))
            } else {
                result += deeper.map { Folder(path: $0.url.path, bytes: $0.size) }
            }
        }
        return Array(result.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }
}
