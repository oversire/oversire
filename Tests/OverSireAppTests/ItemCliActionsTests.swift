import OverSireAssistant
import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

extension FakeTracker: MemberListing {
    public func memberNames() async -> [String: String] { ["me": "Me Fake", "bob": "Bob Stone"] }
}

/// The item actions that the `oversire` CLI runs through app calls.
final class ItemCliActionsTests: XCTestCase {
    let agent = EventActor(type: .agent, name: "codex s1")

    func run(_ rig: EpicRig, _ id: String, _ args: [String: JSONValue], agent: String? = "codex s1") async -> ActionResult {
        await rig.d.actions.run(id, ActionArgs(.object(args), caller: .cli(agent: agent)))
    }

    func item(_ rig: EpicRig, _ n: Int = 0) async -> Item? {
        await MainActor.run { rig.d.projectStore.item(key: rig.items[n].key)?.item }
    }

    func assertNotAllowed(_ r: ActionResult, _ tail: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .notAllowed(let m) = r else { return XCTFail("not a refusal: \(r)", file: file, line: line) }
        XCTAssertTrue(m.hasSuffix(tail) || m.contains(tail), m, file: file, line: line)
    }

    // MARK: Links and attachments

    func testLinkAddsAndWritesAgentRow() async throws {
        let rig = try await EpicRig()
        let r = await run(rig, "item.link", ["key": .string(rig.items[0].key), "url": .string("https://example.com/spec"), "title": .string("Spec")])
        XCTAssertEqual(r.summary, "Link added to \(rig.items[0].key).")
        XCTAssertEqual(rig.fake.addedLinks.count, 1)
        XCTAssertEqual(rig.fake.addedLinks.first?.title, "Spec")
        let row = await rig.row(.itemLinkAdded)
        XCTAssertEqual(row?.actorType, .agent)
        XCTAssertEqual(row?.actor, "codex s1")
        XCTAssertEqual(row?.payload, ["url": .string("https://example.com/spec"), "title": .string("Spec")])
        XCTAssertEqual(row.map { EventCatalog.repo.problems($0) }, [])
    }

    func testLinkRefusesBadURL() async throws {
        let rig = try await EpicRig()
        for url in ["ftp://x", "example.com", ""] {
            let r = await run(rig, "item.link", ["key": .string(rig.items[0].key), "url": .string(url)])
            assertNotAllowed(r, "Give an http or https URL.")
        }
        XCTAssertTrue(rig.fake.addedLinks.isEmpty)
    }

    func testLinkUnsupported() async throws {
        let rig = try await EpicRig(capabilities: [.epics])
        let r = await run(rig, "item.link", ["key": .string(rig.items[0].key), "url": .string("https://example.com")])
        assertNotAllowed(r, "has no links.")
        XCTAssertTrue(rig.fake.addedLinks.isEmpty)
    }

    func testAttachUploads() async throws {
        let rig = try await EpicRig()
        let r = await run(rig, "item.attach", ["key": .string(rig.items[0].key), "name": .string("note.txt"), "data": .string("aGVsbG8="),
                                               "mimeType": .string("text/plain")])
        guard case .ok(_, let data, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(data?["id"]?.string, "a1")
        XCTAssertEqual(rig.fake.uploads.count, 1)
        XCTAssertEqual(rig.fake.uploads[0].file.data, Data("hello".utf8))
        XCTAssertEqual(rig.fake.uploads[0].file.mimeType, "text/plain")
        let row = await rig.row(.itemAttachmentAdded)
        XCTAssertEqual(row?.actorType, .agent)
        XCTAssertEqual(row?.payload?["size"], .int(5))
        XCTAssertEqual(row.map { EventCatalog.repo.problems($0) }, [])
    }

    func testAttachRefusesBadBase64AndTooLarge() async throws {
        let rig = try await EpicRig()
        let bad = await run(rig, "item.attach", ["key": .string(rig.items[0].key), "name": .string("a.bin"), "data": .string("not base64!")])
        assertNotAllowed(bad, "The data is not base64.")
        let big = Data(count: ItemActions.maxAttachBytes + 1).base64EncodedString()
        let large = await run(rig, "item.attach", ["key": .string(rig.items[0].key), "name": .string("a.bin"), "data": .string(big)])
        assertNotAllowed(large, "The file has 11 MB. The limit is 10 MB.")
        XCTAssertTrue(rig.fake.uploads.isEmpty)
    }

    func testAttachUnsupported() async throws {
        let rig = try await EpicRig(capabilities: [.epics])
        let r = await run(rig, "item.attach", ["key": .string(rig.items[0].key), "name": .string("a.txt"), "data": .string("aGVsbG8=")])
        assertNotAllowed(r, "has no attachments.")
    }

    // MARK: Project reads

    func testProjectStatuses() async throws {
        let rig = try await EpicRig()
        let r = await run(rig, "project.statuses", ["project": .string("FAKE")])
        guard case .ok(_, let data, _) = r, let rows = data?.array else { return XCTFail("\(r)") }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0]["id"]?.string, "s-todo")
        XCTAssertEqual(rows[0]["group"]?.string, "unstarted")
        XCTAssertEqual(rows[0]["category"]?.string, "todo")
        XCTAssertEqual(rows[3]["category"]?.string, "done")
        assertNotAllowed(await run(rig, "project.statuses", ["project": .string("NOPE")]), "OverSire has no loaded project NOPE.")
    }

    func testProjectLabels() async throws {
        let rig = try await EpicRig()
        let r = await run(rig, "project.labels", ["project": .string("FAKE")])
        guard case .ok(_, let data, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(data?.array?.first?["name"]?.string, "bug")
        XCTAssertEqual(data?.array?.first?["id"]?.string, "l-bug")
        let none = try await EpicRig(capabilities: [.epics])
        assertNotAllowed(await run(none, "project.labels", ["project": .string("FAKE")]), "has no labels.")
    }

    func testProjectPeople() async throws {
        let rig = try await EpicRig()
        let r = await run(rig, "project.people", ["project": .string("FAKE")])
        guard case .ok(_, let data, _) = r, let rows = data?.array else { return XCTFail("\(r)") }
        XCTAssertEqual(rows.compactMap { $0["id"]?.string }, ["bob", "me"])
        XCTAssertEqual(rows.first { $0["id"]?.string == "me" }?["me"]?.bool, true)
        XCTAssertEqual(rows.first { $0["id"]?.string == "bob" }?["me"]?.bool, false)
    }

    func testOptionsCallsDoneWithoutProject() async throws {
        let rig = try await EpicRig()
        let options: ItemOptions = await withCheckedContinuation { c in
            DispatchQueue.main.async { rig.d.projectStore.options(projectKey: "nope") { c.resume(returning: $0) } }
        }
        XCTAssertTrue(options.labels.isEmpty)
        XCTAssertTrue(options.members.isEmpty)
    }

    // MARK: Writes

    func testAssignByNameAndMe() async throws {
        let rig = try await EpicRig()
        let key = rig.items[0].key
        _ = await run(rig, "item.assign", ["key": .string(key), "people": .array([.string("me")])])
        var i = await item(rig)
        XCTAssertEqual(i?.assignees, ["me"])
        _ = await run(rig, "item.assign", ["key": .string(key), "people": .array([.string("bob stone"), .string("me")])])
        i = await item(rig)
        XCTAssertEqual(i?.assignees, ["bob", "me"])
        let r = await run(rig, "item.assign", ["key": .string(key), "people": .array([.string("zed")])])
        assertNotAllowed(r, "No person zed in FAKE. Use: Bob Stone, Me Fake.")
        _ = await run(rig, "item.assign", ["key": .string(key), "people": .array([])])
        i = await item(rig)
        XCTAssertEqual(i?.assignees, [])
    }

    func testSetStatusByCategoryWord() async throws {
        let rig = try await EpicRig()
        let key = rig.items[0].key
        for (word, id) in [("done", "s-done"), ("todo", "s-todo"), ("progress", "s-doing")] {
            let r = await run(rig, "item.setStatus", ["key": .string(key), "status": .string(word)])
            XCTAssertEqual(r.summary.hasSuffix("."), true, r.summary)
            let i = await item(rig)
            XCTAssertEqual(i?.statusOptionId, id, word)
        }
        let r = await run(rig, "item.setStatus", ["key": .string(key), "status": .string("blocked")])
        assertNotAllowed(r, "has no status blocked.")
    }

    func testSetStatusRowNamesAgent() async throws {
        let rig = try await EpicRig()
        _ = await run(rig, "item.setStatus", ["key": .string(rig.items[0].key), "status": .string("done")])
        let row = await rig.row(.itemStateChanged)
        XCTAssertEqual(row?.actorType, .agent)
        XCTAssertEqual(row?.actor, "codex s1")
        XCTAssertEqual(row.map { EventCatalog.repo.problems($0) }, [])
    }

    func testCreateWithLabelsAndParent() async throws {
        let rig = try await EpicRig()
        let r = await run(rig, "item.create", ["project": .string("FAKE"), "title": .string("Child"), "labels": .array([.string("bug")]),
                                               "parent": .string(rig.items[0].key)])
        guard case .ok(let summary, let data, _) = r, let key = data?["key"]?.string else { return XCTFail("\(r)") }
        XCTAssertEqual(summary, "\(key) is made under \(rig.items[0].key).")
        await until("the snapshot has the item") { await rig.snapshot()?.items.contains { $0.key == key } == true }
        let made = await MainActor.run { rig.d.projectStore.item(key: key)?.item }
        XCTAssertEqual(made?.labels, ["l-bug"])
        XCTAssertEqual(made?.parentId, rig.items[0].id)
    }

    /// A refresh that misses the new item must not fail the call (OVERSIRE-540).
    func testCreateAnswersWhenTheRefreshMissesTheItem() async throws {
        let rig = try await EpicRig()
        rig.fake.freezeList()
        let r = await run(rig, "item.create", ["project": .string("FAKE"), "title": .string("Late")])
        guard case .ok(_, let data, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(data?["key"]?.string, "FAKE-4")
        XCTAssertEqual(data?["id"]?.string, "i4")
        XCTAssertEqual(data?["url"]?.string, "https://tracker.fake/FAKE-4")
    }

    func testCreateWithEpicSetsTheEpicBeforeTheAnswer() async throws {
        let rig = try await EpicRig()
        let r = await run(rig, "item.create", ["project": .string("FAKE"), "title": .string("In epic"), "epic": .string("Review desk")])
        guard case .ok(let summary, let data, _) = r, let id = data?["id"]?.string else { return XCTFail("\(r)") }
        XCTAssertEqual(summary, "FAKE-4 is made in Review desk.")
        let epics = try await rig.fake.items(rig.fake.project, since: nil, limit: 50)
        XCTAssertEqual(epics.first { $0.id == id }?.epicId, rig.epic.id)
    }

    func testCreateEpicFailureStillMakesTheItem() async throws {
        let rig = try await EpicRig()
        rig.fake.failWrites(to: "i4")
        let r = await run(rig, "item.create", ["project": .string("FAKE"), "title": .string("Not in epic"), "epic": .string("Review desk")])
        guard case .ok(let summary, let data, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(data?["key"]?.string, "FAKE-4")
        XCTAssertTrue(summary.hasPrefix("FAKE-4 is made. It is not in Review desk:"), summary)
    }

    func testNewItemIsFoundBeforeTheRefresh() async throws {
        let rig = try await EpicRig()
        rig.fake.freezeList()
        let r = await run(rig, "item.create", ["project": .string("FAKE"), "title": .string("Fresh")])
        guard case .ok(_, let data, _) = r, let key = data?["key"]?.string else { return XCTFail("\(r)") }
        let c = await run(rig, "item.comment", ["key": .string(key), "body": .string("Hello")])
        guard case .ok = c else { return XCTFail("\(c)") }
        rig.fake.thawList()
        await rig.reload()
        let inSnapshot = await rig.snapshot()?.items.contains { $0.key == key }
        XCTAssertEqual(inSnapshot, true)
        let stubs = await MainActor.run { rig.d.projectStore.item(key: key)?.item.commentCount }
        XCTAssertEqual(stubs, 1, "the snapshot item replaces the stub")
    }

    func testCreateBadLabel() async throws {
        let rig = try await EpicRig()
        let r = await run(rig, "item.create", ["project": .string("FAKE"), "title": .string("Child"), "labels": .array([.string("nope")])])
        assertNotAllowed(r, "No label nope. Use: bug.")
        let all = await MainActor.run { rig.d.projectStore.snapshot("FAKE")?.items.count }
        XCTAssertEqual(all, 3)
    }

    func testCreateUnknownParentMakesNothing() async throws {
        let rig = try await EpicRig()
        let r = await run(rig, "item.create", ["project": .string("FAKE"), "title": .string("Child"), "parent": .string("FAKE-99")])
        assertNotAllowed(r, "OverSire has no loaded item FAKE-99.")
        let count = try await rig.fake.items(rig.fake.project, since: nil, limit: 50).count
        XCTAssertEqual(count, 3)
    }

    func testCreateParentUnsupported() async throws {
        let rig = try await EpicRig(capabilities: [.epics])
        let r = await run(rig, "item.create", ["project": .string("FAKE"), "title": .string("Child"), "parent": .string(rig.items[0].key)])
        assertNotAllowed(r, "has no sub-items.")
        let count = try await rig.fake.items(rig.fake.project, since: nil, limit: 50).count
        XCTAssertEqual(count, 3)
    }

    func testUpdateParentNone() async throws {
        let rig = try await EpicRig()
        let child = rig.items[1].key
        _ = await run(rig, "item.update", ["key": .string(child), "parent": .string(rig.items[0].key)])
        var i = await item(rig, 1)
        XCTAssertEqual(i?.parentId, rig.items[0].id)
        let r = await run(rig, "item.update", ["key": .string(child), "parent": .string("none")])
        XCTAssertEqual(r.summary, "\(child) is updated.")
        i = await item(rig, 1)
        XCTAssertNil(i?.parentId)
    }

    func testUpdateParentUnsupported() async throws {
        let rig = try await EpicRig(capabilities: [.epics])
        let r = await run(rig, "item.update", ["key": .string(rig.items[1].key), "parent": .string("none")])
        assertNotAllowed(r, "has no sub-items.")
    }

    func testRelateDuplicateAndBadKind() async throws {
        let rig = try await EpicRig()
        let ok = await run(rig, "item.relate", ["key": .string(rig.items[0].key), "kind": .string("duplicate"), "other": .string(rig.items[1].key)])
        XCTAssertEqual(ok.summary, "\(rig.items[0].key) duplicate \(rig.items[1].key).")
        let rels = try await rig.fake.relations(of: rig.items[0])
        XCTAssertEqual(rels.map(\.kind), [.duplicate])
        let bad = await run(rig, "item.relate", ["key": .string(rig.items[0].key), "kind": .string("foo"), "other": .string(rig.items[1].key)])
        assertNotAllowed(bad, "No relation kind foo.")
    }

    func testRelateUnsupported() async throws {
        let rig = try await EpicRig(capabilities: [.epics])
        let r = await run(rig, "item.relate", ["key": .string(rig.items[0].key), "kind": .string("blocks"), "other": .string(rig.items[1].key)])
        assertNotAllowed(r, "has no relations.")
    }

    // MARK: Reads

    func testItemListGroupListAndCliLimit() async throws {
        let rig = try await EpicRig(items: 1, tracking: false)
        for n in 0..<99 { _ = try await rig.fake.create(ItemDraft(title: String(repeating: "Long title \(n) ", count: 6)), in: rig.fake.project) }
        try await rig.track()
        let key = rig.items[0].key
        let set = await run(rig, "item.setStatus", ["key": .string(key), "status": .string("In Review")])
        XCTAssertEqual(set.summary, "\(key) is In Review.")
        let two = await run(rig, "item.list", ["project": .string("FAKE"), "group": .string("progress,review"), "limit": .int(200)])
        guard case .ok(_, let d1, _) = two else { return XCTFail("\(two)") }
        XCTAssertEqual(d1?["total"]?.int, 1)
        let todo = await run(rig, "item.list", ["project": .string("FAKE"), "group": .string("todo,review"), "limit": .int(200)])
        guard case .ok(_, let d2, _) = todo else { return XCTFail("\(todo)") }
        XCTAssertEqual(d2?["total"]?.int, 100)
        XCTAssertNil(d2?["cut"], "a CLI caller gets the larger limit")
        XCTAssertGreaterThan(d2?.text.utf8.count ?? 0, JSONValue.readLimit)
        let ui = await rig.d.actions.run("item.list", ActionArgs(.object(["project": .string("FAKE"), "limit": .int(200)])))
        guard case .ok(_, let d3, _) = ui else { return XCTFail("\(ui)") }
        XCTAssertNotNil(d3?["cut"], "another caller gets the 24,000 bytes limit")
    }

    func testSearchAllProject() async throws {
        let rig = try await EpicRig()
        let all = await run(rig, "search.all", ["query": .string("Item"), "project": .string("FAKE")])
        guard case .ok(_, let data, _) = all else { return XCTFail("\(all)") }
        let keys = data?["items"]?.array?.compactMap { $0["key"]?.string } ?? []
        XCTAssertEqual(keys.count, 3)
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("FAKE-") })
        assertNotAllowed(await run(rig, "search.all", ["query": .string("Item"), "project": .string("NOPE")]), "OverSire has no loaded project NOPE.")
    }

    func testMarkdownHasLinks() async throws {
        let rig = try await EpicRig()
        _ = await run(rig, "item.link", ["key": .string(rig.items[0].key), "url": .string("https://example.com/spec")])
        let r = await run(rig, "item.markdown", ["key": .string(rig.items[0].key)])
        guard case .ok(_, let data, _) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(data?["markdown"]?.string?.hasSuffix("\n## Links\n- https://example.com/spec\n") == true, data?["markdown"]?.string ?? "")
    }

    // MARK: Agent actor of the poll rows

    /// The comment read picks only my items, and it matches the display name of the token owner.
    private func mine(_ rig: EpicRig, _ i: ItemRef) async throws {
        let me = await rig.snapshot()?.me ?? ""
        try await rig.fake.update(i, ItemPatch(assignees: [me]))
        await rig.reload()
    }

    func testCommentRowNamesAgent() async throws {
        let rig = try await EpicRig()
        try await mine(rig, rig.items[0])
        _ = await run(rig, "item.comment", ["key": .string(rig.items[0].key), "body": .string("Checked.")])
        let row = await rig.row(.commentCreated)
        XCTAssertEqual(row?.actorType, .agent)
        XCTAssertEqual(row?.actor, "codex s1")
        let left = await MainActor.run { rig.d.projectStore.writeActors }
        XCTAssertEqual(left, [:], "the mark ends after the refresh")
    }

    func testCreateRowNamesAgent() async throws {
        let rig = try await EpicRig()
        let r = await run(rig, "item.create", ["project": .string("FAKE"), "title": .string("Made by an agent")])
        guard case .ok(_, let data, _) = r, let key = data?["key"]?.string else { return XCTFail("\(r)") }
        let row = await rig.row(.itemCreated)
        XCTAssertEqual(row?.item, key)
        XCTAssertEqual(row?.actorType, .agent)
        XCTAssertEqual(row?.actor, "codex s1")
    }

    func testStartRowNamesAgent() async throws {
        let rig = try await EpicRig()
        _ = await run(rig, "item.start", ["key": .string(rig.items[0].key)])
        let row = await rig.row(.itemStateChanged)
        XCTAssertEqual(row?.actorType, .agent)
        XCTAssertEqual(row?.actor, "codex s1")
        XCTAssertEqual(row?.payload?["to"], .string("In Progress"))
        let again = await run(rig, "item.reopen", ["key": .string(rig.items[0].key)])
        XCTAssertEqual(again.summary, "\(rig.items[0].key) is open again.")
    }

    func testUpdateRowNamesAgent() async throws {
        let rig = try await EpicRig()
        _ = await run(rig, "item.assignMe", ["key": .string(rig.items[0].key)])
        let row = await rig.row(.itemUpdated)
        XCTAssertEqual(row?.actorType, .agent)
        XCTAssertEqual(row?.actor, "codex s1")
    }

    func testUIWriteKeepsHuman() async throws {
        let rig = try await EpicRig()
        try await mine(rig, rig.items[0])
        let ok: Bool = await withCheckedContinuation { c in
            DispatchQueue.main.async {
                rig.d.projectStore.comment(itemId: rig.items[0].id, body: "From the UI.") { c.resume(returning: $0) }
                XCTAssertEqual(rig.d.projectStore.writeActors, [:])
            }
        }
        XCTAssertTrue(ok)
        let row = await rig.row(.commentCreated)
        XCTAssertEqual(row?.actorType, .human)
    }
}
