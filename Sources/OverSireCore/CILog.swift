import Foundation

/// CI log text. It knows the GitHub Actions markers ("##[error]", "##[group]"). Other logs pass through.
public enum CILog {
    public static let snippetLines = 15

    /// The lines up to the last "##[error]" marker, or the last lines when there is no marker.
    public static func errorSnippet(_ log: String) -> String {
        let lines = clean(log)
        let end = lines.lastIndex { $0.hasPrefix("##[error]") }.map { $0 + 1 } ?? lines.count
        return lines[max(0, end - snippetLines)..<end].joined(separator: "\n")
    }

    /// Log lines without time stamps, color codes, group markers and empty lines.
    public static func clean(_ log: String) -> [String] {
        let stamp = try! NSRegularExpression(pattern: #"^\d{4}-\d\d-\d\dT[\d:.]+Z ?|\u001B?\[[0-9;]*m"#)
        return log.components(separatedBy: "\n").compactMap { raw in
            let ns = raw.trimmingCharacters(in: .newlines) as NSString
            var l = stamp.stringByReplacingMatches(in: ns as String, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            if l.hasPrefix("##[group]") || l.hasPrefix("##[endgroup]") || l.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            if l.count > 220 { l = String(l.prefix(220)) + "\u{2026}" }
            return l
        }
    }

    public static func isError(_ line: String) -> Bool {
        if line.hasPrefix("##[error]") { return true }
        let l = line.lowercased()
        return l.contains("error:") || l.hasPrefix("fail") || l.contains("--- fail") || l.contains("panic:") || l.contains("exit code 1")
    }
}
