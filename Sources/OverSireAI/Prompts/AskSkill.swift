import Foundation

/// The `oversire-ask` command for the coding sessions that OverSire starts in Orca. The app writes the script
/// on the Orca host and adds `promptLine` to the launch prompt. The script sends one round of questions to the
/// OverSire coordinator and prints the answer.
public enum AskSkill {
    public static let dir = "/tmp/oversire/bin"
    public static let name = "oversire-ask"
    public static var path: String { dir + "/" + name }
    public static var command: String { "python3 " + path }

    public static var promptLine: String {
        "To ask the user a question, run `\(command) --help` and do what it says. Do not use the AskUserQuestion tool."
    }

    public static var askAgainLine: String { "Ask again with `\(command)`. Run it with --help first." }

    public static var help: String {
        """
        Use \(name) to ask the user questions through OverSire.

        1. Make one JSON object with at most 4 questions:
           {"round":1,"questions":[{"id":"q1","type":"single","text":"Which store?","why":"Two exist.","options":["SQLite","JSON files"],"allowsOther":true}]}
           type is single, multi or free. A free question has no options. Increase round for each new round.
        2. Run: \(command) '<json>'
           Give the command a timeout of 10 minutes.
        3. Wait for the answer. The command prints it as JSON: {"round":1,"answers":{"q1":"SQLite"},"note":"..."}
           A multi answer is a list. A free answer or an "other" text is a string.
        4. If the command stops before it prints an answer, run: \(command) --resume <message id>
           The command prints the message id when it starts.
        Do not use the AskUserQuestion tool.
        """
    }

    /// Python 3, so it parses the JSON of the Orca CLI on any host.
    public static var script: String {
        #"""
        #!/usr/bin/env python3
        # oversire-ask: asks the user through the OverSire coordinator of this Orca server. Written by OverSire.
        import json, os, subprocess, sys, time

        HELP = __HELP__
        OBJECTIVE = "OverSire questions"

        def orca(*args):
            exe = os.environ.get("ORCA_CLI", "orca")
            out = subprocess.run([exe, *args, "--json"], capture_output=True, text=True)
            try:
                d = json.loads(out.stdout)
            except ValueError:
                sys.exit("oversire-ask: orca %s failed: %s" % (args[1], (out.stderr or out.stdout).strip()[:300]))
            if not d.get("ok"):
                sys.exit("oversire-ask: orca %s failed: %s" % (args[1], (d.get("error") or {}).get("message", "error")))
            return d.get("result") or {}

        def address():
            to = os.environ.get("OVERSIRE_ASK_TO")
            if to:
                return to
            runs = [r for r in orca("orchestration", "run-list").get("runs", []) if r.get("objective") == OBJECTIVE]
            if not runs:
                sys.exit("oversire-ask: OverSire is not running on this Orca server. Ask the question in the chat.")
            return "run:" + max(runs, key=lambda r: r.get("created_at", ""))["id"]

        def wait(me, msg, every):
            sys.stderr.write("oversire-ask: waiting for the answer to %s\n" % msg)
            sys.stderr.flush()
            while True:
                for m in orca("orchestration", "check", "--terminal", me, "--all").get("messages", []):
                    if m.get("thread_id") == msg and m.get("id") != msg:
                        print(m.get("body", ""))
                        return
                time.sleep(every)

        def main(argv):
            if not argv or argv[0] in ("-h", "--help"):
                print(HELP)
                return
            me = os.environ.get("ORCA_TERMINAL_HANDLE")
            if not me:
                sys.exit("oversire-ask: run it in an Orca terminal (ORCA_TERMINAL_HANDLE is not set).")
            every = float(os.environ.get("OVERSIRE_ASK_EVERY", "3"))
            if argv[0] == "--resume":
                if len(argv) < 2:
                    sys.exit("oversire-ask: give the message id after --resume.")
                return wait(me, argv[1], every)
            body = argv[0] if argv[0] != "-" else sys.stdin.read()
            try:
                q = json.loads(body)
            except ValueError as e:
                sys.exit("oversire-ask: the questions are not JSON: %s" % e)
            qs = q.get("questions") if isinstance(q, dict) else None
            if not isinstance(qs, list) or not 1 <= len(qs) <= 4 or not all(isinstance(x, dict) and x.get("text") for x in qs):
                sys.exit("oversire-ask: give 1 to 4 questions, each with a text. Run --help.")
            sent = orca("orchestration", "send", "--type", "question", "--subject", "Question", "--to", address(),
                        "--from", me, "--body", json.dumps(q, ensure_ascii=False))
            wait(me, sent["message"]["id"], every)

        main(sys.argv[1:])
        """#.replacingOccurrences(of: "__HELP__", with: pythonString(help))
    }

    public static var file: (name: String, data: Data) { (name, Data(script.utf8)) }

    /// A Python string literal of `s`. JSON strings are valid Python strings.
    static func pythonString(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8), as: UTF8.self)
            .dropFirst().dropLast().description
    }
}
