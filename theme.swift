import Cocoa

// Colors of the window pages. Each color has a dark and a light value, the same as the preview.
// Status colors follow Okabe-Ito. A status also always has a symbol or text.
enum Palette {
    static let bg = pair(0x15161A, 0xFFFFFF)
    static let side = pair(0x101114, 0xF3F4F6)
    static let panel = pair(0x1B1C21, 0xF8F9FA)
    static let raise = pair(0x23252B, 0xFFFFFF)
    static let line = pair(0x2E3037, 0xE2E4E8)
    static let fg = pair(0xE9EAEE, 0x16171A)
    static let mut = pair(0xA6AAB3, 0x4F545D)
    static let dim = pair(0x8D929C, 0x5E636C)
    static let sel = pair(0x2A2D36, 0xE3E7EE)
    static let acc = pair(0x5AAEE8, 0x0B6BB3)
    static let ok = pair(0x1FB386, 0x00855F)
    static let bad = pair(0xE2703A, 0xC2510A)
    static let run = pair(0x5AB8EC, 0x1D7FB8)
    static let warn = pair(0xE9A21A, 0xA86F00)
    static let intake = pair(0xB98AD6, 0x8A55AE)
    static let term = pair(0x0D0E11, 0x15171B)
    static let termFg = pair(0xC9CDD4, 0xD5D8DE)

    static func isDark(_ a: NSAppearance) -> Bool { a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private static func pair(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { a in hex(isDark(a) ? dark : light) }
    }

    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension Theme {
    var label: String { rawValue.capitalized }

    // nil follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}

// The state of a run, an agent or an item, as a symbol, a color and a word.
struct Tone {
    let symbol: String
    let color: NSColor
    let word: String

    static let ok = Tone(symbol: "checkmark.circle.fill", color: Palette.ok, word: "Passed")
    static let bad = Tone(symbol: "xmark.circle.fill", color: Palette.bad, word: "Failed")
    static let running = Tone(symbol: "circle.dashed", color: Palette.run, word: "Running")
    static let queued = Tone(symbol: "clock", color: Palette.dim, word: "Queued")
    static let waiting = Tone(symbol: "exclamationmark.bubble.fill", color: Palette.warn, word: "Needs input")
    static let working = Tone(symbol: "bolt.circle.fill", color: Palette.run, word: "Working")
    static let done = Tone(symbol: "checkmark.seal.fill", color: Palette.ok, word: "Done")
    static let idle = Tone(symbol: "moon.zzz", color: Palette.dim, word: "Idle")
    static let cancelled = Tone(symbol: "slash.circle", color: Palette.dim, word: "Cancelled")
    static let intake = Tone(symbol: "tray.and.arrow.down.fill", color: Palette.intake, word: "Intake")
    static let info = Tone(symbol: "info.circle.fill", color: Palette.acc, word: "Info")
    static let warning = Tone(symbol: "exclamationmark.triangle.fill", color: Palette.warn, word: "Warning")

    init(symbol: String, color: NSColor, word: String) {
        self.symbol = symbol; self.color = color; self.word = word
    }

    init(_ run: Run) { self.init(status: run.status, conclusion: run.conclusion) }
    init(_ job: RunJob) { self.init(status: job.status ?? "queued", conclusion: job.conclusion) }

    init(status: String, conclusion: String?) {
        switch status {
        case "in_progress": self = .running
        case "queued", "waiting", "pending", "requested": self = .queued
        default:
            switch conclusion ?? "" {
            case "success": self = .ok
            case "failure", "timed_out", "startup_failure": self = .bad
            case "cancelled": self = .cancelled
            case "skipped", "neutral": self = Tone(symbol: "minus.circle", color: Palette.dim, word: "Skipped")
            default: self = Tone(symbol: "questionmark.circle", color: Palette.dim, word: (conclusion ?? "Done").capitalized)
            }
        }
    }

    init(_ phase: ItemAgent.Phase) {
        switch phase {
        case .starting: self = Tone(symbol: "hourglass", color: Palette.run, word: "Starting")
        case .working: self = .working
        case .waiting: self = .waiting
        case .done: self = .done
        case .failed: self = Tone(symbol: "xmark.octagon.fill", color: Palette.bad, word: "Failed")
        }
    }
}
