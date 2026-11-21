import Foundation

/// A dotted version of a vendor CLI. A missing part is 0: 1.0 equals 1.0.0.
public struct VendorVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    /// Reads "0.2.2", "v1.0.12" or "1.2.3-rc1". Drops the text after "-" or "+".
    public init?(_ text: String) {
        var t = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if t.first == "v" || t.first == "V" { t = t.dropFirst() }
        t = t.prefix { $0 != "-" && $0 != "+" }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    /// The first `N.N` or `N.N.N` on the first line that is not empty.
    public static func find(in output: String) -> VendorVersion? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        for word in line.split(whereSeparator: { !$0.isASCII || !($0.isNumber || $0 == ".") }) {
            let nums = word.split(separator: ".", omittingEmptySubsequences: false)
            guard nums.count >= 2, nums.prefix(3).allSatisfy({ !$0.isEmpty }) else { continue }
            if let v = VendorVersion(nums.prefix(3).joined(separator: ".")) { return v }
        }
        return nil
    }

    /// The parts without the trailing zeros.
    private var trimmed: ArraySlice<Int> {
        var p = parts[...]
        while p.last == 0 { p = p.dropLast() }
        return p
    }

    public static func == (a: VendorVersion, b: VendorVersion) -> Bool { a.trimmed == b.trimmed }
    public func hash(into h: inout Hasher) { h.combine(Array(trimmed)) }

    public static func < (a: VendorVersion, b: VendorVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let l = i < a.parts.count ? a.parts[i] : 0, r = i < b.parts.count ? b.parts[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// Where the binary comes from: the OverSire copy, or the PATH folders.
public enum VendorSource: String, Codable, Hashable, Sendable {
    case oversire, path
}

public enum VendorState: String, Codable, Hashable, Sendable {
    case ok, old, missing
}

/// The binary that `vendor.run` runs for a vendor, with its version and its state.
public struct VendorBinary: Hashable, Sendable {
    public let vendor: ProviderID
    public let binary: String
    public let minVersion: VendorVersion?
    public let path: String?
    public let version: VendorVersion?
    public let source: VendorSource?
    public let state: VendorState

    public init(vendor: ProviderID, cli: VendorCLI, path: String?, version: VendorVersion?, source: VendorSource?) {
        self.vendor = vendor
        self.binary = cli.binary
        self.minVersion = cli.minVersion.flatMap(VendorVersion.init)
        self.path = path
        self.version = version
        self.source = source
        if path == nil {
            state = .missing
        } else if let floor = minVersion, version.map({ $0 < floor }) ?? true {
            state = .old
        } else {
            state = .ok
        }
    }

    public var installHint: String { "Run `oversire vendor install \(vendor.rawValue)`." }

    /// Why the app does not run the binary, or nil.
    public var problem: String? {
        switch state {
        case .ok: return nil
        case .missing: return "\(binary) is not installed. \(installHint)"
        case .old:
            let floor = minVersion?.description ?? ""
            guard let version else {
                return "\(binary) at \(path ?? "") gives no version. OverSire needs \(floor) or newer. \(installHint)"
            }
            return "\(binary) \(version) is older than \(floor). \(installHint)"
        }
    }
}
