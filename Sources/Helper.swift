import Foundation
import ServiceManagement

// Rename this file whenever pmsetCmds changes, so existing installs are asked to reinstall the helper.
let sudoersPath = "/etc/sudoers.d/decaffeinate"
// Background check that turns lid-close sleep back on if Decaffeinate isn't running (after a crash
// or force quit), so the Mac never stays awake unattended. Bundled in Contents/Library/LaunchAgents.
let watchdog = SMAppService.agent(plistName: "io.github.dstmrk.decaffeinate.watchdog.plist")

// macOS 14+/newer models name the setting "powermode"; older ones "lowpowermode". -b/-c restore per power source.
let pmsetCmds = ["-a disablesleep 0", "-a disablesleep 1"] +
    ["powermode", "lowpowermode"].flatMap { k in ["-a", "-b", "-c"].flatMap { f in (0...2).map { "\(f) \(k) \($0)" } } }

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
