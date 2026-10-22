import Foundation

/// One person, with the data of all sources: trackers, code hosts and machines.
public struct PersonDetail: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var login: String?
    public var email: String?
    /// The accounts that know the person, for example "plane:ocral" or "github:acme".
    public var sources: [String]
    /// The machines of the person, by name.
    public var machines: [String]

    public init(id: String, name: String, login: String? = nil, email: String? = nil, sources: [String] = [], machines: [String] = []) {
        self.id = id
        self.name = name
        self.login = login
        self.email = email
        self.sources = sources
        self.machines = machines
    }

    public init(_ ref: PersonRef, email: String? = nil, sources: [String] = [], machines: [String] = []) {
        self.init(id: ref.id, name: ref.name, login: ref.login, email: email, sources: sources, machines: machines)
    }

    public var ref: PersonRef { PersonRef(id: id, name: name, login: login) }

    private enum CodingKeys: String, CodingKey { case id, name, login, email, sources, machines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  login: try c.decodeIfPresent(String.self, forKey: .login), email: try c.decodeIfPresent(String.self, forKey: .email),
                  sources: try c.decodeIfPresent([String].self, forKey: .sources) ?? [],
                  machines: try c.decodeIfPresent([String].self, forKey: .machines) ?? [])
    }

    // Empty lists stay out of the JSON.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(login, forKey: .login)
        try c.encodeIfPresent(email, forKey: .email)
        if !sources.isEmpty { try c.encode(sources, forKey: .sources) }
        if !machines.isEmpty { try c.encode(machines, forKey: .machines) }
    }

    /// Joins the same person from many lists. Two emails decide when both are there (case-insensitive).
    /// Else the same login decides. The first entry gives the id and the name. All sources and machines stay.
    public static func merge(_ lists: [[PersonDetail]]) -> [PersonDetail] {
        func key(_ s: String?) -> String? {
            s.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
        }
        var out: [PersonDetail] = []
        for p in lists.joined() {
            let email = key(p.email), login = key(p.login)
            let hits = out.indices.filter { i in
                let e = key(out[i].email)
                if let email, let e { return email == e }
                return login != nil && login == key(out[i].login)
            }
            guard let first = hits.first else {
                out.append(p)
                continue
            }
            // A person can join two entries: one by email, one by login. Two other emails stay apart.
            for i in hits.dropFirst().reversed() where key(out[i].email) == nil || key(out[i].email) == key(out[first].email) {
                out[first].absorb(out[i])
                out.remove(at: i)
            }
            out[first].absorb(p)
        }
        return out
    }

    private mutating func absorb(_ o: PersonDetail) {
        if login == nil { login = o.login }
        if email == nil { email = o.email }
        for s in o.sources where !sources.contains(s) { sources.append(s) }
        for m in o.machines where !machines.contains(m) { machines.append(m) }
    }
}

/// The people that the app knows. The consumer joins trackers, code hosts and machines behind it.
public protocol People: Sendable {
    /// The people of one project. Nil gives all people.
    func people(for project: ProjectRef?) async throws -> [PersonRef]
    func person(_ ref: PersonRef) async throws -> PersonDetail
}
