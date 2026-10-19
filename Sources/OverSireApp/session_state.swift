import Foundation
import OverSireCore

// The true state of one agent session. Read in order: the first clear fact wins.
enum SessionState: String, Codable, CaseIterable {
    case closed, needsInput, blocked, background, done, working, longCommand, quiet

    var label: String {
        switch self {
        case .closed: return "Closed"
        case .needsInput: return "Needs input"
        case .blocked: return "Blocked on you"
        case .background: return "Background command"
        case .done: return "Session done"
        case .working: return "Working"
        case .longCommand: return "Long command"
        case .quiet: return "Quiet"
        }
    }

    /// True when the session keeps its queue slot.
    var holdsSlot: Bool { [.needsInput, .background, .working, .longCommand, .quiet].contains(self) }

    /// True when the agent ended its turn.
    var ended: Bool { [.blocked, .background, .done].contains(self) }

    /// The facts of the read order, in the order of `SessionState.of`.
    var facts: String {
        switch self {
        case .closed: return "No live terminal"
        case .needsInput: return "Orca waits for input"
        case .blocked: return "Orca done, the last turn lists steps for you"
        case .background: return "Orca done, a background shell runs"
        case .done: return "Orca done, no shell, no steps"
        case .working: return "The screen changed in the last minutes"
        case .longCommand: return "The screen is the same, the spinner counter moves"
        case .quiet: return "Nothing moves"
        }
    }
}

// What the read order looks at for one session.
struct SessionFacts: Equatable {
    var phase: AgentSession.Phase
    var liveTerminals = 1
    var blocked = false            // the end check found steps for the user
    var shells = 0                 // background shells on the screen
    var sameFor: TimeInterval = 0  // since the last screen change
    var ticking = false            // the spinner counter moved, the screen did not

    func state(quietAfter: TimeInterval) -> SessionState {
        if liveTerminals == 0 || phase == .failed { return .closed }
        switch phase {
        case .waiting: return .needsInput
        case .done: return blocked ? .blocked : shells > 0 ? .background : .done
        default:
            if sameFor < quietAfter { return .working }
            return ticking ? .longCommand : .quiet
        }
    }
}

// What OverSire saw on the screen of one session. One read a minute keeps it current.
struct SessionWatch: Equatable {
    var fingerprint = ""
    var changedAt: Date
    var counter: String?
    var ticking = false
    var shells = 0
    var turn = ""
    var recap: String?
    var readAt: Date

    init(at: Date) {
        changedAt = at
        readAt = at
    }

    mutating func observe(_ s: HarnessScreen, at: Date) {
        let fp = s.fingerprint
        let c = s.counter
        if fp != fingerprint {
            fingerprint = fp
            changedAt = at
            ticking = false
        } else if c != nil && c != counter {
            ticking = true
        } else if c == nil {
            ticking = false
        }
        counter = c
        shells = s.shells
        turn = s.lastTurn()
        recap = s.recap
        readAt = at
    }
}

extension AgentSession {
    /// A stable hash of the last agent message.
    var messageHash: String { String((message ?? "").fnv1a, radix: 16) }
}
