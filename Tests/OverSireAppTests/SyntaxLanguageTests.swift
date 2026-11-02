import OverSireCore
import XCTest
@testable import OverSireApp

final class SyntaxLanguageTests: XCTestCase {
    /// The colored words of a line, as "kind:text".
    private func words(_ lang: SyntaxLanguage, _ line: String, state: inout SyntaxLanguage.State) -> [String] {
        let u = line as NSString
        return lang.tokens(line, state: &state).map { "\($0.kind):\(u.substring(with: $0.range))" }
    }

    private func words(_ lang: SyntaxLanguage, _ line: String) -> [String] {
        var s = SyntaxLanguage.State()
        return words(lang, line, state: &s)
    }

    func testLanguageFromPath() {
        XCTAssertNotNil(SyntaxLanguage.of("core/dbio/iop/duckdb.go"))
        XCTAssertNotNil(SyntaxLanguage.of("tests/suite.cli.yaml"))
        XCTAssertNotNil(SyntaxLanguage.of("justfile"))
        XCTAssertNotNil(SyntaxLanguage.of("Dockerfile.dev"))
        XCTAssertNil(SyntaxLanguage.of("README.md"))
        XCTAssertNil(SyntaxLanguage.of("LICENSE"))
    }

    func testGo() {
        XCTAssertEqual(words(.go, "func (d *DuckDb) Init() error { // start"),
                       ["keyword:func", "type:error", "comment:// start"])
        XCTAssertEqual(words(.go, "\tv := \"2.0.0\" + `raw`"), ["string:\"2.0.0\"", "string:`raw`"])
        XCTAssertEqual(words(.go, "x := 404"), ["number:404"])
    }

    func testSwiftTypesAndEscapes() {
        XCTAssertEqual(words(.swift, "let s: String = \"a \\\"b\\\" c\""),
                       ["keyword:let", "type:String", "string:\"a \\\"b\\\" c\""])
        XCTAssertEqual(words(.swift, "var x1 = y2"), ["keyword:var"])
    }

    func testBlockCommentCarries() {
        var s = SyntaxLanguage.State()
        XCTAssertEqual(words(.go, "a := 1 /* open", state: &s), ["number:1", "comment:/* open"])
        XCTAssertEqual(words(.go, "still in", state: &s), ["comment:still in"])
        XCTAssertEqual(words(.go, "done */ return", state: &s), ["comment:done */", "keyword:return"])
        XCTAssertEqual(s, SyntaxLanguage.State())
    }

    func testPythonLongString() {
        var s = SyntaxLanguage.State()
        XCTAssertEqual(words(.python, "x = \"\"\"doc", state: &s), ["string:\"\"\"doc"])
        XCTAssertEqual(words(.python, "end\"\"\" # note", state: &s), ["string:end\"\"\"", "comment:# note"])
    }

    func testYamlKeys() {
        XCTAssertEqual(words(.yaml, "- id: 839"), ["key:id", "number:839"])
        XCTAssertEqual(words(.yaml, "  name: 'GH #831: tar.gz'"), ["key:name", "string:'GH #831: tar.gz'"])
        XCTAssertEqual(words(.yaml, "    GH831_DUCKDB: 'duckdb:///tmp/x.duckdb'"), ["key:GH831_DUCKDB", "string:'duckdb:///tmp/x.duckdb'"])
        XCTAssertEqual(words(.yaml, "  run: |"), ["key:run"])
        XCTAssertEqual(words(.yaml, "  url: http://x  # c"), ["key:url", "comment:# c"])
        XCTAssertEqual(words(.yaml, "debug: true"), ["key:debug", "keyword:true"])
    }

    func testJsonKeys() {
        XCTAssertEqual(words(.json, "  \"name\": \"x\", \"n\": 2"), ["key:\"name\"", "string:\"x\"", "string:\"n\"", "number:2"])
    }

    func testShellHashInWord() {
        XCTAssertEqual(words(.shell, "echo $# a#b # real"), ["comment:# real"])
    }

    func testSqlAnyCase() {
        XCTAssertEqual(words(.sql, "SELECT id FROM t -- note"), ["keyword:SELECT", "keyword:FROM", "comment:-- note"])
    }

    func testHunkSides() {
        // The removed line opens a comment on the old side only. The added line stays code.
        let lines = [
            DiffLine(kind: .del, old: 1, text: "/* old"),
            DiffLine(kind: .add, new: 1, text: "x := 1"),
            DiffLine(kind: .ctx, old: 2, new: 2, text: "return"),
        ]
        let t = SyntaxLanguage.go.tokens(of: lines)
        XCTAssertEqual(t[1].map(\.kind), [.number])
        XCTAssertEqual(t[2].map(\.kind), [.keyword])
    }

    func testStyledClampsTokens() {
        let s = SyntaxLanguage.styled("ab", tokens: [.init(kind: .string, range: NSRange(location: 1, length: 10))],
                                      font: .monospacedSystemFont(ofSize: 11, weight: .regular), wraps: false)
        XCTAssertEqual(s.length, 2)
    }
}
