import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One file for the ticket.
struct SnapFile: Hashable {
    enum Role: Hashable { case marked, clean, zoom(mark: Int) }   // mark: 1-based

    var name: String
    var data: Data
    var role: Role
}

enum SnapRenderError: Error, Equatable { case badImage, encode }

/// Draws the marks and the crop onto the original pixels. Core Graphics and ImageIO only.
struct SnapRenderer {
    static let zoomBelow = 0.05      // a mark smaller than this part of the crop gets a zoom file
    static let zoomMargin = 30.0     // px around the mark
    static let vermillion = CGColor(srgbRed: 0xD5 / 255.0, green: 0x5E / 255.0, blue: 0, alpha: 1)

    /// snap-N.png, snap-N-clean.png, and snap-N-mark-M.png for each small mark. `index` is 1-based.
    func render(_ shot: SnapShot, png: Data, index n: Int) throws -> [SnapFile] {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw SnapRenderError.badImage }
        let crop = shot.crop.intersection(SnapRect(x: 0, y: 0, w: Double(image.width), h: Double(image.height)))
            ?? SnapRect(x: 0, y: 0, w: Double(image.width), h: Double(image.height))
        var out = [SnapFile(name: "snap-\(n).png", data: try draw(image, crop, marks: shot.marks), role: .marked),
                   SnapFile(name: "snap-\(n)-clean.png", data: try draw(image, crop, marks: []), role: .clean)]
        for m in Self.zoomed(shot) {
            out.append(SnapFile(name: "snap-\(n)-mark-\(m).png", data: try zoom(image, shot.marks[m - 1].rect, in: crop), role: .zoom(mark: m)))
        }
        return out
    }

    /// The 1-based numbers of the marks that get a zoom file.
    static func zoomed(_ shot: SnapShot) -> [Int] {
        let area = shot.crop.area
        return shot.marks.indices.filter { area > 0 && shot.marks[$0].rect.area / area < zoomBelow }.map { $0 + 1 }
    }

    // Line and disc sizes grow with the image: 1 on an 800 px image, 2 on a Retina window.
    static func unit(_ crop: SnapRect) -> Double { max(1, max(crop.w, crop.h) / 800) }

    private func draw(_ image: CGImage, _ crop: SnapRect, marks: [SnapMark]) throws -> Data {
        let w = Int(crop.w.rounded()), h = Int(crop.h.rounded())
        guard let ctx = Self.context(w, h) else { throw SnapRenderError.encode }
        // Flip, so that y goes down as in the PNG.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        Self.drawImage(image, in: ctx, origin: CGPoint(x: -crop.x, y: -crop.y))
        let k = Self.unit(crop)
        for (i, m) in marks.enumerated() {
            let r = CGRect(x: m.rect.x - crop.x, y: m.rect.y - crop.y, width: m.rect.w, height: m.rect.h)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(4 * k)
            ctx.stroke(r)
            ctx.setStrokeColor(Self.vermillion)
            ctx.setLineWidth(2 * k)
            ctx.stroke(r)
            // The disc sits above the top-left corner. At the top edge it goes inside the mark.
            let above = r.minY - 20 * k >= 0
            let c = CGPoint(x: r.minX + 9 * k, y: above ? r.minY - 11 * k : r.minY + 11 * k)
            let disc = CGRect(x: c.x - 9 * k, y: c.y - 9 * k, width: 18 * k, height: 18 * k)
            ctx.setFillColor(Self.vermillion)
            ctx.fillEllipse(in: disc)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(1.5 * k)
            ctx.strokeEllipse(in: disc)
            Self.drawNumber(i + 1, at: c, size: 11 * k, in: ctx)
        }
        return try Self.png(ctx)
    }

    private func zoom(_ image: CGImage, _ mark: SnapRect, in crop: SnapRect) throws -> Data {
        let m = Self.zoomMargin
        let area = SnapRect(x: mark.x - m, y: mark.y - m, w: mark.w + 2 * m, h: mark.h + 2 * m).intersection(crop) ?? mark
        let w = Int((area.w * 2).rounded()), h = Int((area.h * 2).rounded())
        guard let ctx = Self.context(w, h) else { throw SnapRenderError.encode }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 2, y: -2)
        ctx.interpolationQuality = .high
        Self.drawImage(image, in: ctx, origin: CGPoint(x: -area.x, y: -area.y))
        ctx.setStrokeColor(Self.vermillion)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: mark.x - area.x, y: mark.y - area.y, width: mark.w, height: mark.h))
        return try Self.png(ctx)
    }

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // The context is flipped, so the image is drawn flipped back around its own middle.
    private static func drawImage(_ image: CGImage, in ctx: CGContext, origin: CGPoint) {
        let r = CGRect(origin: origin, size: CGSize(width: image.width, height: image.height))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: r.minY + r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: r)
        ctx.restoreGState()
    }

    private static func drawNumber(_ n: Int, at c: CGPoint, size: Double, in ctx: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, String(n) as CFString, attrs))
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: c.x - b.midX, y: c.y + b.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func png(_ ctx: CGContext) throws -> Data {
        guard let img = ctx.makeImage() else { throw SnapRenderError.encode }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw SnapRenderError.encode }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw SnapRenderError.encode }
        return out as Data
    }
}

/// The ticket text and the agent prompt of a basket.
enum SnapTicket {
    static let defaultPrompt = """
        Intake item {key} holds a basket of screenshots ({count} shots). They are one request.
        Download them: plane-cli wi attachment download {item} -w {workspace} -p {project} --dir {dir}
        Read the description. Each mark is a numbered box on snap-N.png, with its pixel box in the text.
        Read the code in this checkout to find the cause and the files. Then write a clear title and description into {key}: \
        plane-cli intake update {intake} -w {workspace} -p {project} --name "…" --description-md @file. \
        Keep each file name and mark number next to its note. Ask me if a shot is not clear.
        """

    static func title(_ b: SnapBasket) -> String {
        let n = b.shots.count
        let about = b.shots.lazy.map(\.note).compactMap { note -> String? in
            let line = note.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            return line.isEmpty ? nil : line
        }.first ?? b.shots.first.map { $0.windowTitle.isEmpty ? $0.app : $0.windowTitle } ?? b.project
        let short = about.count > 60 ? String(about.prefix(59)) + "…" : about
        return "Snap basket · \(n) shot\(n == 1 ? "" : "s") · \(short)"
    }

    /// One section for each shot. Blocks have blank lines between them, because one newline joins two lines.
    static func markdown(_ b: SnapBasket) -> String {
        let n = b.shots.count
        var blocks = ["Snap basket · \(n) shot\(n == 1 ? "" : "s"). Marks are boxes in pixels of the attached PNG, from the top-left corner."]
        for (i, s) in b.shots.enumerated() {
            let k = i + 1, c = s.crop, zoom = SnapRenderer.zoomed(s)
            blocks.append("### Shot \(k) · snap-\(k).png")
            blocks.append("\(Int(c.w.rounded())) × \(Int(c.h.rounded())) px · \(s.app) · \"\(s.windowTitle)\"")
            let extra = ["snap-\(k)-clean.png (no marks)"] + zoom.map { "snap-\(k)-mark-\($0).png (zoom of mark \($0))" }
            blocks.append("Also attached: " + extra.joined(separator: ", "))
            let note = s.note.trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.append(note.isEmpty ? "(no shot note)" : note)
            if !s.marks.isEmpty {
                blocks.append(s.marks.enumerated().map { j, m in
                    let r = m.rect.relative(to: c)
                    let text = m.note.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                    let z = zoom.contains(j + 1) ? " · zoom: snap-\(k)-mark-\(j + 1).png" : ""
                    return "- [\(j + 1)] x \(Int(r.x)), y \(Int(r.y)), w \(Int(r.w)), h \(Int(r.h)) px: \(text.isEmpty ? "(no note)" : text)\(z)"
                }.joined(separator: "\n"))
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Fills the placeholders. A placeholder with no value stays as it is.
    static func prompt(template: String, values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}
