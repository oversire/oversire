import AppKit
import OverSireCore

// The items that the user keeps at the top of each list (OVERSIRE-433). A Pin record of the store holds each one,
// so the favorites sync between the Macs. A favorite shows first, also when it is Done.
final class Favorites {
    static let changed = Notification.Name("FavoritesChanged")
    /// The id of the Favorites group in the item lists.
    static let groupId = "favorites"
    static let title = "Favorites"

    private let writes: StoreWrites
    private(set) var keys: Set<String>
    private var observer: NSObjectProtocol?

    init(writes: StoreWrites) {
        self.writes = writes
        keys = Self.load(writes)
        observer = NotificationCenter.default.addObserver(forName: StoreWrites.remoteChanged, object: writes, queue: .main) { [weak self] n in
            guard let self, n.userInfo?["collection"] as? String == Pin.collection else { return }
            let now = Self.load(self.writes)
            guard now != self.keys else { return }
            self.keys = now
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    static func id(_ key: String) -> String { "item:" + key.uppercased() }

    private static func load(_ writes: StoreWrites) -> Set<String> {
        Set(writes.load(Pin.self).compactMap { p in
            if case .item(let r) = p.subject { return r.key.uppercased() }
            return nil
        })
    }

    /// Uishots only: the favorites in memory, with no store write.
    func seed(_ keys: [String]) { self.keys = Set(keys.map { $0.uppercased() }) }

    func contains(_ key: String) -> Bool { keys.contains(key.uppercased()) }

    /// False when nothing changed.
    @discardableResult
    func set(_ ref: ItemRef, on: Bool, now: Date = Date()) -> Bool {
        let k = ref.key.uppercased()
        guard on != keys.contains(k) else { return false }
        if on {
            keys.insert(k)
            writes.put(Pin(id: Self.id(k), subject: .item(ref), at: now))
        } else {
            keys.remove(k)
            writes.delete(Pin.self, id: Self.id(k))
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
        return true
    }

    /// The favorites first, then the rest. Each part keeps its order.
    func first<T>(_ list: [T], key: (T) -> String) -> (favorites: [T], rest: [T]) {
        var f: [T] = [], r: [T] = []
        for x in list { if contains(key(x)) { f.append(x) } else { r.append(x) } }
        return (f, r)
    }

    /// The star of the Favorites group header.
    static func glyph(size: CGFloat = 12) -> NSView {
        Glyph("star.fill", color: Palette.warn, size: size, label: title)
    }
}

let FAVORITES = Favorites(writes: STORE_WRITES)

// The FAVORITES label over the favorites of a project in the menu bar list.
final class FavoritesLabel: NSView {
    init(w: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 22))
        let s = NSStackView(h: [Favorites.glyph(size: 10), NSTextField.text(Favorites.title.uppercased(), size: 10.5, weight: .semibold, color: Palette.dim)], spacing: 5)
        s.frame = NSRect(x: 12, y: 2, width: w - 24, height: 16)
        s.translatesAutoresizingMaskIntoConstraints = true
        addSubview(s)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Favorites.title)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The line between the favorites and the other items.
    static func end(w: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 9))
        let line = SeparatorLine(y: 4, w: w - 24)
        line.frame.origin.x = 12
        v.addSubview(line)
        return v
    }
}
