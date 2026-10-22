import Foundation
import OverSireCore

/// Removes secrets from tool results before they go to the model, and from the args in the log.
/// It replaces the known secret values (the Keychain) and the token shapes of the vendors.
public struct Redactor: Sendable {
    public static let mask = "[secret]"

    // GitHub, OpenAI and Anthropic, Plane, Slack, and a bearer header.
    static let shapes: [String] = [
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        #"\bsk-[A-Za-z0-9_-]{16,}"#,
        #"\bplane_api_[A-Za-z0-9]{16,}"#,
        #"\bxox[abpr]-[A-Za-z0-9-]{10,}"#,
        #"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{16,}=*"#,
    ]
    private static let regexes: [NSRegularExpression] = shapes.compactMap { try? NSRegularExpression(pattern: $0) }

    /// Values shorter than 8 characters are not secrets: a mask of them breaks plain words.
    public let secrets: [String]

    public init(secrets: [String] = []) {
        self.secrets = Set(secrets.filter { $0.count >= 8 }).sorted { $0.count > $1.count }
    }

    public func redact(_ s: String) -> String {
        var out = s
        for v in secrets where out.contains(v) { out = out.replacingOccurrences(of: v, with: Self.mask) }
        for re in Self.regexes {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: Self.mask)
        }
        return out
    }

    public func redact(_ v: JSONValue) -> JSONValue {
        switch v {
        case .string(let s): return .string(redact(s))
        case .array(let a): return .array(a.map(redact))
        case .object(let o): return .object(o.mapValues(redact))
        default: return v
        }
    }
}
