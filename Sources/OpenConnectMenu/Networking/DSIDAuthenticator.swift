import ChromeCDP
import Foundation

/// Drives a real, visible Chrome window to the VPN login page and waits for
/// the `DSID` session cookie to appear once the user logs in. The browser
/// driving lives in the `ChromeCDP` package; this adds the VPN specifics.
/// Direct reimplementation of `launcher.py`'s `fetch_dsid()`.
actor DSIDAuthenticator {
    func fetchDSID(vpnURL: String) async throws -> String {
        // The login profile is kept between runs; the 1Password extension in
        // it needs its desktop-app host to unlock without the master password.
        try await ChromeCookieFetcher.fetch(
            cookieNamed: "DSID", at: vpnURL, profileDir: AppPaths.chromeProfileDir,
            nativeMessagingHosts: ["com.1password.1password"])
    }
}
