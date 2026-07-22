import Foundation

/// Quoting helpers for building shell command strings that get spliced into
/// an AppleScript `do shell script "..."` string literal. Two independent
/// escaping layers, applied in order, exactly mirror the Python app's
/// `shlex.quote` (POSIX shell layer) + manual backslash/quote escaping
/// (AppleScript string-literal layer).
enum ShellQuoting {
    /// Wraps `token` in POSIX single quotes, safe for any content (including
    /// spaces, `$`, backticks, double quotes, and even embedded single
    /// quotes) because everything inside `'...'` is literal except `'`
    /// itself, which is closed-escaped-reopened as `'\''`.
    ///
    /// This is safe to apply twice to compose a command that itself gets
    /// wrapped in another `sh -c '...'`: the second pass only needs to
    /// protect whatever single quotes exist in its input (including ones the
    /// first pass introduced), and the algorithm does that unconditionally.
    static func posixSingleQuote(_ token: String) -> String {
        "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func posixSingleQuoteJoin(_ tokens: [String]) -> String {
        tokens.map(posixSingleQuote).joined(separator: " ")
    }

    /// Escapes a string for embedding inside a double-quoted AppleScript
    /// string literal: `\` -> `\\`, then `"` -> `\"`. Mirrors
    /// `privileged.py`'s `shell.replace("\\", "\\\\").replace('"', '\\"')`.
    static func appleScriptStringLiteralEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
