import Foundation

/// The reply of the status prompt: where the work of one session stands.
public struct StatusReply: Hashable, Sendable, Codable {
    public enum State: String, Hashable, Sendable, Codable { case working, done, unfinished, blocked, stuck }

    /// A step that only the developer can do. `kind`: manual-check, secret, approval, login, deploy or other.
    public struct Step: Hashable, Sendable, Codable {
        public var text: String
        public var kind: String

        public init(text: String, kind: String = "other") {
            self.text = text
            self.kind = kind
        }
    }

    public var state: State
    public var headline: String
    public var done: [String]
    public var next: [String]
    public var needsYou: [Step]
    public var blockedBy: [String]
    public var nudge: String

    public init(state: State, headline: String, done: [String] = [], next: [String] = [], needsYou: [Step] = [],
                blockedBy: [String] = [], nudge: String = "") {
        self.state = state
        self.headline = headline
        self.done = done
        self.next = next
        self.needsYou = needsYou
        self.blockedBy = blockedBy
        self.nudge = nudge
    }
}
