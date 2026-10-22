import XCTest
import OverSireCore
import OverSireSync
@testable import OverSireApp

final class StoreHomeTests: XCTestCase {
    let cloud = CloudLink(base: URL(string: "https://hub.test")!, token: "tok", device: "D1")
    let mba = MachineLink(machine: "mba", base: DaemonClient.loopback, token: nil, local: true)
    let mbp = MachineLink(machine: "mbp", base: URL(string: "http://mbp.tail:7690")!, token: "osd1.APP1.secret", local: false)

    func group(home: String, cloud: Group.Cloud? = nil) -> Group {
        let at = Date(timeIntervalSince1970: 0)
        return Group(id: "g1", name: "My machines", home: MachineName(rawValue: home), version: 1,
                     members: ["mba", "mbp"].map { GroupMember(machine: MachineName(rawValue: $0), host: "\($0).tail", addrs: [], port: 7690, roles: ["serve"], joinedAt: at) },
                     devices: [], cloud: cloud)
    }

    func testTable() {
        let rows: [(String, Group?, CloudLink?, [MachineLink], StoreHome)] = [
            ("paired cloud, no group", nil, cloud, [], .cloud(cloud)),
            ("paired cloud wins over a member", group(home: "mbp"), cloud, [mba, mbp], .cloud(cloud)),
            ("group with cloud, this Mac not paired", group(home: "mbp", cloud: .init(hub: "https://hub.test", account: "a")), nil, [mba, mbp], .local),
            ("remote home", group(home: "mbp"), nil, [mba, mbp], .member(mbp)),
            ("this Mac is home: loopback", group(home: "mba"), nil, [mba, mbp], .member(mba)),
            ("home offline", group(home: "mbp"), nil, [mba], .local),
            ("no group", nil, nil, [mba], .local),
        ]
        for (name, g, c, links, want) in rows {
            XCTAssertEqual(storeHome(group: g, cloud: c, links: links), want, name)
        }
    }

    func testReplicas() {
        XCTAssertEqual(StoreHome.cloud(cloud).replica(http: URLSessionTransport(), group: nil)?.id, SyncedStore.cloudReplica)
        XCTAssertEqual(StoreHome.member(mbp).replica(http: URLSessionTransport(), group: "g1")?.id, "member:g1/mbp")
        XCTAssertNil(StoreHome.local.replica(http: URLSessionTransport(), group: "g1"))
        XCTAssertEqual(StoreHome.cloud(cloud).identity, "D1")
        XCTAssertNil(StoreHome.local.identity)
    }
}
