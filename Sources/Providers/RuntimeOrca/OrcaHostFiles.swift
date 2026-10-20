import CryptoKit
import Foundation
import OverSireCore

// The Orca CLI has no upload command. Thus the files go as base64 text into a hidden shell on the host:
// `base64 -d` writes each file, then a checksum line proves that it arrived whole.

extension OrcaRuntime: HostFileWriting {
    /// The largest text of one send. 1 MB is over the macOS argument limit.
    static let chunkBytes = 256 * 1024
    static let readTimeout: Duration = .seconds(30)

    public func writeFiles(_ files: [HostFile], workspacePath: String, dir: String,
                           progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [String] {
        guard !files.isEmpty else { return [] }
        let made = try await run(["terminal", "create", "--worktree", "path:" + workspacePath, "--title", "oversire-upload"],
                                 timeout: .seconds(30))
        guard let h = (made["terminal"] as? [String: Any])?["handle"] as? String else { throw ProviderError.decoding("Orca made no terminal") }
        do {
            let paths = try await upload(files, dir: dir, terminal: h, progress: progress)
            _ = try? await run(["terminal", "close", "--terminal", h])
            return paths
        } catch {
            _ = try? await run(["terminal", "close", "--terminal", h])
            throw error
        }
    }

    private func upload(_ files: [HostFile], dir: String, terminal h: String,
                        progress: @Sendable (Int, Int) -> Void) async throws -> [String] {
        let id = uploadId()
        try await Task.sleep(for: shellWait)
        let probe = "command -v base64 >/dev/null && { command -v shasum >/dev/null || command -v sha256sum >/dev/null; }"
            + " && \(Self.mark("OK", id)) || \(Self.mark("NO", id))"
        try await type(h, probe)
        let ok = try? await readUntil(h, lines: 40) { $0.contains { $0.contains("OVERSIRE-OK-" + id) || $0.contains("OVERSIRE-NO-" + id) } }
        guard let ok, ok.contains(where: { $0.contains("OVERSIRE-OK-" + id) }) else {
            throw ProviderError.vendor(code: "host_tools", message: "The Orca host needs a POSIX shell with base64 and shasum or sha256sum.")
        }

        let paths = Self.safeNames(files.map(\.name)).map { dir + "/" + $0 }
        let texts = files.map { $0.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]) + "\n" }
        let total = texts.reduce(0) { $0 + $1.utf8.count }
        var sent = 0
        progress(0, total)
        for (path, text) in zip(paths, texts) {
            try await type(h, "stty -echo; mkdir -p \(Self.quote(dir)); base64 -d > \(Self.quote(path))")
            for chunk in Self.chunks(text) {
                _ = try await run(["terminal", "send", "--terminal", h, "--text", chunk], timeout: .seconds(30))
                sent += chunk.utf8.count
                progress(sent, total)
            }
            _ = try await run(["terminal", "send", "--terminal", h, "--text", "\u{04}"])
        }

        let list = paths.map(Self.quote).joined(separator: " ")
        try await type(h, "stty echo; printf '\\n'; if command -v shasum >/dev/null; then shasum -a 256 \(list); else sha256sum \(list); fi"
            + " | cut -c1-64; \(Self.mark("DONE", id))")
        let done = "OVERSIRE-DONE-" + id
        let out: [String]
        do { out = try await readUntil(h, lines: max(40, paths.count + 20)) { $0.contains { $0.contains(done) } } } catch {
            throw ProviderError.vendor(code: "checksum", message: "The Orca host gave no checksums.")
        }
        let sums = Array(Self.checksums(out, before: done).suffix(files.count))
        for (i, f) in files.enumerated() {
            let want = SHA256.hash(data: f.data).map { String(format: "%02x", $0) }.joined()
            guard sums.count == files.count, sums[i] == want else {
                throw ProviderError.vendor(code: "checksum", message: "\(f.name) did not arrive whole on the Orca host.")
            }
        }
        return paths
    }

    /// A line for the shell, then Enter.
    func type(_ h: String, _ line: String) async throws {
        _ = try await run(["terminal", "send", "--terminal", h, "--text", line, "--enter"])
    }

    /// Reads the output until `done` accepts it.
    func readUntil(_ h: String, lines: Int, _ done: ([String]) -> Bool) async throws -> [String] {
        let end = ContinuousClock.now + Self.readTimeout
        while true {
            let r = try await run(["terminal", "read", "--terminal", h, "--limit", "\(lines)"])
            let tail = (r["terminal"] as? [String: Any])?["tail"] as? [String] ?? []
            if done(tail) { return tail }
            guard ContinuousClock.now < end else { throw ProviderError.vendor(code: "timeout", message: "The Orca host did not answer.") }
            try await Task.sleep(for: max(shellWait, .milliseconds(50)))
        }
    }

    /// The command that prints OVERSIRE-<word>-<id>. The command line itself does not hold that text.
    static func mark(_ word: String, _ id: String) -> String { "printf 'OVERSIRE-%s-%s\\n' \(word) \(id)" }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Keeps [A-Za-z0-9._-] and changes the rest to "-". A second use of a name gets -2, -3 before the extension.
    static func safeNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.map { n in
            var base = String(n.unicodeScalars.map { s -> Character in
                s.isASCII && (CharacterSet.alphanumerics.contains(s) || "._-".unicodeScalars.contains(s)) ? Character(s) : "-"
            })
            if base.allSatisfy({ $0 == "." }) { base = "file" }
            let ext = (base as NSString).pathExtension
            let stem = ext.isEmpty ? base : String(base.dropLast(ext.count + 1))
            var name = base
            var i = 2
            while seen.contains(name) {
                name = stem + "-\(i)" + (ext.isEmpty ? "" : "." + ext)
                i += 1
            }
            seen.insert(name)
            return name
        }
    }

    /// Cuts base64 text at line ends. Each chunk is at most `chunkBytes` and ends with a new line.
    static func chunks(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if cur.utf8.count + line.utf8.count + 1 > chunkBytes, !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
            cur += line + "\n"
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The checksums that the host printed before the marker, in order.
    static func checksums(_ lines: [String], before marker: String) -> [String] {
        let end = lines.lastIndex { $0.contains(marker) } ?? lines.endIndex
        let re = try! NSRegularExpression(pattern: "(?<![0-9a-f])([0-9a-f]{64})\\s*$")
        return lines[..<end].compactMap { l in
            let ns = l as NSString
            return re.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        }
    }
}
