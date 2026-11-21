import OverSireCore
import XCTest
@testable import OverSireApp

final class VendorVersionsTests: XCTestCase {
    typealias Runner = VendorCallsTests.FakeRunner

    final class Stamps: @unchecked Sendable {
        private let lock = NSLock()
        private var mtime = Date(timeIntervalSince1970: 1_000)
        func touch() { lock.withLock { mtime += 60 } }
        func stamp(_ path: String) -> VendorVersions.Stamp? {
            lock.withLock { VendorVersions.Stamp(path: path, mtime: mtime, size: 100, inode: 7) }
        }
    }

    let plane = VendorCLI(binary: "plane-cli", tokenEnv: "PLANE_API_KEY", managedEnv: "PLANE_MANAGED_BY", minVersion: "0.2.2")
    let path = "/usr/local/bin/plane-cli"

    func runner(_ stdout: String = "plane-cli version 0.2.2\n", status: Int32 = 0, timedOut: Bool = false) -> Runner {
        let r = Runner()
        r.exit = VendorExit(status: status, stdout: Data(stdout.utf8), stderr: Data(), truncated: false, timedOut: timedOut, ms: 4)
        return r
    }

    func testProbesOncePerStamp() async throws {
        let r = runner(), stamps = Stamps()
        let v = VendorVersions(runner: r, stamp: { stamps.stamp($0) })
        let a = await v.version(of: path, cli: plane)
        let b = await v.version(of: path, cli: plane)
        XCTAssertEqual(a, VendorVersion("0.2.2"))
        XCTAssertEqual(b, a)
        XCTAssertEqual(r.launches.count, 1)
        let l = try XCTUnwrap(r.launches.first)
        XCTAssertEqual(l.exe, path)
        XCTAssertEqual(l.args, ["--version"])
        XCTAssertNil(l.environment["PLANE_API_KEY"], "the probe gets no token")
        XCTAssertEqual(l.environment["PLANE_MANAGED_BY"], "OverSire")
        XCTAssertEqual(l.timeout, .seconds(5))
        XCTAssertEqual(l.maxStdout, 4096)
        XCTAssertNil(l.cwd)
        XCTAssertEqual(l.logWords, ["plane-cli", "--version"])
    }

    func testNewStampProbesAgain() async {
        let r = runner(), stamps = Stamps()
        let v = VendorVersions(runner: r, stamp: { stamps.stamp($0) })
        _ = await v.version(of: path, cli: plane)
        stamps.touch()
        _ = await v.version(of: path, cli: plane)
        XCTAssertEqual(r.launches.count, 2)
    }

    func testConcurrentCallsShareOneProbe() async {
        let r = runner(), stamps = Stamps()
        r.delay = 100_000_000
        let v = VendorVersions(runner: r, stamp: { stamps.stamp($0) })
        let cli = plane, path = path
        let got = await withTaskGroup(of: VendorVersion?.self) { g in
            for _ in 0..<5 { g.addTask { await v.version(of: path, cli: cli) } }
            var all: [VendorVersion?] = []
            for await x in g { all.append(x) }
            return all
        }
        XCTAssertEqual(got, Array(repeating: VendorVersion("0.2.2"), count: 5))
        XCTAssertEqual(r.launches.count, 1)
    }

    func testFailedProbeIsNilAndCached() async {
        let r = runner("error\n", status: 1), stamps = Stamps()
        let v = VendorVersions(runner: r, stamp: { stamps.stamp($0) })
        let a = await v.version(of: path, cli: plane)
        let b = await v.version(of: path, cli: plane)
        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertEqual(r.launches.count, 1)
    }

    func testTimeoutIsNil() async {
        let r = runner("plane-cli version 0.2.2\n", timedOut: true), stamps = Stamps()
        let v = VendorVersions(runner: r, stamp: { stamps.stamp($0) })
        let a = await v.version(of: path, cli: plane)
        XCTAssertNil(a)
        let err = Runner()
        err.error = CocoaError(.fileNoSuchFile)
        let e = await VendorVersions(runner: err, stamp: { stamps.stamp($0) }).version(of: path, cli: plane)
        XCTAssertNil(e, "a start error gives nil")
    }

    func testStampFollowsLinks() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("vendor-versions-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a-0.2.1"), b = dir.appendingPathComponent("b-0.2.2"), link = dir.appendingPathComponent("plane-cli")
        try Data("#!/bin/sh\necho 0.2.1\n".utf8).write(to: a)
        try Data("#!/bin/sh\necho 0.2.2 new\n".utf8).write(to: b)
        try fm.createSymbolicLink(at: link, withDestinationURL: a)
        let s1 = try XCTUnwrap(VendorVersions.stamp(link.path))
        XCTAssertTrue(s1.path.hasSuffix("/a-0.2.1"), s1.path)
        XCTAssertEqual(s1.size, 21)
        XCTAssertEqual(VendorVersions.stamp(link.path), s1, "the same file gives the same stamp")
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: b)
        let s2 = try XCTUnwrap(VendorVersions.stamp(link.path))
        XCTAssertTrue(s2.path.hasSuffix("/b-0.2.2"), s2.path)
        XCTAssertNotEqual(s1, s2)
        XCTAssertNil(VendorVersions.stamp(dir.appendingPathComponent("nope").path))
    }
}
