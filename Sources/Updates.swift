import Foundation

// Update check: this fork's latest GitHub release, compared with this build's version. Off unless
// the user turns on the daily check or picks "Check for updates…".
let releasesAPI = URL(string: "https://api.github.com/repos/dstmrk/decaffeinate/releases/latest")!
let releasesPage = URL(string: "https://github.com/dstmrk/decaffeinate/releases/latest")!
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

// "v1.2.0" → [1, 2, 0]. nil for anything else, a pre-release suffix included, so it's never offered as an update.
func versionParts(_ v: String) -> [Int]? {
    let parts = (v.hasPrefix("v") ? v.dropFirst() : Substring(v)).split(separator: ".", omittingEmptySubsequences: false)
    guard parts.allSatisfy({ p in !p.isEmpty && p.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
    let n = parts.compactMap { Int($0) } // drops a component too large for Int
    return n.count == parts.count ? n : nil
}

// The release's version as shown in the menu ("v1.2.0" → "1.2.0") when it's newer than this build, else nil.
// Missing components count as 0: "1.2" and "1.2.0" are the same version.
func newerVersion(_ tag: String, than current: String) -> String? {
    guard var a = versionParts(tag), var b = versionParts(current) else { return nil }
    let n = max(a.count, b.count)
    a += Array(repeating: 0, count: n - a.count)
    b += Array(repeating: 0, count: n - b.count)
    return b.lexicographicallyPrecedes(a) ? String(tag.drop { $0 == "v" }) : nil
}

// tag_name from the releases/latest JSON; nil for an error body or anything unexpected.
func latestTag(_ data: Data) -> String? {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String
}

// A day after the last successful check, or at once if the clock was set back past it.
func updateCheckDue(last: Date?, now: Date = Date()) -> Bool {
    guard let last else { return true }
    let elapsed = now.timeIntervalSince(last)
    return elapsed >= 24 * 60 * 60 || elapsed < 0
}

// One anonymous request to GitHub's public API; nothing about the Mac is sent. nil on any failure.
func fetchLatestTag(_ done: @escaping (String?) -> Void) {
    var req = URLRequest(url: releasesAPI, timeoutInterval: 15)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("Decaffeinate/\(appVersion)", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        let tag = (resp as? HTTPURLResponse)?.statusCode == 200 ? data.flatMap(latestTag) : nil
        DispatchQueue.main.async { done(tag) }
    }.resume()
}

// One-click install. CI attaches the app to every release as a zip made by ditto, which keeps the code signature.
// Release tags always start with "v" (ci.yml releases only v* tags); newerVersion() leaves only digits and dots.
let updateBundleID = "io.github.dstmrk.decaffeinate"
func updateZipURL(_ version: String) -> URL {
    URL(string: "https://github.com/dstmrk/decaffeinate/releases/download/v\(version)/Decaffeinate.zip")!
}

// The unpacked app is the one that was offered: this app, at that version. Anything else is refused.
func isOfferedUpdate(_ info: [String: Any]?, version: String) -> Bool {
    info?["CFBundleIdentifier"] as? String == updateBundleID && info?["CFBundleShortVersionString"] as? String == version
}

func succeeds(_ path: String, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// Downloads the offered release and unpacks it on the same volume as `app`, so the swap is a rename. The new app's
// URL, or nil on any failure.
func downloadUpdate(_ version: String, beside app: URL, _ done: @escaping (URL?) -> Void) {
    var req = URLRequest(url: updateZipURL(version), timeoutInterval: 60)
    req.setValue("Decaffeinate/\(appVersion)", forHTTPHeaderField: "User-Agent")
    URLSession.shared.downloadTask(with: req) { zip, resp, _ in
        let new = (resp as? HTTPURLResponse)?.statusCode == 200 ? zip.flatMap { unpackUpdate($0, version, beside: app) } : nil
        DispatchQueue.main.async { done(new) }
    }.resume()
}

// The app's own download carries no quarantine flag and ditto --noqtn adds none, so Gatekeeper doesn't stop the
// relaunch: the trust is the same as downloading the dmg by hand, an HTTPS download from this repo's releases.
// codesign catches a truncated or altered bundle. Runs while URLSession still holds the zip.
func unpackUpdate(_ zip: URL, _ version: String, beside app: URL) -> URL? {
    let fm = FileManager.default
    guard let dir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true) else { return nil }
    let new = dir.appendingPathComponent("Decaffeinate.app")
    if succeeds("/usr/bin/ditto", ["-x", "-k", "--noqtn", zip.path, dir.path]),
       isOfferedUpdate(Bundle(url: new)?.infoDictionary, version: version),
       succeeds("/usr/bin/codesign", ["--verify", "--strict", new.path]) {
        return new
    }
    try? fm.removeItem(at: dir)
    return nil
}

// Opens the app again once this process has exited: open on a running app would only bring it forward.
func relaunch(_ app: URL) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
                   String(ProcessInfo.processInfo.processIdentifier), app.path]
    try? p.run()
}
