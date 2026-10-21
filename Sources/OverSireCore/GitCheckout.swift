import Foundation

/// The state of a git checkout, as the cleanup reads it.
public struct CheckoutState: Hashable, Sendable {
    public let branch: String      // "" for a detached HEAD
    public let dirty: Int          // files with changes that are not committed
    public let ahead: Int          // commits of the branch that are not in the base branch
    public let base: String

    public init(branch: String, dirty: Int, ahead: Int, base: String) {
        self.branch = branch
        self.dirty = dirty
        self.ahead = ahead
        self.base = base
    }

    /// No changes, and the branch is merged or has no commits of its own.
    public var clean: Bool { dirty == 0 && ahead == 0 }

    /// "3 files with changes", "2 commits not in main", or nil.
    public var risk: String? {
        if dirty > 0 { return "\(dirty) file\(dirty == 1 ? "" : "s") with changes" }
        if ahead > 0 { return "\(ahead) commit\(ahead == 1 ? "" : "s") not in \(base)" }
        return nil
    }
}

/// A local branch of a repo.
public struct GitBranch: Hashable, Sendable {
    public let name: String
    public let merged: Bool       // in the base branch
    public let checkedOut: Bool   // a worktree uses it

    public init(name: String, merged: Bool, checkedOut: Bool) {
        self.name = name
        self.merged = merged
        self.checkedOut = checkedOut
    }
}

/// Git calls on one repo or worktree, through a CommandRunner. Reads use no lock files.
public struct GitCheckout: Sendable {
    public static let git = "/usr/bin/git"
    public let path: String
    let commands: any CommandRunner

    public init(path: String, commands: any CommandRunner) {
        self.path = path
        self.commands = commands
    }

    func run(_ args: [String]) async throws -> String {
        let out = try await commands.run(Self.git, ["-C", path, "-c", "core.optionalLocks=false"] + args, stdin: nil, timeout: .seconds(20))
        guard out.status == 0 else {
            throw ProviderError.vendor(code: "git", message: out.stderr.isEmpty ? "git \(args.first ?? "") failed" : out.stderr)
        }
        return String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The default branch: the target of origin/HEAD, else main, else master.
    public func baseBranch() async -> String {
        if let head = try? await run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]), head.hasPrefix("origin/") {
            let b = String(head.dropFirst("origin/".count))
            if (try? await run(["rev-parse", "--verify", "--quiet", "refs/heads/" + b])) != nil { return b }
        }
        if (try? await run(["rev-parse", "--verify", "--quiet", "refs/heads/main"])) != nil { return "main" }
        return "master"
    }

    public func state() async throws -> CheckoutState {
        let base = await baseBranch()
        let branch = (try? await run(["symbolic-ref", "--short", "HEAD"])) ?? ""
        let status = try await run(["status", "--porcelain"])
        let dirty = status.split(separator: "\n").count
        let ahead = Int(try await run(["rev-list", "--count", base + "..HEAD"])) ?? 0
        return CheckoutState(branch: branch, dirty: dirty, ahead: ahead, base: base)
    }

    /// The local branches, with merged state against `base`.
    public func branches(base: String) async throws -> [GitBranch] {
        let merged = Set(try await run(["branch", "--merged", base, "--format=%(refname:short)"]).split(separator: "\n").map(String.init))
        let all = try await run(["branch", "--format=%(refname:short)\t%(worktreepath)"])
        return all.split(separator: "\n").map { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return GitBranch(name: parts[0], merged: merged.contains(parts[0]), checkedOut: parts.count > 1 && !parts[1].isEmpty)
        }
    }

    /// The main checkout of a worktree: the folder that holds the shared .git folder.
    public func mainCheckout() async throws -> String {
        let common = try await run(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        return (common as NSString).deletingLastPathComponent
    }

    /// Removes the worktree at `worktree`. Git refuses a worktree with changes unless `force`.
    public func removeWorktree(_ worktree: String, force: Bool) async throws {
        _ = try await run(["worktree", "remove"] + (force ? ["--force"] : []) + [worktree])
    }

    /// Deletes a merged local branch. Git refuses a branch that is not merged.
    public func deleteBranch(_ name: String) async throws {
        _ = try await run(["branch", "-d", name])
    }

    /// Forgets origin/<name> after the branch went from the remote.
    public func forgetRemoteBranch(_ name: String) async throws {
        _ = try await run(["branch", "-dr", "origin/" + name])
    }

    /// The branches of origin that the last fetch saw, without "origin/".
    public func remoteBranches() async throws -> [String] {
        try await run(["for-each-ref", "--format=%(refname:lstrip=3)", "refs/remotes/origin"]).split(separator: "\n").map(String.init)
            .filter { $0 != "HEAD" }
    }
}
