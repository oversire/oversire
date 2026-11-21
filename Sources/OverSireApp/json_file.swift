import Foundation

extension Decodable {
    /// Reads and decodes a JSON file. Gives nil when the file is missing or bad.
    static func read(atPath path: String) -> Self? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: d)
    }
}

extension Encodable {
    /// Writes the value as JSON, atomically. Drops errors.
    func write(atPath path: String, makeDir: Bool = false) {
        guard let d = try? JSONEncoder().encode(self) else { return }
        let url = URL(fileURLWithPath: path)
        if makeDir {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try? d.write(to: url, options: .atomic)
    }
}
