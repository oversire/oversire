import Foundation
import OverSireCore
import OverSireAI

/// Writes the oversire-ask script on each runtime host. One write lasts `life`, because the host can delete /tmp.
final class AskScripts: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [AccountID: Date] = [:]
    private let life: TimeInterval
    private let now: @Sendable () -> Date

    init(life: TimeInterval = 6 * 3600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.life = life
        self.now = now
    }

    /// The prompt with the line about oversire-ask. The prompt stays as it is when the runtime takes no files or the write fails.
    func prompt(_ prompt: String, host: (any HostFileWriting)?, workspacePath: String) async -> String {
        await ready(host: host, workspacePath: workspacePath) ? prompt + "\n\n" + AskSkill.promptLine : prompt
    }

    /// Writes the script when the last write is old. False: the runtime takes no files or the write failed.
    func ready(host: (any HostFileWriting)?, workspacePath: String) async -> Bool {
        guard let host, host.capabilities.contains(.hostFiles) else { return false }
        if lock.withLock({ written[host.account].map { now().timeIntervalSince($0) < life } ?? false }) { return true }
        let f = AskSkill.file
        guard (try? await host.writeFiles([HostFile(name: f.name, data: f.data)], workspacePath: workspacePath, dir: AskSkill.dir) { _, _ in }) != nil
        else { return false }
        lock.withLock { written[host.account] = now() }
        return true
    }
}

let ASK_SCRIPTS = AskScripts()
