import Cocoa

// Starts a detached script that outlives this process, then quits the app.
struct Relauncher {
    let appURL: URL

    /// Waits for the pid to exit, then opens the app. Arguments: the pid, the app path, then `args`.
    static let reopen = """
    pid=$1; app=$2
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    open "$app"
    """

    /// `started` runs after the script starts and before the app quits.
    func relaunch(script: String = Relauncher.reopen, args: [String] = [], started: () -> Void = {}) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", "\(getpid())", appURL.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        started()
        NSApp.terminate(nil)
    }
}
