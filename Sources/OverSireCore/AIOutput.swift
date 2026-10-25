import Foundation

/// The result of one automatic AI job, in the synced store. Only the owner app runs the job; the other apps show its record (OVERSIRE-327).
public struct AIOutput: StoreRecord {
    public static let collection = "ai-outputs"

    /// <kind>:<subject>. One record for each subject: a new input replaces the old result.
    public let id: String
    public let kind: String
    public let subject: String
    /// The hash of the job input. A record with another hash does not count for a new input.
    public var hash: String
    /// The app form of the result.
    public var body: JSONValue
    public var at: Date

    public init(kind: String, subject: String, hash: String, body: JSONValue, at: Date) {
        id = Self.id(kind, subject)
        self.kind = kind
        self.subject = subject
        self.hash = hash
        self.body = body
        self.at = at
    }

    public static func id(_ kind: String, _ subject: String) -> String { kind + ":" + subject }
}
