import Cocoa
import ServiceManagement

// `Decaffeinate --selftest`: the pure logic, checked on any Mac (CI runs it on every pull request).
func selftest() -> Never {
    precondition(bailReason(.nominal, nil) == nil)
    precondition(bailReason(.fair, 50) == "too hot" && bailReason(.fair, 100) == "too hot") // on battery: the first warm level
    precondition(bailReason(.fair, nil) == nil && bailReason(.serious, nil) == "too hot") // on power: once macOS throttles
    precondition(maxThermal(onBattery: true) == .fair && maxThermal(onBattery: false) == .serious)
    precondition(bailReason(.fair, 10, min: 20) == "too hot") // both on battery: heat is named first
    precondition(bailReason(.critical, 80) == "too hot")
    precondition(bailReason(.nominal, 14, min: 15) == "battery 14%")
    precondition(bailReason(.nominal, 15, min: 15) == nil)
    precondition(bailReason(.nominal, 1, min: 0) == nil)
    precondition(bailReason(.nominal, 19, min: 20) == "battery 19%" && bailReason(.nominal, 20, min: 20) == nil)
    precondition(bailReason(.nominal, 0, min: 0) == nil && bailReason(.nominal, 0, min: -5) == nil) // "Never" can't trigger
    // The cutoff menu: ascending, "Never" first, and the default is one of the choices.
    precondition(batteryCutoffs == [0, 5, 10, 15, 20, 30, 40, 50] && batteryCutoffs == batteryCutoffs.sorted())
    precondition(batteryCutoffs.contains(defaultMinBattery) && defaultMinBattery == 20)
    precondition(cutoffTitle(0) == "Never" && cutoffTitle(20) == "20%" && cutoffTitle(50) == "50%")
    precondition(cutoffTitle(12) == "12%" && cutoffTitle(-5) == "Never") // a hand-edited value outside the list still reads true
    let custom = "Battery Power:\n lowpowermode         1\nAC Power:\n lowpowermode         0\n"
    precondition(powerModeSettings(custom)! == ("lowpowermode", ["-b": 1, "-c": 0]))
    precondition(powerModeSettings("AC Power:\n powermode 2\n")! == ("powermode", ["-c": 2]))
    precondition(powerModeSettings("AC Power:\n sleep 1\n") == nil)
    precondition(pmsetCmds.contains("-b lowpowermode 1") && pmsetCmds.contains("-c powermode 2"))
    // isArmed: any one of these ends the stay-awake, so each must flip the result on its own.
    precondition(isArmed(enabled: true, sessionActive: true, hasLid: true, screenLocked: false, awakeWhenLocked: false, sentToSleep: false))
    precondition(isArmed(enabled: true, sessionActive: true, hasLid: true, screenLocked: true, awakeWhenLocked: true, sentToSleep: false))
    precondition(!isArmed(enabled: false, sessionActive: true, hasLid: true, screenLocked: false, awakeWhenLocked: true, sentToSleep: false))
    precondition(!isArmed(enabled: true, sessionActive: false, hasLid: true, screenLocked: false, awakeWhenLocked: true, sentToSleep: false)) // fast user switch
    precondition(!isArmed(enabled: true, sessionActive: true, hasLid: false, screenLocked: false, awakeWhenLocked: true, sentToSleep: false)) // Mac mini, iMac
    precondition(!isArmed(enabled: true, sessionActive: true, hasLid: true, screenLocked: true, awakeWhenLocked: false, sentToSleep: false))
    // A cutoff or Sleep now: the screen locking on the way down (awakeWhenLocked on) must not re-arm it.
    precondition(!isArmed(enabled: true, sessionActive: true, hasLid: true, screenLocked: true, awakeWhenLocked: true, sentToSleep: true))
    precondition(!isArmed(enabled: true, sessionActive: true, hasLid: true, screenLocked: false, awakeWhenLocked: true, sentToSleep: true))
    // sudoersRule: one line, only whitelisted pmset commands, no wildcard.
    let bobRule = sudoersRule(user: "bob")
    precondition(bobRule.hasPrefix("bob ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, ") && bobRule.hasSuffix("\n"))
    precondition(bobRule.split(separator: "\n").count == 1 && bobRule.components(separatedBy: ", ").count == pmsetCmds.count)
    precondition(!bobRule.contains("*") && !bobRule.contains("NOPASSWD: ALL"))
    // sudoPmsetArgs
    precondition(sudoPmsetArgs(in: "a || b || /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0") == ["-a disablesleep 0"])
    precondition(sudoPmsetArgs(in: "/usr/bin/sudo -n /usr/bin/pmset -a x 1 || /usr/bin/sudo -n /usr/bin/pmset -b y 2") == ["-a x 1", "-b y 2"])
    precondition(sudoPmsetArgs(in: "/usr/bin/pmset -g").isEmpty)
    precondition(sudoPmsetArgs(in: "x && /usr/bin/sudo -n /usr/bin/pmset -a y 0\nz; /usr/bin/sudo -n /usr/bin/pmset $f $k $v; w") == ["-a y 0", "$f $k $v"])
    precondition(sudoPmsetArgs(in: "/usr/bin/sudo -n /usr/bin/pmset -a y 0 && z") == ["-a y 0"])
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
    precondition(sudoPmsetArgs(in: wdShell) == ["-a disablesleep 0", "$f $k $v"],
                 "watchdog plist missing from the bundle, or its sudo pmset commands changed")
    // $f $k $v: each power source the app saves, either Low Power Mode name, any level pmset reports.
    let wdPowerCmds = ["-b", "-c"].flatMap { f in ["powermode", "lowpowermode"].flatMap { k in (0...2).map { "\(f) \(k) \($0)" } } }
    precondition((["-a disablesleep 0"] + wdPowerCmds).allSatisfy { pmsetCmds.contains($0) })
    // ...and it restores what lowPowerOn() saved: same defaults domain, same key, the -b/-c flags powerModeSettings uses.
    precondition(wdShell.contains("d=\(Bundle.main.bundleIdentifier ?? "missing")\n") && wdShell.contains("\(savedPowerModeKey).$f"))
    precondition(wdShell.contains("for f in -b -c;") && Set(powerModeSettings(custom)!.values.keys) == ["-b", "-c"])
    // ...and a closed Mac the app was holding goes to sleep: after sleep is back on, before the early exit of
    // the Low Power restore, only if the lid is still shut. sleepnow needs no sudo, so no new sudoers entry.
    let wdSleep = "/usr/bin/defaults read $d \(heldClosedKey) > /dev/null 2>&1 && /usr/bin/defaults delete $d \(heldClosedKey) && " +
        "/usr/sbin/ioreg -r -k AppleClamshellState -d 1 | /usr/bin/grep -q '\"AppleClamshellState\" = Yes' && /usr/bin/pmset sleepnow\n"
    let wdOrder = ["-a disablesleep 0", wdSleep, "savedPowerMode > /dev/null 2>&1 || exit 0"].map { wdShell.range(of: $0)?.lowerBound }
    precondition(!wdOrder.contains(nil) && wdOrder.map { $0! } == wdOrder.map { $0! }.sorted(), "watchdog: sleep step missing or out of order")
    // The watchdog is the crash safety net: off (declined, disabled in Login Items, failed to register) must be visible.
    precondition(!watchdogNeedsAttention(hasLid: true, status: .enabled))
    precondition(watchdogNeedsAttention(hasLid: true, status: .requiresApproval))
    precondition(watchdogNeedsAttention(hasLid: true, status: .notRegistered))
    precondition(watchdogNeedsAttention(hasLid: true, status: .notFound))
    precondition(!watchdogNeedsAttention(hasLid: false, status: .notRegistered)) // no lid, never registered
    // Update check: only plain dotted numbers count as versions, so a pre-release tag is never offered.
    precondition(versionParts("v1.2.0") == [1, 2, 0] && versionParts("1.10") == [1, 10])
    precondition(versionParts("v1.3.0-rc1") == nil && versionParts("") == nil && versionParts("v") == nil)
    precondition(versionParts("1..2") == nil && versionParts("1.+2") == nil && versionParts("1.99999999999999999999") == nil)
    precondition(newerVersion("v1.2.0", than: "1.1.9") == "1.2.0" && newerVersion("v1.10.0", than: "1.9.0") == "1.10.0")
    precondition(newerVersion("v2", than: "1.9.9") == "2" && newerVersion("1.2.0", than: "1.1") == "1.2.0")
    precondition(newerVersion("v1.2.0", than: "1.2.0") == nil && newerVersion("v1.2", than: "1.2.0") == nil && newerVersion("v1.2.0", than: "1.2") == nil)
    precondition(newerVersion("v1.1.0", than: "1.2.0") == nil)
    precondition(newerVersion("v0.1.0", than: "0.0.0") == "0.1.0") // built from source without tags
    precondition(newerVersion("v1.3.0-rc1", than: "1.2.0") == nil && newerVersion("v1.3.0", than: "unknown") == nil)
    precondition(latestTag(Data(#"{"tag_name": "v1.2.0", "name": "Decaffeinate 1.2.0"}"#.utf8)) == "v1.2.0")
    precondition(latestTag(Data(#"{"message": "Not Found"}"#.utf8)) == nil && latestTag(Data(#"{"tag_name": 12}"#.utf8)) == nil)
    precondition(latestTag(Data("<html>".utf8)) == nil && latestTag(Data("[1]".utf8)) == nil)
    let day = 24 * 60 * 60.0, t0 = Date(timeIntervalSince1970: 1_000_000)
    precondition(updateCheckDue(last: nil, now: t0)) // never checked
    precondition(!updateCheckDue(last: t0, now: t0 + day - 1) && updateCheckDue(last: t0, now: t0 + day))
    precondition(updateCheckDue(last: t0, now: t0 - 1)) // clock set back past the last check
    precondition(releasesAPI.absoluteString == "https://api.github.com/repos/dstmrk/decaffeinate/releases/latest") // this fork, not upstream
    // Lid state and lid events both go through this one lookup; if it failed, every Mac would look lid-less.
    precondition(rootDomain != 0, "IOPMrootDomain not found")
    precondition(Set(glyphs.keys) == ["active", "disabled"])
    precondition(run("/bin/echo", ["hi"]) == "hi\n")
    precondition(run("/bin/sh", ["-c", "head -c 200000 /dev/zero"]).utf8.count == 200_000) // more than a pipe buffer
    precondition(run("/nonexistent", []) == "")
    print("Self-test passed.")
    print("This Mac: lid \(hasLid ? "yes" : "no"), external display \(externalDisplayActive() ? "yes" : "no"), power setting \(powerModeSettings()?.key ?? "none"), " +
          "battery \(batteryPercent().map { "\($0)%" } ?? "on AC")")
    exit(0)
}
