import Cocoa
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
    var bailed = false // slept for safety; stays asleep until lid opens
    var deskMode = false // lid closed with an external display in use
    var installing = false

    var armed: Bool { isArmed(enabled: enabled, sessionActive: sessionActive, hasLid: hasLid, screenLocked: screenLocked, awakeWhenLocked: awakeWhenLocked) }
    let powerKey = powerModeSettings()?.key

    func applicationDidFinishLaunching(_ n: Notification) {
        // Without the sudoers rule every pmset call fails silently, so on a Mac with a lid there's nothing to run.
        if !ensureHelper() { return }
        let menu = NSMenu()
        let cutoffs = NSMenu()
        for pct in [0, 10, 15, 20] {
            let i = NSMenuItem(title: pct == 0 ? "Off" : "\(pct)%", action: #selector(setCutoff), keyEquivalent: "")
            i.tag = pct; i.target = self
            cutoffs.addItem(i)
        }
        cutoffItem.submenu = cutoffs
        updateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        [watchdogItem, updateItem, toggle, lowPowerItem, lockedItem, loginItem, dailyUpdatesItem, cutoffItem].forEach { $0.target = self; menu.addItem($0) }
        menu.addItem(.separator())
        uninstallItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        [checkUpdatesItem, uninstallItem].forEach { $0.target = self; menu.addItem($0) }
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
        if hasLid {
            do { try watchdog.register() } catch { NSLog("Decaffeinate: watchdog registration failed: \(error)") }
        }
        // Polls the lid every 2 seconds. An IOKit interest notification would react faster, but polling is simpler and cheap.
        // The tolerance lets macOS coalesce this wakeup with other timers instead of waking the CPU on its own.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }.tolerance = 0.5
        // Hourly, so a day that passes during sleep or a failed check is caught up within the hour.
        // The first one waits a little: at login the network is often not up yet.
        Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkDaily() }.tolerance = 10 * 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkDaily() }
        apply()
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

    func apply() {
        if installing || !ensureHelper() { return }
        bailed = false
        // disablesleep has to be set before the lid closes (lid close sleeps instantly),
        // so while armed it also stops idle sleep with the lid open. Display sleep is unaffected.
        pmset(armed ? "-a disablesleep 1" : "-a disablesleep 0")
        if !armed { restorePowerMode() }
        // Turning sleep back on while the lid is already shut doesn't sleep the Mac by itself.
        if !armed && wasClosed && !deskMode { run("/usr/bin/pmset", ["sleepnow"]) }
        refreshUI()
    }

    // Saves the user's per-source Low Power setting (persisted, survives a crash) then turns it on everywhere.
    func lowPowerOn() {
        guard let cur = powerModeSettings(), UserDefaults.standard.dictionary(forKey: savedPowerModeKey) == nil else { return }
        UserDefaults.standard.set(cur.values, forKey: savedPowerModeKey)
        pmset("-a \(cur.key) 1")
    }

    func tick() {
        let closed = lidClosed() ?? false
        let desk = closed && externalDisplayActive()
        if closed != wasClosed || desk != deskMode {
            wasClosed = closed
            deskMode = desk
            if armed && closed && !desk {
                if lowPower { lowPowerOn() }
                run("/usr/bin/pmset", ["displaysleepnow"])
            } else if armed {
                // Lid opened, or an external display took over while closed: back to normal.
                restorePowerMode()
                apply() // also re-arms after a safety sleep
            }
            refreshUI()
        }
        // Safety cutoff: lid closed and too hot or battery low → let it sleep. Not in a desk setup,
        // where someone is using the Mac on an external display.
        if armed && closed && !desk && !bailed, let why = bailReason(ProcessInfo.processInfo.thermalState, batteryPercent()) {
            NSLog("Decaffeinate: sleeping, \(why)")
            bailed = true
            pmset("-a disablesleep 0")
            run("/usr/bin/pmset", ["sleepnow"])
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
        cutoffItem.submenu?.items.forEach { $0.state = $0.tag == minBatteryPercent ? .on : .off }
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
