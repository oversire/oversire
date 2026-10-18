import XCTest
@testable import OverSireApp

final class SnapModelTests: XCTestCase {
    private func shot(_ marks: [SnapRect]) -> SnapShot {
        SnapShot(project: "OVERSIRE", kind: .area, app: "Safari", windowTitle: "Jobs", pixelSize: CGSize(width: 200, height: 100),
                 scale: 2, marks: marks.enumerated().map { SnapMark(rect: $1, note: "m\($0 + 1)") })
    }

    func testCropClipsAndRemovesMarks() {
        let s = shot([SnapRect(x: 10, y: 10, w: 20, h: 20),     // outside
                      SnapRect(x: 40, y: 30, w: 40, h: 20),     // half inside
                      SnapRect(x: 60, y: 40, w: 10, h: 10)])    // inside
        let (out, removed) = s.apply(crop: SnapRect(x: 50, y: 20, w: 100, h: 60))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(out.marks.map(\.note), ["m2", "m3"])
        XCTAssertEqual(out.marks[0].rect, SnapRect(x: 50, y: 30, w: 30, h: 20))
        XCTAssertTrue(out.isCropped)
        XCTAssertEqual(s.apply(crop: SnapRect(x: -10, y: -10, w: 500, h: 500)).0.crop, s.full, "the crop stays in the image")
    }

    func testMoveKeepsTheMarkInsideTheCrop() {
        var s = shot([SnapRect(x: 60, y: 40, w: 10, h: 10)]).apply(crop: SnapRect(x: 50, y: 20, w: 100, h: 60)).0
        s.move(mark: 0, by: CGVector(dx: -100, dy: 500))
        XCTAssertEqual(s.marks[0].rect, SnapRect(x: 50, y: 70, w: 10, h: 10))
        s.move(mark: 9, by: CGVector(dx: 1, dy: 1))
        XCTAssertEqual(s.marks.count, 1)
    }

    func testEditSnapshotGivesTheSameValueBack() {
        var s = shot([SnapRect(x: 60, y: 40, w: 10, h: 10)])
        let before = s.edit
        s = s.apply(crop: SnapRect(x: 100, y: 0, w: 100, h: 100)).0
        XCTAssertNotEqual(s.edit, before)
        s.edit = before
        XCTAssertEqual(s, shot([SnapRect(x: 60, y: 40, w: 10, h: 10)]).withId(s.id).withTime(s.takenAt))
    }

    func testRelativeCoordinates() {
        XCTAssertEqual(SnapRect(x: 50, y: 40, w: 10.4, h: 9.6).relative(to: SnapRect(x: 30, y: 20, w: 100, h: 50)),
                       SnapRect(x: 20, y: 20, w: 10, h: 10))
    }

    func testReorder() {
        var b = SnapBasket(project: "OVERSIRE", at: Date(timeIntervalSince1970: 0))
        b.shots = [shot([]), shot([]), shot([])]
        let ids = b.shots.map(\.id)
        b.reorder(0, to: 2)
        XCTAssertEqual(b.shots.map(\.id), [ids[1], ids[2], ids[0]])
        b.reorder(5, to: 0)
        XCTAssertEqual(b.shots.map(\.id), [ids[1], ids[2], ids[0]])
        XCTAssertTrue(b.id.hasSuffix("-oversire"), b.id)
    }

    func testOldConfigHasDefaultSnapSettings() throws {
        let old = try JSONDecoder().decode(CaptureConfig.self, from: Data(#"{"enabled":true,"keyCode":45}"#.utf8))
        XCTAssertEqual(old.snap, SnapConfig())
        XCTAssertEqual(old.snap.keyCode, 1)
        XCTAssertEqual(old.snap.basketKeyCode, 11)
        XCTAssertEqual(old.snap.modifiers, 0x1900)
        XCTAssertEqual(old.snap.keepDays, 30)
        XCTAssertEqual(old.snap.sendMode, .agent)
        let some = try JSONDecoder().decode(SnapConfig.self, from: Data(#"{"keepDays":7,"sendMode":"nope","lastProject":"SLING"}"#.utf8))
        XCTAssertEqual(some.keepDays, 7)
        XCTAssertEqual(some.sendMode, .agent)
        XCTAssertEqual(some.lastProject, "SLING")
    }
}

extension SnapShot {
    func withId(_ id: UUID) -> SnapShot { var s = self; s.id = id; return s }
    func withTime(_ d: Date) -> SnapShot { var s = self; s.takenAt = d; return s }
}
