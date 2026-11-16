import Foundation
import Security

/// Asks the system whether it trusts a server's certificate chain, so a
/// gateway whose certificate chains to a root in the keychain (a corporate
/// CA, say) doesn't need to be pinned. libopenconnect itself only knows
/// `/etc/ssl/cert.pem`.
public enum SystemTrust {
    /// - Parameters:
    ///   - chain: DER certificates, leaf first.
    ///   - host: the name the server was reached by, checked against the leaf.
    public static func trusts(chain: [Data], host: String?) -> Bool {
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty, certificates.count == chain.count else { return false }

        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString?)
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
              let trust
        else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
