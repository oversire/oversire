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
