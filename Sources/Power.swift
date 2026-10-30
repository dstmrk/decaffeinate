import Cocoa
import IOKit
import IOKit.ps

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

// The power management root: it holds the lid state and posts its changes. Looked up once, kept for the app's lifetime.
let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

// nil on Macs without a lid (Mac mini, iMac, Studio, Pro).
func lidClosed() -> Bool? {
    IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool
}
let hasLid = lidClosed() != nil

// Whether Decaffeinate should hold the Mac awake right now. Every false here must lead to `disablesleep 0`.
// sentToSleep: Decaffeinate put the Mac to sleep (a safety cutoff, or Sleep now) and it hasn't come back yet.
func isArmed(enabled: Bool, sessionActive: Bool, hasLid: Bool, screenLocked: Bool, awakeWhenLocked: Bool, sentToSleep: Bool) -> Bool {
    enabled && sessionActive && hasLid && !(screenLocked && !awakeWhenLocked) && !sentToSleep
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

// Safety cutoffs while the lid is closed. The battery and time limits are set from the menu (0 = never).
let batteryCutoffs = [0, 5, 10, 15, 20, 30, 40, 50]
let defaultMinBattery = 20
var minBatteryPercent: Int { UserDefaults.standard.object(forKey: "minBattery") as? Int ?? defaultMinBattery }
// Hours the lid may stay closed before the Mac sleeps anyway, for a job that ended long ago. Off by default.
let closedHourLimits = [0, 1, 2, 4, 8, 12, 24]
var maxClosedHours: Int { UserDefaults.standard.integer(forKey: "maxClosedHours") }

// Also names a stored value that isn't in the menu, so the menu always shows the limit in force.
func cutoffTitle(_ value: Int, _ unit: String) -> String { value <= 0 ? "Never" : "\(value)\(unit)" }

// The first level above normal: a closed MacBook (in a bag, on a sofa) can't shed heat the way an open one does.
let maxThermal = ProcessInfo.ThermalState.fair

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

// closedFor: seconds since the current lid-closed hold began.
func bailReason(_ thermal: ProcessInfo.ThermalState, _ battery: Int?, min: Int = minBatteryPercent,
                closedFor: TimeInterval = 0, maxHours: Int = maxClosedHours) -> String? {
    if thermal.rawValue >= maxThermal.rawValue { return "too hot" }
    if let b = battery, b < min { return "battery \(b)%" }
    if maxHours > 0 && closedFor >= TimeInterval(maxHours * 3600) { return "lid closed \(maxHours) h" }
    return nil
}

// The user's Low Power Mode per power source while the lid is closed, e.g. ["-b": 1, "-c": 0].
// The watchdog reads it by this name to restore it after a crash.
let savedPowerModeKey = "savedPowerMode"

// Set while Decaffeinate holds the Mac awake with the lid closed and no external display. The watchdog reads it
// by this name: if the app died meanwhile (or quit), nothing else would put the closed Mac to sleep.
let heldClosedKey = "heldClosed"

// Puts back exactly what lowPowerOn() saved, per power source.
func restorePowerMode() {
    guard let saved = UserDefaults.standard.dictionary(forKey: savedPowerModeKey) as? [String: Int],
          let key = powerModeSettings()?.key else { return }
    saved.forEach { pmset("\($0.key) \(key) \($0.value)") }
    UserDefaults.standard.removeObject(forKey: savedPowerModeKey)
}

func restore() {
    pmset("-a disablesleep 0")
    restorePowerMode()
}
