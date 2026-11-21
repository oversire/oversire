import Foundation
import OverSireCore

/// The text of `oversire vendor skill <vendor>`: a header from the descriptor, then the skill text of the CLI or a
/// pointer to its help.
struct VendorSkillPage: Hashable, Sendable {
    var vendor: ProviderID
    var displayName: String
    var cli: VendorCLI
    var accounts: [String]
    var projects: [String]
    var binary: VendorBinary
    /// The stdout of the skill command. Nil: the CLI gave none.
    var skillText: String?

    var reference: VendorSkillReference {
        if binary.state == .missing { return .notInstalled }
        return skillText == nil ? .help : .skill
    }

    var output: VendorSkillOutput {
        VendorSkillOutput(vendor: vendor.rawValue, binary: cli.binary, path: binary.path, reference: reference, markdown: markdown)
    }

    private var target: String { projects.isEmpty ? "--account <ACCOUNT>" : "--project <PROJECT>" }
    private var helpForms: String { "`oversire vendor run \(target) -- help <command>`, or `-- <command> --help`" }

    var header: String {
        let bin = cli.binary
        var intro = "The OverSire app on this Mac runs \(bin) for you."
        if cli.tokenEnv != nil { intro += " Do not run \(bin) directly: it has no token outside OverSire." }
        let account = "`oversire vendor run --account <ACCOUNT> -- <command> [flags]`"
        var lines = [projects.isEmpty ? "Run: \(account)." : "Run: `oversire vendor run --project <PROJECT> -- <command> [flags]`, or \(account).",
                     "Put the command first, then its flags. Help: \(helpForms)."]
        var sets: [String] = []
        if let e = cli.tokenEnv { sets.append("\(e) (the token of the account)") }
        if let e = cli.hostEnv { sets.append("\(e) (the host)") }
        if let e = cli.accountEnv { sets.append("\(e) (the workspace)") }
        if let e = cli.projectEnv { sets.append("\(e) (the project of --project)") }
        if let e = cli.managedEnv { sets.append("\(e)=OverSire") }
        if !sets.isEmpty { lines.append("The app sets: \(sets.joined(separator: ", ")).") }
        if cli.tokenEnv == nil { lines.append("\(bin) keeps its own login. OverSire has no token for it.") }
        var flags: [String] = []
        if !cli.lockedFlags.isEmpty { flags.append("The app refuses these flags: \(cli.lockedFlags.joined(separator: ", ")).") }
        if !cli.projectFlags.isEmpty {
            flags.append(cli.lockedFlags.isEmpty ? "The app refuses these flags with --project: \(cli.projectFlags.joined(separator: ", "))."
                                                 : "With --project, also: \(cli.projectFlags.joined(separator: ", ")).")
        }
        if !flags.isEmpty { lines.append(flags.joined(separator: " ")) }
        if !cli.deniedCommands.isEmpty {
            lines.append("The app refuses these commands: \(cli.deniedCommands.map { $0.joined(separator: " ") }.joined(separator: ", ")).")
        }
        let accountText = accounts.isEmpty ? "Accounts: none. Add one in Settings › Providers." : "Accounts: \(accounts.joined(separator: ", "))."
        lines.append("\(accountText) Projects: \(projects.isEmpty ? "none" : projects.joined(separator: ", ")).")
        lines.append(installLine)
        lines.append("The app sends no stdin and gives no TTY. The output has at most \(VendorCalls.maxStdout >> 20) MB. "
            + "The command has \(VendorCalls.timeout.components.seconds) s.")
        return "# \(displayName) (\(vendor.rawValue)): \(bin) through OverSire\n\n\(intro)\n\n" + lines.map { "- \($0)\n" }.joined()
    }

    var installLine: String {
        let name = binary.version.map { "\(binary.binary) \($0)" } ?? binary.binary
        let place: String
        switch binary.source {
        case .oversire: place = "OverSire copy at \(binary.path ?? "")."
        case .path: place = "PATH copy at \(binary.path ?? "")."
        case nil: place = "Copy at \(binary.path ?? "")."
        }
        switch binary.state {
        case .ok: return "\(name): \(place)"
        case .old: return "\(name): old, OverSire needs \(binary.minVersion?.description ?? ""). \(place)"
        case .missing: return "\(binary.binary): not installed."
        }
    }

    var markdown: String {
        let body: String
        switch reference {
        case .skill:
            var t = Substring(skillText ?? "")
            while t.last?.isNewline == true { t = t.dropLast() }
            body = String(t)
        case .help where cli.skillCommand == nil:
            body = "\(cli.binary) has no skill text for OverSire. Read the help: \(helpForms)."
        case .help:
            body = "\(cli.binary) gave no skill text. It can be an old version. Read the help: \(helpForms)."
        case .notInstalled:
            body = binary.problem ?? "\(cli.binary) is not installed."
        }
        return "\(header)\n## \(cli.binary) reference\n\n\(body)\n"
    }

    var summary: String {
        switch reference {
        case .skill: return "The skill of \(cli.binary)."
        case .help where cli.skillCommand == nil: return "\(cli.binary) has no skill text. Read its help."
        case .help: return "\(cli.binary) gave no skill text. Read its help."
        case .notInstalled: return "\(cli.binary) is not installed."
        }
    }
}
