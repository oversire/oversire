import XCTest
import OverSireCore
import OverSireTestKit
@testable import TrackerPlane

/// A Plane that keeps relations on both items, like the real one.
final class RelationsPlane: HTTPTransport, @unchecked Sendable {
    static let inverse = ["blocked_by": "blocking", "blocking": "blocked_by", "relates_to": "relates_to"]
    private let lock = NSLock()
    private var rels: [String: [String: [String]]] = [:]
    private var seq: [String: Int] = [:]
    private(set) var requests: [String] = []

    init(items: [String: Int]) { seq = items }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path(percentEncoded: false) ?? ""
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let parts = path.split(separator: "/").map(String.init)
        let (status, out): (Int, Any) = lock.withLock {
            requests.append(method + " " + path)
            if method == "POST", parts.last == "issues" {
                let id = "new-\(seq.count)"
                seq[id] = 100 + seq.count
                return (201, ["id": id, "sequence_id": seq[id]!])
            }
            guard let w = parts.firstIndex(of: "work-items"), w + 1 < parts.count else { return (404, ["detail": "no route"]) }
            let id = parts[w + 1]
            if parts.last == id {
                guard let s = seq[id] else { return (404, ["detail": "not found"]) }
                return (200, ["id": id, "sequence_id": s])
            }
            switch (method, parts.last) {
            case ("GET", "relations"?):
                var o: [String: [String]] = [:]
                for t in ["blocking", "blocked_by", "duplicate", "relates_to", "start_after", "start_before", "finish_after", "finish_before"] {
                    o[t] = rels[id]?[t] ?? []
                }
                return (200, o)
            case ("POST", "relations"?):
                let type = body["relation_type"] as? String ?? ""
                for other in body["issues"] as? [String] ?? [] {
                    rels[id, default: [:]][type, default: []].append(other)
                    rels[other, default: [:]][Self.inverse[type] ?? type, default: []].append(id)
                }
                return (201, [[Any]]())
            case ("POST", "remove"?):
                let other = body["related_issue"] as? String ?? ""
                for t in rels[id]?.keys.map({ $0 }) ?? [] { rels[id]?[t]?.removeAll { $0 == other } }
                for t in rels[other]?.keys.map({ $0 }) ?? [] { rels[other]?[t]?.removeAll { $0 == id } }
                return (204, NSNull())
            default:
                return (404, ["detail": "no route"])
            }
        }
        let data = out is NSNull ? Data() : try JSONSerialization.data(withJSONObject: out)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class PlaneRelationsTests: XCTestCase {
    let pid = "9ba476d7-ad30-44cf-b9ef-3fa1e42ed926"
    let ws = "/api/v1/workspaces/ocral"

    private func ref(_ plane: PlaneTracker, _ id: String, _ key: String) -> ItemRef {
        ItemRef(project: ProjectRef(account: plane.account, id: pid, key: "OVERSIRE"), id: id, key: key,
                url: URL(string: "https://app.plane.so/ocral/browse/\(key)/")!)
    }

    /// Answers recorded read-only from the real OVERSIRE-82.
    func testRelationsFromRecordedAnswers() async throws {
        let http = RecordedPlane()
        let plane = PlaneTracker(workspace: PlaneWorkspace(slug: "ocral"), token: "tok", http: http)
        let dir = fixtureDir("plane")
        func fixture(_ name: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(name + ".json"), encoding: .utf8) }
        let item = ref(plane, "3cb742b5-53fb-4ba7-a0da-0984f3f8b163", "OVERSIRE-82")
        let base = "\(ws)/projects/\(pid)/work-items/"
        http.on("GET", base + item.id + "/relations/", try fixture("relations"))
        http.on("GET", base + "2a8bef3d-61fd-48c6-93e0-5df1836b50d5/", try fixture("item-80"))
        http.on("GET", base + "dacfb6d2-fbf5-469a-adc1-aabe33eacb73/", try fixture("item-88"))

        let rels = try await plane.relations(of: item)
        XCTAssertEqual(rels.map(\.kind), [.blockedBy, .blocks])
        XCTAssertEqual(rels.map(\.item.key), ["OVERSIRE-80", "OVERSIRE-88"])
        XCTAssertEqual(rels.first?.item.url.absoluteString, "https://app.plane.so/ocral/browse/OVERSIRE-80/")
        _ = try await plane.relations(of: item)
        XCTAssertEqual(http.requests.filter { $0.url?.path(percentEncoded: false).hasSuffix("-5df1836b50d5/") == true }.count, 1, "a resolved key is kept")
    }

    func testUnknownItemOfAnotherProjectIsDropped() async throws {
        let http = RecordedPlane()
        let plane = PlaneTracker(workspace: PlaneWorkspace(slug: "ocral"), token: "tok", http: http)
        let item = ref(plane, "a", "OVERSIRE-1")
        http.on("GET", "\(ws)/projects/\(pid)/work-items/a/relations/", #"{"blocked_by":["x"],"duplicate":["d"],"start_after":["s"]}"#)
        let rels = try await plane.relations(of: item)
        XCTAssertTrue(rels.isEmpty, "x has no answer (404), duplicate and start_after drop")
    }

    func testApplyBodies() async throws {
        let http = RecordedPlane()
        let plane = PlaneTracker(workspace: PlaneWorkspace(slug: "ocral"), token: "tok", http: http)
        let a = ref(plane, "a", "OVERSIRE-1"), b = ref(plane, "b", "OVERSIRE-2"), c = ref(plane, "c", "OVERSIRE-3")
        let path = "\(ws)/projects/\(pid)/work-items/a/relations/"
        http.on("POST", path, status: 201, "[]")
        http.on("POST", path + "remove/", status: 204, "")
        try await plane.apply(RelationPatch(add: [ItemRelation(kind: .blockedBy, item: b), ItemRelation(kind: .blockedBy, item: c)],
                                            remove: [ItemRelation(kind: .relatesTo, item: c)]), to: a)
        let add = try XCTUnwrap(http.body("POST", path))
        XCTAssertEqual(add["relation_type"] as? String, "blocked_by")
        XCTAssertEqual(add["issues"] as? [String], ["b", "c"])
        XCTAssertEqual(http.body("POST", path + "remove/")?["related_issue"] as? String, "c")
        let order = http.requests.map { $0.url?.path(percentEncoded: false) ?? "" }
        XCTAssertEqual(order, [path, path + "remove/"], "add before remove")
    }

    func testConformance() async {
        let http = RelationsPlane(items: ["a": 1])
        let plane = PlaneTracker(workspace: PlaneWorkspace(slug: "ocral"), token: "tok", http: http)
        let item = ref(plane, "a", "OVERSIRE-1")
        let r = await TrackerConformance.relations(plane, item: item, project: item.project)
        XCTAssertTrue(r.passed, r.description)
        XCTAssertTrue(ProviderConformance.capabilities(plane).passed)
        XCTAssertTrue(plane.capabilities.contains(.relations))
    }
}
