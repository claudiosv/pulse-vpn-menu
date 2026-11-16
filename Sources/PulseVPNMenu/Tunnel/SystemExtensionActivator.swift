import Foundation
import PulseVPNTunnelProtocol
import SystemExtensions

enum ExtensionActivation {
    case ready
    /// The user has to allow the extension in System Settings first. The
    /// request stays outstanding and completes by itself once they do.
    case needsApproval
}

enum ExtensionActivationError: Error, CustomStringConvertible {
    case rebootRequired
    case failed(Error)

    var description: String {
        switch self {
        case .rebootRequired:
            return "The network extension will be ready after a restart."
        case .failed(let error):
            let nsError = error as NSError
            if nsError.domain == OSSystemExtensionErrorDomain,
               nsError.code == OSSystemExtensionError.unsupportedParentBundleLocation.rawValue {
                return "The network extension can only be installed when Pulse VPN Menu is in the Applications folder."
            }
            return "Could not activate the network extension: \(error.localizedDescription)"
        }
    }
}

/// Installs (or updates) the packet tunnel system extension bundled in
/// `Contents/Library/SystemExtensions`. Replaces the `SMAppService` daemon
/// registration: the system keeps the extension, runs it as root in the app
/// sandbox, and replaces it when the bundled copy has a different version.
@MainActor
final class SystemExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = SystemExtensionActivator()

    private var activated = false
    private var pending: [ObjectIdentifier: CheckedContinuation<ExtensionActivation, Error>] = [:]

    /// Idempotent — safe to call before every connect attempt. The first
    /// call after launch asks the system, which answers at once when the
    /// installed extension is already this build's.
    func activate() async throws -> ExtensionActivation {
        if activated { return .ready }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: TunnelConstants.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        return try await withCheckedThrowingContinuation { continuation in
            pending[ObjectIdentifier(request)] = continuation
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func resolve(_ id: ObjectIdentifier, with result: Result<ExtensionActivation, Error>) {
        if case .success(.ready) = result { activated = true }
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    // The delegate is called on the queue given to the request: main.

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        let id = ObjectIdentifier(request)
        MainActor.assumeIsolated { resolve(id, with: .success(.needsApproval)) }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        let id = ObjectIdentifier(request)
        let completed = result == .completed
        MainActor.assumeIsolated {
            if completed {
                // Also reached after an approval, when nobody is waiting.
                resolve(id, with: .success(.ready))
            } else {
                resolve(id, with: .failure(ExtensionActivationError.rebootRequired))
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let id = ObjectIdentifier(request)
        MainActor.assumeIsolated { resolve(id, with: .failure(ExtensionActivationError.failed(error))) }
    }
}
