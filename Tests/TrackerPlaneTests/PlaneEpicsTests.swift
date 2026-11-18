import XCTest
import OverSireCore
import OverSireTestKit
@testable import TrackerPlane

/// A Plane that keeps modules and their work items, like the real one.
final class ModulesPlane: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var modules: [[String: Any]] = []
    private var members: [String: [String]] = ["a": []]    // item id → module ids
    private(set) var requests: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path(percentEncoded: false) ?? ""
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let parts = path.split(separator: "/").map(String.init)
        let (status, out): (Int, Any) = lock.withLock {
            requests.append(method + " " + path)
            func module(_ id: String) -> [String: Any]? { modules.first { $0["id"] as? String == id } }
            switch (method, path) {
            case ("GET", _) where path.hasSuffix("/projects/P1/"): return (200, ["id": "P1", "identifier": "ENG", "module_view": true])
            case ("GET", _) where path.hasSuffix("/modules/"): return (200, ["data": modules, "next": NSNull()])
            case ("POST", _) where path.hasSuffix("/modules/"):
                let m: [String: Any] = ["id": "m\(modules.count + 1)", "name": body["name"] ?? "", "status": body["status"] ?? "planned",
                                        "sort_order": 1000 * (modules.count + 1)]
                modules.append(m)
                return (201, m)
            case ("POST", _) where path.hasSuffix("/work-items/"):
                let id = parts[parts.count - 2]
                for item in body["add"] as? [String] ?? [] { members[item, default: []].append(id) }
                for item in body["remove"] as? [String] ?? [] { members[item]?.removeAll { $0 == id } }
                return (200, ["added": body["add"] ?? [], "removed": body["remove"] ?? []])
            case ("PATCH", _), ("GET", _) where parts.contains("modules"):
                guard let n = modules.firstIndex(where: { $0["id"] as? String == parts.last }) else { return (404, ["detail": "no module"]) }
                if method == "PATCH" { for (k, v) in body { modules[n][k] = v } }
                return (200, modules[n])
            case ("GET", _) where path.hasSuffix("/work-items/"):
                return (200, ["data": members.map { ["id": $0.key, "state_id": "s1", "sequence_id": 1, "module_ids": $0.value,
                                                      "updated_at": "2026-11-10T10:00:00Z"] as [String: Any] }, "next": NSNull()])
            case ("GET", _) where parts.contains("work-items"):
                return (200, ["id": parts.last ?? "", "module_ids": members[parts.last ?? ""] ?? []])
            case ("GET", _) where path.hasSuffix("/issues/"):
                return (200, ["results": members.keys.map { ["id": $0, "name": "Item", "sequence_id": 1, "state": "s1",
                                                              "updated_at": "2026-11-10T10:00:00Z"] as [String: Any] },
                              "next_page_results": false])
            default: return (404, ["detail": "no route \(method) \(path)"])
            }
        }
        return (try JSONSerialization.data(withJSONObject: out), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class PlaneEpicsTests: XCTestCase {
    let ws = "/api/v1/workspaces/acme"
    let v2 = "/api/v2/workspaces/acme"
    var http: RecordedPlane!
    var plane: PlaneTracker!
    var project: ProjectRef { ProjectRef(account: plane.account, id: "P1", key: "ENG") }

    override func setUp() {
        http = RecordedPlane()
        plane = PlaneTracker(workspace: PlaneWorkspace(slug: "acme"), token: "tok", http: http)
        http.on("GET", "\(ws)/projects/P1/", #"{"id":"P1","identifier":"ENG","module_view":true}"#)
        http.on("GET", "\(ws)/members/", "[]")
    }

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtureDir("plane").appendingPathComponent(name + ".json"), encoding: .utf8)
    }

    private func item(_ id: String) -> ItemRef {
        ItemRef(project: project, id: id, key: "ENG-1", url: URL(string: "https://app.plane.so/acme/browse/ENG-1/")!)
    }

    private func loadFixtures() throws {
        http.on("GET", "\(v2)/projects/P1/modules/", try fixture("modules"))
        http.on("GET", "\(v2)/projects/P1/work-items/", try fixture("work-items-v2"))
    }

    private var posts: [(path: String, body: [String: Any])] {
        http.requests.filter { $0.httpMethod == "POST" && $0.url?.path().hasSuffix("/work-items/") == true }.map {
            ($0.url!.path(), (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any]) ?? [:])
        }
    }

    func testEpicsFromModules() async throws {
        try loadFixtures()
        let epics = try await plane.epics(in: project)
        XCTAssertEqual(epics.map(\.id.rawValue), ["m1", "m2", "m3", "m4", "m5", "m6"], "sort order, no archived module")
        XCTAssertEqual(epics.map(\.state), [.planned, .planned, .active, .paused, .done, .canceled])
        XCTAssertEqual(epics.map(\.nativeState), ["backlog", "planned", "in-progress", "paused", "completed", "cancelled"])
        let a = try XCTUnwrap(epics.first)
        XCTAssertEqual(a.title, "Alpha")
        XCTAssertEqual(a.goal, "Ship **alpha**")
        XCTAssertEqual(a.lead, "u1")
        XCTAssertEqual(a.url, "https://app.plane.so/acme/projects/P1/modules/m1/")
        let cal = Calendar.current
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: try XCTUnwrap(a.startDate)), DateComponents(year: 2026, month: 10, day: 1))
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: try XCTUnwrap(a.targetDate)), DateComponents(year: 2026, month: 12, day: 1))
        XCTAssertNil(epics[1].goal)
    }

    func testStatusMap() {
        for (native, state) in [("backlog", EpicState.planned), ("planned", .planned), ("in-progress", .active), ("paused", .paused),
                                ("completed", .done), ("cancelled", .canceled), ("other", .planned)] {
            XCTAssertEqual(PlaneTracker.epicState(native), state, native)
        }
        for s in EpicState.allCases { XCTAssertEqual(PlaneTracker.epicState(PlaneTracker.planeStatus(s)), s) }
    }

    func testIndexStampsFirstModuleAndKey() async throws {
        try loadFixtures()
        let index = try await plane.index(project)
        let i1 = try XCTUnwrap(index.first { $0.id == "i1" })
        XCTAssertEqual(i1.epicId, "m1", "module_ids is [m2, m1], and m1 has the lower sort order")
        XCTAssertEqual(i1.key, "ENG-1")
        XCTAssertEqual(i1.activityAt, ISO8601DateFormatter().date(from: "2026-11-10T10:00:00Z"))
        XCTAssertEqual(index.first { $0.id == "i2" }?.parentId, "i1")
        XCTAssertEqual(index.first { $0.id == "i2" }?.stateId, "s1")
        XCTAssertNil(index.first { $0.id == "i3" }?.epicId)
    }

    func testItemInTwoModulesGetsFirstAndFlag() async throws {
        try loadFixtures()
        http.on("GET", "\(ws)/projects/P1/states/", "{}")
        let row = { (id: String, n: Int) in #"{"id":"\#(id)","name":"Item","sequence_id":\#(n),"state":"s1","updated_at":"2026-11-10T10:00:00Z"}"# }
        http.on("GET", "\(ws)/projects/P1/issues/", #"{"results":[\#(row("i1", 1)),\#(row("i2", 2)),\#(row("i3", 3))],"next_page_results":false}"#)
        let items = try await plane.items(project, since: nil, limit: 50)
        let i1 = try XCTUnwrap(items.first { $0.id == "i1" })
        XCTAssertEqual(i1.epicId, "m1")
        XCTAssertEqual(i1.otherEpicIds, ["m2"])
        XCTAssertEqual(items.first { $0.id == "i2" }?.epicId, "m3")
        XCTAssertNil(items.first { $0.id == "i2" }?.otherEpicIds)
        XCTAssertNil(items.first { $0.id == "i3" }?.epicId)
    }

    func testSetEpicAddsThenRemovesOthers() async throws {
        try loadFixtures()
        http.on("GET", "\(v2)/projects/P1/work-items/i1/", #"{"id":"i1","module_ids":["m1","m2"]}"#)
        for m in ["m1", "m2", "m3"] { http.on("POST", "\(v2)/projects/P1/modules/\(m)/work-items/", try fixture("module-link")) }
        try await plane.setEpic("m3", for: item("i1"))
        let p = posts
        XCTAssertEqual(p.map(\.path), ["\(v2)/projects/P1/modules/m3/work-items/", "\(v2)/projects/P1/modules/m1/work-items/",
                                       "\(v2)/projects/P1/modules/m2/work-items/"], "add first, then remove")
        XCTAssertEqual(p.map { $0.body.keys.sorted() }, [["add"], ["remove"], ["remove"]])
        XCTAssertEqual(p[0].body["add"] as? [String], ["i1"])
    }

    func testSetEpicKeepsTheTargetModule() async throws {
        try loadFixtures()
        http.on("GET", "\(v2)/projects/P1/work-items/i1/", #"{"id":"i1","module_ids":["m1","m2"]}"#)
        http.on("POST", "\(v2)/projects/P1/modules/m2/work-items/", try fixture("module-unlink"))
        try await plane.setEpic("m1", for: item("i1"))
        XCTAssertEqual(posts.map(\.path), ["\(v2)/projects/P1/modules/m2/work-items/"])
        XCTAssertEqual(posts.first?.body["remove"] as? [String], ["i1"])
    }

    func testSetEpicNilRemovesFromAll() async throws {
        http.on("GET", "\(v2)/projects/P1/work-items/i1/", #"{"id":"i1","module_ids":["m1","m2"]}"#)
        for m in ["m1", "m2"] { http.on("POST", "\(v2)/projects/P1/modules/\(m)/work-items/", try fixture("module-unlink")) }
        try await plane.setEpic(nil, for: item("i1"))
        XCTAssertEqual(posts.map { $0.body.keys.sorted() }, [["remove"], ["remove"]])
        XCTAssertEqual(posts.map(\.path), ["\(v2)/projects/P1/modules/m1/work-items/", "\(v2)/projects/P1/modules/m2/work-items/"])
    }

    func testSetEpicOfAnotherProjectIsUnsupported() async throws {
        try loadFixtures()
        do { try await plane.setEpic("other-project-module", for: item("i1")); XCTFail("no error") } catch {
            XCTAssertEqual(error as? ProviderError, .unsupported(.epics))
        }
        XCTAssertTrue(posts.isEmpty, "nothing is written")
    }

    func testModulesOffIsUnsupported() async throws {
        try loadFixtures()
        http.on("GET", "\(ws)/projects/P1/", #"{"id":"P1","identifier":"ENG","module_view":false}"#)
        do { _ = try await plane.epics(in: project); XCTFail("no error") } catch {
            XCTAssertEqual(error as? ProviderError, .unsupported(.epics))
        }
        do { _ = try await plane.createEpic(EpicDraft(title: "X"), in: project); XCTFail("no error") } catch {
            XCTAssertEqual(error as? ProviderError, .unsupported(.epics))
        }
        do { try await plane.setEpic(nil, for: item("i1")); XCTFail("no error") } catch {
            XCTAssertEqual(error as? ProviderError, .unsupported(.epics))
        }
        XCTAssertFalse(http.requests.contains { $0.url?.path().contains("/modules/") == true }, "no module call")
    }

    func testCreateAndCloseSendPlaneFields() async throws {
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 5))!
        http.on("POST", "\(v2)/projects/P1/modules/", status: 201, #"{"id":"m9","name":"Launch","status":"in-progress","description":"Goal"}"#)
        let made = try await plane.createEpic(EpicDraft(title: "Launch", goal: "Goal", state: .active, lead: "u1", targetDate: day), in: project)
        XCTAssertEqual(made.id, "m9")
        XCTAssertEqual(made.state, .active)
        let body = try XCTUnwrap(http.body("POST", "\(v2)/projects/P1/modules/"))
        XCTAssertEqual(body["name"] as? String, "Launch")
        XCTAssertEqual(body["description"] as? String, "Goal")
        XCTAssertEqual(body["status"] as? String, "in-progress")
        XCTAssertEqual(body["lead_id"] as? String, "u1")
        XCTAssertEqual(body["target_date"] as? String, "2026-12-05")

        http.on("PATCH", "\(v2)/projects/P1/modules/m9/", "{}")
        http.on("GET", "\(v2)/projects/P1/modules/m9/", #"{"id":"m9","name":"Launch","status":"completed"}"#)
        let closed = try await plane.updateEpic(made, EpicPatch(state: .done, clear: [.targetDate]))
        XCTAssertEqual(closed.state, .done)
        let patch = try XCTUnwrap(http.body("PATCH", "\(v2)/projects/P1/modules/m9/"))
        XCTAssertEqual(patch["status"] as? String, "completed")
        XCTAssertTrue(patch["target_date"] is NSNull)
    }

    func testDuplicateNameIsAVendorError() async {
        http.on("POST", "\(v2)/projects/P1/modules/", status: 400, #"{"error":"A module with this name exists"}"#)
        do { _ = try await plane.createEpic(EpicDraft(title: "Dup"), in: project); XCTFail("no error") } catch {
            XCTAssertEqual(error as? ProviderError, .vendor(code: "400", message: "Plane: A module with this name exists"))
        }
    }

    func testWriteClearsTheCaches() async throws {
        try loadFixtures()
        http.on("GET", "\(v2)/projects/P1/work-items/i3/", #"{"id":"i3","module_ids":[]}"#)
        http.on("POST", "\(v2)/projects/P1/modules/m3/work-items/", try fixture("module-link"))
        let modules = { self.http.requests.filter { $0.url?.path() == "\(self.v2)/projects/P1/modules/" }.count }
        let indexes = { self.http.requests.filter { $0.url?.path() == "\(self.v2)/projects/P1/work-items/" }.count }
        _ = try await plane.epics(in: project)
        _ = try await plane.epics(in: project)
        _ = try await plane.index(project)
        _ = try await plane.index(project)
        XCTAssertEqual(modules(), 1, "the modules are kept")
        XCTAssertEqual(indexes(), 1, "the index is kept")
        try await plane.setEpic("m3", for: item("i3"))
        _ = try await plane.index(project)
        XCTAssertEqual(indexes(), 2, "a write clears the index")
        XCTAssertEqual(modules(), 2, "a write clears the modules")
    }

    func testConformance() async {
        let fake = ModulesPlane()
        let plane = PlaneTracker(workspace: PlaneWorkspace(slug: "acme"), token: "tok", http: fake)
        let p = ProjectRef(account: plane.account, id: "P1", key: "ENG")
        let ref = ItemRef(project: p, id: "a", key: "ENG-1", url: URL(string: "https://app.plane.so/acme/browse/ENG-1/")!)
        let r = await TrackerConformance.epics(plane, item: ref, project: p)
        XCTAssertTrue(r.passed, r.description)
        XCTAssertTrue(fake.requests.contains { $0.hasPrefix("POST") && $0.hasSuffix("/modules/m1/work-items/") }, "the suite links the item")
        XCTAssertTrue(ProviderConformance.capabilities(plane).passed)
        XCTAssertTrue(plane.capabilities.contains(.epics))
        XCTAssertEqual(PlaneTracker.descriptor.epicNoun, "module")
        XCTAssertFalse(PlaneTracker.descriptor.epicFields.contains(.crossProject))
    }
}
