import XCTest
import OverSireCore
@testable import OverSireApp

final class NetworkPathTests: XCTestCase {
    private let cloud = URLRequest(url: URL(string: "https://hub.oversire.dev/v1/events")!)
    private let loopback = URLRequest(url: URL(string: "http://127.0.0.1:7690/v1/whoami")!)

    func testOfflineErrorsAreQuietOnlyWhileThePathIsDown() {
        let p = NetworkPath()
        let dns = URLError(.cannotFindHost)
        XCTAssertFalse(p.quiet(cloud, dns), "online: a DNS error is a fault")
        p.update(satisfied: false)
        XCTAssertNotNil(p.offlineSince)
        XCTAssertFalse(p.isOnline)
        XCTAssertTrue(p.quiet(cloud, dns))
        XCTAssertTrue(p.quiet(cloud, URLError(.notConnectedToInternet)))
        XCTAssertFalse(p.quiet(cloud, URLError(.badServerResponse)), "not a path error")
        p.update(satisfied: true)
        XCTAssertNil(p.offlineSince)
        XCTAssertFalse(p.quiet(cloud, dns))
    }

    func testACancelIsAlwaysQuiet() {
        let p = NetworkPath()
        XCTAssertTrue(p.quiet(cloud, URLError(.cancelled)))
        XCTAssertTrue(p.quiet(cloud, CancellationError()))
    }

    func testARefusedLoopbackCallIsQuietOnAMacWithNoDaemon() {
        let p = NetworkPath()
        let refused = URLError(.cannotConnectToHost)
        XCTAssertFalse(p.quiet(loopback, refused), "the first refusal is a warning")
        p.localAbsent = true
        XCTAssertTrue(p.quiet(loopback, refused))
        XCTAssertFalse(p.quiet(URLRequest(url: URL(string: "http://100.97.81.23:7690/v1/whoami")!), refused), "another machine")
    }

    func testTheWakeWaitHoldsThePolls() {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let p = NetworkPath(now: { now })
        p.woke()
        XCTAssertFalse(p.isOnline)
        now += NetworkPath.wakeWait
        XCTAssertTrue(p.isOnline)
        p.woke()
        p.update(satisfied: true)
        XCTAssertTrue(p.isOnline, "a path update ends the wait")
    }

    func testTheOfflineText() {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 11, 5, 19, 38)
        XCTAssertEqual(NetworkPath.offlineText(Calendar.current.date(from: c)!), "Offline since 19:38")
    }

    func testAnHTMLErrorPageGivesItsTitle() {
        let html = Data("<!DOCTYPE html>\n<html><head><title>Worker threw exception | hub.oversire.dev | Cloudflare</title></head><body>…</body></html>".utf8)
        XCTAssertEqual(IOLog.bodyText(html), "(error page: Worker threw exception | hub.oversire.dev | Cloudflare)")
        XCTAssertEqual(IOLog.bodyText(Data("<html><body>x</body></html>".utf8)), "(error page)")
        XCTAssertEqual(IOLog.bodyText(Data(#"{"error":"nope"}"#.utf8)), #"{"error":"nope"}"#)
    }

    func testAQuietFailureIsVerboseAndTheLogDropsIt() throws {
        let l = IOLogTests.Lines()
        IOLog(sink: l).request(cloud, status: nil, ms: 3, error: "The Internet connection appears to be offline.", quiet: true)
        let e = try XCTUnwrap(l.all.first)
        XCTAssertEqual(e.level, .warn)
        XCTAssertEqual(e.verbose, true)

        let dir = NSTemporaryDirectory() + "oversire-logs-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = LogStore(dir: dir, problems: ProblemTracker(path: nil))
        s.write(e)
        XCTAssertTrue(s.entries.isEmpty, "Normal detail keeps no quiet failure")
    }
}
