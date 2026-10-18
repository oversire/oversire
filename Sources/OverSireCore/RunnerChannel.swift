import Foundation

/// The x-oversire-schema number of work-order.json. A runner sends it in its hello.
public let workOrderSchemaVersion = 1

/// A message on the WebSocket between the hub and a runner device. Contract: runner.json.
public enum RunnerMessage: Hashable, Sendable {
    /// Runner to hub, first after each connect. `contract` is the work-order schema number of the runner.
    case hello(version: String, contract: Int, runtimes: [ProviderID], os: String? = nil, allow: AllowSummary? = nil)
    case ack(order: String)
    case result(order: String, state: WorkOrder.State, result: WorkOrderResult? = nil)
    case welcome(device: String, contract: Int)
    case refused(reason: String, contracts: [Int])
    case order(WorkOrder)
    case update(version: String)

    public struct AllowSummary: Hashable, Sendable, Codable {
        public var runtimes: [ProviderID]
        public var repos: Int
        public var agents: [String]

        public init(runtimes: [ProviderID], repos: Int, agents: [String]) {
            self.runtimes = runtimes
            self.repos = repos
            self.agents = agents
        }
    }
}

extension RunnerMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, version, contract, runtimes, os, allow, order, state, result, device, reason, contracts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(version: try c.decode(String.self, forKey: .version), contract: try c.decode(Int.self, forKey: .contract),
                          runtimes: try c.decode([ProviderID].self, forKey: .runtimes), os: try c.decodeIfPresent(String.self, forKey: .os),
                          allow: try c.decodeIfPresent(AllowSummary.self, forKey: .allow))
        case "ack": self = .ack(order: try c.decode(String.self, forKey: .order))
        case "result":
            let state = try c.decode(WorkOrder.State.self, forKey: .state)
            guard [.done, .failed, .expired].contains(state) else {
                throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "A result ends an order")
            }
            self = .result(order: try c.decode(String.self, forKey: .order), state: state,
                           result: try c.decodeIfPresent(WorkOrderResult.self, forKey: .result))
        case "welcome": self = .welcome(device: try c.decode(String.self, forKey: .device), contract: try c.decode(Int.self, forKey: .contract))
        case "refused": self = .refused(reason: try c.decode(String.self, forKey: .reason), contracts: try c.decode([Int].self, forKey: .contracts))
        case "order": self = .order(try c.decode(WorkOrder.self, forKey: .order))
        case "update": self = .update(version: try c.decode(String.self, forKey: .version))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown runner message \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(version, contract, runtimes, os, allow):
            try c.encode("hello", forKey: .type)
            try c.encode(version, forKey: .version)
            try c.encode(contract, forKey: .contract)
            try c.encode(runtimes, forKey: .runtimes)
            try c.encodeIfPresent(os, forKey: .os)
            try c.encodeIfPresent(allow, forKey: .allow)
        case let .ack(order):
            try c.encode("ack", forKey: .type)
            try c.encode(order, forKey: .order)
        case let .result(order, state, result):
            try c.encode("result", forKey: .type)
            try c.encode(order, forKey: .order)
            try c.encode(state, forKey: .state)
            try c.encodeIfPresent(result, forKey: .result)
        case let .welcome(device, contract):
            try c.encode("welcome", forKey: .type)
            try c.encode(device, forKey: .device)
            try c.encode(contract, forKey: .contract)
        case let .refused(reason, contracts):
            try c.encode("refused", forKey: .type)
            try c.encode(reason, forKey: .reason)
            try c.encode(contracts, forKey: .contracts)
        case let .order(o):
            try c.encode("order", forKey: .type)
            try c.encode(o, forKey: .order)
        case let .update(version):
            try c.encode("update", forKey: .type)
            try c.encode(version, forKey: .version)
        }
    }
}

/// The hub writes one record for each runner device, on each hello and close. Contract: runner.json.
public struct RunnerState: StoreRecord {
    public static let collection = "runners"

    public var device: String
    public var version: String
    public var contract: Int
    public var runtimes: [ProviderID]
    public var os: String?
    public var allow: RunnerMessage.AllowSummary?
    public var online: Bool
    public var lastSeen: Date

    public init(device: String, version: String, contract: Int, runtimes: [ProviderID], os: String? = nil,
                allow: RunnerMessage.AllowSummary? = nil, online: Bool, lastSeen: Date) {
        self.device = device
        self.version = version
        self.contract = contract
        self.runtimes = runtimes
        self.os = os
        self.allow = allow
        self.online = online
        self.lastSeen = lastSeen
    }

    public var id: String { device }
}
