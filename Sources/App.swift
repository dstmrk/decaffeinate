import Cocoa
import IOKit
import IOKit.ps
import ServiceManagement

// Menu bar template glyphs: Lucide "coffee" (ISC, see LICENSE) on its 24-unit grid, drawn at 18 pt so the
// 2-unit stroke lands at 1.5 pt. Filled steaming cup = on, empty outline cup = off.
// macOS tints templates for light and dark menu bars.
let lucideStroke = "fill='none' stroke='black' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'"
let cupOutline = "<path d='M16 8a1 1 0 0 1 1 1v8a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4V9a1 1 0 0 1 1-1h14a4 4 0 1 1 0 8h-1' \(lucideStroke)/>"
let cupFill = "<path d='M4 8h12a1 1 0 0 1 1 1v8a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4V9a1 1 0 0 1 1-1z' fill='black'/>"
let steam = "<path d='M6 2v2M10 2v2M14 2v2' \(lucideStroke)/>"
let glyphSVG = [
    "active": cupFill + cupOutline + steam,
    "disabled": cupOutline,
]
let glyphs: [String: NSImage] = glyphSVG.mapValues { body in
    let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' width='18' height='18'>\(body)</svg>"
    // SF Symbol fallback in case this macOS can't decode SVG into NSImage.
    let img = NSImage(data: Data(svg.utf8)) ?? NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)!
    img.size = NSSize(width: 18, height: 18)
    img.isTemplate = true
    return img
}

class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let toggle = NSMenuItem(title: "Keep awake when lid closed", action: #selector(flip), keyEquivalent: "")
    let uninstallItem = NSMenuItem(title: "Uninstall…", action: #selector(uninstall), keyEquivalent: "")
    let lowPowerItem = NSMenuItem(title: "Low Power Mode when lid closed", action: #selector(flipLowPower), keyEquivalent: "")
    let cutoffItem = NSMenuItem(title: "Sleep when battery below", action: nil, keyEquivalent: "")
    let closedLimitItem = NSMenuItem(title: "Sleep after lid closed for", action: nil, keyEquivalent: "")
    // While armed, disablesleep 1 makes Apple menu › Sleep do nothing.
    let sleepItem = NSMenuItem(title: "Sleep now", action: #selector(sleepNow), keyEquivalent: "")
    let lockedItem = NSMenuItem(title: "Keep awake when screen locked", action: #selector(flipLocked), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Launch at login", action: #selector(flipLogin), keyEquivalent: "")
    let watchdogItem = NSMenuItem(title: "Crash protection is off, fix…", action: #selector(openLoginItems), keyEquivalent: "")
    let updateItem = NSMenuItem(title: "", action: #selector(openReleases), keyEquivalent: "")
    let dailyUpdatesItem = NSMenuItem(title: "Check for updates daily", action: #selector(flipDailyUpdates), keyEquivalent: "")
    let checkUpdatesItem = NSMenuItem(title: "Check for updates…", action: #selector(checkUpdatesNow), keyEquivalent: "")
    var dailyUpdates: Bool { UserDefaults.standard.bool(forKey: "dailyUpdates") } // opt-in: off means no network requests
    var latestVersion: String? // set when a check found a newer release
    var lowPower: Bool { UserDefaults.standard.object(forKey: "lowPower") as? Bool ?? true }
    var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    var sessionActive = true
    var awakeWhenLocked: Bool { UserDefaults.standard.object(forKey: "awakeWhenLocked") as? Bool ?? true }
    var screenLocked = false
    var wasClosed = false
    var sentToSleep = false // see isArmed; ends when the Mac is back out of a bag (lid open or desk setup)
    var deskMode = false // lid closed with an external display in use
    var closedAt: Date? // start of the current lid-closed hold
    var closedLimitTimer: Timer?
    var installing = false

    var armed: Bool {
        isArmed(enabled: enabled, sessionActive: sessionActive, hasLid: hasLid, screenLocked: screenLocked,
                awakeWhenLocked: awakeWhenLocked, sentToSleep: sentToSleep)
    }
    let powerKey = powerModeSettings()?.key

    func applicationDidFinishLaunching(_ n: Notification) {
        // Without the sudoers rule every pmset call fails silently, so on a Mac with a lid there's nothing to run.
        if !ensureHelper() { return }
        let menu = NSMenu()
        cutoffItem.submenu = choices(batteryCutoffs, "%", #selector(setCutoff))
        closedLimitItem.submenu = choices(closedHourLimits, " h", #selector(setClosedLimit))
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        uninstallItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        // What changes the stay-awake or alerts about it stays on the first level; set-and-forget options go one level down.
        let settings = NSMenu()
        [lowPowerItem, lockedItem, cutoffItem, closedLimitItem, loginItem, dailyUpdatesItem].forEach { $0.target = self; settings.addItem($0) }
        settings.addItem(.separator())
        [checkUpdatesItem, uninstallItem].forEach { $0.target = self; settings.addItem($0) }
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settings
        [watchdogItem, updateItem, toggle, sleepItem].forEach { $0.target = self; menu.addItem($0) }
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApp.terminate), keyEquivalent: "q"))
        item.menu = menu

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionActive = false; self?.apply()
        }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionActive = true; self?.apply()
        }
        // With "Keep awake when screen locked" off, any lock (yours, or the automatic one after the display
        // turns off) ends the stay-awake.
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true; self?.apply()
        }
        dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false; self?.apply()
        }
        // Posted on logout/shutdown/restart.
        ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in restore() }

        restorePowerMode() // in case a previous run quit or crashed with the lid closed
        UserDefaults.standard.removeObject(forKey: heldClosedKey) // likewise; syncHold() writes it again if it still holds
        if hasLid {
            do { try watchdog.register() } catch { NSLog("Decaffeinate: watchdog registration failed: \(error)") }
        }
        // No timer: the app sleeps until something reevaluate() reads changes. Without a lid nothing can.
        if hasLid { observeLidAndCutoffs() }
        // Hourly, so a day that passes during sleep or a failed check is caught up within the hour.
        // The first one waits a little: at login the network is often not up yet.
        Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkDaily() }.tolerance = 10 * 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkDaily() }
        apply()
        reevaluate()
        warnIfWatchdogOff()
    }

    func applicationWillTerminate(_ n: Notification) { restore() }

    // The rule can disappear while the app runs (someone follows the README's manual removal), which makes
    // every pmset call fail silently. One stat per state change; apply() runs when someone is at the screen.
    // Declining quits the app. Returns false when it did.
    func ensureHelper() -> Bool {
        if !hasLid || FileManager.default.fileExists(atPath: sudoersPath) { return true }
        if installHelper() { return true }
        NSApp.terminate(nil)
        return false
    }

    // Once per launch; the menu item keeps showing it after that.
    func warnIfWatchdogOff() {
        guard watchdogNeedsAttention(hasLid: hasLid, status: watchdog.status) else { return }
        let alert = NSAlert()
        alert.messageText = "Crash protection is off"
        alert.informativeText = "The background check that turns sleep back on after a crash is not running. " +
            "If Decaffeinate crashes with the lid closed, your Mac stays awake until you open it again. " +
            "Allow Decaffeinate in System Settings › General › Login Items."
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openLoginItems() }
    }

    @objc func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    // A submenu of limits, each item tagged with its value; 0 reads "Never".
    func choices(_ values: [Int], _ unit: String, _ action: Selector) -> NSMenu {
        let m = NSMenu()
        for v in values {
            let i = NSMenuItem(title: cutoffTitle(v, unit), action: action, keyEquivalent: "")
            i.tag = v; i.target = self
            m.addItem(i)
        }
        return m
    }

    func apply() {
        if installing || !ensureHelper() { return }
        // disablesleep has to be set before the lid closes (lid close sleeps instantly),
        // so while armed it also stops idle sleep with the lid open. Display sleep is unaffected.
        pmset(armed ? "-a disablesleep 1" : "-a disablesleep 0")
        if !armed { restorePowerMode() }
        // Turning sleep back on while the lid is already shut doesn't sleep the Mac by itself.
        // Repeated while sentToSleep, so an event during the sleep (the screen locking) can't re-arm it.
        if !armed && (sentToSleep || wasClosed && !deskMode) { run("/usr/bin/pmset", ["sleepnow"]) }
        syncHold()
        refreshUI()
    }

    // Safety cutoffs and Sleep now. Stays asleep until the Mac is out of a bag again: a wake with the lid
    // still shut and no external display (a key press, the power button) only sleeps it again.
    func sendToSleep() {
        sentToSleep = true
        apply()
    }

    @objc func sleepNow() { sendToSleep() }

    // Keeps the hold's start time, its time limit and the watchdog's flag in step with what the Mac is doing.
    func syncHold() {
        let held = armed && wasClosed && !deskMode
        guard held != (closedAt != nil) else { return }
        closedAt = held ? Date() : nil
        if held { UserDefaults.standard.set(true, forKey: heldClosedKey) } else { UserDefaults.standard.removeObject(forKey: heldClosedKey) }
        scheduleClosedLimit()
    }

    // One timer per hold, so the limit needs no polling; reevaluate() decides when it fires.
    func scheduleClosedLimit() {
        closedLimitTimer?.invalidate()
        closedLimitTimer = nil
        guard let closedAt, maxClosedHours > 0 else { return }
        let t = Timer(fire: closedAt + TimeInterval(maxClosedHours * 3600), interval: 0, repeats: false) { [weak self] _ in
            self?.reevaluate()
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        closedLimitTimer = t
    }

    // Saves the user's per-source Low Power setting (persisted, survives a crash) then turns it on everywhere.
    func lowPowerOn() {
        guard let cur = powerModeSettings(), UserDefaults.standard.dictionary(forKey: savedPowerModeKey) == nil else { return }
        UserDefaults.standard.set(cur.values, forKey: savedPowerModeKey)
        pmset("-a \(cur.key) 1")
    }

    // Each input of reevaluate() as an event: the lid (root domain messages), an external display coming or going,
    // battery level and power source, heat, and waking from sleep (the lid can open while the Mac sleeps).
    // Events in between that change nothing cost one IOKit read.
    func observeLidAndCutoffs() {
        let me = Unmanaged.passUnretained(self).toOpaque() // the delegate lives as long as the app
        let port = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        var notifier: io_object_t = 0
        // Every root domain message, not just the clamshell one: they are rare and reevaluate() ignores the rest.
        IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { ctx, _, _, _ in
            Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue().reevaluate()
        }, me, &notifier)
        if let battery = IOPSNotificationCreateRunLoopSource({ ctx in
            Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue().reevaluate()
        }, me)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), battery, .defaultMode)
        }
        for name in [NSApplication.didChangeScreenParametersNotification, ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reevaluate() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            guard let self else { return }
            self.reevaluate()
            // A wake after sendToSleep(). Lid open: back to normal. Lid closed: an external display can take a few
            // seconds to come back, so wait; then a desk setup goes back to normal and a Mac still in a bag to sleep.
            guard self.sentToSleep else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + (lidClosed() == true ? 15 : 0)) { [weak self] in
                guard let self, self.sentToSleep else { return }
                if !(lidClosed() == true && !externalDisplayActive()) { self.sentToSleep = false }
                self.apply()
            }
        }
    }

    func reevaluate() {
        let closed = lidClosed() ?? false
        let desk = closed && externalDisplayActive()
        if closed != wasClosed || desk != deskMode {
            wasClosed = closed
            deskMode = desk
            if !closed || desk { sentToSleep = false } // see sendToSleep()
            if armed && closed && !desk {
                if lowPower { lowPowerOn() }
                run("/usr/bin/pmset", ["displaysleepnow"])
            } else if armed {
                // Lid opened, or an external display took over while closed: back to normal.
                restorePowerMode()
                apply() // also re-arms after a safety sleep
            }
            syncHold()
            refreshUI()
        }
        // Safety cutoff: lid closed and too hot, battery low or closed too long → let it sleep. Not in a desk
        // setup, where someone is using the Mac on an external display.
        if armed && closed && !desk, let why = bailReason(ProcessInfo.processInfo.thermalState, batteryPercent(),
                                                          closedFor: closedAt.map { Date().timeIntervalSince($0) } ?? 0) {
            NSLog("Decaffeinate: sleeping, \(why)")
            sendToSleep()
        }
    }

    func refreshUI() {
        toggle.state = enabled && hasLid ? .on : .off
        toggle.isEnabled = hasLid
        toggle.title = hasLid ? "Keep awake when lid closed" : "This Mac has no lid, nothing to do"
        lowPowerItem.isHidden = powerKey == nil || !hasLid
        item.button?.image = glyphs[armed ? "active" : "disabled"]
        item.button?.setAccessibilityLabel(armed ? "Decaffeinate: on" : "Decaffeinate: off")
        item.button?.toolTip = !armed ? "Lid close: sleep"
            : deskMode ? "Lid closed with an external display: normal desk use"
            : "Lid close: stay awake, low power, screen off"
        lowPowerItem.state = lowPower ? .on : .off
        lockedItem.state = awakeWhenLocked ? .on : .off
        lockedItem.isHidden = !hasLid
        cutoffItem.title = "Sleep when battery below: \(cutoffTitle(minBatteryPercent, "%"))"
        cutoffItem.submenu?.items.forEach { $0.state = $0.tag == minBatteryPercent ? .on : .off }
        closedLimitItem.title = "Sleep after lid closed for: \(cutoffTitle(maxClosedHours, " h"))"
        closedLimitItem.submenu?.items.forEach { $0.state = $0.tag == maxClosedHours ? .on : .off }
        sleepItem.isHidden = !armed
        watchdogItem.isHidden = !watchdogNeedsAttention(hasLid: hasLid, status: watchdog.status)
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        dailyUpdatesItem.state = dailyUpdates ? .on : .off
        updateItem.isHidden = latestVersion == nil
        updateItem.title = "Download Decaffeinate \(latestVersion ?? "")"
    }

    func checkDaily() {
        if dailyUpdates && updateCheckDue(last: UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date) {
            checkForUpdate(manual: false)
        }
    }

    // Only a successful check counts as the day's check. The daily one stays quiet: a newer release
    // shows up as the Download item at the top of the menu. A manual one answers with an alert either way.
    func checkForUpdate(manual: Bool) {
        fetchLatestTag { [weak self] tag in
            guard let self else { return }
            if let tag {
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                self.latestVersion = newerVersion(tag, than: appVersion)
                self.refreshUI()
            }
            if manual { self.showUpdateResult(found: tag != nil) }
        }
    }

    func showUpdateResult(found: Bool) {
        let alert = NSAlert()
        let offered = found ? latestVersion : nil // a check finishing while the alert is up can't change what Download means
        if !found {
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "GitHub didn't return a release. Check your connection and try again later."
        } else if let v = offered {
            alert.messageText = "Decaffeinate \(v) is available"
            alert.informativeText = "You have \(appVersion). The download page opens in your browser."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
        } else {
            alert.messageText = "Decaffeinate is up to date"
            alert.informativeText = "\(appVersion) is the latest version."
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn && offered != nil { openReleases() }
    }

    @objc func checkUpdatesNow() { checkForUpdate(manual: true) }

    @objc func openReleases() { NSWorkspace.shared.open(releasesPage) }

    @objc func flipDailyUpdates() {
        UserDefaults.standard.set(!dailyUpdates, forKey: "dailyUpdates")
        checkDaily()
        refreshUI()
    }

    @objc func flipLowPower() {
        UserDefaults.standard.set(!lowPower, forKey: "lowPower")
        refreshUI()
    }

    @objc func flipLocked() {
        UserDefaults.standard.set(!awakeWhenLocked, forKey: "awakeWhenLocked")
        apply()
    }

    @objc func setCutoff(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "minBattery")
        refreshUI()
    }

    @objc func setClosedLimit(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "maxClosedHours")
        scheduleClosedLimit()
        refreshUI()
    }

    @objc func flipLogin() {
        let svc = SMAppService.mainApp
        do {
            try svc.status == .enabled ? svc.unregister() : svc.register()
        } catch {
            NSLog("Decaffeinate: launch at login failed: \(error)")
        }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refreshUI()
    }

    @objc func flip() {
        enabled.toggle()
        sentToSleep = false // a way out if a Sleep now never slept
        UserDefaults.standard.set(enabled, forKey: "enabled")
        apply()
    }

    // Explains the rule before the admin prompt. False if declined or the install failed.
    func installHelper() -> Bool {
        // runModal spins the run loop, so lock/session notifications can re-enter apply() while the alert is up.
        installing = true
        defer { installing = false }
        let alert = NSAlert()
        alert.messageText = "Decaffeinate needs your permission, once"
        alert.informativeText = "To keep your Mac awake with the lid closed, Decaffeinate needs to change a few power settings. " +
            "macOS will ask for your password to allow this, and then never again.\n\n" +
            "It can only change sleep and Low Power Mode settings, nothing else on your Mac."
        alert.addButton(withTitle: "Continue…")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let user = NSUserName()
        let rule = sudoersRule(user: user)
        let sh = installScript(rule: rule, path: sudoersPath)
        NSAppleScript(source: "do shell script \"\(sh)\" with administrator privileges")?.executeAndReturnError(nil)
        return FileManager.default.fileExists(atPath: sudoersPath)
    }

    // Leaves the Mac as it was before the first launch: the Bin alone would keep the sudoers rule,
    // the watchdog and the login item registered.
    @objc func uninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Decaffeinate?"
        alert.informativeText = "Your Mac goes back to sleeping when the lid closes. Decaffeinate removes its helper, " +
            "background check, login item and settings, moves itself to the Bin and quits."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        restore() // while sudo still allows it
        if FileManager.default.fileExists(atPath: sudoersPath) {
            let removed = NSAppleScript(source: "do shell script \"/bin/rm -f \(sudoersPath)\" with administrator privileges")?.executeAndReturnError(nil) != nil
            guard removed else { apply(); return } // admin prompt cancelled: nothing removed, re-arm
        }
        try? watchdog.unregister()
        try? SMAppService.mainApp.unregister()
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        if (try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)) == nil {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) // no write access: let the user drag it
        }
        NSApp.terminate(nil)
    }
}
