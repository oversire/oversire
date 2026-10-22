import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

/// The contract fixture Contract/fixtures/<type>/<name>.json.
func contractFixture(_ type: String, _ name: String, file: String = #filePath) throws -> Data {
    let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("Contract/fixtures/\(type)/\(name).json"))
}

func contract<T: Decodable>(_: T.Type, _ type: String, _ name: String) throws -> T {
    try DaemonClient.decode(try contractFixture(type, name))
}

/// A Keychain in memory.
final class MemoryKeychain: CredentialKeeping, @unchecked Sendable {
    let items = Locked<[String: String]>([:])
    func get(_ key: String) -> String? { items.get()[key] }
    func set(_ key: String, _ value: String) { items.with { $0[key] = value } }
}

final class DaemonSourceTests: XCTestCase {
    let loopback = DaemonClient.loopback

    private func session(_ id: String, at: Date = Date(timeIntervalSince1970: 1_000)) -> ProviderEvent {
        let account = AccountID(provider: "orca", id: "mbp")
        let ref = SessionRef(workspace: WorkspaceRef(account: account, id: "wt-1"), id: id)
        return ProviderEvent(id: "mbp-\(id)", provider: "orca", account: account, kind: .session, action: "waiting",
                             subject: .session(ref), at: at)
    }

    // MARK: CloudSource as a daemon source

    func testADaemonSourceWithNoTokenSendsNoAuthorization() async throws {
        let daemon = FakeDaemon()
        let cursors = CursorStore(url: nil)
        let source = CloudSource(base: loopback, token: nil, name: "mba", cursorKey: "daemon:mba", http: daemon, socket: daemon,
                                 cursors: cursors, clock: ManualClock())
        let stream = source.events()
        await eventually("live") { await source.health() == .live }
        daemon.emit(session("t1"))
        let got = await take(1, from: stream)
        XCTAssertEqual(got.map(\.id), ["mbp-t1"])
        XCTAssertFalse(daemon.requests.isEmpty)
        XCTAssertTrue(daemon.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertEqual(daemon.requests.first?.url?.absoluteString, "ws://127.0.0.1:7690/v1/connect")
        await eventually("ack") { daemon.acks == [1] }
        XCTAssertEqual(cursors["daemon:mba"]?.rawValue, "1")
        XCTAssertNil(cursors[CloudSource.cursorKey], "each source keeps its own cursor")
        await source.stop()
    }

    func testEachSourceHasItsOwnCursor() async throws {
        let a = FakeDaemon(), b = FakeDaemon()
        let cursors = CursorStore(url: nil)
        let sa = CloudSource(base: loopback, token: nil, name: "mba", cursorKey: "daemon:mba", http: a, socket: a, cursors: cursors, clock: ManualClock())
        let sb = CloudSource(base: loopback, token: nil, name: "mbp", cursorKey: "daemon:mbp", http: b, socket: b, cursors: cursors, clock: ManualClock())
        let streamA = sa.events(), streamB = sb.events()
        await eventually("live") { let a = await sa.health(); let b = await sb.health(); return a == .live && b == .live }
        a.emit(session("t1"))
        b.emit(session("t2"))
        b.emit(session("t3"))
        _ = await take(1, from: streamA)
        _ = await take(2, from: streamB)
        await eventually("cursors") { cursors["daemon:mba"]?.rawValue == "1" && cursors["daemon:mbp"]?.rawValue == "2" }
        await sa.stop()
        await sb.stop()
    }

    func testTheHealthTextUsesTheName() async throws {
        let daemon = FakeDaemon(token: "good")
        let source = CloudSource(base: URL(string: "http://mbp:7690")!, token: "bad", name: "mbp", cursorKey: "daemon:mbp",
                                 http: daemon, socket: daemon, cursors: CursorStore(url: nil), clock: ManualClock())
        let stream = source.events()
        await eventually("failed") { await source.health() == .failed("mbp rejected this Mac's token") }
        await source.stop()
        _ = stream
    }

    func testAGroupFrameCallsOnGroup() async throws {
        let daemon = FakeDaemon()
        let groups = Locked(0)
        let source = CloudSource(base: loopback, token: nil, name: "mba", cursorKey: "daemon:mba", http: daemon, socket: daemon,
                                 cursors: CursorStore(url: nil), clock: ManualClock(), onGroup: { groups.with { $0 += 1 } })
        let stream = source.events()
        await eventually("live") { await source.health() == .live }
        daemon.groupChanged()
        await eventually("group") { groups.get() == 1 }
        await source.stop()
        _ = stream
    }

    // MARK: DaemonClient

    /// ReplayTransport files with the bodies of the contract fixtures (GET only).
    private func replay(_ routes: [(String, Data)], token: String? = nil) throws -> (DaemonClient, ReplayTransport) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = URL(string: "http://mbp:7690")!
        let builder = DaemonClient(base: base, token: token, http: FakeDaemon())
        for (path, body) in routes {
            let r = builder.request(path)
            let f: [String: Any] = ["method": "GET", "url": r.url!.absoluteString, "status": 200, "headers": [String: String](),
                                    "body": String(decoding: body, as: UTF8.self)]
            try JSONSerialization.data(withJSONObject: f).write(to: dir.appendingPathComponent(ReplayTransport.name(r) + ".json"))
        }
        let t = ReplayTransport(dir: dir, record: false)
        return (DaemonClient(base: base, token: token, http: t), t)
    }

    func testDaemonClientReadsTheContractFixtures() async throws {
        let (client, t) = try replay([
            ("/v1/whoami", try contractFixture("daemon-info", "tailscale-device")),
            ("/v1/sessions", try contractFixture("daemon-sessions-page", "two")),
            ("/v1/group", try contractFixture("group", "two-members")),
            ("/v1/questions", try contractFixture("daemon-questions-page", "two")),
        ], token: "osd1.x")
        let me = try await client.whoami()
        XCTAssertEqual(me.machine, "mbp")
        XCTAssertEqual(me.group, "9f3c1a2b7d4e5f60")
        let page = try await client.sessions()
        XCTAssertEqual(page.sessions.map(\.id), ["tab-2:leaf-1", "s-4f8a2c1e"])
        XCTAssertEqual(page.sessions[0].reason, .question)
        let g = try await client.group()
        XCTAssertEqual(g.members.map(\.machine), ["mbp", "mba"])
        let qs = try await client.questions()
        XCTAssertFalse(qs.questions.isEmpty)
        XCTAssertEqual(t.missing, [])
    }

    func testDaemonClientSendsTheCredentialAndMapsErrors() async throws {
        let daemon = FakeDaemon(token: "osd1.x")
        let good = DaemonClient(base: URL(string: "http://mbp:7690")!, token: "osd1.x", http: daemon)
        _ = try await good.whoami()
        XCTAssertEqual(daemon.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer osd1.x")
        let bad = DaemonClient(base: URL(string: "http://mbp:7690")!, token: "other", http: daemon)
        do { _ = try await bad.sessions(); XCTFail("no error") } catch ProviderError.unauthorized {}
        do { _ = try await good.group(); XCTFail("no error") } catch ProviderError.notFound {}
        daemon.online = false
        do { _ = try await good.whoami(); XCTFail("no error") } catch ProviderError.transport {}
    }

    func testDaemonClientIssuesAnAppCredential() async throws {
        let daemon = FakeDaemon()
        let c = try await DaemonClient(base: loopback, token: nil, http: daemon).issueApp(name: "OverSire on mba")
        XCTAssertEqual(c.deviceId, "APP1")
        let body = try JSONSerialization.jsonObject(with: daemon.requests.last!.httpBody!) as! [String: String]
        XCTAssertEqual(body, ["name": "OverSire on mba", "kind": "app"])
    }

    // MARK: Machines

    func testMachinesFromAGroup() async throws {
        let g = try contract(Group.self, "group", "two-members")
        let daemon = FakeDaemon(machine: "mba", group: g)
        let keychain = MemoryKeychain()
        let m = Machines(local: DaemonClient(base: loopback, token: nil, http: daemon), keychain: keychain, http: daemon, deviceName: "OverSire on mba")
        await m.refresh()
        let links = await m.links()
        XCTAssertEqual(links, [
            MachineLink(machine: "mbp", base: URL(string: "http://100.97.81.23:7690")!, token: "osd1.APP1.secret", local: false),
            MachineLink(machine: "mba", base: loopback, token: nil, local: true),
        ])
        XCTAssertEqual(keychain.get("daemon.group.9f3c1a2b7d4e5f60"), "osd1.APP1.secret")
        // The credential is issued once.
        await m.refresh()
        XCTAssertEqual(daemon.issued, 1)
    }

    func testDialURLPrefersTheTailnetAddress() {
        func m(_ addrs: [String]) -> GroupMember {
            GroupMember(machine: "mbp.local", host: "mbp.local", addrs: addrs, port: 7690, roles: ["serve"], joinedAt: Date())
        }
        XCTAssertEqual(m(["fd7a:115c:a1e0::1", "100.97.81.23"]).dialURL, URL(string: "http://100.97.81.23:7690"))
        XCTAssertEqual(m(["fd7a:115c:a1e0::1"]).dialURL, URL(string: "http://[fd7a:115c:a1e0::1]:7690"))
        XCTAssertEqual(m([]).dialURL, URL(string: "http://mbp.local:7690"), "no address: the host name")
    }

    func testARosterChangeGivesNewLinks() async throws {
        var g = try contract(Group.self, "group", "two-members")
        let daemon = FakeDaemon(machine: "mba", group: g)
        let m = Machines(local: DaemonClient(base: loopback, token: nil, http: daemon), keychain: MemoryKeychain(), http: daemon)
        var changes = await m.changes().makeAsyncIterator()
        var seen: [[String]] = []
        seen.append(await changes.next()?.map(\.machine) ?? ["end"])
        await m.refresh()
        seen.append(await changes.next()?.map(\.machine) ?? ["end"])
        g.members.append(GroupMember(machine: "mini", host: "mini", addrs: [], port: 7690, roles: ["serve"], joinedAt: Date()))
        daemon.group = g
        await m.refresh()
        seen.append(await changes.next()?.map(\.machine) ?? ["end"])
        g.members.removeAll { $0.machine == "mbp" }
        daemon.group = g
        await m.refresh()
        seen.append(await changes.next()?.map(\.machine) ?? ["end"])
        XCTAssertEqual(seen, [[], ["mbp", "mba"], ["mbp", "mba", "mini"], ["mba", "mini"]])
    }

    func testAMachineWithoutAGroupHasOnlyItsLocalLink() async throws {
        let daemon = FakeDaemon(machine: "mba")
        let m = Machines(local: DaemonClient(base: loopback, token: nil, http: daemon), keychain: MemoryKeychain(), http: daemon)
        await m.refresh()
        let links = await m.links()
        XCTAssertEqual(links, [MachineLink(machine: "mba", base: loopback, token: nil, local: true)])
        XCTAssertEqual(daemon.issued, 0)
    }

    func testWithNoLocalDaemonTheFirstMemberThatAnswersGivesTheGroup() async throws {
        let g = try contract(Group.self, "group", "two-members")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString).json")
        let remote = FakeDaemon(machine: "mbp", group: g, token: "osd1.app")
        let keychain = MemoryKeychain()
        // The app joined as kind app (the settings page). The join keeps the group and the credential.
        let first = Machines(local: DaemonClient(base: loopback, token: nil, http: remote), keychain: keychain, http: remote, cache: cache)
        remote.online = true
        let join = JoinResult(group: g, credential: DeviceCredential(deviceId: "D1", token: "osd1.app"))
        await first.joined(join)
        // A new start with no local daemon: the cache gives the members.
        let offline = FakeDaemon()
        offline.online = false
        let m = Machines(local: DaemonClient(base: loopback, token: nil, http: offline), keychain: keychain, http: remote, cache: cache)
        await m.refresh()
        let links = await m.links()
        XCTAssertEqual(links.map(\.machine), ["mbp", "mba"])
        XCTAssertTrue(links.allSatisfy { $0.token == "osd1.app" && !$0.local })
        let info = await m.info
        XCTAssertNil(info)
        try? FileManager.default.removeItem(at: cache)
    }

    func testMachinesConfigDefaults() throws {
        let c = MachinesConfig()
        let local = MachineLink(machine: "mba", base: loopback, token: nil, local: true)
        let remote = MachineLink(machine: "mbp", base: URL(string: "http://mbp:7690")!, token: "t", local: false)
        let other = MachineLink(machine: "mini", base: URL(string: "http://mini:7690")!, token: "t", local: false)
        XCTAssertEqual(c.runtimeAccount(local, environments: ["mbp"]), "local")
        XCTAssertEqual(c.runtimeAccount(remote, environments: ["mbp"]), "mbp")
        XCTAssertNil(c.runtimeAccount(other, environments: ["mbp"]))
        var picked = c
        picked.runtimeAccounts["mini"] = "lab"
        XCTAssertEqual(picked.runtimeAccount(other, environments: []), "lab")
        let decoded = try JSONDecoder().decode(MachinesConfig.self, from: Data(#"{"muted":["mbp"]}"#.utf8))
        XCTAssertEqual(decoded, MachinesConfig(enabled: true, runtimeAccounts: [:], muted: ["mbp"]))
    }

    // MARK: DaemonQuestions

    private let mbp = AccountID(provider: "orca", id: "mbp")
    private let mbpLink = MachineLink(machine: "mbp", base: URL(string: "http://mbp:7690")!, token: "t", local: false)

    private func ref(_ handle: String, workspace: String = "wt-1") -> SessionRef {
        SessionRef(workspace: WorkspaceRef(account: mbp, id: workspace), id: handle)
    }

    private func channel(_ daemon: FakeDaemon, supervised: Set<String> = []) -> DaemonQuestions {
        DaemonQuestions(link: mbpLink, account: mbp, client: DaemonClient(base: mbpLink.base, token: "t", http: daemon),
                        supervised: { supervised }, pushes: DaemonQuestions.Pushes())
    }

    func testEachDaemonQuestionFixtureMaps() async throws {
        let names = ["form-hook", "form-screen-page", "permission-bash", "plan-approval", "turn", "waiting", "cli-not-answerable"]
        let qs = try names.map { try contract(DaemonQuestion.self, "daemon-question", $0) }
        let daemon = FakeDaemon(token: "t")
        daemon.questions = qs
        let sessions = Set(qs.compactMap(\.terminal)).map { ref($0) }
        let got = try await channel(daemon).openQuestions(in: sessions)
        // The turn question of s-4f8a2c1e and the CLI question have no terminal: the app does not know them.
        XCTAssertEqual(got.count, 5)
        for q in got {
            let src = qs.first { "daemon:mbp:" + $0.id.rawValue == q.id.rawValue }!
            XCTAssertEqual(q.session, ref(src.terminal!))
            XCTAssertEqual(q.origin, .session)
            XCTAssertEqual(q.round, 1)
            XCTAssertEqual(q.items, src.items)
            XCTAssertEqual(q.askedAt, src.askedAt)
            XCTAssertEqual(q.expiresAt, src.expiresAt)
            XCTAssertEqual(q.via.rawValue, src.via.rawValue)
            XCTAssertEqual(q.answerable, src.answerable)
        }
        let form = got.first { $0.id.rawValue == "daemon:mbp:form:toolu_01HJ8kq2Vx3mN7pR4sT6wY9z" }
        XCTAssertEqual(form?.via, .form)
        XCTAssertEqual(form?.items.map(\.id), ["q1", "q2"])
    }

    func testANotAnswerableQuestionShowsAsWaiting() throws {
        let q = try contract(DaemonQuestion.self, "daemon-question", "cli-not-answerable")
        let c = channel(FakeDaemon())
        let s = c.question(q, session: ref("term"))
        XCTAssertEqual(s.via, .waiting)
        XCTAssertFalse(s.answerable)
    }

    func testAnUnknownTerminalIsDropped() async throws {
        let daemon = FakeDaemon(token: "t")
        daemon.questions = [try contract(DaemonQuestion.self, "daemon-question", "form-hook")]
        let got = try await channel(daemon).openQuestions(in: [ref("term_other")])
        XCTAssertEqual(got, [])
    }

    func testATurnQuestionOfASupervisedTerminalIsDropped() async throws {
        var turn = try contract(DaemonQuestion.self, "daemon-question", "turn")
        turn.terminal = "term_worker"
        var form = try contract(DaemonQuestion.self, "daemon-question", "form-hook")
        form.terminal = "term_worker"
        let daemon = FakeDaemon(token: "t")
        daemon.questions = [turn, form]
        let got = try await channel(daemon, supervised: ["term_worker"]).openQuestions(in: [ref("term_worker")])
        XCTAssertEqual(got.map(\.via), [.form])
    }

    func testAnswerMapsEachResult() async throws {
        let dq = try contract(DaemonQuestion.self, "daemon-question", "form-hook")
        let daemon = FakeDaemon(token: "t")
        let c = channel(daemon)
        let q = c.question(dq, session: ref(dq.terminal!))
        let a = QuestionAnswer(question: q.id, items: [.init(id: "q1", choices: ["D1"]), .init(id: "q2", choices: ["Event log"])], note: "go")
        let id = dq.id.rawValue
        let cases: [(String, AnswerResult)] = [("sent", .sent), ("already-answered", .alreadyAnswered)]
        for (name, want) in cases {
            daemon.result(id, try contract(DaemonAnswerResult.self, "daemon-answer-result", name))
            let got = try await c.answer(q, a)
            XCTAssertEqual(got, want, name)
        }
        daemon.result(id, DaemonAnswerResult(result: .gone))
        let gone = try await c.answer(q, a)
        XCTAssertEqual(gone, .gone)
        daemon.result(id, try contract(DaemonAnswerResult.self, "daemon-answer-result", "form-changed"))
        do {
            _ = try await c.answer(q, a)
            XCTFail("no error")
        } catch ProviderError.vendor(let code, let message) {
            XCTAssertEqual(code, "form_changed")
            XCTAssertEqual(message, "The question in Orca changed. Answer it in Orca.")
        }
        let sent = daemon.answers.last!
        XCTAssertEqual(sent.id, id)
        XCTAssertEqual(sent.answer, RunnerAnswer(id: id, items: a.items, note: "go"))
        // A bad answer sends nothing.
        let before = daemon.answers.count
        do { _ = try await c.answer(q, QuestionAnswer(question: q.id, items: [])); XCTFail("no error") } catch is QuestionError {}
        XCTAssertEqual(daemon.answers.count, before)
    }

    func testAnswerGivenReadsTheDaemon() async throws {
        let dq = try contract(DaemonQuestion.self, "daemon-question", "turn")
        let daemon = FakeDaemon(token: "t")
        let c = channel(daemon)
        let q = c.question(dq, session: ref("term"))
        let none = try await c.answerGiven(q)
        XCTAssertNil(none)
        daemon.given(dq.id.rawValue, RunnerAnswer(id: dq.id.rawValue, items: [.init(id: "reply", other: "Only questions.")]))
        let given = try await c.answerGiven(q)
        XCTAssertEqual(given, QuestionAnswer(question: q.id, items: [.init(id: "reply", other: "Only questions.")]))
        XCTAssertTrue(daemon.calls.contains("GET /v1/questions/turn:s-4f8a2c1e:1792663320000/given"))
    }

    func testPushesWakeEachStream() async throws {
        let p = DaemonQuestions.Pushes()
        let c = DaemonQuestions(link: mbpLink, account: mbp, client: DaemonClient(base: mbpLink.base, token: nil, http: FakeDaemon()),
                                supervised: { [] }, pushes: p)
        let first = c.changes!
        let second = c.changes!
        p.push()
        let a = await take(1, from: first)
        let b = await take(1, from: second)
        XCTAssertEqual(a.count + b.count, 2)
    }

    // MARK: The board with two channels of one account

    func testTheBoardKeepsTheQuestionsOfTwoChannelsOfOneAccount() async throws {
        let orca = FakeQuestionChannel(account: "mbp")
        let dq = try contract(DaemonQuestion.self, "daemon-question", "form-hook")
        let daemon = FakeDaemon(token: "t")
        daemon.questions = [dq]
        let ask = SessionQuestion(id: "orca:mbp:m1", session: orca.session("term_ask"), origin: .session, items: [QuestionItem(id: "q1", text: "Go?", kind: .free)],
                                  via: .askReply, askedAt: Date(timeIntervalSince1970: 5))
        orca.ask(ask)
        let c = DaemonQuestions(link: mbpLink, account: orca.account, client: DaemonClient(base: mbpLink.base, token: "t", http: daemon),
                                supervised: { [] }, pushes: DaemonQuestions.Pushes())
        let sessions = [orca.session(dq.terminal!), orca.session("term_ask")]
        // The fake owns each id, so the daemon channel goes first. OrcaQuestions owns only its own ids.
        let board = QuestionBoard(channels: [c, orca], sessions: { sessions })
        await board.refresh()
        XCTAssertEqual(Set(board.entries.keys.map(\.rawValue)), ["orca:mbp:m1", "daemon:mbp:" + dq.id.rawValue])
        XCTAssertTrue(board.entries.values.allSatisfy { $0.state == .open })

        // The daemon goes offline: its question stays open, and the Orca ask too.
        daemon.online = false
        await board.refresh()
        XCTAssertTrue(board.entries.values.allSatisfy { $0.state == .open })

        // The daemon answers the form. The answer goes through the daemon.
        daemon.online = true
        let id = QuestionID(rawValue: "daemon:mbp:" + dq.id.rawValue)
        try await board.answer(id, QuestionAnswer(question: id, items: [.init(id: "q1", choices: ["D1"]), .init(id: "q2", choices: ["Event log"])]))
        XCTAssertEqual(daemon.answers.map(\.id), [dq.id.rawValue])
        XCTAssertEqual(orca.sent, [])
    }
}
