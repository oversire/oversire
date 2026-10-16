import Foundation

// ─── Plane rich text ─────────────────────────────────────────────────────────
// Plane keeps descriptions and comments as editor HTML. OverSire shows and edits
// Markdown, so it converts both ways. It covers what the Plane editor writes:
// paragraphs, headings, lists, task lists, quotes, code, tables, links and mentions.

enum PlaneMarkup {
    // `mention` gives the name for a user id of a <mention-component>.
    static func markdown(fromHTML html: String, mention: (String) -> String? = { _ in nil }) -> String {
        var w = MarkdownWriter()
        var i = html.startIndex
        while i < html.endIndex {
            guard html[i] == "<", let close = html[i...].firstIndex(of: ">") else {
                let next = html[i...].firstIndex(of: "<") ?? html.endIndex
                w.text(decodeEntities(String(html[i..<next])))
                i = next
                if i < html.endIndex, html[i...].firstIndex(of: ">") == nil {
                    w.text(String(html[i...]))
                    break
                }
                continue
            }
            let tag = Tag(String(html[html.index(after: i)..<close]))
            i = html.index(after: close)
            if tag.name == "mention-component", !tag.closing {
                let id = tag.attrs["entity_identifier"] ?? ""
                w.text("@" + (mention(id) ?? tag.attrs["entity_name"].flatMap { $0 == "user_mention" ? nil : $0 } ?? "someone"))
                continue
            }
            w.tag(tag)
        }
        return w.finish()
    }

    static func html(fromMarkdown md: String) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return blocks(lines[...])
    }

    // MARK: Markdown → HTML

    private static func blocks(_ lines: ArraySlice<String>) -> String {
        var out = ""
        var i = lines.startIndex
        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            if trimmed.hasPrefix("```") {
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.endIndex, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                out += "<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>"
                continue
            }
            if let h = heading(trimmed) {
                out += "<h\(h.level)>\(inline(h.text))</h\(h.level)>"
                i += 1; continue
            }
            if trimmed.count >= 3, Set(trimmed).count == 1, trimmed.first == "-" || trimmed.first == "*" {
                out += "<hr>"
                i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.endIndex, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if q.first == " " { q = q.dropFirst() }
                    quoted.append(String(q)); i += 1
                }
                out += "<blockquote>\(blocks(quoted[...]))</blockquote>"
                continue
            }
            if i + 1 < lines.endIndex, let head = cells(line), let sep = cells(lines[i + 1]),
               sep.count == head.count, sep.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) {
                var rows = [head]
                i += 2
                while i < lines.endIndex, let row = cells(lines[i]) { rows.append(row); i += 1 }
                out += "<table><tbody>" + rows.enumerated().map { n, row in
                    let tag = n == 0 ? "th" : "td"
                    let padded = row + Array(repeating: "", count: max(0, head.count - row.count))
                    return "<tr>" + padded.prefix(head.count).map { "<\(tag)><p>\(inline($0))</p></\(tag)>" }.joined() + "</tr>"
                }.joined() + "</tbody></table>"
                continue
            }
            if ListItem(line) != nil {
                var items: [ListItem] = []
                while i < lines.endIndex {
                    if let item = ListItem(lines[i]) {
                        items.append(item)
                    } else if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, lines[i].first == " ", !items.isEmpty {
                        items[items.count - 1].text += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    i += 1
                }
                out += list(items[...])
                continue
            }
            var para: [String] = []
            while i < lines.endIndex {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("```") || t.hasPrefix(">") || heading(t) != nil || ListItem(lines[i]) != nil { break }
                para.append(t); i += 1
            }
            out += "<p>" + para.map(inline).joined(separator: "<br>") + "</p>"
        }
        return out
    }

    // The cells of a table row such as "| a | b |". A "\\|" stays in the cell.
    private static func cells(_ line: String) -> [String]? {
        var t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") else { return nil }
        t.removeFirst()
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        return t.replacingOccurrences(of: "\\|", with: "\u{2}").components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: "\u{2}", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    private static func heading(_ s: String) -> (level: Int, text: String)? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(s.dropFirst(hashes + 1)))
    }

    private struct ListItem {
        let indent: Int
        let ordered: Bool
        let checked: Bool?
        var text: String

        init?(_ line: String) {
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let rest = line.drop { $0 == " " || $0 == "\t" }
            var body: Substring
            if let m = rest.first, "-*+".contains(m), rest.dropFirst().first == " " {
                ordered = false
                body = rest.dropFirst(2)
            } else {
                let digits = rest.prefix { $0.isNumber }
                let after = rest.dropFirst(digits.count)
                guard !digits.isEmpty, digits.count < 10, let d = after.first, d == "." || d == ")", after.dropFirst().first == " " else { return nil }
                ordered = true
                body = after.dropFirst(2)
            }
            if !ordered, body.hasPrefix("[ ] ") || body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                checked = body.dropFirst().first != " "
                body = body.dropFirst(4)
            } else {
                checked = nil
            }
            self.indent = indent
            self.text = String(body)
        }
    }

    // Items deeper than the first one belong to the item above them.
    private static func list(_ items: ArraySlice<ListItem>) -> String {
        guard let first = items.first else { return "" }
        let base = first.indent
        var groups: [(item: ListItem, children: ArraySlice<ListItem>)] = []
        var i = items.startIndex
        while i < items.endIndex {
            let item = items[i]
            var j = i + 1
            while j < items.endIndex, items[j].indent > base { j += 1 }
            groups.append((item, items[(i + 1)..<j]))
            i = j
        }
        let tasks = groups.allSatisfy { $0.item.checked != nil }
        let tag = first.ordered ? "ol" : "ul"
        var out = tasks ? "<ul data-type=\"taskList\">" : "<\(tag)>"
        for g in groups {
            let text = g.item.text.components(separatedBy: "\n").map(inline).joined(separator: "<br>")
            let nested = g.children.isEmpty ? "" : list(g.children)
            if tasks {
                out += "<li data-type=\"taskItem\" data-checked=\"\(g.item.checked == true)\"><p>\(text)</p>\(nested)</li>"
            } else {
                out += "<li><p>\(text)</p>\(nested)</li>"
            }
        }
        return out + (tasks ? "</ul>" : "</\(tag)>")
    }

    static let assetRE = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})\)"#)
    private static let imageRE = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)
    private static let linkRE = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#)
    private static let boldRE = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let strikeRE = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let italicRE = try! NSRegularExpression(pattern: #"(?<![\w*])([*_])(?=\S)(.+?)(?<=\S)\1(?![\w*])"#)

    static func inline(_ text: String) -> String {
        // Code spans first, so their text keeps its * and _.
        var codes: [String] = []
        var s = ""
        var parts = text.components(separatedBy: "`")
        if parts.count % 2 == 0 { parts[parts.count - 2] += "`" + parts.removeLast() }
        for (n, part) in parts.enumerated() {
            if n % 2 == 1 {
                codes.append("<code>\(escape(part))</code>")
                s += "\u{1}\(codes.count - 1)\u{1}"
            } else {
                s += escape(part)
            }
        }
        s = replace(assetRE, in: s, with: "<image-component src=\"$2\"></image-component>")
        s = replace(imageRE, in: s, with: "<img src=\"$2\" alt=\"$1\">")
        s = replace(linkRE, in: s, with: "<a href=\"$2\">$1</a>")
        s = replace(boldRE, in: s, with: "<strong>$2</strong>")
        s = replace(strikeRE, in: s, with: "<s>$1</s>")
        s = replace(italicRE, in: s, with: "<em>$2</em>")
        for (n, c) in codes.enumerated() { s = s.replacingOccurrences(of: "\u{1}\(n)\u{1}", with: c) }
        return s
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&nbsp;", " "), ("&#160;", " ")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}

// One HTML tag: name, attributes, and whether it closes or closes itself.
private struct Tag {
    let name: String
    let closing: Bool
    let selfClosing: Bool
    var attrs: [String: String] = [:]

    private static let attrRE = try! NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#)

    init(_ raw: String) {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        closing = s.hasPrefix("/")
        if closing { s = s.dropFirst() }
        selfClosing = s.hasSuffix("/")
        if selfClosing { s = s.dropLast() }
        let n = s.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        name = n.lowercased()
        let rest = String(s.dropFirst(n.count))
        for m in Tag.attrRE.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
            guard let k = Range(m.range(at: 1), in: rest) else { continue }
            let v = [3, 4, 5].compactMap { Range(m.range(at: $0), in: rest) }.first.map { String(rest[$0]) } ?? ""
            attrs[rest[k].lowercased()] = PlaneMarkup.decodeEntities(v)
        }
    }
}

private struct MarkdownWriter {
    private var out = ""
    private var lists: [(ordered: Bool, n: Int)] = []
    private var links: [String] = []
    private var quotes: [String.Index] = []
    private var pre = false
    private var itemOpen = false     // a list marker was written and the item has no text yet
    private var table: (row: Int, cells: Int)?

    private var indent: String { String(repeating: "  ", count: max(0, lists.count - 1)) }

    mutating func text(_ t: String) {
        if pre { out += t; return }
        var flat = t.replacingOccurrences(of: "\n", with: " ")
        if table != nil { flat = flat.replacingOccurrences(of: "|", with: "\\|") }
        if flat.trimmingCharacters(in: .whitespaces).isEmpty && (out.isEmpty || out.hasSuffix("\n") || out.hasSuffix(" ")) { return }
        out += flat
        itemOpen = false
    }

    // A blank line before a block, or one new line inside a list.
    private mutating func block() {
        if out.isEmpty { return }
        if !lists.isEmpty {
            if !out.hasSuffix("\n") { out += "\n" }
            return
        }
        while !out.hasSuffix("\n\n") { out += "\n" }
    }

    mutating func tag(_ t: Tag) {
        let open = !t.closing
        // A table cell holds one line. Its paragraphs and breaks become spaces.
        if table != nil, ["p", "div", "br", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6"].contains(t.name) {
            if (t.name == "br" || !open) && !out.hasSuffix(" ") && !out.hasSuffix("| ") { out += " " }
            return
        }
        switch t.name {
        case "table":
            if open { block(); table = (0, 0) } else { table = nil; out += "\n" }
        case "p", "div":
            if open {
                if itemOpen { return }
                if !lists.isEmpty {
                    if !out.hasSuffix("\n") { out += "\n" }
                    out += indent + "  "
                } else {
                    block()
                }
            } else if lists.isEmpty {
                out += "\n\n"
            }
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if open { block(); out += String(repeating: "#", count: Int(String(t.name.last!)) ?? 1) + " " } else { out += "\n\n" }
        case "br":
            out += lists.isEmpty ? "\n" : "\n" + indent + "  "
        case "strong", "b":
            out += "**"
        case "em", "i":
            out += "_"
        case "s", "del", "strike":
            out += "~~"
        case "code":
            if !pre { out += "`" }
        case "pre":
            if open {
                block()
                let lang = t.attrs["class"].flatMap { $0.hasPrefix("language-") ? String($0.dropFirst(9)) : nil } ?? ""
                out += "```" + lang + "\n"
                pre = true
            } else {
                pre = false
                if !out.hasSuffix("\n") { out += "\n" }
                out += "```\n\n"
            }
        case "a":
            if open { links.append(t.attrs["href"] ?? ""); out += "[" }
            else { out += "](" + (links.popLast() ?? "") + ")" }
        case "img", "image-component":
            // Plane keeps the asset id in src. OverSire gets a download link for it on display.
            if open, let src = t.attrs["src"], !src.isEmpty { out += "![](" + src + ")" }
        case "ul", "ol":
            if open {
                if lists.isEmpty { block() }
                lists.append((t.name == "ol", 0))
            } else {
                _ = lists.popLast()
                if lists.isEmpty { out += "\n\n" }
            }
        case "li":
            guard open, !lists.isEmpty else { return }
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            lists[lists.count - 1].n += 1
            let l = lists[lists.count - 1]
            var marker = l.ordered ? "\(l.n). " : "- "
            if let c = t.attrs["data-checked"] { marker += c == "true" ? "[x] " : "[ ] " }
            out += indent + marker
            itemOpen = true
        case "blockquote":
            if open {
                block()
                quotes.append(out.endIndex)
            } else if let start = quotes.popLast(), start <= out.endIndex {
                let body = out[start...].trimmingCharacters(in: .whitespacesAndNewlines)
                out = String(out[..<start]) + body.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
            }
        case "hr":
            if open { block(); out += "---\n\n" }
        case "tr":
            guard var tb = table else { return }
            if open {
                out += "| "
                tb.cells = 0
            } else {
                while out.hasSuffix(" ") { out.removeLast() }
                out += "\n"
                if tb.row == 0 { out += "|" + String(repeating: " --- |", count: max(1, tb.cells)) + "\n" }
                tb.row += 1
            }
            table = tb
        case "td", "th":
            guard !open, table != nil else { return }
            while out.hasSuffix(" ") && !out.hasSuffix("| ") { out.removeLast() }
            out += " | "
            table?.cells += 1
        default:
            break
        }
    }

    func finish() -> String {
        var s = out.components(separatedBy: "\n").map { line -> String in
            var l = Substring(line)
            while l.last == " " { l = l.dropLast() }
            return String(l)
        }.joined(separator: "\n")
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
