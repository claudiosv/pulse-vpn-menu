import Foundation

/// Minimal typed views over the raw `[String: Any]` CDP responses the login
/// flow actually needs (`Target.getTargets`, `Storage.getCookies`) —
/// not a full CDP protocol binding like nodriver's generated `cdp` package.
public struct CDPTarget: Sendable {
    public let targetId: String
    public let type: String
}

public struct CDPCookie: Sendable {
    public let name: String
    public let value: String
}

public enum CDPModels {
    public static func targets(from result: [String: Any]) -> [CDPTarget] {
        guard let list = result["targetInfos"] as? [[String: Any]] else { return [] }
        return list.compactMap { dict in
            guard let id = dict["targetId"] as? String, let type = dict["type"] as? String else { return nil }
            return CDPTarget(targetId: id, type: type)
        }
    }

    public static func cookies(from result: [String: Any]) -> [CDPCookie] {
        guard let list = result["cookies"] as? [[String: Any]] else { return [] }
        return list.compactMap { dict in
            guard let name = dict["name"] as? String, let value = dict["value"] as? String else { return nil }
            return CDPCookie(name: name, value: value)
        }
    }
}
