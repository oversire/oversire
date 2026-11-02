import Cocoa
import OverSireCore

// ─── Diff syntax colors ──────────────────────────────────────────────────────
// A small tokenizer for the diff of Item › Changes (OVERSIRE-392). No package: keywords, strings, comments, numbers, types and keys.
// It reads one line at a time. A block comment or a long string continues on the next line through `State`.
// The colors are decoration only. The diff marks ("+", "−") stay the signal.

struct SyntaxLanguage {
    enum Kind: Equatable { case keyword, string, comment, number, type, key }

    /// A colored range in UTF-16 units, for `NSAttributedString`.
    struct Token: Equatable {
        let kind: Kind
        let range: NSRange
    }

    /// An open block comment or long string: the mark that closes it.
    struct State: Equatable {
        fileprivate var close: [UInt16]?
        fileprivate var kind = Kind.comment
    }

    struct Block {
        let open: String
        let close: String
        let kind: Kind
    }

    var keywords: Set<String> = []
    /// Words that color as a type, such as `string` in Go.
    var builtins: Set<String> = []
    var lineComments: [String] = []
    var blocks: [Block] = []
    var quotes: Set<UInt16> = [quote, apostrophe]
    /// A word with a capital first letter is a type.
    var capitalTypes = false
    /// A word or string before this mark, at the start of the line, is a key: `name:` in YAML, `"name":` in JSON, `name =` in TOML.
    var keyMark: UInt16?
    /// More characters in a word after its first letter, such as "-" in YAML keys.
    var wordExtra: Set<UInt16> = []
    /// SQL keywords match in any case.
    var caseless = false

    // MARK: Tokens

    /// The tokens of the lines of one hunk. The old and the new side each keep their own state.
    func tokens(of lines: [DiffLine]) -> [[Token]] {
        var old = State(), new = State()
        return lines.map { l in
            switch l.kind {
            case .del: return tokens(l.text, state: &old)
            case .add: return tokens(l.text, state: &new)
            case .ctx:
                _ = tokens(l.text, state: &old)
                return tokens(l.text, state: &new)
            }
        }
    }

    func tokens(_ line: String, state: inout State) -> [Token] {
        let u = Array(line.utf16)
        let n = u.count
        var out: [Token] = []
        var i = 0
        func add(_ k: Kind, _ from: Int, _ to: Int) { if to > from { out.append(Token(kind: k, range: NSRange(location: from, length: to - from))) } }

        if let close = state.close {
            guard let end = Self.find(close, in: u, from: 0) else {
                add(state.kind, 0, n)
                return out
            }
            add(state.kind, 0, end + close.count)
            i = end + close.count
            state.close = nil
        }
        scan: while i < n {
            let c = u[i]
            if c == 32 || c == 9 { i += 1; continue }
            for m in lineComments {
                let mark = Array(m.utf16)
                // "#" opens a comment only at a word edge: `$#` and `a#b` are code.
                guard Self.has(mark, in: u, at: i), mark != [hash] || i == 0 || u[i - 1] == 32 || u[i - 1] == 9 else { continue }
                add(.comment, i, n)
                break scan
            }
            for b in blocks {
                let open = Array(b.open.utf16)
                guard Self.has(open, in: u, at: i) else { continue }
                let close = Array(b.close.utf16)
                guard let end = Self.find(close, in: u, from: i + open.count) else {
                    add(b.kind, i, n)
                    state = State(close: close, kind: b.kind)
                    break scan
                }
                add(b.kind, i, end + close.count)
                i = end + close.count
                continue scan
            }
            if quotes.contains(c) {
                var j = i + 1
                while j < n, u[j] != c { j += u[j] == backslash ? 2 : 1 }
                let end = min(j + 1, n)
                add(isKey(u, from: i, to: end) ? .key : .string, i, end)
                i = end
                continue
            }
            if Self.digit(c), i == 0 || !word(u[i - 1]) {
                var j = i + 1
                while j < n, word(u[j]) || u[j] == dot { j += 1 }
                add(.number, i, j)
                i = j
                continue
            }
            if Self.letter(c) {
                var j = i + 1
                while j < n, word(u[j]) || wordExtra.contains(u[j]) { j += 1 }
                let w = String(utf16CodeUnits: Array(u[i..<j]), count: j - i)
                if isKey(u, from: i, to: j) {
                    add(.key, i, j)
                } else if keywords.contains(caseless ? w.lowercased() : w) {
                    add(.keyword, i, j)
                } else if builtins.contains(w) || capitalTypes && (65...90).contains(c) {
                    add(.type, i, j)
                }
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    /// A key starts the line (after spaces and list dashes) and the key mark follows it.
    /// A ":" key needs a space or the line end after it, so `a:b` and `http://` are not keys.
    private func isKey(_ u: [UInt16], from: Int, to: Int) -> Bool {
        guard let keyMark, u[..<from].allSatisfy({ $0 == 32 || $0 == 9 || $0 == dash }) else { return false }
        var j = to
        while j < u.count, u[j] == 32 { j += 1 }
        guard j < u.count, u[j] == keyMark else { return false }
        return keyMark != colon || j + 1 == u.count || u[j + 1] == 32 || u[j + 1] == 9
    }

    private func word(_ c: UInt16) -> Bool { Self.letter(c) || Self.digit(c) }
    private static func letter(_ c: UInt16) -> Bool { (65...90).contains(c) || (97...122).contains(c) || c == 95 }
    private static func digit(_ c: UInt16) -> Bool { (48...57).contains(c) }

    private static func has(_ m: [UInt16], in u: [UInt16], at i: Int) -> Bool {
        i + m.count <= u.count && u[i..<(i + m.count)].elementsEqual(m)
    }

    private static func find(_ m: [UInt16], in u: [UInt16], from: Int) -> Int? {
        var i = from
        while i + m.count <= u.count {
            if u[i] == backslash, m.count == 1 || m == [quote, quote, quote] { i += 2; continue }
            if has(m, in: u, at: i) { return i }
            i += 1
        }
        return nil
    }
}

private let quote: UInt16 = 34, apostrophe: UInt16 = 39, backslash: UInt16 = 92
private let hash: UInt16 = 35, dash: UInt16 = 45, dot: UInt16 = 46, colon: UInt16 = 58, equals: UInt16 = 61

// MARK: Languages

extension SyntaxLanguage {
    /// The language of a file from its name or extension. Nil shows plain text.
    static func of(_ path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "makefile", "justfile", "gnumakefile": return shell
        case "dockerfile", "containerfile": return docker
        default: break
        }
        if name.hasPrefix("dockerfile.") { return docker }
        switch (name as NSString).pathExtension {
        case "swift": return swift
        case "go": return go
        case "ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts": return script
        case "py", "pyi": return python
        case "rs": return rust
        case "java", "kt", "kts", "scala", "cs", "groovy", "dart": return java
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "proto": return c
        case "rb", "rake", "gemspec": return ruby
        case "sh", "bash", "zsh", "fish", "mk", "just", "env": return shell
        case "yaml", "yml": return yaml
        case "json", "jsonc", "json5", "jsonl": return json
        case "toml", "ini", "cfg", "conf": return toml
        case "sql": return sql
        case "css", "scss", "sass", "less": return css
        case "tf", "tfvars", "hcl": return hcl
        case "lua": return lua
        default: return nil
        }
    }

    private static let cBlock = Block(open: "/*", close: "*/", kind: .comment)

    static let swift = SyntaxLanguage(
        keywords: ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "convenience",
                   "default", "defer", "deinit", "didSet", "do", "dynamic", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
                   "final", "for", "func", "get", "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is", "lazy", "let",
                   "mutating", "nil", "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat", "required",
                   "rethrows", "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
                   "true", "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet"],
        lineComments: ["//"], blocks: [Block(open: "\"\"\"", close: "\"\"\"", kind: .string), cBlock], quotes: [quote], capitalTypes: true)

    static let go = SyntaxLanguage(
        keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go",
                   "goto", "if", "import", "interface", "iota", "map", "nil", "package", "range", "return", "select", "struct", "switch",
                   "true", "type", "var"],
        builtins: ["any", "bool", "byte", "complex128", "complex64", "error", "float32", "float64", "int", "int16", "int32", "int64",
                   "int8", "rune", "string", "uint", "uint16", "uint32", "uint64", "uint8", "uintptr", "append", "cap", "close", "copy",
                   "delete", "len", "make", "new", "panic", "recover"],
        lineComments: ["//"], blocks: [cBlock, Block(open: "`", close: "`", kind: .string)])

    static let script = SyntaxLanguage(
        keywords: ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "constructor", "continue", "debugger",
                   "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function",
                   "get", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "null", "of",
                   "private", "protected", "public", "readonly", "return", "satisfies", "set", "static", "super", "switch", "this", "throw",
                   "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield"],
        builtins: ["any", "boolean", "never", "number", "object", "string", "symbol", "unknown"],
        lineComments: ["//"], blocks: [cBlock, Block(open: "`", close: "`", kind: .string)], capitalTypes: true)

    static let python = SyntaxLanguage(
        keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False",
                   "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "None", "nonlocal", "not", "or",
                   "pass", "raise", "return", "self", "True", "try", "while", "with", "yield"],
        builtins: ["bool", "bytes", "dict", "float", "int", "list", "print", "set", "str", "tuple"],
        lineComments: ["#"],
        blocks: [Block(open: "\"\"\"", close: "\"\"\"", kind: .string), Block(open: "'''", close: "'''", kind: .string)], capitalTypes: true)

    static let rust = SyntaxLanguage(
        keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for",
                   "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
                   "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"],
        builtins: ["bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str", "u8", "u16", "u32", "u64", "u128", "usize"],
        lineComments: ["//"], blocks: [cBlock], quotes: [quote], capitalTypes: true)

    static let java = SyntaxLanguage(
        keywords: ["abstract", "as", "break", "case", "catch", "class", "companion", "const", "continue", "data", "default", "do", "else",
                   "enum", "extends", "false", "final", "finally", "for", "fun", "if", "implements", "import", "in", "interface", "internal",
                   "is", "namespace", "new", "null", "object", "open", "override", "package", "private", "protected", "public", "return",
                   "sealed", "static", "super", "switch", "this", "throw", "throws", "true", "try", "using", "val", "var", "void", "when",
                   "while"],
        builtins: ["boolean", "byte", "char", "double", "float", "int", "long", "short", "string"],
        lineComments: ["//"], blocks: [Block(open: "\"\"\"", close: "\"\"\"", kind: .string), cBlock], capitalTypes: true)

    static let c = SyntaxLanguage(
        keywords: ["auto", "break", "case", "class", "const", "constexpr", "continue", "default", "define", "delete", "do", "else", "endif",
                   "enum", "extern", "false", "for", "goto", "if", "ifdef", "ifndef", "import", "include", "inline", "message", "namespace",
                   "new", "nullptr", "NULL", "option", "package", "pragma", "private", "public", "repeated", "return", "rpc", "service",
                   "sizeof", "static", "struct", "switch", "syntax", "template", "this", "true", "typedef", "union", "using", "virtual",
                   "volatile", "while"],
        builtins: ["bool", "char", "double", "float", "int", "int32", "int64", "long", "short", "signed", "size_t", "string", "uint32",
                   "uint64", "unsigned", "void"],
        lineComments: ["//"], blocks: [cBlock])

    static let ruby = SyntaxLanguage(
        keywords: ["alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "for", "if",
                   "in", "module", "next", "nil", "not", "or", "require", "rescue", "return", "self", "super", "then", "true", "unless",
                   "until", "when", "while", "yield"],
        lineComments: ["#"], capitalTypes: true)

    static let shell = SyntaxLanguage(
        keywords: ["case", "do", "done", "elif", "else", "esac", "exit", "export", "fi", "for", "function", "if", "in", "local", "readonly",
                   "return", "set", "shift", "source", "then", "unset", "until", "while"],
        lineComments: ["#"])

    static let docker = SyntaxLanguage(
        keywords: ["ADD", "ARG", "AS", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE", "FROM", "HEALTHCHECK", "LABEL", "ONBUILD", "RUN",
                   "SHELL", "STOPSIGNAL", "USER", "VOLUME", "WORKDIR"],
        lineComments: ["#"])

    static let yaml = SyntaxLanguage(
        keywords: ["true", "false", "null", "yes", "no", "on", "off", "True", "False", "Null", "TRUE", "FALSE"],
        lineComments: ["#"], keyMark: colon, wordExtra: [dash, dot])

    static let json = SyntaxLanguage(keywords: ["true", "false", "null"], lineComments: ["//"], blocks: [cBlock], quotes: [quote], keyMark: colon)

    static let toml = SyntaxLanguage(keywords: ["true", "false"], lineComments: ["#", ";"], keyMark: equals, wordExtra: [dash, dot])

    static let sql = SyntaxLanguage(
        keywords: ["add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "cast", "commit", "create", "cross", "default",
                   "delete", "desc", "distinct", "drop", "else", "end", "exists", "false", "from", "full", "group", "having", "if", "in",
                   "index", "inner", "insert", "into", "is", "join", "key", "left", "like", "limit", "not", "null", "offset", "on", "or",
                   "order", "outer", "over", "partition", "primary", "references", "replace", "returning", "right", "rollback", "select",
                   "set", "table", "then", "true", "union", "unique", "update", "using", "values", "view", "when", "where", "with"],
        builtins: ["BIGINT", "BOOLEAN", "CHAR", "DATE", "DECIMAL", "DOUBLE", "FLOAT", "INT", "INTEGER", "JSON", "NUMERIC", "SMALLINT", "TEXT",
                   "TIMESTAMP", "VARCHAR", "bigint", "boolean", "char", "date", "decimal", "double", "float", "int", "integer", "json",
                   "numeric", "smallint", "text", "timestamp", "varchar"],
        lineComments: ["--"], blocks: [cBlock], caseless: true)

    static let css = SyntaxLanguage(
        keywords: ["important", "media", "import", "keyframes", "supports", "include", "mixin", "extend", "use"],
        lineComments: ["//"], blocks: [cBlock], keyMark: colon, wordExtra: [dash])

    static let hcl = SyntaxLanguage(
        keywords: ["data", "dynamic", "false", "for", "if", "in", "locals", "module", "null", "output", "provider", "resource", "terraform",
                   "true", "variable"],
        lineComments: ["#", "//"], blocks: [cBlock], quotes: [quote], keyMark: equals, wordExtra: [dash])

    static let lua = SyntaxLanguage(
        keywords: ["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not",
                   "or", "repeat", "return", "then", "true", "until", "while"],
        lineComments: ["--"])
}

// MARK: Colors

extension SyntaxLanguage.Kind {
    /// Okabe-Ito hues, with a light and a dark tone.
    var color: NSColor {
        switch self {
        case .keyword: return Palette.intake
        case .string: return Palette.acc
        case .comment: return Palette.dim
        case .number: return Palette.warn
        case .type: return Palette.codeType
        case .key: return Palette.ok
        }
    }
}

extension SyntaxLanguage {
    /// The text of a diff line with its colors.
    static func styled(_ text: String, tokens: [Token], font: NSFont, wraps: Bool) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = wraps ? .byCharWrapping : .byClipping
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: Palette.fg, .paragraphStyle: p])
        let length = s.length
        for t in tokens where t.range.location < length {
            s.addAttribute(.foregroundColor, value: t.kind.color, range: NSRange(location: t.range.location, length: min(t.range.length, length - t.range.location)))
        }
        return s
    }
}
