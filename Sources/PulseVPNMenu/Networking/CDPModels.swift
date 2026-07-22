import Foundation

/// Minimal typed views over the raw `[String: Any]` CDP responses the DSID
/// auth flow actually needs (`Target.getTargets`, `Storage.getCookies`) —
/// not a full CDP protocol binding like nodriver's generated `cdp` package.
struct CDPTarget {
    let targetId: String
    let type: String
}

struct CDPCookie {
    let name: String
    let value: String
}

enum CDPModels {
    static func targets(from result: [String: Any]) -> [CDPTarget] {
        guard let list = result["targetInfos"] as? [[String: Any]] else { return [] }
        return list.compactMap { dict in
            guard let id = dict["targetId"] as? String, let type = dict["type"] as? String else { return nil }
            return CDPTarget(targetId: id, type: type)
        }
    }

    static func cookies(from result: [String: Any]) -> [CDPCookie] {
        guard let list = result["cookies"] as? [[String: Any]] else { return [] }
        return list.compactMap { dict in
            guard let name = dict["name"] as? String, let value = dict["value"] as? String else { return nil }
            return CDPCookie(name: name, value: value)
        }
    }
}
