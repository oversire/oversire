import Foundation
import OverSireCore

// ─── Changes › file panel model ──────────────────────────────────────────────
// The rows of the file panel (OVERSIRE-388, OVERSIRE-389): a tree by default, or a list.
// The filters: one repo or all, a search text, and the status groups to show.

/// The status switches of the file panel. A renamed file counts as changed.
enum FileGroup: String, CaseIterable, Hashable {
    case new, changed, deleted

    init(_ s: FileStatus) {
        switch s {
        case .added: self = .new
        case .deleted: self = .deleted
        case .modified, .renamed: self = .changed
        }
    }

    var letter: String {
        switch self {
        case .new: return "A"
        case .changed: return "M"
        case .deleted: return "D"
        }
    }

    var word: String {
        switch self {
        case .new: return "New"
        case .changed: return "Changed"
        case .deleted: return "Deleted"
        }
    }
}

enum FileView: String {
    case tree, list

    private static let key = "review.fileView"
    private static var shot = FileView.tree
    static var saved: FileView {
        get { UIShots.shooting ? shot : UserDefaults.standard.string(forKey: key).flatMap(FileView.init) ?? .tree }
        set { if UIShots.shooting { shot = newValue } else { UserDefaults.standard.set(newValue.rawValue, forKey: key) } }
    }
}

struct FileFilter: Hashable {
    /// Nil shows all repos.
    var repo: String?
    var query = ""
    var hidden: Set<FileGroup> = []

    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func matches(_ f: ReviewFile) -> Bool {
        if let repo, f.repo != repo { return false }
        if hidden.contains(FileGroup(f.status)) { return false }
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || f.id.localizedCaseInsensitiveContains(q)
    }
}

/// The rows of the file panel, in order.
struct FileTree {
    enum Kind: Hashable { case head, repo, folder, file }

    struct Row: Hashable {
        /// A folder id is `repo/path`; it keys the folds.
        let id: String
        let kind: Kind
        let name: String
        let depth: Int
        var file: ReviewFile?
        var files = 0
        var pending = 0
        var open = true
    }

    let files: [ReviewFile]
    /// The repos in their order. A repo of a file that is not in it comes last.
    let repos: [String]
    var filter = FileFilter()
    var collapsed: Set<String> = []
    /// ReviewFile.id → pending comments.
    var pending: [String: Int] = [:]

    var shown: [ReviewFile] { files.filter(filter.matches) }

    /// The files in the order of the rows, with the filter. A collapsed folder does not hide its files.
    func steps(_ view: FileView) -> [ReviewFile] {
        var all = self
        all.collapsed = []
        return all.rows(view).compactMap(\.file)
    }

    private var order: [String] {
        repos + Set(files.map(\.repo)).subtracting(repos).sorted()
    }

    /// Repo rows show only when the panel shows more than one repo.
    private var repoRows: Bool { filter.repo == nil && Set(files.map(\.repo)).count > 1 }

    func rows(_ view: FileView) -> [Row] {
        let shown = self.shown
        var out: [Row] = []
        for r in order {
            let fs = shown.filter { $0.repo == r }
            guard !fs.isEmpty else { continue }
            switch view {
            case .list:
                if repoRows { out.append(Row(id: r, kind: .head, name: r, depth: 0, files: fs.count)) }
                out += fs.map { Row(id: $0.id, kind: .file, name: $0.path, depth: 0, file: $0, pending: pending[$0.id] ?? 0) }
            case .tree:
                let root = Node()
                fs.forEach { root.add($0, pending: pending[$0.id] ?? 0) }
                var depth = 0
                if repoRows {
                    let open = isOpen(r)
                    out.append(Row(id: r, kind: .repo, name: r, depth: 0, files: root.count, pending: root.pending, open: open))
                    guard open else { continue }
                    depth = 1
                }
                walk(root, repo: r, prefix: "", depth: depth, into: &out)
            }
        }
        return out
    }

    /// A search opens all folders, so each match shows.
    private func isOpen(_ id: String) -> Bool { filter.searching || !collapsed.contains(id) }

    private func walk(_ n: Node, repo: String, prefix: String, depth: Int, into out: inout [Row]) {
        for name in n.dirs.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            var label = name, path = prefix + name, d = n.dirs[name]!
            // A chain of folders with one child is one row.
            while d.files.isEmpty, d.dirs.count == 1, let (k, next) = d.dirs.first {
                label += "/" + k
                path += "/" + k
                d = next
            }
            let id = repo + "/" + path, open = isOpen(id)
            out.append(Row(id: id, kind: .folder, name: label, depth: depth, files: d.count, pending: d.pending, open: open))
            if open { walk(d, repo: repo, prefix: path + "/", depth: depth + 1, into: &out) }
        }
        let files = n.files.sorted { Self.base($0.path).localizedStandardCompare(Self.base($1.path)) == .orderedAscending }
        out += files.map { Row(id: $0.id, kind: .file, name: Self.base($0.path), depth: depth, file: $0, pending: pending[$0.id] ?? 0) }
    }

    static func base(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

    private final class Node {
        var dirs: [String: Node] = [:]
        var files: [ReviewFile] = []
        var count = 0
        var pending = 0

        func add(_ f: ReviewFile, pending p: Int) {
            var n = self
            n.count += 1
            n.pending += p
            for part in f.path.split(separator: "/").dropLast().map(String.init) {
                let next = n.dirs[part] ?? Node()
                n.dirs[part] = next
                n = next
                n.count += 1
                n.pending += p
            }
            n.files.append(f)
        }
    }
}
