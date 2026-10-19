import XCTest
import OverSireCore
import OverSireTestKit
@testable import TrackerPlane

/// Recorded Plane answers, keyed by "METHOD path". Each request is kept.
final class RecordedPlane: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: (Int, String)] = [:]
    private(set) var requests: [URLRequest] = []

    func on(_ method: String, _ path: String, status: Int = 200, _ body: String) {
        lock.withLock { answers[method + " " + path] = (status, body) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = (request.httpMethod ?? "GET") + " " + (request.url?.path(percentEncoded: false) ?? "")
        let (status, body) = lock.withLock {
            requests.append(request)
            return answers[key] ?? (404, #"{"detail":"no answer for \#(key)"}"#)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func body(_ method: String, _ path: String) -> [String: Any]? {
        lock.withLock { requests.last { $0.httpMethod == method && $0.url?.path(percentEncoded: false) == path } }
            .flatMap { $0.httpBody }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

final class TrackerPlaneTests: XCTestCase {
    let ws = "/api/v1/workspaces/acme"
    var http: RecordedPlane!
    var plane: PlaneTracker!
    var project: ProjectRef { ProjectRef(account: plane.account, id: "P1", key: "ENG") }

    override func setUp() {
        http = RecordedPlane()
        plane = PlaneTracker(workspace: PlaneWorkspace(slug: "acme"), token: "tok", http: http)
        http.on("GET", "/api/v1/users/me/", #"{"id":"u1","display_name":"ada","email":"ada@x.dev"}"#)
        http.on("GET", "\(ws)/members/", #"[{"member":{"id":"u1","display_name":"Ada"}},{"member":{"id":"u2","display_name":"Bo"}}]"#)
        http.on("GET", "\(ws)/projects/", #"{"results":[{"id":"P1","name":"Engine","identifier":"ENG","archived_at":null},{"id":"P2","name":"Attic","identifier":"OLD","archived_at":"2026-01-01T00:00:00Z"}],"next_page_results":false}"#)
        http.on("GET", "\(ws)/projects/P1/states/", ##"{"results":[{"id":"s2","name":"Doing","color":"#F59E0B","group":"started","sequence":2},{"id":"s1","name":"Todo","color":"#888888","group":"unstarted","sequence":1}]}"##)
    }

    func testCapabilitiesAgreeWithProtocols() {
        let r = ProviderConformance.capabilities(plane!)
        XCTAssertTrue(r.passed, r.description)
    }

    func testWorkspaceURLs() throws {
        let ws = PlaneWorkspace(slug: "acme")
        XCTAssertEqual(ws.itemURL("ENG-4"), "https://app.plane.so/acme/browse/ENG-4/")
        XCTAssertEqual(ws.url, "https://app.plane.so/acme/")
        XCTAssertEqual(PlaneWorkspace(slug: "acme", host: "https://plane.example.com").itemURL("ENG-4"),
                       "https://plane.example.com/acme/browse/ENG-4/")
        let old = try JSONDecoder().decode(PlaneWorkspace.self, from: Data(#"{"slug":"acme"}"#.utf8))
        XCTAssertEqual(old.host, PlaneWorkspace.cloudHost)
    }

    func testActivityRows() {
        let names = ["u1": "Ada"]
        let states = [StatusOption(id: "s1", name: "Todo", color: "#888888", group: "unstarted"),
                      StatusOption(id: "s2", name: "In progress", color: "#F59E0B", group: "started")]
        XCTAssertEqual(PlaneTracker.change(["verb": "created"], names: names, states: states), .added)
        XCTAssertEqual(PlaneTracker.change(["verb": "updated", "field": "state", "old_value": "Todo", "new_value": NSNull(),
                                            "new_identifier": "s2"], names: names, states: states),
                       .status(from: "Todo", to: "In progress"))
        XCTAssertEqual(PlaneTracker.change(["verb": "updated", "field": "assignees", "new_value": "", "new_identifier": "u1"],
                                           names: names, states: states), .assigned("Ada"))
        XCTAssertEqual(PlaneTracker.change(["verb": "updated", "field": "priority", "old_value": "low", "new_value": "urgent"],
                                           names: names, states: states), .field(name: "Priority", from: "Low", to: "Urgent"))
        XCTAssertNil(PlaneTracker.change(["verb": "updated", "field": "description"], names: names, states: states))
    }

    func testMarkup() {
        let names = ["u1": "Ada"]
        let html = #"<h2>Context</h2><p>Hi <mention-component entity_identifier="u1" entity_name="user_mention"></mention-component>, see <a href="https://x.dev">this</a> &amp; <strong>that</strong>.</p><ul data-type="taskList"><li data-type="taskItem" data-checked="true"><p>one</p></li><li data-type="taskItem" data-checked="false"><p>two</p></li></ul><pre><code>let a = 1 &lt; 2</code></pre>"#
        let pmd = PlaneMarkup.markdown(fromHTML: html, mention: { names[$0] })
        XCTAssertTrue(pmd.contains("## Context") && pmd.contains("Hi @Ada, see [this](https://x.dev) & **that**."), "html to markdown \(pmd)")
        XCTAssertTrue(pmd.contains("- [x] one") && pmd.contains("- [ ] two") && pmd.contains("```\nlet a = 1 < 2\n```"), "tasks and code \(pmd)")
        let back = PlaneMarkup.html(fromMarkdown: pmd)
        XCTAssertTrue(back.contains(#"data-type="taskList""#) && back.contains("<h2>Context</h2>") && back.contains("&lt; 2"),
              "markdown to html \(back)")
        XCTAssertTrue(PlaneMarkup.markdown(fromHTML: PlaneMarkup.html(fromMarkdown: pmd)) == PlaneMarkup.markdown(fromHTML: back), "round trip")
        XCTAssertTrue(PlaneMarkup.html(fromMarkdown: "a <b> & c") == "<p>a &lt;b&gt; &amp; c</p>", "plain text is escaped")
        let planeTable = "<p>Work items</p><table><tbody><tr><th colspan=\"1\" rowspan=\"1\"><p>Plane</p></th><th><p>Repo</p></th></tr>"
            + "<tr><td><p>TREBI-286</p></td><td><p>Connector <code>internal/host</code></p><p>a|b</p></td></tr></tbody></table><p>After</p>"
        let tableMD = PlaneMarkup.markdown(fromHTML: planeTable)
        XCTAssertTrue(tableMD == "Work items\n\n| Plane | Repo |\n| --- | --- |\n| TREBI-286 | Connector `internal/host` a\\|b |\n\nAfter",
              "table to Markdown: \(tableMD)")
        let tableHTML = PlaneMarkup.html(fromMarkdown: tableMD)
        XCTAssertTrue(tableHTML.contains("<table><tbody><tr><th><p>Plane</p></th>") && tableHTML.contains("<td><p>Connector <code>internal/host</code> a|b</p></td>"),
              "table to HTML: \(tableHTML)")
        XCTAssertTrue(PlaneMarkup.markdown(fromHTML: tableHTML) == tableMD, "table round trip")
        let asset = "a246509a-505b-46c2-80a1-7e0dd05b475d"
        let imgMD = PlaneMarkup.markdown(fromHTML: "<p>See</p><image-component src=\"\(asset)\" width=\"200\"></image-component>")
        XCTAssertTrue(imgMD == "See\n\n![](\(asset))", "image to Markdown: \(imgMD)")
        let imgHTML = PlaneMarkup.html(fromMarkdown: imgMD)
        XCTAssertTrue(imgHTML.contains("<image-component src=\"\(asset)\"></image-component>"), "image to HTML: \(imgHTML)")
        XCTAssertTrue(PlaneMarkup.html(fromMarkdown: "![x](https://e.com/a.png)").contains("<img src=\"https://e.com/a.png\" alt=\"x\">"), "web image")
    }

    func testProbeProjectsAndStatuses() async throws {
        let me = try await plane.probe()
        XCTAssertEqual(me.person.id, "u1")
        XCTAssertEqual(me.person.name, "ada")
        let projects = try await plane.projects()
        XCTAssertEqual(projects.map(\.title), ["Attic", "Engine"])
        XCTAssertEqual(projects.first { $0.identifier == "OLD" }?.closed, true)
        XCTAssertEqual(projects.first { $0.identifier == "ENG" }?.ref, project)
        let statuses = try await plane.statuses(project)
        XCTAssertEqual(statuses.map(\.id), ["s1", "s2"], "sorted by sequence")
        XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "X-Api-Key"), "tok")
    }

    func testItemsCompleteTheTree() async throws {
        // The list has only the sub-item. The index gives its parent, which loads alone.
        http.on("GET", "\(ws)/projects/P1/issues/", #"{"results":[{"id":"i2","name":"Child","sequence_id":2,"state":"s1","parent":"i1","priority":"high","assignees":[{"id":"u2"}],"labels":[{"name":"bug"}],"created_by":"u1","updated_at":"2026-10-16T10:00:00Z","last_activity_at":"2026-10-16T11:00:00Z","description_html":"<p>Hi</p>"}],"next_page_results":false}"#)
        http.on("GET", "\(ws)/projects/P1/issues/i1/", #"{"id":"i1","name":"Parent","sequence_id":1,"state":"s2","updated_at":"2026-10-15T10:00:00Z"}"#)
        let items = try await plane.items(project, since: nil, limit: 50)
        XCTAssertEqual(Set(items.map(\.key)), ["ENG-1", "ENG-2"])
        let child = try XCTUnwrap(items.first { $0.id == "i2" })
        XCTAssertEqual(child.parentId, "i1")
        XCTAssertEqual(child.assignees, ["Bo"])
        XCTAssertEqual(child.author, "Ada")
        XCTAssertEqual(child.labels, ["bug"])
        XCTAssertEqual(child.fields["Priority"], "High")
        XCTAssertEqual(child.body, "Hi")
        XCTAssertEqual(child.url, "https://app.plane.so/acme/browse/ENG-2/")
    }

    func testItemsKeepOneCopyOfEachId() async throws {
        // A write during a refresh moves a row, so two offset pages give it two times. The newest copy wins.
        http.on("GET", "\(ws)/projects/P1/issues/", #"{"results":[{"id":"i1","name":"New","sequence_id":1,"state":"s2","parent":"i2","last_activity_at":"2026-10-16T12:00:00Z"},{"id":"i2","name":"Parent","sequence_id":2,"state":"s1","last_activity_at":"2026-10-16T11:00:00Z"},{"id":"i1","name":"Old","sequence_id":1,"state":"s1","last_activity_at":"2026-10-16T10:00:00Z"}],"next_page_results":false}"#)
        let items = try await plane.items(project, since: nil, limit: 50)
        XCTAssertEqual(items.map(\.id), ["i1", "i2"])
        XCTAssertEqual(items.first?.title, "New")
        XCTAssertEqual(items.first?.parentId, "i2")
    }

    func testItemsLoadOnlyTheDelta() async throws {
        let list = "\(ws)/projects/P1/issues/"
        func row(_ id: String, _ n: Int, _ at: String) -> String {
            #"{"id":"\#(id)","name":"Item \#(n)","sequence_id":\#(n),"state":"s1","last_activity_at":"\#(at)"}"#
        }
        http.on("GET", list, #"{"results":[\#(row("i1", 1, "2026-10-16T10:00:00Z")),\#(row("i2", 2, "2026-10-16T09:00:00Z"))],"next_page_results":false}"#)
        _ = try await plane.items(project, since: nil, limit: 50)
        let fullLists = { self.http.requests.filter { $0.url?.path() == list && $0.url?.query()?.contains("expand") == true }.count }
        XCTAssertEqual(fullLists(), 1)

        // i2 changed, i3 is new and i1 is gone. Only i2 and i3 load.
        plane.indexMaxAge = 0
        http.on("GET", list, #"{"results":[\#(row("i3", 3, "2026-10-16T12:00:00Z")),\#(row("i2", 2, "2026-10-16T11:00:00Z"))],"next_page_results":false}"#)
        http.on("GET", "\(list)i2/", row("i2", 2, "2026-10-16T11:00:00Z"))
        http.on("GET", "\(list)i3/", row("i3", 3, "2026-10-16T12:00:00Z"))
        let items = try await plane.items(project, since: nil, limit: 50)
        XCTAssertEqual(Set(items.map(\.key)), ["ENG-2", "ENG-3"])
        XCTAssertEqual(fullLists(), 1, "no full list between the full refreshes")
        XCTAssertEqual(Set(http.requests.compactMap { $0.url?.path() }.filter { $0.hasSuffix("i2/") || $0.hasSuffix("i3/") }),
                       ["\(list)i2/", "\(list)i3/"])
    }

    func testWritesMakePlaneJSON() async throws {
        let ref = ItemRef(project: project, id: "i1", key: "ENG-1", url: URL(string: "https://app.plane.so/acme/browse/ENG-1/")!)
        http.on("PATCH", "\(ws)/projects/P1/issues/i1/", "{}")
        try await plane.update(ref, ItemPatch(title: "New", status: "s2", bodyMarkdown: "**b**"))
        let body = try XCTUnwrap(http.body("PATCH", "\(ws)/projects/P1/issues/i1/"))
        XCTAssertEqual(body["name"] as? String, "New")
        XCTAssertEqual(body["state"] as? String, "s2")
        XCTAssertEqual(body["description_html"] as? String, "<p><strong>b</strong></p>")

        http.on("POST", "\(ws)/projects/P1/issues/", #"{"id":"i9","sequence_id":9}"#)
        let made = try await plane.create(ItemDraft(title: "T", bodyMarkdown: nil, status: nil, priority: "low"), in: project)
        XCTAssertEqual(made.key, "ENG-9")
        XCTAssertEqual(http.body("POST", "\(ws)/projects/P1/issues/")?["priority"] as? String, "low")

        http.on("GET", "\(ws)/projects/P1/issues/i1/", #"{"id":"i1","assignees":["u2"]}"#)
        try await plane.assignMe(ref)
        XCTAssertEqual(http.body("PATCH", "\(ws)/projects/P1/issues/i1/")?["assignees"] as? [String], ["u2", "u1"])
    }

    func testIntake() async throws {
        http.on("GET", "/api/v2/workspaces/acme/projects/P1/intake-issues/", #"{"data":[{"id":"n1","work_item_id":"w1","name":"Ask","priority":"none","created_by_id":"u2","created_at":"2026-10-16T09:00:00Z"}]}"#)
        let list = try await plane.intake(project)
        XCTAssertEqual(list.map(\.name), ["Ask"])
        XCTAssertNil(list[0].priority)
        XCTAssertEqual(list[0].author, "Bo")
        http.on("PATCH", "\(ws)/projects/P1/intake-issues/w1/status/", "{}")
        try await plane.triage(list[0], in: project, .duplicate(of: "i1"))
        let body = http.body("PATCH", "\(ws)/projects/P1/intake-issues/w1/status/")
        XCTAssertEqual(body?["status"] as? Int, 2)
        XCTAssertEqual(body?["duplicate_to"] as? String, "i1")
    }

    func testErrorsMapToProviderErrors() async {
        for (status, want) in [(401, ProviderError.unauthorized), (403, .forbidden), (404, .notFound)] {
            http.on("GET", "\(ws)/projects/P1/labels/", status: status, "{}")
            do { _ = try await plane.labels(project); XCTFail("no error for \(status)") }
            catch { XCTAssertEqual(error as? ProviderError, want) }
        }
        http.on("GET", "\(ws)/projects/P1/labels/", status: 500, #"{"detail":"boom"}"#)
        do { _ = try await plane.labels(project); XCTFail("no error") }
        catch { XCTAssertEqual(error as? ProviderError, .vendor(code: "500", message: "Plane: boom")) }
    }

    func testWebhooks() async throws {
        let hooks = "/api/v2/workspaces/acme/webhooks/"
        http.on("POST", hooks, #"{"id":"h1","secret_key":"s3cret"}"#)
        let made = try await plane.register(url: URL(string: "https://relay.dev/plane/acme")!)
        XCTAssertEqual(made.secret, "s3cret")
        XCTAssertEqual(http.body("POST", hooks)?["scopes"] as? [String], PlaneTracker.hookScopes)
        http.on("GET", hooks, #"{"data":[{"id":"h1","url":"https://relay.dev/plane/acme","is_active":false}]}"#)
        let list = try await plane.webhooks()
        XCTAssertEqual(list.first?.active, false)
        try await plane.unregister("gone")   // not found counts as done
    }

    func testPollSetsABaselineThenGivesDeltas() async throws {
        let issues = "\(ws)/projects/P1/issues/"
        http.on("GET", issues, #"{"results":[{"id":"i1","name":"A","sequence_id":1,"created_at":"2026-10-16T08:00:00Z","updated_at":"2026-10-16T10:00:00Z"}]}"#)
        let first = try await plane.poll(since: nil)
        XCTAssertTrue(first.events.isEmpty, "the first poll sets the baseline")

        http.on("GET", issues, #"{"results":[{"id":"i2","name":"B","sequence_id":2,"created_at":"2026-10-16T11:00:00Z","updated_at":"2026-10-16T11:00:00Z"},{"id":"i1","name":"A","sequence_id":1,"created_at":"2026-10-16T08:00:00Z","updated_at":"2026-10-16T10:30:00Z"},{"id":"i0","name":"Z","sequence_id":3,"created_at":"2026-10-16T08:00:00Z","updated_at":"2026-10-16T09:00:00Z"}]}"#)
        let second = try await plane.poll(since: first.cursor)
        XCTAssertEqual(second.events.map(\.action), ["updated", "created"])
        XCTAssertEqual(second.events.last?.subject, .item(ItemRef(project: project, id: "i2", key: "ENG-2",
                                                                    url: URL(string: "https://app.plane.so/acme/browse/ENG-2/")!)))
        XCTAssertEqual(second.events.last?.summary?.title, "B")

        let third = try await plane.poll(since: second.cursor)
        XCTAssertTrue(third.events.isEmpty, "no repeats")
        XCTAssertFalse(http.requests.contains { $0.url?.path(percentEncoded: false) == "\(ws)/projects/P2/issues/" }, "archived projects are skipped")
    }

    func testDescriptor() throws {
        struct Secrets: SecretReader { func secret(_ key: String) -> String? { key == "PLANE_TOKEN_acme" ? "tok" : nil } }
        struct NoCommands: CommandRunner {
            func run(_ exe: String, _ args: [String], stdin: Data?, timeout: Duration) async throws -> CommandOutput {
                throw ProviderError.unsupported("cli")
            }
        }
        let env = ProviderEnvironment(http: http, commands: NoCommands(), secrets: Secrets())
        let made = try PlaneTracker.descriptor.make(AccountConfig(account: AccountID(provider: .plane, id: "acme"),
                                                                  values: ["workspace": "acme"]), env)
        XCTAssertEqual((made as? PlaneTracker)?.workspace.host, PlaneWorkspace.cloudHost)
        XCTAssertThrowsError(try PlaneTracker.descriptor.make(AccountConfig(account: AccountID(provider: .plane, id: "x")), env))
    }
}
