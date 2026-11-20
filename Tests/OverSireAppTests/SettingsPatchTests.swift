import OverSireAssistant
import OverSireCore
import XCTest
@testable import OverSireApp

/// The source app takes a shared setting from a client (OVERSIRE-529).
final class SettingsPatchTests: XCTestCase {
    actor Outlet: EventOutlet {
        var rows: [EventDraft] = []
        func append(_ drafts: [EventDraft]) async { rows += drafts }
        func link(_ l: [ItemLink]) async {}
    }

    private var agents: AgentsConfig!
    private let data = TestAppData()
    private let outlet = Outlet()

    override func setUp() { agents = AGENTS }
    override func tearDown() { AGENTS = agents }

    private func spec(_ touched: @escaping @MainActor (SettingsSection) -> Void = { _ in }) -> ActionSpec {
        let desk = EventDesk(outlet: outlet)
        desk.machine = { "mbp" }
        desk.email = { "flarco@gmail.com" }
        return SettingsActions(link: ActionLink(data), desk: { desk }, after: touched).specs[0]
    }

    private func patch(_ section: String, value: JSONValue, base: String, caller: ActionCaller = .member(machine: "mba", name: "Fritz")) -> ActionArgs {
        ActionArgs(.object(["section": .string(section), "value": value, "baseHash": .string(base)]), caller: caller)
    }

    private func toggled() -> (old: HomeSettings, value: JSONValue) {
        let old = homeSettings(from: currentConfig())
        var c = currentConfig()
        var a = c.agents ?? AgentsConfig()
        a.autoStart.toggle()
        c.agents = a
        return (old, homeSettings(from: c).value(.agents))
    }

    func testAppliesAndWritesEvent() async {
        let (old, value) = toggled()
        let want = !AGENTS.autoStart
        let r = await spec().perform(patch("agents", value: value, base: old.hashes["agents"] ?? ""))
        guard case .ok = r else { return XCTFail("\(r)") }
        XCTAssertEqual(AGENTS.autoStart, want)
        for _ in 0..<200 where await outlet.rows.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        let rows = await outlet.rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .settingsChanged)
        XCTAssertEqual(rows[0].payload, ["section": .string("agents"), "keys": .array([.string("autoStart")]), "from": .string("mba")])
        XCTAssertEqual(rows[0].via, "app@mba")
        XCTAssertEqual(rows[0].summary, "Agents settings changed from mba")
    }

    func testRunsTheFollowUpOfTheSection() async {
        final class Seen: @unchecked Sendable { var list: [SettingsSection] = [] }
        let seen = Seen()
        let (old, value) = toggled()
        _ = await spec { seen.list.append($0) }.perform(patch("agents", value: value, base: old.hashes["agents"] ?? ""))
        XCTAssertEqual(seen.list, [.agents])
    }

    func testConflictOnOldHash() async {
        let (_, value) = toggled()
        let before = AGENTS
        let r = await spec().perform(patch("agents", value: value, base: "old"))
        XCTAssertEqual(r, .failed("Changed on mbp. Look again."))
        XCTAssertEqual(AGENTS, before)
        let out = await MemberCalls().handle(MemberCall(id: "1", action: "settings.patch", args: patch("agents", value: value, base: "old").values,
                                                       from: MemberCaller(machine: "mba", name: "Fritz")),
                                             actions: ActionList([spec()])) {}
        XCTAssertEqual(out.status, .failed)
        XCTAssertEqual(out.data, .object(["conflict": .bool(true)]))
        XCTAssertEqual(out.summary, "Changed on mbp. Look again.")
    }

    func testRefusesNonMember() async {
        let (old, value) = toggled()
        let before = AGENTS
        let r = await spec().perform(patch("agents", value: value, base: old.hashes["agents"] ?? "", caller: .user))
        guard case .notAllowed = r else { return XCTFail("\(r)") }
        XCTAssertEqual(AGENTS, before)
    }

    func testRefusesUnknownSection() async {
        let r = await spec().perform(patch("accounts", value: .object([:]), base: ""))
        XCTAssertEqual(r, .notAllowed("Unknown section."))
    }

    func testRefusesAValueThatDoesNotDecode() async {
        let old = homeSettings(from: currentConfig())
        let r = await spec().perform(patch("agents", value: .object(["autoStart": .string("yes")]), base: old.hashes["agents"] ?? ""))
        guard case .notAllowed = r else { return XCTFail("\(r)") }
    }

    func testSameValueWritesNothing() async {
        let old = homeSettings(from: currentConfig())
        let r = await spec().perform(patch("agents", value: old.value(.agents), base: old.hashes["agents"] ?? ""))
        guard case .ok(let m, _, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(m, "Agents settings did not change.")
        try? await Task.sleep(nanoseconds: 50_000_000)
        let rows = await outlet.rows
        XCTAssertTrue(rows.isEmpty)
    }
}
