import XCTest
@testable import OverSireApp

final class WebLinkTests: XCTestCase {
    private let base = URL(string: "http://mbp.t.ts.net:7690")!

    func testAWebLinkPutsTheRouteUnderGoAndTheFocusInTheQuery() {
        let t = Target(.item("OVERSIRE-400", .changes), focus: "OVERSIRE-402")
        XCTAssertEqual(WebLink.url(t, base: base).absoluteString, "http://mbp.t.ts.net:7690/go/item/OVERSIRE-400/changes?focus=OVERSIRE-402")
        XCTAssertEqual(WebLink.url(Target(.home), base: URL(string: "http://mbp:7690/")!).absoluteString, "http://mbp:7690/go/home")
    }

    func testASettingsAnchorGoesIntoThePathAndNotIntoTheFocus() {
        let t = Target(path: "settings/agents#runbooks")!
        let url = WebLink.url(t, base: base).absoluteString
        XCTAssertTrue(url.hasPrefix("http://mbp.t.ts.net:7690/go/settings/"), url)
        XCTAssertFalse(url.contains("focus="), url)
    }

    func testAMarkdownLinkUsesTheWebLinkAndElseTheAppLink() {
        let t = Target(.item("OVERSIRE-400", .overview))
        XCTAssertEqual(WebLink.markdown(t, title: "OVERSIRE-400 Fix [x]", base: base),
                       "[OVERSIRE-400 Fix \\[x\\]](http://mbp.t.ts.net:7690/go/item/OVERSIRE-400)")
        XCTAssertEqual(WebLink.markdown(t, title: "OVERSIRE-400", base: nil), "[OVERSIRE-400](oversire://item/OVERSIRE-400)")
    }

    func testTheBlockHasAWebLineOnlyWithABase() {
        let ws = Workstream(key: "FRITZ-1")
        let plain = PlaneWriteBack.blockMarkdown(ws)
        XCTAssertEqual(plain, "- Open in OverSire: oversire://item/FRITZ-1", "no base keeps the block of today")
        XCTAssertEqual(PlaneWriteBack.blockMarkdown(ws, web: base),
                       plain + "\n- Open (web): http://mbp.t.ts.net:7690/go/item/FRITZ-1")
    }
}
