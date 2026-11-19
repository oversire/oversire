import Foundation
import OverSireCore

/// The relation cache on disk: one JSON file for each project store key.
struct RelationDisk {
    struct Entry: Codable, Equatable {
        let relations: [ItemRelation]
        /// The time of the good read.
        let at: Date
        /// The `updatedAt` of the item when the read started. Nil when it was not known.
        let itemUpdatedAt: Date?
    }

    let folder: URL

    init(folder: URL) { self.folder = folder }

    /// Upper-case key → entry. A missing or bad file gives no entries.
    func load(project: String) -> [String: Entry] {
        guard let data = try? Data(contentsOf: file(project)) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    func save(project: String, _ entries: [String: Entry]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(entries).write(to: file(project), options: .atomic)
    }

    /// A store key has a "/", so the name encodes it.
    func file(_ project: String) -> URL {
        let safe = project.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? project
        return folder.appendingPathComponent(safe + ".json")
    }

    /// The default date form keeps the full precision, so a compare with `updatedAt` stays exact.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
}
