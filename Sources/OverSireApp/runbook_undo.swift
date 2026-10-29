import Foundation
import OverSireCore

/// The runbook changes of the editor and of the assistant. Each change keeps a copy of the runbooks and of the
/// project defaults before it, so Undo reverts it. It keeps at most 20 copies.
/// Use it on the main thread.
final class RunbookUndo {
    static let limit = 20

    private struct Snapshot {
        let label: String
        let runbooks: [Runbook]
        let defaults: [String: String]   // project key → runbook id
    }

    private let bus: ChangeBus
    private var stack: [Snapshot] = []

    init(bus: ChangeBus = .shared) { self.bus = bus }

    /// The label of the change that Undo reverts, for example "Delete Small".
    var last: String? { stack.last?.label }

    /// Applies `body` to the config, saves it and tells the pages.
    func change(_ label: String, _ body: (inout ProjectsConfig) -> Void) {
        let c = PROJECTS_CFG
        stack.append(Snapshot(label: label, runbooks: c.runtime.runbooks, defaults: c.settings.compactMapValues(\.runbook)))
        if stack.count > Self.limit { stack.removeFirst() }
        body(&PROJECTS_CFG)
        commit()
    }

    /// Reverts the last change. Nil when there is none.
    func undo() -> String? {
        guard let s = stack.popLast() else { return nil }
        PROJECTS_CFG.runtime.runbooks = s.runbooks
        for key in Set(PROJECTS_CFG.settings.keys).union(s.defaults.keys) {
            var l = PROJECTS_CFG.local(key)
            l.runbook = s.defaults[key]
            PROJECTS_CFG.setLocal(key, l)
        }
        commit()
        return s.label
    }

    private func commit() {
        saveConfig()
        bus.post(.config())
    }
}

let RUNBOOK_UNDO = RunbookUndo()
