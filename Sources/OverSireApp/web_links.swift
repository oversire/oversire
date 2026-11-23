import Foundation

// ─── Web links ───────────────────────────────────────────────────────────────
// http://<daemon>/go/<route> opens the route in the app of the Mac of the click (link.json).
// Terminals such as Orca make links only of http and https text.

enum WebLink {
    /// The base of the web links. The AppDelegate sets it to the group home.
    static var base: () -> URL? = { nil }

    static func url(_ t: Target, base: URL) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = c.path.trimmingSuffix("/") + "/go/" + t.route.path
        c.queryItems = t.focus.map { [URLQueryItem(name: "focus", value: $0)] }
        return c.url!
    }

    /// [title](web link), else the oversire:// link.
    static func markdown(_ t: Target, title: String, base: URL?) -> String {
        let link = base.map { url(t, base: $0) } ?? t.url
        let safe = title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "[\(safe)](\(link.absoluteString))"
    }
}

private extension String {
    func trimmingSuffix(_ s: String) -> String { hasSuffix(s) ? String(dropLast(s.count)) : self }
}
