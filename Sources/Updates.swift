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
