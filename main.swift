import Cocoa
import IOKit
import IOKit.ps
import ServiceManagement

// Decaffeinate is a fork of Pilot Light by sudolabs (https://github.com/CyrisXD/pilot-light, MIT).
// It keeps a MacBook awake with the lid closed while you're logged in, switches it to
// Low Power Mode and turns the display off, then puts everything back when the lid opens.
// Logging out, switching users or quitting restores normal lid-close sleep, and so does locking the
// screen when "Keep awake when screen locked" is off.

// Rename this file whenever pmsetCmds changes, so existing installs are asked to reinstall the helper.
let sudoersPath = "/etc/sudoers.d/decaffeinate"
// Background check that turns lid-close sleep back on if Decaffeinate isn't running (after a crash
// or force quit), so the Mac never stays awake unattended. Bundled in Contents/Library/LaunchAgents.
let watchdog = SMAppService.agent(plistName: "io.github.dstmrk.decaffeinate.watchdog.plist")

// macOS 14+/newer models name the setting "powermode"; older ones "lowpowermode". -b/-c restore per power source.
let pmsetCmds = ["-a disablesleep 0", "-a disablesleep 1"] +
    ["powermode", "lowpowermode"].flatMap { k in ["-a", "-b", "-c"].flatMap { f in (0...2).map { "\(f) \(k) \($0)" } } }

@discardableResult
func run(_ path: String, _ args: [String]) -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = pipe; p.standardError = pipe
    guard (try? p.run()) != nil else { return "" }
    // Drain before waiting: a child that fills the pipe buffer (64 KB) blocks until someone reads it.
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: out, as: UTF8.self)
}

// Only the exact commands whitelisted in sudoers; -n never prompts.
func pmset(_ cmd: String) { run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + cmd.split(separator: " ").map(String.init)) }

// nil on Macs without a lid (Mac mini, iMac, Studio, Pro).
func lidClosed() -> Bool? {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    defer { IOObjectRelease(root) }
    return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool
}
let hasLid = lidClosed() != nil

// Whether Decaffeinate should hold the Mac awake right now. Every false here must lead to `disablesleep 0`.
func isArmed(enabled: Bool, sessionActive: Bool, hasLid: Bool, screenLocked: Bool, awakeWhenLocked: Bool) -> Bool {
    enabled && sessionActive && hasLid && !(screenLocked && !awakeWhenLocked)
}

// The watchdog is only registered on Macs with a lid. When it isn't running, a crash with the lid closed
// leaves the Mac awake until Decaffeinate is opened again.
func watchdogNeedsAttention(hasLid: Bool, status: SMAppService.Status) -> Bool {
    hasLid && status != .enabled
}

// The sudoers rule: exactly the pmset commands in pmsetCmds, for one user, nothing else.
func sudoersRule(user: String) -> String {
    "\(user) ALL=(root) NOPASSWD: " + pmsetCmds.map { "/usr/bin/pmset \($0)" }.joined(separator: ", ") + "\n"
}

// Shell script run as root by installHelper. Root makes the temp file in /tmp (sticky, root-owned, mode 0600;
// not $TMPDIR, which could point into a user-owned directory), so nothing the user can write sits between the
// visudo check and the install. No quotes or backslashes, so it embeds in an AppleScript string as is.
func installScript(rule: String, path: String) -> String {
    "t=$(/usr/bin/mktemp /tmp/decaffeinate.XXXXXX) && /bin/echo '\(rule.trimmingCharacters(in: .newlines))' > $t && " +
        "/usr/sbin/visudo -cf $t && /usr/bin/install -m 0440 -o root -g wheel $t \(path); s=$?; /bin/rm -f $t; exit $s"
}

// The pmset arguments a shell command runs through `sudo -n /usr/bin/pmset`, e.g. the watchdog's.
func sudoPmsetArgs(in shell: String) -> [String] {
    let marker = "/usr/bin/sudo -n /usr/bin/pmset "
    var found: [String] = [], rest = Substring(shell)
    while let r = rest.range(of: marker) {
        rest = rest[r.upperBound...]
        let end = rest.range(of: " ||")?.lowerBound ?? rest.endIndex
        found.append(String(rest[..<end]).trimmingCharacters(in: .whitespaces))
        rest = rest[end...]
    }
    return found
}

// True when an external display is in use. With the lid closed that's a normal desk setup
// (clamshell mode), so Decaffeinate leaves the displays and power mode alone.
func externalDisplayActive() -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
    guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return false }
    return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
}

// Current Low Power Mode setting per power source, e.g. ["-b": 1, "-c": 0], from `pmset -g custom`.
// Key is whichever name this Mac uses; nil if the Mac has no Low Power Mode.
func powerModeSettings(_ out: String = run("/usr/bin/pmset", ["-g", "custom"])) -> (key: String, values: [String: Int])? {
    var key: String?, flag = "-c", values: [String: Int] = [:]
    for line in out.split(separator: "\n") {
        if line.hasPrefix("Battery Power") { flag = "-b" } else if line.hasPrefix("AC Power") { flag = "-c" }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count == 2, ["powermode", "lowpowermode"].contains(String(parts[0])), let v = Int(parts[1]) {
            key = String(parts[0]); values[flag] = v
        }
    }
    return key.map { ($0, values) }
}

// Safety cutoffs while the lid is closed. The battery limit is set from the menu (0 = off).
var minBatteryPercent: Int { UserDefaults.standard.object(forKey: "minBattery") as? Int ?? 15 }
let maxThermal = ProcessInfo.ThermalState.serious

// Battery percent when running on battery, nil on AC.
func batteryPercent() -> Int? {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    guard IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String == kIOPSBatteryPowerValue else { return nil }
    for ps in IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef] {
        if let d = IOPSGetPowerSourceDescription(info, ps).takeUnretainedValue() as? [String: Any],
           let pct = d[kIOPSCurrentCapacityKey] as? Int { return pct }
    }
    return nil
}

func bailReason(_ thermal: ProcessInfo.ThermalState, _ battery: Int?, min: Int = minBatteryPercent) -> String? {
    if thermal.rawValue >= maxThermal.rawValue { return "too hot" }
    if let b = battery, b < min { return "battery \(b)%" }
    return nil
}

// Watts drawn from the battery plus full-charge energy; nil on AC (charging muddies the reading) or no battery.
func batteryDraw() -> (watts: Double, capacityWh: Double)? {
    let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard s != 0 else { return nil }
    defer { IOObjectRelease(s) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let p = props?.takeRetainedValue() as? [String: Any] else { return nil }
    return batteryDraw(p)
}

// Apple Silicon reports MaxCapacity as a percent and the mAh in AppleRawMaxCapacity; Intel reports mAh in MaxCapacity.
func batteryDraw(_ p: [String: Any]) -> (watts: Double, capacityWh: Double)? {
    guard p["ExternalConnected"] as? Bool == false,
          let mv = p["Voltage"] as? Int,
          let ma = (p["InstantAmperage"] ?? p["Amperage"]) as? Int, ma < 0,
          let mah = (p["AppleRawMaxCapacity"] as? Int) ?? (p["MaxCapacity"] as? Int).flatMap({ $0 > 100 ? $0 : nil })
    else { return nil }
    return (Double(-ma * mv) / 1e6, Double(mah * mv) / 1e6)
}

func statLine(_ label: String, sum: Double, n: Int, capacityWh: Double) -> String {
    guard n > 0 else { return "\(label): measuring on battery…" }
    let w = sum / Double(n)
    let hours = capacityWh > 0 ? String(format: " · ~%.0f h battery", capacityWh / w) : ""
    return String(format: "%@: %.1f W%@", label, w, hours)
}

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
    var lowPower: Bool { UserDefaults.standard.object(forKey: "lowPower") as? Bool ?? true }
    var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    var sessionActive = true
    var awakeWhenLocked: Bool { UserDefaults.standard.object(forKey: "awakeWhenLocked") as? Bool ?? true }
    var screenLocked = false
    var wasClosed = false
    var bailed = false // slept for safety; stays asleep until lid opens
    var deskMode = false // lid closed with an external display in use
    let openStat = NSMenuItem(), closedStat = NSMenuItem()
    let resetStats = NSMenuItem(title: "Reset power averages", action: #selector(reset), keyEquivalent: "")
    var installing = false
    var lastChange = Date(), lastSample = Date.distantPast
    var capacityWh = 0.0

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
        [watchdogItem, toggle, lowPowerItem, lockedItem, loginItem, cutoffItem].forEach { $0.target = self; menu.addItem($0) }
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Average power on battery", action: nil, keyEquivalent: "")
        header.isEnabled = false
        [header, openStat, closedStat].forEach { menu.addItem($0) }
        resetStats.target = self
        menu.addItem(resetStats)
        menu.addItem(.separator())
        uninstallItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        uninstallItem.target = self
        menu.addItem(uninstallItem)
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
        guard let cur = powerModeSettings(), UserDefaults.standard.dictionary(forKey: "savedPowerMode") == nil else { return }
        UserDefaults.standard.set(cur.values, forKey: "savedPowerMode")
        pmset("-a \(cur.key) 1")
    }

    func tick() {
        let closed = lidClosed() ?? false
        let desk = closed && externalDisplayActive()
        if closed != wasClosed || desk != deskMode {
            wasClosed = closed
            deskMode = desk
            lastChange = Date()
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
        if Date().timeIntervalSince(lastSample) >= 30 { sample() }
    }

    // Running mean per lid state, persisted so it builds up over days.
    // Skips the first minute after a lid change (display/power mode still settling)
    // and lid-closed time when Decaffeinate isn't holding the Mac awake.
    func sample() {
        lastSample = Date()
        guard Date().timeIntervalSince(lastChange) > 60, !wasClosed || (armed && !bailed && !deskMode),
              let b = batteryDraw() else { return }
        capacityWh = b.capacityWh
        let key = wasClosed ? "closed" : "open", d = UserDefaults.standard
        d.set(d.double(forKey: key + "Sum") + b.watts, forKey: key + "Sum")
        d.set(d.integer(forKey: key + "N") + 1, forKey: key + "N")
        refreshStats()
    }

    func refreshStats() {
        let d = UserDefaults.standard
        openStat.title = statLine("Lid open", sum: d.double(forKey: "openSum"), n: d.integer(forKey: "openN"), capacityWh: capacityWh)
        closedStat.title = statLine("Lid closed", sum: d.double(forKey: "closedSum"), n: d.integer(forKey: "closedN"), capacityWh: capacityWh)
    }

    @objc func reset() {
        let alert = NSAlert()
        alert.messageText = "Reset power averages?"
        alert.informativeText = "Lid-open and lid-closed averages start over from zero."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true) // menu bar apps aren't frontmost; without this the alert opens behind other windows
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ["openSum", "openN", "closedSum", "closedN"].forEach(UserDefaults.standard.removeObject)
        refreshStats()
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
        refreshStats()
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
        alert.messageText = "Decaffeinate needs a one-time admin permission"
        alert.informativeText = "It adds a sudoers rule that lets Decaffeinate run only the pmset sleep and Low Power commands, " +
            "so it doesn't ask for your password every time the lid closes. Without it Decaffeinate can't keep your Mac awake."
        alert.addButton(withTitle: "Install…")
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

// Puts back exactly what lowPowerOn() saved, per power source.
func restorePowerMode() {
    guard let saved = UserDefaults.standard.dictionary(forKey: "savedPowerMode") as? [String: Int],
          let key = powerModeSettings()?.key else { return }
    saved.forEach { pmset("\($0.key) \(key) \($0.value)") }
    UserDefaults.standard.removeObject(forKey: "savedPowerMode")
}

func restore() {
    pmset("-a disablesleep 0")
    restorePowerMode()
}

if CommandLine.arguments.contains("--selftest") {
    precondition(bailReason(.nominal, nil) == nil)
    precondition(bailReason(.fair, 50) == nil)
    precondition(bailReason(.serious, nil) == "too hot")
    precondition(bailReason(.critical, 80) == "too hot")
    precondition(bailReason(.nominal, 14, min: 15) == "battery 14%")
    precondition(bailReason(.nominal, 15, min: 15) == nil)
    precondition(bailReason(.nominal, 1, min: 0) == nil)
    precondition(statLine("Lid open", sum: 0, n: 0, capacityWh: 100) == "Lid open: measuring on battery…")
    precondition(statLine("Lid closed", sum: 48, n: 10, capacityWh: 96) == "Lid closed: 4.8 W · ~20 h battery")
    let custom = "Battery Power:\n lowpowermode         1\nAC Power:\n lowpowermode         0\n"
    precondition(powerModeSettings(custom)! == ("lowpowermode", ["-b": 1, "-c": 0]))
    precondition(powerModeSettings("AC Power:\n powermode 2\n")! == ("powermode", ["-c": 2]))
    precondition(powerModeSettings("AC Power:\n sleep 1\n") == nil)
    precondition(batteryDraw(["ExternalConnected": false, "Voltage": 12000, "InstantAmperage": -1000, "AppleRawMaxCapacity": 8000, "MaxCapacity": 100])! == (12.0, 96.0))
    precondition(batteryDraw(["ExternalConnected": false, "Voltage": 12000, "Amperage": -500, "MaxCapacity": 5000])! == (6.0, 60.0)) // Intel
    precondition(batteryDraw(["ExternalConnected": true, "Voltage": 12000, "InstantAmperage": 2000, "AppleRawMaxCapacity": 8000]) == nil)
    precondition(pmsetCmds.contains("-b lowpowermode 1") && pmsetCmds.contains("-c powermode 2"))
    // isArmed: any one of these ends the stay-awake, so each must flip the result on its own.
    precondition(isArmed(enabled: true, sessionActive: true, hasLid: true, screenLocked: false, awakeWhenLocked: false))
    precondition(isArmed(enabled: true, sessionActive: true, hasLid: true, screenLocked: true, awakeWhenLocked: true))
    precondition(!isArmed(enabled: false, sessionActive: true, hasLid: true, screenLocked: false, awakeWhenLocked: true))
    precondition(!isArmed(enabled: true, sessionActive: false, hasLid: true, screenLocked: false, awakeWhenLocked: true)) // fast user switch
    precondition(!isArmed(enabled: true, sessionActive: true, hasLid: false, screenLocked: false, awakeWhenLocked: true)) // Mac mini, iMac
    precondition(!isArmed(enabled: true, sessionActive: true, hasLid: true, screenLocked: true, awakeWhenLocked: false))
    // sudoersRule: one line, only whitelisted pmset commands, no wildcard.
    let bobRule = sudoersRule(user: "bob")
    precondition(bobRule.hasPrefix("bob ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, ") && bobRule.hasSuffix("\n"))
    precondition(bobRule.split(separator: "\n").count == 1 && bobRule.components(separatedBy: ", ").count == pmsetCmds.count)
    precondition(!bobRule.contains("*") && !bobRule.contains("NOPASSWD: ALL"))
    // sudoPmsetArgs
    precondition(sudoPmsetArgs(in: "a || b || /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0") == ["-a disablesleep 0"])
    precondition(sudoPmsetArgs(in: "/usr/bin/sudo -n /usr/bin/pmset -a x 1 || /usr/bin/sudo -n /usr/bin/pmset -b y 2") == ["-a x 1", "-b y 2"])
    precondition(sudoPmsetArgs(in: "/usr/bin/pmset -g").isEmpty)
    // installScript runs as root inside an AppleScript string: the file is made by root, validated, then installed,
    // and the script needs no quote or backslash escaping.
    let script = installScript(rule: bobRule, path: "/etc/sudoers.d/x")
    precondition(!bobRule.contains("'") && !script.contains("\"") && !script.contains("\\"))
    precondition(script.contains("echo '" + String(bobRule.dropLast()) + "'")) // one line, trailing newline left to echo
    precondition(script.hasPrefix("t=$(/usr/bin/mktemp /tmp/decaffeinate.XXXXXX) &&")) // root-owned, 0600, created exclusively, in sticky /tmp
    precondition(!script.contains(NSTemporaryDirectory())) // nothing the user can write between check and install
    precondition(script.range(of: "/usr/sbin/visudo -cf $t")!.lowerBound < script.range(of: "/usr/bin/install -m 0440 -o root -g wheel $t /etc/sudoers.d/x")!.lowerBound)
    precondition(script.hasSuffix("; s=$?; /bin/rm -f $t; exit $s")) // cleaned up on success and failure
    // The watchdog runs as the user through the same sudoers rule: every command it runs must be whitelisted.
    let agents = Bundle.main.bundlePath + "/Contents/Library/LaunchAgents/"
    let wd = NSDictionary(contentsOfFile: agents + "io.github.dstmrk.decaffeinate.watchdog.plist")
    let wdShell = (wd?["ProgramArguments"] as? [String])?.last ?? ""
    precondition(!sudoPmsetArgs(in: wdShell).isEmpty, "watchdog plist missing from the bundle or runs no sudo pmset")
    precondition(sudoPmsetArgs(in: wdShell).allSatisfy { pmsetCmds.contains($0) })
    // The watchdog is the crash safety net: off (declined, disabled in Login Items, failed to register) must be visible.
    precondition(!watchdogNeedsAttention(hasLid: true, status: .enabled))
    precondition(watchdogNeedsAttention(hasLid: true, status: .requiresApproval))
    precondition(watchdogNeedsAttention(hasLid: true, status: .notRegistered))
    precondition(watchdogNeedsAttention(hasLid: true, status: .notFound))
    precondition(!watchdogNeedsAttention(hasLid: false, status: .notRegistered)) // no lid, never registered
    precondition(Set(glyphs.keys) == ["active", "disabled"])
    precondition(run("/bin/echo", ["hi"]) == "hi\n")
    precondition(run("/bin/sh", ["-c", "head -c 200000 /dev/zero"]).utf8.count == 200_000) // more than a pipe buffer
    precondition(run("/nonexistent", []) == "")
    print("Self-test passed.")
    print("This Mac: lid \(hasLid ? "yes" : "no"), external display \(externalDisplayActive() ? "yes" : "no"), power setting \(powerModeSettings()?.key ?? "none"), " +
          "battery \(batteryPercent().map { "\($0)%" } ?? "on AC"), draw \(batteryDraw().map { String(format: "%.1f W", $0.watts) } ?? "n/a on AC")")
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
