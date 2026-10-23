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

// The user's Low Power Mode per power source while the lid is closed, e.g. ["-b": 1, "-c": 0].
// The watchdog reads it by this name to restore it after a crash.
let savedPowerModeKey = "savedPowerMode"

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
