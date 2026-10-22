import Foundation
import OverSireCore
import OverSireAI
import OverSireAssistant

// The page actions of the assistant: move the window and read what it shows.
struct PageActions {
    let link: ActionLink

    var specs: [ActionSpec] {
        let link = link
        return [
            ActionSpec(id: "page.navigate", title: "Go to page", help: "Opens a page of the window, for example item/OVERSIRE-12/session or work/lanes. `focus` is a row id to show. It works only when Follow along is on for the chat.",
                       kind: .read, input: ActionSpec.args(["route": ("string", "The path of the page."), "focus": ("string", "A row id of the page.")], required: ["route"])) { a in
                if case .assistant(let thread) = a.caller, await !link.follows(thread) {
                    return .notAllowed("Follow along is off for this chat. Give the user the link oversire://\(a.string("route") ?? "").")
                }
                return await link.run { d, done in
                    guard let path = a.string("route"), let t = Target(path: path) else { done(.notAllowed("No page \(a.string("route") ?? "").")); return }
                    guard let w = d.pages else { done(.notAllowed("The window is not open.")); return }
                    let from = w.router.current.path
                    w.go(t.route, focus: a.string("focus") ?? t.focus)
                    let focus = a.string("focus") ?? t.focus
                    done(.ok(summary: "The window shows \(t.route.title).", parts: [.navigation(route: t.route.path, focus: focus, from: from)]))
                }
            },
            ActionSpec(id: "page.current", title: "Current page", help: "Reads the page of the window: its route, title, the rows in view (id and one line) and the selection.",
                       kind: .read) { _ in
                await link.run { d, done in
                    guard let page = d.pages?.page else { done(.ok(summary: "The window is not open.")); return }
                    let c = page.context
                    done(.ok(summary: "\(c.title): \(c.rows.count) rows in view.", data: JSONValue(encoding: c)))
                }
            },
        ]
    }
}
