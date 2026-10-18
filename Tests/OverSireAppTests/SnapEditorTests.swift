import XCTest
@testable import OverSireApp

final class SnapEditorTests: XCTestCase {
    private func shot(project: String = "") -> SnapShot {
        SnapShot(project: project, kind: .window, app: "Safari", windowTitle: "Jobs", pixelSize: CGSize(width: 400, height: 200), scale: 2)
    }

    func testProjectAndReason() {
        XCTAssertEqual(SnapEditorModel(shot: shot(project: "SLING"), basketProject: nil, basketCount: 0, lastProject: "X").reason, .windowTitle)
        let last = SnapEditorModel(shot: shot(), basketProject: nil, basketCount: 0, lastProject: "X")
        XCTAssertEqual([last.shot.project, last.reason.label], ["X", "last used"])
        let b = SnapEditorModel(shot: shot(project: "SLING"), basketProject: "OVERSIRE", basketCount: 2, lastProject: nil)
        XCTAssertEqual(b.shot.project, "OVERSIRE")
        XCTAssertEqual(b.reason.label, "this basket · window looks like SLING")
    }

    func testUndoCoversMarksAndCrop() {
        var m = SnapEditorModel(shot: shot(), basketProject: "A", basketCount: 0, lastProject: nil)
        m.addMark(SnapRect(x: 10, y: 10, w: 20, h: 20))
        m.addMark(SnapRect(x: 300, y: 150, w: 20, h: 20))
        m.startCrop()
        m.crop = SnapRect(x: 0, y: 0, w: 200, h: 100)
        XCTAssertEqual(m.applyCrop(), 1)
        XCTAssertEqual(m.shot.marks.count, 1)
        m.undo()
        XCTAssertEqual(m.shot.marks.count, 2)
        XCTAssertFalse(m.shot.isCropped)
        m.redo()
        XCTAssertTrue(m.shot.isCropped)
        m.undo(); m.undo(); m.undo()
        XCTAssertTrue(m.shot.marks.isEmpty)
        XCTAssertFalse(m.canUndo)
        XCTAssertTrue(m.canRedo)
        m.addMark(SnapRect(x: 0, y: 0, w: 5, h: 5))
        XCTAssertFalse(m.canRedo, "a new change clears redo")
    }

    func testChangeWithNoEffectIsNotKept() {
        var m = SnapEditorModel(shot: shot(), basketProject: "A", basketCount: 0, lastProject: nil)
        m.addMark(SnapRect(x: 0, y: 0, w: 20, h: 20))
        m.nudge(0, by: CGVector(dx: -5, dy: 0))   // at the edge already
        m.undo()
        XCTAssertTrue(m.shot.marks.isEmpty)
    }

    func testMarkStaysInsideTheCrop() {
        var m = SnapEditorModel(shot: shot(), basketProject: "A", basketCount: 0, lastProject: nil)
        m.addMark(SnapRect(x: 390, y: 190, w: 40, h: 40))
        XCTAssertEqual(m.shot.marks[0].rect, SnapRect(x: 360, y: 160, w: 40, h: 40))
        m.addMark(SnapRect(x: 0, y: 0, w: 900, h: 50))
        XCTAssertEqual(m.shot.marks[1].rect.w, 400)
    }

    func testEscapeOrder() {
        var m = SnapEditorModel(shot: shot(), basketProject: "A", basketCount: 1, lastProject: nil)
        m.addMark(SnapRect(x: 0, y: 0, w: 20, h: 20))
        m.startCrop()
        m.pick("B")
        XCTAssertEqual(m.escape(inField: true), .cancelCrop)
        XCTAssertEqual(m.escape(inField: true), .cancelMismatch)
        XCTAssertEqual(m.escape(inField: true), .leaveField)
        m.selected = 0
        XCTAssertEqual(m.escape(inField: false), .clearSelection)
        XCTAssertEqual(m.escape(inField: false), .askDiscard)
        XCTAssertEqual(m.escape(inField: false), .cancelConfirm)
        m.deleteMark(0)
        XCTAssertEqual(m.escape(inField: false), .discard, "a blank shot goes at once")
    }

    func testMismatchBlocksAdd() {
        var m = SnapEditorModel(shot: shot(), basketProject: "A", basketCount: 2, lastProject: nil)
        XCTAssertEqual(m.addBlock, .empty)
        m.shot.note = "Wrong count"
        XCTAssertNil(m.addBlock)
        XCTAssertFalse(m.pick("B"))
        XCTAssertEqual(m.addBlock, .mismatch)
        XCTAssertEqual(m.shot.project, "A")
        m.resolveMismatch(newBasket: true)
        XCTAssertEqual([m.shot.project, m.reason.label], ["B", "new basket"])
        XCTAssertNil(m.addBlock)
        XCTAssertTrue(m.pick("a"), "case does not matter")
    }

    func testFinishAppliesAnOpenCrop() {
        var m = SnapEditorModel(shot: shot(), basketProject: "A", basketCount: 0, lastProject: nil)
        m.startCrop()
        m.crop = SnapRect(x: 10, y: 10, w: 100, h: 50)
        XCTAssertEqual(m.finish().crop, SnapRect(x: 10, y: 10, w: 100, h: 50))
    }

    func testProjectFilter() {
        let all = [SnapProjectChoice(key: "OVERSIRE", title: "OverSire"), SnapProjectChoice(key: "SLING", title: "Sling Platform"),
                   SnapProjectChoice(key: "FRITZ", title: "Ops for Sling")]
        XCTAssertEqual(SnapProjectChoice.filter(all, "sling").map(\.key), ["SLING", "FRITZ"])
        XCTAssertEqual(SnapProjectChoice.filter(all, "plat sl").map(\.key), ["SLING"])
        XCTAssertEqual(SnapProjectChoice.filter(all, "").count, 3)
    }

    func testCornerResizeKeepsTheOppositeCorner() {
        let r = SnapRect(x: 10, y: 10, w: 50, h: 50)
        let b = SnapRect(x: 0, y: 0, w: 100, h: 100)
        XCTAssertEqual(SnapCanvasView.resize(r, corner: 2, to: CGPoint(x: 80, y: 90), in: b), SnapRect(x: 10, y: 10, w: 70, h: 80))
        XCTAssertEqual(SnapCanvasView.resize(r, corner: 0, to: CGPoint(x: -5, y: 70), in: b), SnapRect(x: 0, y: 60, w: 60, h: 10))
    }

    func testPanelPlacement() {
        let v = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(ShotEditorPanel.place(NSSize(width: 600, height: 400), near: CGRect(x: 100, y: 300, width: 300, height: 200), in: v).minX, 416)
        XCTAssertEqual(ShotEditorPanel.place(NSSize(width: 600, height: 400), near: CGRect(x: 1000, y: 300, width: 300, height: 200), in: v).maxX, 984)
    }
}
