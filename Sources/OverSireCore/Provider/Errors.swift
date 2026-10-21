import Foundation

/// The errors of all adapters. Each adapter maps its own errors to this type.
public enum ProviderError: Error, Hashable, Sendable {
    case unauthorized
    case forbidden
    case notFound
    case rateLimited(retryAfter: Duration?)
    case unsupported(Capability)
    case transport(String)
    case decoding(String)
    case vendor(code: String, message: String)

    public var message: String {
        switch self {
        case .unauthorized: return "The token is not valid"
        case .forbidden: return "No access"
        case .notFound: return "Not found"
        case .rateLimited: return "Rate limit hit"
        case .unsupported(let c): return "Not supported: \(c.rawValue)"
        case .transport(let m): return m
        case .decoding(let m): return "Bad answer: \(m)"
        case .vendor(_, let m): return m
        }
    }

    /// The vendor code when the project has its intake off.
    public static let intakeOff = "intake_off"

    public var isIntakeOff: Bool {
        if case .vendor(Self.intakeOff, _) = self { return true }
        return false
    }
}

// Pages show `localizedDescription`. Without this, they show "ProviderError error 4".
extension ProviderError: LocalizedError {
    public var errorDescription: String? { message }
}
