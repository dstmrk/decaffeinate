import Cocoa
import ServiceManagement

// `Decaffeinate --selftest`: the pure logic, checked on any Mac (CI runs it on every pull request).
func selftest() -> Never {
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
    precondition(Set(glyphs.keys) == ["active", "disabled"])
    precondition(run("/bin/echo", ["hi"]) == "hi\n")
    precondition(run("/bin/sh", ["-c", "head -c 200000 /dev/zero"]).utf8.count == 200_000) // more than a pipe buffer
    precondition(run("/nonexistent", []) == "")
    print("Self-test passed.")
    print("This Mac: lid \(hasLid ? "yes" : "no"), external display \(externalDisplayActive() ? "yes" : "no"), power setting \(powerModeSettings()?.key ?? "none"), " +
          "battery \(batteryPercent().map { "\($0)%" } ?? "on AC"), draw \(batteryDraw().map { String(format: "%.1f W", $0.watts) } ?? "n/a on AC")")
    exit(0)
}
