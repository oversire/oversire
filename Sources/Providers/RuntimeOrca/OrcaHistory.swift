import Foundation
import OverSireCore

// The history of an Orca session. `orca search` finds the harness session id (and the file on this Mac).
// A local session goes to the injected TranscriptReading. A remote session gets an ad hoc terminal in its
// workspace: oversire-runner digest, else python3 with digestScript, prints the digest between markers.

extension OrcaRuntime {
    static let historyLines = 600

    public func history(of a: AgentSession, in w: Workspace, budget: HistoryBudget) async throws -> SessionDigest {
        guard a.agent == .claude else { throw ProviderError.unsupported(.sessionHistory) }
        let hit = try? await findSession(a, path: w.path)
        if environment == nil {
            guard let transcripts else { throw ProviderError.unsupported(.sessionHistory) }
            let file = hit?.file ?? hit.flatMap { transcripts.locate(agent: a.agent, sessionId: $0.id) }
                ?? transcripts.newest(agent: a.agent, cwd: w.path)
            guard let file else { throw ProviderError.notFound }
            return try transcripts.digest(file: file, agent: a.agent, budget: budget)
        }
        return try await remoteHistory(agent: a.agent, sessionId: hit?.id, path: w.path, budget: budget)
    }

    /// The newest session of `a` in `path` whose conversation holds the words of its prompt.
    func findSession(_ a: AgentSession, path: String) async throws -> (id: String, file: String?)? {
        let words = (a.prompt ?? a.message ?? "").split { !$0.isLetter && !$0.isNumber }.prefix(8).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        let r = try await run(["search", "--query", words, "--agent", a.agent.rawValue, "--path", path, "--scope", "conversation",
                               "--sort", "newest", "--limit", "5"])
        let hits = r["hits"] as? [[String: Any]] ?? []
        guard let h = hits.first(where: { $0["agent"] as? String == a.agent.rawValue }), let id = h["sessionId"] as? String else { return nil }
        return (id, (h["source"] as? [String: Any])?["filePath"] as? String)
    }

    func remoteHistory(agent: AgentName, sessionId: String?, path: String, budget: HistoryBudget) async throws -> SessionDigest {
        let made = try await run(["terminal", "create", "--worktree", "path:" + path, "--title", "oversire-history"], timeout: .seconds(30))
        guard let h = (made["terminal"] as? [String: Any])?["handle"] as? String else { throw ProviderError.decoding("Orca made no terminal") }
        do {
            let d = try await readDigest(terminal: h, agent: agent, sessionId: sessionId, path: path, budget: budget)
            _ = try? await run(["terminal", "close", "--terminal", h])
            return d
        } catch {
            _ = try? await run(["terminal", "close", "--terminal", h])
            throw error
        }
    }

    private func readDigest(terminal h: String, agent: AgentName, sessionId: String?, path: String,
                            budget: HistoryBudget) async throws -> SessionDigest {
        let id = uploadId()
        try await Task.sleep(for: shellWait)
        try await type(h, "command -v oversire-runner >/dev/null && \(Self.mark("RUNNER", id)) || { command -v python3 >/dev/null"
            + " && \(Self.mark("PY", id)) || \(Self.mark("NO", id)); }")
        let probe = try await readUntil(h, lines: 40) { $0.contains { l in ["RUNNER", "PY", "NO"].contains { l.contains("OVERSIRE-\($0)-" + id) } } }
        let session = sessionId.map(Self.quote) ?? "\"$(ls -t ~/.claude/projects/\(Self.slug(path))/*.jsonl 2>/dev/null | head -1)\""
        let flags = "\(session) --markers --source orca-terminal --earlier \(budget.earlier) --full \(budget.full) --max-chars \(budget.maxChars)"
        if probe.contains(where: { $0.contains("OVERSIRE-RUNNER-" + id) }) {
            try await type(h, "oversire-runner digest --harness \(agent.rawValue) --session " + flags)
        } else if probe.contains(where: { $0.contains("OVERSIRE-PY-" + id) }) {
            let file = "\"${TMPDIR:-/tmp}/oversire-digest-\(id).py\""
            try await type(h, "stty -echo; base64 -d > \(file)")
            let text = Data(Self.digestScript.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]) + "\n"
            for chunk in Self.chunks(text) { _ = try await run(["terminal", "send", "--terminal", h, "--text", chunk], timeout: .seconds(30)) }
            _ = try await run(["terminal", "send", "--terminal", h, "--text", "\u{04}"])
            try await type(h, "stty echo; python3 -I \(file) \(flags); rm -f \(file)")
        } else {
            throw ProviderError.vendor(code: "host_tools", message: "The Orca host needs oversire-runner or python3 to read the session history.")
        }
        let out = try await readUntil(h, lines: Self.historyLines) { $0.contains { $0.hasPrefix("OVERSIRE-DIGEST-END") || $0.hasPrefix("OVERSIRE-DIGEST-ERROR") } }
        return try Self.digest(fromMarked: out)
    }

    /// The digest between OVERSIRE-DIGEST-BEGIN and OVERSIRE-DIGEST-END: gzip, then base64.
    static func digest(fromMarked lines: [String]) throws -> SessionDigest {
        if let e = lines.last(where: { $0.hasPrefix("OVERSIRE-DIGEST-ERROR") }) {
            let m = e.dropFirst("OVERSIRE-DIGEST-ERROR".count).trimmingCharacters(in: .whitespaces)
            throw m.hasPrefix("no transcript") ? ProviderError.notFound : ProviderError.vendor(code: "digest", message: m)
        }
        guard let end = lines.lastIndex(where: { $0.hasPrefix("OVERSIRE-DIGEST-END") }),
              let begin = lines[..<end].lastIndex(where: { $0.hasPrefix("OVERSIRE-DIGEST-BEGIN") }) else {
            throw ProviderError.decoding("no digest markers")
        }
        let b64 = lines[(begin + 1)..<end].map { $0.trimmingCharacters(in: .whitespaces) }.joined()
        guard let gz = Data(base64Encoded: b64), let json = gunzip(gz) else { throw ProviderError.decoding("bad digest text") }
        var d: SessionDigest
        do { d = try JSONDecoder().decode(SessionDigest.self, from: json) } catch { throw ProviderError.decoding("digest: \(error)") }
        d.source = .orcaTerminal
        return d
    }

    /// The members of one gzip file (RFC 1952) without the header and the trailer, then raw deflate.
    static func gunzip(_ d: Data) -> Data? {
        let b = [UInt8](d)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        for bit: UInt8 in [8, 16] where flags & bit != 0 {
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        return try? (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data
    }

    /// The Claude project folder name of a path: each character that is not a letter or a digit becomes "-".
    static func slug(_ path: String) -> String {
        String(path.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }

    /// A copy of scripts/digest.py. RuntimeOrcaTests checks that they are the same.
    static let digestScript = #"""
    #!/usr/bin/env python3
    """Make a SessionDigest (Contract/schema/session-digest.json) from a Claude transcript.

    The remote Orca read runs this script when oversire-runner is not on the host.
    The rules are the same as in AgentBinder TranscriptReader and in oversire-runner digest.
    Contract/fixtures/session-digest holds the cases that all three readers must pass.

    Usage: digest.py [--markers] [--source S] [--earlier N] [--full N] [--max-chars N] <file or session id>
    With --markers, the JSON goes out as gzip and base64 between OVERSIRE-DIGEST-BEGIN and OVERSIRE-DIGEST-END.
    """
    import argparse, base64, glob, gzip, json, os, sys

    PROMPT_CHARS, CLOSING_CHARS, LAST_PROMPT_CHARS = 120, 700, 1500


    def prompt_text(e):
        """The text of a human prompt, or None for every other line."""
        if e.get("type") != "user" or e.get("isMeta") or e.get("isCompactSummary"):
            return None
        m = e.get("message")
        c = m.get("content") if isinstance(m, dict) else None
        if isinstance(c, list):
            if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
                return None
            c = "\n".join(b["text"] for b in c if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str))
        if not isinstance(c, str):
            return None
        return c.strip()


    def is_notice(text):
        # Harness and Orca notices (task, artifact, command output) start with a tag.
        return text.startswith("<") and not text.startswith("<pasted")


    def digest(path, earlier=12, full=3, max_chars=4000, source="file"):
        turns, session = [], None
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(e, dict) or e.get("isSidechain"):
                    continue
                if not session and isinstance(e.get("sessionId"), str):
                    session = e["sessionId"]
                p = prompt_text(e)
                if p is not None:
                    if p.startswith("[Request interrupted"):
                        if turns:
                            turns[-1]["interrupted"] = True
                    elif p and not is_notice(p) and not p.startswith("Caveat:"):
                        turns.append({"prompt": p, "text": [], "tools": 0, "interrupted": False})
                elif e.get("type") == "assistant" and turns:
                    m = e.get("message")
                    c = m.get("content") if isinstance(m, dict) else None
                    for b in c if isinstance(c, list) else []:
                        if not isinstance(b, dict):
                            continue
                        if b.get("type") == "text" and isinstance(b.get("text"), str) and b["text"].strip():
                            turns[-1]["text"].append(b["text"].strip())
                        elif b.get("type") == "tool_use":
                            turns[-1]["tools"] += 1
        turns = [t for t in turns if t["text"]]
        full = min(full, len(turns))
        head, tail = turns[:len(turns) - full], turns[len(turns) - full:]
        out = {"harness": "claude", "sessionId": session or os.path.basename(path).rsplit(".", 1)[0], "source": source,
               "turns": len(turns), "earlier": [], "last": [], "truncated": len(head) > earlier}
        for t in head[-earlier:] if earlier else []:
            d = {"prompt": t["prompt"][:PROMPT_CHARS], "closing": t["text"][-1][:CLOSING_CHARS]}
            if t["interrupted"]:
                d["interrupted"] = True
            out["earlier"].append(d)
        for t in tail:
            text = "\n\n".join(t["text"])
            if len(text) > max_chars:
                text, out["truncated"] = text[-max_chars:], True
            d = {"prompt": t["prompt"][:LAST_PROMPT_CHARS], "text": text, "tools": t["tools"]}
            if t["interrupted"]:
                d["interrupted"] = True
            out["last"].append(d)
        return out


    def find(arg):
        if os.path.isfile(arg):
            return arg
        hits = glob.glob(os.path.expanduser("~/.claude/projects/*/" + arg + ".jsonl"))
        if not hits:
            raise FileNotFoundError("no transcript for session " + arg)
        return max(hits, key=os.path.getmtime)


    def main():
        ap = argparse.ArgumentParser()
        ap.add_argument("session")
        ap.add_argument("--markers", action="store_true")
        ap.add_argument("--source", default="file")
        ap.add_argument("--earlier", type=int, default=12)
        ap.add_argument("--full", type=int, default=3)
        ap.add_argument("--max-chars", type=int, default=4000)
        a = ap.parse_args()
        try:
            body = json.dumps(digest(find(a.session), a.earlier, a.full, a.max_chars, a.source), ensure_ascii=False)
        except Exception as err:
            if not a.markers:
                raise
            print("OVERSIRE-DIGEST-ERROR " + str(err).replace("\n", " "))
            return 1
        if not a.markers:
            print(body)
            return 0
        b = base64.b64encode(gzip.compress(body.encode("utf-8"))).decode()
        print("OVERSIRE-DIGEST-BEGIN")
        for i in range(0, len(b), 76):
            print(b[i:i + 76])
        print("OVERSIRE-DIGEST-END")
        return 0


    if __name__ == "__main__":
        sys.exit(main())
    """#
}
