import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OverSireApp

final class SnapRenderTests: XCTestCase {
    // 200 × 100 px. The top half is blue and the bottom half is gray.
    private static let fixture: Data = {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 50, width: 200, height: 50))   // y goes up in Core Graphics
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }()

    private struct Pixels {
        let w, h: Int
        let bytes: [UInt8]

        init(_ png: Data) {
            let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
            w = img.width
            h = img.height
            var b = [UInt8](repeating: 0, count: w * h * 4)
            let (cw, ch) = (w, h)
            b.withUnsafeMutableBytes { p in
                let ctx = CGContext(data: p.baseAddress, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: cw, height: ch))
            }
            bytes = b
        }

        // x and y from the top-left corner.
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
    }

    private func shot(crop: SnapRect? = nil, note: String = "", marks: [(SnapRect, String)] = []) -> SnapShot {
        SnapShot(project: "OVERSIRE", kind: .window, app: "Safari", windowTitle: "Jobs", pixelSize: CGSize(width: 200, height: 100),
                 scale: 2, crop: crop, note: note, marks: marks.map { SnapMark(rect: $0.0, note: $0.1) })
    }

    private func basket(_ shots: [SnapShot]) -> SnapBasket {
        var b = SnapBasket(project: "OVERSIRE")
        b.shots = shots
        return b
    }

    func testRenderGivesTheFilesAndSizes() throws {
        let s = shot(marks: [(SnapRect(x: 50, y: 40, w: 60, h: 30), "big"), (SnapRect(x: 150, y: 10, w: 10, h: 10), "small")])
        let files = try SnapRenderer().render(s, png: Self.fixture, index: 2)
        XCTAssertEqual(files.map(\.name), ["snap-2.png", "snap-2-clean.png", "snap-2-mark-2.png"])
        XCTAssertEqual(files.map(\.role), [.marked, .clean, .zoom(mark: 2)])
        let marked = Pixels(files[0].data), clean = Pixels(files[1].data), zoom = Pixels(files[2].data)
        XCTAssertEqual([marked.w, marked.h, clean.w, clean.h], [200, 100, 200, 100])
        // The zoom is the mark plus 30 px, cut at the image edge, scaled 2x: x 120…190, y 0…50.
        XCTAssertEqual([zoom.w, zoom.h], [140, 100])

        let (r, g, b) = marked.rgb(50, 55)   // on the left border of mark 1
        XCTAssertGreaterThan(r, 180)
        XCTAssertLessThan(abs(g - 0x5E), 40)
        XCTAssertLessThan(b, 60)
        XCTAssertEqual(clean.rgb(50, 55).0, 128, accuracy: 2)
        XCTAssertEqual(clean.rgb(100, 10).2, 255, "the top is blue, thus the image is not upside down")
        XCTAssertEqual(clean.rgb(100, 90).2, 128, accuracy: 2)
    }

    func testCropCutsThePixels() throws {
        let s = shot(crop: SnapRect(x: 30, y: 20, w: 100, h: 60))
        let files = try SnapRenderer().render(s, png: Self.fixture, index: 1)
        let p = Pixels(files[1].data)
        XCTAssertEqual([p.w, p.h], [100, 60])
        XCTAssertEqual(p.rgb(0, 0).2, 255)
        XCTAssertEqual(p.rgb(0, 40).2, 128, accuracy: 2)
    }

    func testBadImageThrows() {
        XCTAssertThrowsError(try SnapRenderer().render(shot(), png: Data("no".utf8), index: 1)) {
            XCTAssertEqual($0 as? SnapRenderError, .badImage)
        }
    }

    func testMarkdownForTwoShots() {
        let one = shot(note: "The jobs list shows the wrong count.",
                       marks: [(SnapRect(x: 50, y: 40, w: 60, h: 30), "This says 3, there are 4."),
                               (SnapRect(x: 150, y: 10, w: 10, h: 10), "Icon is cut\noff."),
                               (SnapRect(x: 0, y: 50, w: 50, h: 40), "")])
        var two = shot()
        two.app = "Terminal"
        two.windowTitle = "zsh"
        let b = basket([one, two])
        XCTAssertEqual(SnapTicket.markdown(b), """
            Snap basket · 2 shots. Marks are boxes in pixels of the attached PNG, from the top-left corner.

            ### Shot 1 · snap-1.png

            200 × 100 px · Safari · "Jobs"

            Also attached: snap-1-clean.png (no marks), snap-1-mark-2.png (zoom of mark 2)

            The jobs list shows the wrong count.

            - [1] x 50, y 40, w 60, h 30 px: This says 3, there are 4.
            - [2] x 150, y 10, w 10, h 10 px: Icon is cut off. · zoom: snap-1-mark-2.png
            - [3] x 0, y 50, w 50, h 40 px: (no note)

            ### Shot 2 · snap-2.png

            200 × 100 px · Terminal · "zsh"

            Also attached: snap-2-clean.png (no marks)

            (no shot note)

            """)
        XCTAssertEqual(SnapTicket.title(b), "Snap basket · 2 shots · The jobs list shows the wrong count.")
        XCTAssertEqual(SnapTicket.title(basket([two])), "Snap basket · 1 shot · zsh")
    }

    func testMarkdownUsesCropCoordinates() {
        let s = shot(marks: [(SnapRect(x: 50, y: 40, w: 10, h: 10), "x")]).apply(crop: SnapRect(x: 30, y: 20, w: 100, h: 60)).0
        let md = SnapTicket.markdown(basket([s]))
        XCTAssertTrue(md.contains("100 × 60 px"))
        XCTAssertTrue(md.contains("- [1] x 20, y 20, w 10, h 10 px: x · zoom: snap-1-mark-1.png"), md)
    }

    func testPromptFillsThePlaceholders() {
        let p = SnapTicket.prompt(template: SnapTicket.defaultPrompt,
                                  values: ["key": "OVERSIRE-200", "item": "w-1", "intake": "i-1", "count": "2",
                                           "workspace": "ocral", "project": "oversire", "dir": "/tmp/s"])
        XCTAssertTrue(p.hasPrefix("Intake item OVERSIRE-200 holds a basket of screenshots (2 shots)."))
        XCTAssertTrue(p.contains("plane-cli wi attachment download w-1 -w ocral -p oversire --dir /tmp/s"))
        XCTAssertTrue(p.contains("plane-cli intake update i-1 -w ocral -p oversire"))
        XCTAssertFalse(p.contains("{"))
        XCTAssertEqual(SnapTicket.prompt(template: "{key} {other}", values: ["key": "A"]), "A {other}")
    }
}
