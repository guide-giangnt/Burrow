import XCTest
@testable import Burrow

final class DiskMonitorTests: XCTestCase {

    private typealias Reading = DiskMonitorReport.Reading

    // MARK: - Settings defaults & persistence

    func testDefaultsAreOffAndEmpty() {
        let s = DiskMonitorSettings()
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.slackChannel, "")
        XCTAssertEqual(s.slackMentions, [])
        XCTAssertEqual(s.machineName, "")
        XCTAssertEqual(s.paths, ["/"])
    }

    func testSettingsRoundTripThroughDefaults() throws {
        let suite = "burrow-diskmonitor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var s = DiskMonitorSettings()
        s.enabled = true
        s.thresholdPercent = 7.5
        s.slackChannel = "C0123ABCD"
        s.slackMentions = ["U01", "S02"]
        s.save(to: defaults)

        XCTAssertEqual(DiskMonitorSettings.load(from: defaults), s)
    }

    func testSettingsSavedBeforeANewFieldStillLoad() throws {
        // JSON written by a build without `showInMenuBar` must keep the
        // user's values instead of resetting everything to defaults.
        let legacy = #"{"enabled":true,"thresholdPercent":30,"intervalMinutes":60,"paths":["/"],"machineName":"","slackChannel":"C0123ABCD","slackMentions":[],"alertOnly":false,"includeTopFolders":true}"#
        let s = try JSONDecoder().decode(DiskMonitorSettings.self, from: Data(legacy.utf8))
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.thresholdPercent, 30)
        XCTAssertEqual(s.slackChannel, "C0123ABCD")
        XCTAssertEqual(s.slackChannelLink, "")
        XCTAssertFalse(s.alertOnly)
        XCTAssertTrue(s.showInMenuBar)
        XCTAssertEqual(s.percentDisplay, .used)

        let unknown = #"{"percentDisplay":"remaining","thresholdPercent":15}"#
        let u = try JSONDecoder().decode(DiskMonitorSettings.self, from: Data(unknown.utf8))
        XCTAssertEqual(u.percentDisplay, .used)
        XCTAssertEqual(u.thresholdPercent, 15)
    }

    // MARK: - Menu bar

    func testMenuBarLook() {
        let roomy = Reading(path: "/", total: 100 * gb, free: 60 * gb, failed: false)
        let fuller = Reading(path: "/Volumes/B", total: 100 * gb, free: 26 * gb, failed: false)
        XCTAssertEqual(MenuBarFormat.look([roomy, fuller], threshold: 10).symbol, "internaldrive")
        XCTAssertEqual(MenuBarFormat.look([roomy, fuller], threshold: 10).title, "74%")
        XCTAssertEqual(MenuBarFormat.look([roomy, fuller], threshold: 30).symbol, "exclamationmark.triangle")
        XCTAssertEqual(MenuBarFormat.look([roomy, .unreadable("/X")], threshold: 10).title, "!")
        XCTAssertEqual(MenuBarFormat.look([], threshold: 10).title, "")
        XCTAssertEqual(MenuBarFormat.look([roomy, fuller], threshold: 10, display: .free).title, "26%")
        XCTAssertEqual(MenuBarFormat.look([roomy, .unreadable("/X")], threshold: 10, display: .free).title, "!")
    }

    func testMenuBarLines() {
        let r = Reading(path: "/", total: 494_400_000_000, free: 130_700_000_000, failed: false)
        XCTAssertEqual(MenuBarFormat.line(for: r), "/  —  74% used, 130.7 GB free of 494.4 GB")
        XCTAssertEqual(MenuBarFormat.line(for: .unreadable("/X")), "/X  —  couldn't be read")
        XCTAssertEqual(MenuBarFormat.line(for: r, display: .free), "/  —  26% free, 130.7 GB of 494.4 GB")
        XCTAssertEqual(MenuBarFormat.schedule(last: nil, next: nil), "Not checked yet")
        let cal = Calendar.current
        let last = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 18, minute: 5))!
        let next = cal.date(byAdding: .hour, value: 1, to: last)!
        XCTAssertEqual(MenuBarFormat.schedule(last: last, next: next), "Last check 18:05 · next 19:05")
    }

    // MARK: - Validation

    func testParseThreshold() throws {
        XCTAssertEqual(try DiskMonitorSettings.parseThreshold("7.5"), 7.5)
        XCTAssertEqual(try DiskMonitorSettings.parseThreshold(" 12 % "), 12)
        XCTAssertEqual(try DiskMonitorSettings.parseThreshold("0"), 0)
        XCTAssertEqual(try DiskMonitorSettings.parseThreshold("100"), 100)
        XCTAssertThrowsError(try DiskMonitorSettings.parseThreshold("101"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseThreshold("-1"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseThreshold("abc"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseThreshold("nan"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseThreshold("inf"))
    }

    func testParseChannel() throws {
        // Only links: a bare ID or #name is rejected so nothing is hand-typed.
        XCTAssertEqual(try DiskMonitorSettings.parseChannel("  "), "")
        XCTAssertThrowsError(try DiskMonitorSettings.parseChannel("C0123ABCD"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseChannel("#ops"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseChannel("guide.slack.com/archives/C0123ABCD"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseChannel("http://guide.slack.com/archives/C0123ABCD"))
    }

    func testApplyChannelLink() throws {
        var s = DiskMonitorSettings()
        try s.applyChannelLink(" https://guide.slack.com/archives/C0123ABCD ")
        XCTAssertEqual(s.slackChannel, "C0123ABCD")
        XCTAssertEqual(s.slackChannelLink, "https://guide.slack.com/archives/C0123ABCD")

        // Clearing a saved link turns Slack off.
        try s.applyChannelLink("")
        XCTAssertEqual(s.slackChannel, "")
        XCTAssertEqual(s.slackChannelLink, "")

        // An ID saved by an earlier build has no link; an empty field keeps it.
        var legacy = DiskMonitorSettings()
        legacy.slackChannel = "C07MC01NSAH"
        try legacy.applyChannelLink("")
        XCTAssertEqual(legacy.slackChannel, "C07MC01NSAH")

        // A rejected input changes nothing.
        XCTAssertThrowsError(try legacy.applyChannelLink("C0999"))
        XCTAssertEqual(legacy.slackChannel, "C07MC01NSAH")
    }

    func testParseChannelFromSlackLink() throws {
        XCTAssertEqual(try DiskMonitorSettings.parseChannel("https://guide.slack.com/archives/C0123ABCD"), "C0123ABCD")
        XCTAssertEqual(try DiskMonitorSettings.parseChannel(" https://guide.slack.com/archives/C0123ABCD/p1700000000000100 "), "C0123ABCD")
        XCTAssertEqual(try DiskMonitorSettings.parseChannel("https://app.slack.com/client/T0123/G0456EFGH"), "G0456EFGH")
        XCTAssertThrowsError(try DiskMonitorSettings.parseChannel("https://evil.example.com/archives/C0123ABCD"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseChannel("https://guide.slack.com/team/U0123ABCD"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseChannel("https://guide.slack.com/archives/general"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseChannel("https://slack.com.evil.com/archives/C0123ABCD"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseChannel("https://evilslack.com/archives/C0123ABCD"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseChannel("https://user@evil.com/archives/C0123ABCD"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseChannel("https://guide.slack.com@evil.com/archives/C0123ABCD"))
        XCTAssertEqual(try DiskMonitorSettings.parseChannel("HTTPS://Guide.Slack.com:443/archives/C0123ABCD/?x=1#y"), "C0123ABCD")
    }

    func testParseMentions() throws {
        XCTAssertEqual(try DiskMonitorSettings.parseMentions(""), [])
        XCTAssertEqual(try DiskMonitorSettings.parseMentions("U0123ABCD, S0456EFGH ,W0789"),
                       ["U0123ABCD", "S0456EFGH", "W0789"])
        XCTAssertThrowsError(try DiskMonitorSettings.parseMentions("@alice"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseMentions("U0123, C0123"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseMentions("u0123abcd"))
        XCTAssertThrowsError(try DiskMonitorSettings.parseMentions("U1"))
    }

    func testParsePathsDedupesAndFallsBack() {
        XCTAssertEqual(DiskMonitorSettings.parsePaths(" /, /Volumes/Data ,/, "), ["/", "/Volumes/Data"])
        XCTAssertEqual(DiskMonitorSettings.parsePaths(" , "), ["/"])
    }

    // MARK: - Report

    private let gb = Int64(1_000_000_000)

    func testAlertAtOrBelowThresholdOrOnFailure() {
        let ok = Reading(path: "/", total: 100 * gb, free: 50 * gb, failed: false)
        let atThreshold = Reading(path: "/", total: 100 * gb, free: 10 * gb, failed: false)
        XCTAssertFalse(DiskMonitorReport.isAlert([ok], threshold: 10))
        XCTAssertTrue(DiskMonitorReport.isAlert([atThreshold], threshold: 10))
        XCTAssertTrue(DiskMonitorReport.isAlert([ok, .unreadable("/Volumes/X")], threshold: 10))
        XCTAssertFalse(DiskMonitorReport.isAlert([], threshold: 10))
    }

    func testAlertMessageTagsMentionsAndListsFolders() throws {
        let low = Reading(path: "/", total: 500 * gb, free: 20 * gb, failed: false)
        let msg = DiskMonitorReport.message(
            host: "Build Mac", readings: [low], threshold: 10,
            topFolders: [.init(path: NSHomeDirectory() + "/Library", bytes: 40 * gb)],
            mentions: ["U01", "S02"]
        )
        XCTAssertEqual(msg.text, ":warning: Low disk space - Build Mac")
        let attachment = try XCTUnwrap(msg.attachments.first)
        XCTAssertEqual(attachment.color, DiskMonitorReport.alertColor)
        XCTAssertEqual(attachment.blocks.count, 4)
        XCTAssertTrue(attachment.blocks[0].text.contains("*20.0 GB* of 500.0 GB (4.0% free, threshold 10%, *below threshold*)"))
        XCTAssertTrue(attachment.blocks[1].text.contains("40.0 GB  ~/Library"))
        XCTAssertEqual(attachment.blocks[2].text, "<@U01> <!subteam^S02>")
    }

    func testOKMessageHasNoMentions() throws {
        let ok = Reading(path: "/", total: 500 * gb, free: 200 * gb, failed: false)
        let msg = DiskMonitorReport.message(host: "M", readings: [ok], threshold: 10,
                                            topFolders: nil, mentions: ["U01"])
        XCTAssertEqual(msg.text, ":file_folder: Disk report - M")
        let attachment = try XCTUnwrap(msg.attachments.first)
        XCTAssertEqual(attachment.color, DiskMonitorReport.okColor)
        XCTAssertEqual(attachment.blocks.count, 2)
    }

    func testUnreadableAndEscapedText() throws {
        let msg = DiskMonitorReport.message(host: "<!channel> & co", readings: [.unreadable("/Volumes/<X>")],
                                            threshold: 10, topFolders: nil, mentions: [])
        let text = try XCTUnwrap(msg.attachments.first?.blocks.first?.text)
        XCTAssertTrue(text.contains("Host: *&lt;!channel&gt; &amp; co*"))
        XCTAssertTrue(text.contains("`/Volumes/&lt;X&gt;`: *not measured*"))
        XCTAssertEqual(msg.text, ":warning: Low disk space - &lt;!channel&gt; &amp; co")
    }

    func testTopSectionWhenScanTimedOutOrEmpty() throws {
        let low = Reading(path: "/", total: 100 * gb, free: 1 * gb, failed: false)
        let timedOut = DiskMonitorReport.message(host: "M", readings: [low], threshold: 10,
                                                 topFolders: nil, includeTopSection: true, mentions: [])
        XCTAssertTrue(try XCTUnwrap(timedOut.attachments.first).blocks[1].text.contains("didn't finish"))
        XCTAssertEqual(DiskMonitorReport.formatTop([]), "*Top space consumers*\nNothing measurable found.")
    }

    func testEveryMessageEndsWithBurrowSignature() throws {
        let ok = Reading(path: "/", total: 500 * gb, free: 200 * gb, failed: false)
        let report = DiskMonitorReport.message(host: "M", readings: [ok], threshold: 10,
                                               topFolders: nil, mentions: [], version: "1.2.3")
        let test = DiskMonitorReport.testMessage(host: "M", version: "1.2.3")
        let expected = SlackClient.Block.context("Sent from <https://github.com/guide-vinh/Burrow|Burrow> v1.2.3")
        XCTAssertEqual(report.attachments.first?.blocks.last, expected)
        XCTAssertEqual(test.attachments.first?.blocks.last, expected)
        XCTAssertEqual(test.text, ":white_check_mark: Slack test - M")
        XCTAssertFalse(try XCTUnwrap(test.attachments.first?.blocks.first).text.contains(test.text))
    }

    func testContextBlockEncoding() throws {
        let data = try JSONEncoder().encode(SlackClient.Block.context("sig"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "context")
        let elements = try XCTUnwrap(json["elements"] as? [[String: String]])
        XCTAssertEqual(elements, [["type": "mrkdwn", "text": "sig"]])
        XCTAssertNil(json["text"])
    }

    func testBlockEncodesAsMrkdwnSection() throws {
        let data = try JSONEncoder().encode(SlackClient.Block(text: "hi"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "section")
        let text = try XCTUnwrap(json["text"] as? [String: String])
        XCTAssertEqual(text, ["type": "mrkdwn", "text": "hi"])
    }

    func testTilde() {
        XCTAssertEqual(DiskMonitorReport.tilde("/Users/a/Library", home: "/Users/a"), "~/Library")
        XCTAssertEqual(DiskMonitorReport.tilde("/Users/a", home: "/Users/a"), "~")
        XCTAssertEqual(DiskMonitorReport.tilde("/Users/ab", home: "/Users/a"), "/Users/ab")
    }

    func testExplainSlackErrors() {
        XCTAssertTrue(DiskMonitorViewModel.explain(SlackClient.SlackError.api("not_in_channel")).contains("/invite"))
        XCTAssertEqual(DiskMonitorViewModel.explain(SlackClient.SlackError.api("weird")), "Slack error: weird.")
    }

    // MARK: - check()

    private final class Spy {
        var posts: [(SlackClient.Message, String, String)] = []
        var notifications = 0
        var scans = 0
        var free: [String: Int64] = [:]
        var postDelay: UInt64 = 0
    }

    @MainActor
    private func makeVM(_ spy: Spy, token: String? = "xoxb-test",
                        configure: (inout DiskMonitorSettings) -> Void) throws -> (DiskMonitorViewModel, () -> Void) {
        let suite = "burrow-diskmonitor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let kc = Keychain(service: "fun.burrow.tests.\(UUID().uuidString)")
        if let token { kc.write(token, for: "bot-token") }

        var s = DiskMonitorSettings()   // enabled stays false: no timer, no permission prompt
        s.slackChannel = "C0123ABCD"
        configure(&s)
        s.save(to: defaults)

        var deps = DiskMonitorViewModel.Dependencies()
        let total = 100 * gb
        deps.read = { path in Reading(path: path, total: total, free: spy.free[path] ?? 50 * total / 100, failed: false) }
        deps.scanTopFolders = { spy.scans += 1; return [] }
        deps.post = { msg, token, channel in
            if spy.postDelay > 0 { try await Task.sleep(nanoseconds: spy.postDelay) }
            spy.posts.append((msg, token, channel))
        }
        deps.notify = { _, _ in spy.notifications += 1 }

        let vm = DiskMonitorViewModel(defaults: defaults, keychain: kc, dependencies: deps, recheckDelay: 10_000_000)
        return (vm, { kc.delete("bot-token"); defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor
    func testAlertOnlySkipsHealthyDiskAndPostsLowOne() async throws {
        let spy = Spy()
        let (vm, cleanup) = try makeVM(spy) { _ in }
        defer { cleanup() }

        await vm.check()
        XCTAssertTrue(spy.posts.isEmpty)
        XCTAssertEqual(spy.notifications, 0)

        spy.free["/"] = 5 * gb
        await vm.check()
        XCTAssertEqual(spy.posts.count, 1)
        XCTAssertEqual(spy.posts.first?.1, "xoxb-test")
        XCTAssertEqual(spy.posts.first?.2, "C0123ABCD")
        XCTAssertEqual(spy.scans, 1)
        XCTAssertEqual(vm.slackStatus, "Report sent to Slack.")
    }

    @MainActor
    func testNotifiesOnlyWhenAlertingSetGrows() async throws {
        let spy = Spy()
        let (vm, cleanup) = try makeVM(spy) { $0.paths = ["/", "/Volumes/B"] }
        defer { cleanup() }

        spy.free["/"] = 5 * gb
        await vm.check()
        await vm.check()
        XCTAssertEqual(spy.notifications, 1)

        spy.free["/Volumes/B"] = 1 * gb
        await vm.check()
        XCTAssertEqual(spy.notifications, 2)

        spy.free = [:]
        await vm.check()
        spy.free["/"] = 5 * gb
        await vm.check()
        XCTAssertEqual(spy.notifications, 3)
    }

    @MainActor
    func testReportEveryCheckWithoutTopFoldersWhenNotAlertOnly() async throws {
        let spy = Spy()
        let (vm, cleanup) = try makeVM(spy) { $0.alertOnly = false }
        defer { cleanup() }

        await vm.check()
        await vm.check()
        XCTAssertEqual(spy.posts.count, 2)
        XCTAssertEqual(spy.scans, 0)
        XCTAssertEqual(spy.posts.first?.0.attachments.first?.color, DiskMonitorReport.okColor)
    }

    @MainActor
    func testChangingThresholdRechecksWithNewValue() async throws {
        let spy = Spy()
        spy.free["/"] = 26 * gb
        // Enabled in stored settings: init doesn't start the timer, so only
        // the threshold change below can trigger a check.
        let (vm, cleanup) = try makeVM(spy) { $0.enabled = true; $0.alertOnly = false }
        defer { cleanup() }

        vm.settings.thresholdPercent = 20
        vm.settings.thresholdPercent = 30   // debounced: one report, with 30
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(spy.posts.count, 1)
        let attachment = try XCTUnwrap(spy.posts.first?.0.attachments.first)
        XCTAssertEqual(attachment.color, DiskMonitorReport.alertColor)
        XCTAssertTrue(attachment.blocks[0].text.contains("threshold 30%"))
        XCTAssertEqual(spy.notifications, 1)
    }

    @MainActor
    func testRecheckDuringRunningCheckRunsAfterwards() async throws {
        let spy = Spy()
        spy.free["/"] = 26 * gb
        spy.postDelay = 200_000_000   // a slow Slack post keeps the first check busy
        let (vm, cleanup) = try makeVM(spy) { $0.enabled = true; $0.alertOnly = false }
        defer { cleanup() }

        let first = Task { await vm.check() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(vm.isChecking)
        vm.settings.thresholdPercent = 30   // must not be dropped while busy
        await first.value
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(spy.posts.count, 2)
        XCTAssertTrue(try XCTUnwrap(spy.posts.last?.0.attachments.first).blocks[0].text.contains("threshold 30%"))
    }

    @MainActor
    func testDisablingCancelsPendingRecheck() async throws {
        let spy = Spy()
        spy.free["/"] = 5 * gb
        let (vm, cleanup) = try makeVM(spy) { $0.enabled = true }
        defer { cleanup() }

        vm.settings.thresholdPercent = 30
        vm.settings.enabled = false
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(spy.posts.isEmpty)
        XCTAssertEqual(spy.notifications, 0)
    }

    @MainActor
    func testNoSlackWithoutTokenOrChannel() async throws {
        let spy = Spy()
        spy.free["/"] = 1 * gb
        let (noToken, c1) = try makeVM(spy, token: nil) { _ in }
        defer { c1() }
        await noToken.check()
        let (noChannel, c2) = try makeVM(spy) { $0.slackChannel = "" }
        defer { c2() }
        await noChannel.check()
        XCTAssertTrue(spy.posts.isEmpty)
        XCTAssertEqual(spy.notifications, 2)
    }

    // MARK: - Keychain

    func testKeychainWriteReadDelete() {
        let kc = Keychain(service: "fun.burrow.tests.\(UUID().uuidString)")
        defer { kc.delete("token") }
        XCTAssertNil(kc.read("token"))
        XCTAssertTrue(kc.write("xoxb-1", for: "token"))
        XCTAssertEqual(kc.read("token"), "xoxb-1")
        XCTAssertTrue(kc.write("xoxb-2", for: "token"))
        XCTAssertEqual(kc.read("token"), "xoxb-2")
        XCTAssertTrue(kc.write("", for: "token"))
        XCTAssertNil(kc.read("token"))
    }
}
