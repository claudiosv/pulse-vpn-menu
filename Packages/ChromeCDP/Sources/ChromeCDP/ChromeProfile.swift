import Foundation

/// Settings in a Chrome user-data directory that have to be in place before
/// Chrome starts.
public enum ChromeProfile {
    /// Makes Chrome keep session cookies (cookies without an expiry) across
    /// restarts, or stop doing so.
    ///
    /// Chrome only writes session cookies to disk when its startup setting is
    /// "continue where you left off" (`session.restore_on_startup` = 1);
    /// otherwise they are dropped when it quits, and a site that signs you in
    /// with one asks again next time. The side effect is that Chrome reopens
    /// the last tabs on startup, which `ChromeCookieFetcher` closes again.
    ///
    /// Chrome must not be running on `profileDir`: it rewrites its
    /// preferences when it exits.
    public static func setKeepsSessionCookies(_ keep: Bool, profileDir: URL) {
        let fileManager = FileManager.default
        let defaultDir = profileDir.appendingPathComponent("Default", isDirectory: true)
        let file = defaultDir.appendingPathComponent("Preferences")

        var preferences: [String: Any] = [:]
        if let data = try? Data(contentsOf: file),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            preferences = existing
        } else if !keep {
            return   // nothing saved yet, and Chrome's default is already "off"
        }

        var session = preferences["session"] as? [String: Any] ?? [:]
        // 1: continue where you left off; 5: the new tab page (the default).
        session["restore_on_startup"] = keep ? 1 : 5
        preferences["session"] = session

        guard let data = try? JSONSerialization.data(withJSONObject: preferences) else { return }
        try? fileManager.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
