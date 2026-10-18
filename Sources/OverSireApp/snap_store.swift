import Foundation

/// The baskets on disk. One folder for each basket: basket.json, plus shot-<id>.json and shot-<id>.png
/// (the original) for each shot. The rendered files go to out/. Use it on the main thread.
final class SnapStore {
    static let changed = Notification.Name("SnapStoreChanged")
    static let defaultDir = URL(fileURLWithPath: CONFIG_DIR).appendingPathComponent("captures")

    // basket.json holds the shot order. Each shot has its own file.
    private struct BasketFile: Codable {
        var id: String
        var project: String
        var state: SnapBasket.State
        var createdAt: Date
        var order: [UUID]
    }

    let dir: URL
    private(set) var baskets: [SnapBasket] = []   // newest first
    private let fm = FileManager.default

    init(dir: URL = SnapStore.defaultDir) {
        self.dir = dir
        load()
    }

    var openBaskets: [SnapBasket] { baskets.filter(\.isOpen) }

    func basket(_ id: String) -> SnapBasket? { baskets.first { $0.id == id } }

    /// The open basket of the project, or a new empty one. A new basket is saved with its first shot.
    func open(for project: String) -> SnapBasket {
        if let b = openBaskets.first(where: { $0.project.caseInsensitiveCompare(project) == .orderedSame }) { return b }
        var b = SnapBasket(project: project)
        let base = b.id
        var n = 2
        while basket(b.id) != nil || fm.fileExists(atPath: folder(b.id).path) { b.id = "\(base)-\(n)"; n += 1 }
        return b
    }

    /// Adds the shot to the open basket of its project.
    @discardableResult
    func add(_ shot: SnapShot, png: Data) throws -> SnapBasket {
        var b = open(for: shot.project)
        try fm.createDirectory(at: folder(b.id), withIntermediateDirectories: true)
        try png.write(to: pngURL(shot.id, in: b.id), options: .atomic)
        b.shots.append(shot)
        try save(b)
        return b
    }

    /// Writes the basket and each of its shots.
    func update(_ b: SnapBasket) throws { try save(b) }

    func remove(shot id: UUID) throws {
        guard var b = baskets.first(where: { $0.shots.contains { $0.id == id } }) else { return }
        b.shots.removeAll { $0.id == id }
        try? fm.removeItem(at: pngURL(id, in: b.id))
        try? fm.removeItem(at: shotURL(id, in: b.id))
        if b.shots.isEmpty && b.isOpen { try discard(basket: b.id) } else { try save(b) }
    }

    /// Removes the basket and its files.
    func discard(basket id: String) throws {
        try? fm.removeItem(at: folder(id))
        baskets.removeAll { $0.id == id }
        changed()
    }

    func markSent(_ id: String, key: String, session: String?) throws { try set(id, .sent(key: key, session: session)) }

    func set(_ id: String, _ state: SnapBasket.State) throws {
        guard var b = basket(id) else { return }
        b.state = state
        try save(b)
    }

    /// The baskets that are not open, newest first.
    func history(limit: Int = 50) -> [SnapBasket] { Array(baskets.filter { !$0.isOpen }.prefix(limit)) }

    /// Removes the closed baskets made before `date`. Open baskets stay.
    func purge(olderThan date: Date) {
        let old = baskets.filter { !$0.isOpen && $0.createdAt < date }
        guard !old.isEmpty else { return }
        for b in old { try? fm.removeItem(at: folder(b.id)) }
        baskets.removeAll { b in old.contains { $0.id == b.id } }
        changed()
    }

    func png(of shot: UUID, in basket: String) -> Data? { try? Data(contentsOf: pngURL(shot, in: basket)) }

    /// The folder for the rendered files of a basket.
    func outDir(_ basket: String) -> URL { folder(basket).appendingPathComponent("out") }

    // MARK: Files

    private func folder(_ id: String) -> URL { dir.appendingPathComponent(id) }
    private func pngURL(_ shot: UUID, in b: String) -> URL { folder(b).appendingPathComponent("shot-\(shot.uuidString).png") }
    private func shotURL(_ shot: UUID, in b: String) -> URL { folder(b).appendingPathComponent("shot-\(shot.uuidString).json") }

    private func save(_ b: SnapBasket) throws {
        try fm.createDirectory(at: folder(b.id), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        for s in b.shots { try e.encode(s).write(to: shotURL(s.id, in: b.id), options: .atomic) }
        let file = BasketFile(id: b.id, project: b.project, state: b.state, createdAt: b.createdAt, order: b.shots.map(\.id))
        try e.encode(file).write(to: folder(b.id).appendingPathComponent("basket.json"), options: .atomic)
        if let i = baskets.firstIndex(where: { $0.id == b.id }) { baskets[i] = b } else { baskets.insert(b, at: 0) }
        baskets.sort { $0.createdAt > $1.createdAt }
        changed()
    }

    // A bad basket file skips the basket. A bad shot file skips the shot.
    private func load() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        var out: [SnapBasket] = []
        for name in names where !name.hasPrefix(".") {
            let url = folder(name).appendingPathComponent("basket.json")
            guard let data = try? Data(contentsOf: url), let f = try? d.decode(BasketFile.self, from: data) else {
                log.warning("Snap basket \(name, privacy: .public) has no valid basket.json. OverSire skips it.")
                continue
            }
            var b = SnapBasket(project: f.project, at: f.createdAt)
            b.id = f.id
            b.state = f.state
            b.shots = f.order.compactMap { id in
                guard let data = try? Data(contentsOf: shotURL(id, in: f.id)), let s = try? d.decode(SnapShot.self, from: data) else {
                    log.warning("Snap shot \(id.uuidString, privacy: .public) in \(name, privacy: .public) is bad. OverSire skips it.")
                    return nil
                }
                return s
            }
            out.append(b)
        }
        baskets = out.sorted { $0.createdAt > $1.createdAt }
    }

    private func changed() { NotificationCenter.default.post(name: Self.changed, object: self) }
}
