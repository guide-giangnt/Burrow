import AppKit
import Combine
import SwiftUI

/// Menu bar status item for the disk monitor, modelled on diskmon's: the
/// fullest disk's used percentage next to a drive icon, a warning triangle
/// once a disk is at or below the threshold, and a menu with each disk,
/// the threshold presets and quick actions. AppKit `NSStatusItem` rather
/// than SwiftUI `MenuBarExtra`, which needs macOS 13.
@MainActor
final class MenuBarController: NSObject {

    static let shared = MenuBarController()

    private var vm: DiskMonitorViewModel?
    private var statusItem: NSStatusItem?
    private var observation: AnyCancellable?

    /// Idempotent: every new window's launch `.task` calls this.
    func attach(_ vm: DiskMonitorViewModel) {
        guard self.vm == nil else { return }
        self.vm = vm
        // objectWillChange fires before the new value lands; refresh on the
        // next runloop turn so the menu reads the updated state.
        observation = vm.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func refresh() {
        guard let vm, vm.settings.enabled, vm.settings.showInMenuBar else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        let look = MenuBarFormat.look(vm.lastReadings, threshold: vm.settings.thresholdPercent,
                                      display: vm.settings.percentDisplay)
        if let button = item.button {
            let image = NSImage(systemSymbolName: look.symbol, accessibilityDescription: "Disk Monitor")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = look.title.isEmpty ? "" : " \(look.title)"
            button.toolTip = "Burrow Disk Monitor"
        }
        item.menu = buildMenu(vm)
    }

    // MARK: - Menu

    private func buildMenu(_ vm: DiskMonitorViewModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(disabled("Burrow Disk Monitor"))
        menu.addItem(.separator())

        if vm.lastReadings.isEmpty {
            menu.addItem(disabled("Not checked yet"))
        }
        for reading in vm.lastReadings {
            menu.addItem(disabled(MenuBarFormat.line(for: reading, display: vm.settings.percentDisplay)))
        }
        menu.addItem(disabled(MenuBarFormat.schedule(last: vm.lastChecked, next: vm.nextCheck)))
        menu.addItem(.separator())

        let threshold = NSMenuItem(title: "Alert Threshold", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let current = vm.settings.thresholdPercent
        for preset in DiskMonitorSettings.thresholdPresets {
            let entry = action("\(Int(preset))% free", #selector(setThreshold(_:)))
            entry.representedObject = preset
            entry.state = preset == current ? .on : .off
            sub.addItem(entry)
        }
        sub.addItem(.separator())
        let custom = action(
            DiskMonitorSettings.thresholdPresets.contains(current)
                ? "Custom…"
                : "Custom (\(MenuBarFormat.percent(current)))…",
            #selector(openMonitoring)
        )
        custom.state = DiskMonitorSettings.thresholdPresets.contains(current) ? .off : .on
        sub.addItem(custom)
        threshold.submenu = sub
        menu.addItem(threshold)

        let display = NSMenuItem(title: "Show Percentage As", action: nil, keyEquivalent: "")
        let displaySub = NSMenu()
        displaySub.autoenablesItems = false
        for mode in DiskMonitorSettings.PercentDisplay.allCases {
            let entry = action(mode.label, #selector(setPercentDisplay(_:)))
            entry.representedObject = mode.rawValue
            entry.state = mode == vm.settings.percentDisplay ? .on : .off
            displaySub.addItem(entry)
        }
        display.submenu = displaySub
        menu.addItem(display)

        let alertOnly = action("Only Post When Low", #selector(toggleAlertOnly))
        alertOnly.state = vm.settings.alertOnly ? .on : .off
        alertOnly.isEnabled = vm.isSlackConfigured
        menu.addItem(alertOnly)

        let checkNow = action(vm.isChecking ? "Checking…" : "Check Now", #selector(checkNow))
        checkNow.isEnabled = !vm.isChecking
        menu.addItem(checkNow)

        menu.addItem(.separator())
        menu.addItem(action("Open Monitoring…", #selector(openMonitoring)))
        menu.addItem(action("Quit Burrow", #selector(quit), key: "q"))
        return menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func setThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        vm?.settings.thresholdPercent = value
    }

    @objc private func setPercentDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DiskMonitorSettings.PercentDisplay(rawValue: raw)
        else { return }
        vm?.settings.percentDisplay = mode
    }

    @objc private func toggleAlertOnly() {
        vm?.settings.alertOnly.toggle()
    }

    @objc private func checkNow() {
        guard let vm else { return }
        Task { await vm.check() }
    }

    @objc private func openMonitoring() {
        MonitoringNavigation.request()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Lets the menu bar bring a Burrow window forward on the Monitoring tab,
/// including when every window was closed (the app keeps running for the
/// monitor). An open `RootView` reacts to the notification; a newly created
/// one picks up `pending` when it appears.
enum MonitoringNavigation {
    static let notification = Notification.Name("fun.burrow.showMonitoring")
    static var pending = false
    static let mainWindowID = NSUserInterfaceItemIdentifier("fun.burrow.mainWindow")

    @MainActor
    static func request() {
        NSApp.activate(ignoringOtherApps: true)
        // Only windows hosting RootView — not Settings, which also qualifies
        // as a main window but has no Monitoring tab to switch to.
        let window = NSApp.windows.first {
            $0.identifier == mainWindowID && ($0.isVisible || $0.isMiniaturized)
        }
        if let window {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: notification, object: nil)
        } else {
            pending = true
            openNewWindow()
        }
    }

    /// SwiftUI's WindowGroup adds File → New Window (⌘N); trigger it.
    @MainActor
    private static func openNewWindow() {
        guard let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items),
              let newWindow = items.first(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command })
        else { return }
        newWindow.menu?.performActionForItem(at: newWindow.menu?.index(of: newWindow) ?? 0)
    }
}

/// Tags the NSWindow hosting `RootView` with `MonitoringNavigation.mainWindowID`
/// so the menu bar can find it among the app's windows.
struct MainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = MonitoringNavigation.mainWindowID
        }
    }
}

/// Pure text/icon choices for the status item, kept apart for tests.
enum MenuBarFormat {

    /// Icon + title: the fullest disk's used % ("74%") or free % ("26%"),
    /// a warning when any disk is at or below the threshold, "!" when one
    /// couldn't be read.
    static func look(
        _ readings: [DiskMonitorReport.Reading],
        threshold: Double,
        display: DiskMonitorSettings.PercentDisplay = .used
    ) -> (symbol: String, title: String) {
        if readings.contains(where: \.failed) {
            return ("exclamationmark.triangle", "!")
        }
        guard let fullest = readings.max(by: { $0.usedPercent < $1.usedPercent }) else {
            return ("internaldrive", "")
        }
        let symbol = DiskMonitorReport.isAlert(readings, threshold: threshold) ? "exclamationmark.triangle" : "internaldrive"
        switch display {
        case .used: return (symbol, "\(Int(fullest.usedPercent.rounded()))%")
        case .free: return (symbol, "\(Int(fullest.freePercent.rounded()))%")
        }
    }

    /// "/  —  74% used, 130.7 GB free of 494.4 GB" (as in diskmon's menu),
    /// or "/  —  26% free, 130.7 GB of 494.4 GB".
    static func line(for r: DiskMonitorReport.Reading, display: DiskMonitorSettings.PercentDisplay = .used) -> String {
        if r.failed { return "\(r.path)  —  couldn't be read" }
        return "\(r.path)  —  \(usage(r, display))"
    }

    /// The figures shared by the menu and the Monitoring tab.
    static func usage(_ r: DiskMonitorReport.Reading, _ display: DiskMonitorSettings.PercentDisplay) -> String {
        let free = DiskMonitorReport.gb(r.free), total = DiskMonitorReport.gb(r.total)
        switch display {
        case .used: return "\(Int(r.usedPercent.rounded()))% used, \(free) free of \(total)"
        case .free: return "\(Int(r.freePercent.rounded()))% free, \(free) of \(total)"
        }
    }

    static func schedule(last: Date?, next: Date?, now: Date = Date()) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        let lastText = last.map { "Last check \(time.string(from: $0))" } ?? "Not checked yet"
        guard let next else { return lastText }
        return "\(lastText) · next \(time.string(from: next))"
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + "%"
    }
}
