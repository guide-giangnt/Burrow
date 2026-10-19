import Foundation

/// Report logic for the disk monitor: readings in, alert decision and Slack
/// message out. The message builders are pure so they can be unit-tested;
/// `read`/`readAll` and the folder scan are the only I/O.
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

        /// Unreadable, or free space at or below the threshold.
        func isLow(threshold: Double) -> Bool { failed || freePercent <= threshold }

        static func unreadable(_ path: String) -> Reading {
            Reading(path: path, total: 0, free: 0, failed: true)
        }
    }

    /// One row of the "Top space consumers" list. A path ending in "/*"
    /// stands for the loose files directly in that folder, as in diskmon.
    struct Folder: Equatable {
        let path: String
        let bytes: Int64
    }

    static let alertColor = "#E01E5A"
    static let okColor = "#31E5C5"

    // MARK: - Reading volumes

    /// Free space as `statfs` reports it to unprivileged users — like
    /// diskmon. Unlike `VolumeInfo` (Analyze), purgeable space is NOT
    /// counted as free: an alert should fire on space that's really gone.
    /// Missing values mean "couldn't be read", never a false 0 bytes free.
    static func read(_ path: String) -> Reading {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0,
              let free = values.volumeAvailableCapacity
        else { return .unreadable(path) }
        return Reading(path: path, total: Int64(total), free: Int64(free), failed: false)
    }

    /// Reads every path in parallel, each bounded by `timeout`, so one hung
    /// network mount is reported as unreadable instead of stalling the
    /// check for every volume.
    static func readAll(
        _ paths: [String],
        timeout: TimeInterval = 10,
        read: @escaping @Sendable (String) -> Reading = { DiskMonitorReport.read($0) }
    ) async -> [Reading] {
        await withTaskGroup(of: (Int, Reading).self) { group in
            for (index, path) in paths.enumerated() {
                group.addTask {
                    let reading = await firstOf(timeout: timeout, fallback: .unreadable(path)) { read(path) }
                    return (index, reading)
                }
            }
            var readings = [Reading?](repeating: nil, count: paths.count)
            for await (index, reading) in group { readings[index] = reading }
            return readings.compactMap { $0 }
        }
    }

    /// Runs blocking `work` on a background queue and returns its result, or
    /// `fallback` once `timeout` passes. A blocked call can't be interrupted;
    /// it finishes on its own thread and its late result is dropped.
    private static func firstOf<T: Sendable>(
        timeout: TimeInterval,
        fallback: T,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let once = ResumeOnce(cont)
            DispatchQueue.global(qos: .utility).async { once.resume(work()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(fallback) }
        }
    }

    /// Resumes a continuation with whichever result arrives first.
    private final class ResumeOnce<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T, Never>?

        init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }

        func resume(_ value: T) {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    // MARK: - Alert decision

    /// True when any path is unreadable or at/below the threshold.
    static func isAlert(_ readings: [Reading], threshold: Double) -> Bool {
        readings.contains { $0.isLow(threshold: threshold) }
    }

    // MARK: - Formatting

    /// Decimal gigabytes with one decimal, the unit macOS uses for disks.
    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }

    /// Percent as written in Slack and notifications: one fixed, locale-free
    /// format ("7.5", "10"), so a report never mixes "7,5" with "4.0".
    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US_POSIX")))
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return f
    }()

    // MARK: - Slack messages

    static func message(
        host: String,
        readings: [Reading],
        threshold: Double,
        topFolders: [Folder]?,
        includeTopSection: Bool = false,
        mentions: [String],
        now: Date = Date(),
        version: String = Bundle.main.shortVersion
    ) -> SlackClient.Message {
        let alert = isAlert(readings, threshold: threshold)

        let host = escape(host)
        var lines = ["Host: *\(host)*"]
        for r in readings {
            if r.failed {
                lines.append("Free space `\(escape(r.path))`: *not measured* - couldn't read this volume")
                continue
            }
            let state = r.isLow(threshold: threshold) ? ", *below threshold*" : ""
            lines.append("Free space `\(escape(r.path))`: *\(gb(r.free))* of \(gb(r.total)) "
                + "(\(percent(r.freePercent))% free, threshold \(percent(threshold))%\(state))")
        }
        if alert { lines.append("The disk is running low - this needs a look.") }
        lines.append("Checked: \(stampFormatter.string(from: now))")

        var blocks = [SlackClient.Block.section(lines.joined(separator: "\n"))]
        // A requested scan that returned nil timed out; say so rather than
        // dropping the section silently.
        if let topFolders {
            blocks.append(.section(formatTop(topFolders)))
        } else if includeTopSection {
            blocks.append(.section("*Top space consumers*\n_Scan didn't finish in time; list omitted._"))
        }
        blocks.append(.context(signature(version: version)))

        // Mentions go in the top-level text, not an attachment block: Slack
        // reliably notifies for mentions in the message body.
        var text = alert ? ":warning: Low disk space - \(host)" : ":file_folder: Disk report - \(host)"
        if alert && !mentions.isEmpty {
            text += "\n" + mentions.map(SlackClient.mention).joined(separator: " ")
        }
        return SlackClient.Message(text: text, attachments: [.init(color: alert ? alertColor : okColor, blocks: blocks)])
    }

    /// Footer on every message, so the channel can tell Burrow's reports
    /// apart from other bots posting as the same Slack app.
    static func signature(version: String = Bundle.main.shortVersion) -> String {
        "Sent from <https://github.com/guide-vinh/Burrow|Burrow> v\(version)"
    }

    /// The "Send Test Message" payload, signed like a real report.
    static func testMessage(host: String, version: String = Bundle.main.shortVersion) -> SlackClient.Message {
        // Short title as `text`, details in the attachment — like a report,
        // so Slack doesn't show the same sentence twice.
        let body = "Host: *\(escape(host))*\nSlack is set up correctly. Disk reports and alerts will be posted to this channel."
        return SlackClient.Message(
            text: ":white_check_mark: Slack test - \(escape(host))",
            attachments: [.init(color: okColor, blocks: [.section(body), .context(signature(version: version))])]
        )
    }

    static func formatTop(_ folders: [Folder]) -> String {
        guard !folders.isEmpty else { return "*Top space consumers*\nNothing measurable found." }
        let rows = folders.map { f -> String in
            let size = gb(f.bytes)
            let path = (f.path as NSString).abbreviatingWithTildeInPath
            return String(repeating: " ", count: max(0, 9 - size.count)) + size + "  " + escape(path)
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

    // MARK: - Top folders

    /// `scanFolders` bounded by `timeout`; nil when it didn't finish. The
    /// scan runs `du` in cancellable mode, so losing the race terminates
    /// the walk instead of leaving it running in the background.
    static func scanTopFolders(timeout: TimeInterval = 120) async -> [Folder]? {
        await withTaskGroup(of: [Folder]?.self) { group in
            group.addTask { await scanFolders() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Largest folders under the home directory: one `du` level, with the
    /// biggest few expanded one level deeper so ~/Library doesn't swallow
    /// the whole list. Nothing is excluded (unlike Analyze): containers,
    /// simulators and the Trash are exactly what tends to fill a disk.
    static func scanFolders(limit: Int = 8, expand: Int = 3) async -> [Folder] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let top = await DiskUsageScanner.scan(home, excluding: [], cancellable: true)
        guard !Task.isCancelled else { return [] }
        let first = top.children.sorted { $0.size > $1.size }

        var result = first.dropFirst(expand).map { Folder(path: $0.url.path, bytes: $0.size) }
        result += looseFiles(in: home.path, total: top.total, children: top.children.map(\.size))
        for entry in first.prefix(expand) {
            let deeper = await DiskUsageScanner.scan(entry.url, excluding: [], cancellable: true)
            guard !Task.isCancelled else { return [] }
            if deeper.children.isEmpty {
                result.append(Folder(path: entry.url.path, bytes: entry.size))
            } else {
                result += deeper.children.map { Folder(path: $0.url.path, bytes: $0.size) }
                result += looseFiles(in: entry.url.path, total: deeper.total, children: deeper.children.map(\.size))
            }
        }
        return rank(result, limit: limit)
    }

    /// The "<folder>/*" row: files directly in a folder, i.e. its total
    /// minus its subfolders. Omitted when there's nothing to show.
    static func looseFiles(in folder: String, total: Int64, children: [Int64]) -> [Folder] {
        let loose = total - children.reduce(0, +)
        return loose > 0 ? [Folder(path: folder + "/*", bytes: loose)] : []
    }

    static func rank(_ folders: [Folder], limit: Int) -> [Folder] {
        Array(folders.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }
}
