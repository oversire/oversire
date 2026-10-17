import Foundation

// ─── Cloud billing ───────────────────────────────────────────────────────────
// The hub writes these records. The app only reads them. Money is an integer in micro-USD.
// The JSON form is in Contract/schema/billing.json.

/// One model call. It is the audit log of the cloud AI.
public struct UsageRow: StoreRecord {
    public static let collection = "usage"

    public let id: String
    public let at: Date
    public let jobRun: String
    public let taskKind: String
    public let endpoint: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int
    public let costMicroUSD: Int

    public init(id: String, at: Date, jobRun: String, taskKind: String, endpoint: String, model: String,
                inputTokens: Int, outputTokens: Int, cachedTokens: Int, costMicroUSD: Int) {
        self.id = id
        self.at = at
        self.jobRun = jobRun
        self.taskKind = taskKind
        self.endpoint = endpoint
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.costMicroUSD = costMicroUSD
    }
}

/// Append only. A grant or a top-up is positive, usage is negative.
public struct LedgerEntry: StoreRecord {
    public static let collection = "ledger"

    public enum Kind: String, Codable, Sendable, CaseIterable { case grant, topup, usage, refund, adjust }

    public let id: String
    public let at: Date
    public let kind: Kind
    public let amountMicroUSD: Int
    public let ref: String?              // UsageRow id or Stripe event id
    public let note: String?

    public init(id: String, at: Date, kind: Kind, amountMicroUSD: Int, ref: String? = nil, note: String? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.amountMicroUSD = amountMicroUSD
        self.ref = ref
        self.note = note
    }
}

/// The hub computes it from the ledger. One record with the id "state".
public struct BillingState: StoreRecord {
    public static let collection = "billing"

    public struct AutoTopUp: Hashable, Sendable, Codable {
        public var amountMicroUSD: Int
        public var thresholdMicroUSD: Int

        public init(amountMicroUSD: Int, thresholdMicroUSD: Int) {
            self.amountMicroUSD = amountMicroUSD
            self.thresholdMicroUSD = thresholdMicroUSD
        }
    }

    public var plan: String
    public var periodStart: Date
    public var periodEnd: Date
    public var grantMicroUSD: Int
    public var grantUsedMicroUSD: Int
    public var balanceMicroUSD: Int
    public var dailyCapMicroUSD: Int
    public var autoTopUp: AutoTopUp?
    public var notice80Sent: Bool

    public init(plan: String, periodStart: Date, periodEnd: Date, grantMicroUSD: Int, grantUsedMicroUSD: Int = 0,
                balanceMicroUSD: Int = 0, dailyCapMicroUSD: Int, autoTopUp: AutoTopUp? = nil, notice80Sent: Bool = false) {
        self.plan = plan
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.grantMicroUSD = grantMicroUSD
        self.grantUsedMicroUSD = grantUsedMicroUSD
        self.balanceMicroUSD = balanceMicroUSD
        self.dailyCapMicroUSD = dailyCapMicroUSD
        self.autoTopUp = autoTopUp
        self.notice80Sent = notice80Sent
    }

    public var id: String { "state" }
    public var grantLeftMicroUSD: Int { max(0, grantMicroUSD - grantUsedMicroUSD) }
}
