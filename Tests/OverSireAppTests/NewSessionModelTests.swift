import OverSireCore
import XCTest
@testable import OverSireApp

final class NewSessionModelTests: XCTestCase {
    private let choices = [
        NewSessionModel.Choice(key: "SLING", name: "Sling", store: "ocral/s", root: "/Users/me/Projects/sling-workspace"),
        NewSessionModel.Choice(key: "TOWERTAIL", name: "Towertail", store: "ocral/t", root: "/Users/me/Projects/towertail"),
        NewSessionModel.Choice(key: "OVERSIRE", name: "OverSire", store: "ocral/o", root: "/Users/me/Projects/oversire-workspace"),
        NewSessionModel.Choice(key: "FRITZ", name: "Personal", store: "ocral/f", root: nil),
    ]

    private func model(last: String? = nil, intake: Bool = true) -> NewSessionModel {
        var cfg = SessionConfig()
        cfg.lastProject = last
        cfg.intake = intake
        return NewSessionModel(choices: choices, cfg: cfg, agent: "claude")
    }

    func testSelectionStartsFromTheLastProject() {
        XCTAssertEqual(model(last: "ocral/o").selection?.key, "OVERSIRE")
        XCTAssertEqual(model(last: "gone/x").selection?.key, "SLING", "an unknown project falls back to the first")
        XCTAssertEqual(model().selection?.key, "SLING")
        XCTAssertNil(NewSessionModel(choices: [], cfg: SessionConfig(), agent: "claude").selection)
    }

    func testMatchOrder() {
        var m = model()
        m.type("ov")
        XCTAssertEqual(m.matches.first?.key, "OVERSIRE")
        m.type("work")
        XCTAssertEqual(m.matches.map(\.key), ["SLING", "OVERSIRE"], "folder names match")
        m.type("s")
        XCTAssertEqual(m.matches.map(\.key), ["SLING", "OVERSIRE", "FRITZ"], "key prefix first, then the rest in list order")
        m.type("per")
        XCTAssertEqual(m.matches.map(\.key), ["FRITZ"], "name prefix")
        m.type("")
        XCTAssertEqual(m.matches.count, 4)
        m.type("zzz")
        XCTAssertTrue(m.matches.isEmpty)
    }

    func testMoveStaysInRangeAndPickClosesTheList() {
        var m = model()
        m.type("s")
        m.move(-1)
        XCTAssertEqual(m.highlight, 0)
        m.move(10)
        XCTAssertEqual(m.highlight, 2)
        m.pick("ocral/t")
        XCTAssertEqual(m.selection?.key, "TOWERTAIL")
        XCTAssertFalse(m.listOpen)
        XCTAssertEqual(m.query, "")
        XCTAssertEqual(m.highlight, 0)
        m.pick("nope")
        XCTAssertEqual(m.selection?.key, "TOWERTAIL", "an unknown key keeps the selection")
    }

    func testCanStartAndBlocker() {
        var m = model(last: "ocral/o")
        XCTAssertFalse(m.canStart)
        XCTAssertEqual(m.blocker, "Type a prompt or attach a file.")
        m.text = "  \n "
        XCTAssertEqual(m.blocker, "Type a prompt or attach a file.")
        m.text = "Fix the toolbar"
        XCTAssertTrue(m.canStart)
        XCTAssertNil(m.blocker)
        m.text = ""
        m.add([.init(name: "a.png", data: Data(count: 10))])
        XCTAssertTrue(m.canStart, "files alone are enough")

        m.pick("ocral/f")
        XCTAssertFalse(m.canStart)
        XCTAssertEqual(m.blocker, "Choose an Orca workspace folder for FRITZ.")

        m.pick("ocral/o")
        m.maxBytes = 5
        XCTAssertTrue(m.canStart, "intake has no size limit")
        m.intake = false
        XCTAssertFalse(m.canStart)
        m.maxBytes = 10 * 1024 * 1024
        m.files = [.init(name: "big.bin", data: Data(count: 10 * 1024 * 1024))]
        XCTAssertTrue(m.canStart, "the limit itself is in")
        m.files = [.init(name: "big.bin", data: Data(count: 10 * 1024 * 1024 + 1))]
        XCTAssertEqual(m.blocker, "Files are over 10 MB. Turn on intake to send them.")

        m.files = []
        m.text = "go"
        m.phase = .starting("Opening terminal…")
        XCTAssertFalse(m.canStart)
        XCTAssertNil(m.blocker)
        m.phase = .failed("boom")
        XCTAssertTrue(m.canStart)
    }

    func testItemModesNeedNoWorkspaceAndATitle() {
        var m = model(last: "ocral/f")
        m.mode = .intake
        XCTAssertEqual(m.blocker, "Type a title or a description.")
        m.text = "Login crashes\nafter the redirect"
        XCTAssertNil(m.blocker, "FRITZ has no Orca folder: Intake does not need one")
        XCTAssertEqual(m.itemTitle, "Login crashes")
        m.titleText = "  OAuth crash "
        XCTAssertEqual(m.itemTitle, "OAuth crash")
        m.text = ""
        XCTAssertTrue(m.canStart, "a title alone is enough")
        XCTAssertEqual(m.button, "Create intake")
        m.mode = .item
        XCTAssertEqual(m.button, "Create item")
        XCTAssertEqual(m.footerNote, "")
        m.mode = .session
        XCTAssertEqual(m.button, "Start claude")
        XCTAssertEqual(m.blocker, "Choose an Orca workspace folder for FRITZ.")
    }

    func testItemStateDefaultsToTodo() {
        var c = choices
        c[0].states = [StatusOption(id: "b", name: "Backlog", color: "#999", group: "backlog"),
                       StatusOption(id: "t", name: "Todo", color: "#999", group: "unstarted")]
        var m = NewSessionModel(choices: c, cfg: SessionConfig(), agent: "claude")
        XCTAssertEqual(m.itemState, "t")
        m.state = "b"
        XCTAssertEqual(m.itemState, "b")
    }

    func testModeComesFromTheConfig() throws {
        var cfg = SessionConfig()
        cfg.mode = .item
        XCTAssertEqual(NewSessionModel(choices: choices, cfg: cfg, agent: "claude").mode, .item)
        let back = try JSONDecoder().decode(SessionConfig.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back.mode, .item)
        XCTAssertEqual(try JSONDecoder().decode(SessionConfig.self, from: Data(#"{"mode":"later"}"#.utf8)).mode, .session, "an unknown mode falls back")
    }

    func testTitle() {
        XCTAssertEqual(NewSessionModel.title("\n  Fix the sync  \nmore text"), "Fix the sync")
        XCTAssertEqual(NewSessionModel.title(""), "New session")
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(NewSessionModel.title(long).count, 80)
        XCTAssertTrue(NewSessionModel.title(long).hasSuffix("…"))
        XCTAssertEqual(NewSessionModel.title(String(repeating: "b", count: 80)), String(repeating: "b", count: 80))
    }

    func testTermName() {
        XCTAssertEqual(NewSessionModel.termName(agent: "claude", text: "Why does the CI fail on main?"), "claude-why-does-the")
        XCTAssertEqual(NewSessionModel.termName(agent: "codex", text: "  #42: fix (über) bug!!"), "codex-42-fix-ber")
        XCTAssertEqual(NewSessionModel.termName(agent: "claude", text: "🙂"), "claude-session")
    }

    func testAddDropsDuplicatesAndRemove() {
        var m = model()
        m.add([.init(name: "a.png", data: Data(count: 3)), .init(name: "a.png", data: Data(count: 3)), .init(name: "a.png", data: Data(count: 4))])
        XCTAssertEqual(m.files.map(\.bytes), [3, 4])
        XCTAssertTrue(m.files[0].isImage)
        XCTAssertFalse(NewSessionModel.Attachment(name: "notes.txt", data: Data()).isImage)
        XCTAssertEqual(NewSessionModel.Attachment(name: "notes.txt", data: Data()).mimeType, "text/plain")
        m.remove(m.files[0].id)
        XCTAssertEqual(m.files.map(\.bytes), [4])
        XCTAssertEqual(m.totalBytes, 4)
    }

    func testHintsFollowIntakeAndFiles() {
        var m = model()
        XCTAssertEqual(m.intakeHint, "Tracks this work. The prompt is the description.")
        XCTAssertEqual(m.footerNote, "The agent gets the prompt and the item key.")
        m.add([.init(name: "a.png", data: Data(count: 3))])
        XCTAssertEqual(m.intakeHint, "The prompt is the description. The files go on the item.")
        m.intake = false
        XCTAssertEqual(m.intakeHint, "No item. The files go to the Orca host and the prompt gets their paths.")
        XCTAssertEqual(m.footerNote, "The prompt goes to the agent as typed.")
        m.files = []
        XCTAssertEqual(m.intakeHint, "No item. Good for a question or a quick chat.")
    }

    func testPasteNameSkipsTakenNames() {
        var m = model()
        XCTAssertEqual(m.pasteName, "pasted-1.png")
        m.add([.init(name: "pasted-1.png", data: Data(count: 1)), .init(name: "pasted-3.png", data: Data(count: 1))])
        XCTAssertEqual(m.pasteName, "pasted-2.png")
    }
}
