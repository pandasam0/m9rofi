import Foundation

public struct Budget: Codable, Hashable, Sendable, Identifiable {
    public var id: Category { category }
    public var category: Category
    /// Monthly limit in SAR.
    public var monthlyLimit: Decimal
    public init(category: Category, monthlyLimit: Decimal) {
        self.category = category
        self.monthlyLimit = monthlyLimit
    }
}

/// A rule learned from a user correction: merchant key → category.
public struct CategoryRule: Codable, Hashable, Sendable {
    public var merchantKey: String
    public var category: Category
    public var createdAt: Date
    public init(merchantKey: String, category: Category, createdAt: Date = Date()) {
        self.merchantKey = merchantKey
        self.category = category
        self.createdAt = createdAt
    }
}

public struct LedgerSettings: Codable, Hashable, Sendable {
    public var baseCurrency: String = "SAR"
    public var timeZoneID: String = "Asia/Riyadh"
    /// 1 = Sunday (Saudi work week).
    public var firstWeekday: Int = 1
    /// Outgoing transfers to third parties count as spending (category "transfers").
    public var countExternalTransfersAsSpending: Bool = true
    /// ATM withdrawals count as spending. Default false: withdrawal is a move to cash;
    /// actual cash spending is recorded manually against the Cash account.
    public var cashWithdrawalsAsSpending: Bool = false
    /// Owner name variants (e.g. as printed on transfers) used to flag self-transfers.
    public var ownerNames: [String] = []
    public var staleAccountDays: Int = 7
    public var upcomingChargeNoticeDays: Int = 2
    public var budgetThresholds: [Int] = [50, 75, 90, 100]
    /// Day of month the salary usually arrives (used for "remaining salary" when detection fails).
    public var salaryDay: Int?
    public var faceIDEnabled: Bool = true
    public var notifyNewExpense: Bool = true

    public init() {}

    // Tolerant decoding: new settings added in later versions fall back to defaults.
    enum CodingKeys: String, CodingKey {
        case baseCurrency, timeZoneID, firstWeekday, countExternalTransfersAsSpending, cashWithdrawalsAsSpending, ownerNames,
             staleAccountDays, upcomingChargeNoticeDays, budgetThresholds, salaryDay, faceIDEnabled, notifyNewExpense
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LedgerSettings()
        baseCurrency = try c.decodeIfPresent(String.self, forKey: .baseCurrency) ?? d.baseCurrency
        timeZoneID = try c.decodeIfPresent(String.self, forKey: .timeZoneID) ?? d.timeZoneID
        firstWeekday = try c.decodeIfPresent(Int.self, forKey: .firstWeekday) ?? d.firstWeekday
        countExternalTransfersAsSpending = try c.decodeIfPresent(Bool.self, forKey: .countExternalTransfersAsSpending) ?? d.countExternalTransfersAsSpending
        cashWithdrawalsAsSpending = try c.decodeIfPresent(Bool.self, forKey: .cashWithdrawalsAsSpending) ?? d.cashWithdrawalsAsSpending
        ownerNames = try c.decodeIfPresent([String].self, forKey: .ownerNames) ?? d.ownerNames
        staleAccountDays = try c.decodeIfPresent(Int.self, forKey: .staleAccountDays) ?? d.staleAccountDays
        upcomingChargeNoticeDays = try c.decodeIfPresent(Int.self, forKey: .upcomingChargeNoticeDays) ?? d.upcomingChargeNoticeDays
        budgetThresholds = try c.decodeIfPresent([Int].self, forKey: .budgetThresholds) ?? d.budgetThresholds
        salaryDay = try c.decodeIfPresent(Int.self, forKey: .salaryDay)
        faceIDEnabled = try c.decodeIfPresent(Bool.self, forKey: .faceIDEnabled) ?? d.faceIDEnabled
        notifyNewExpense = try c.decodeIfPresent(Bool.self, forKey: .notifyNewExpense) ?? d.notifyNewExpense
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 3 * 3600)! }

    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = firstWeekday
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }
}

/// Entire persisted state. Encrypted at rest by the app layer.
public struct LedgerState: Codable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int = LedgerState.schemaVersion
    public var accounts: [Account] = []
    public var transactions: [Transaction] = []
    public var balances: [BalanceSnapshot] = []
    public var budgets: [Budget] = []
    public var categoryRules: [CategoryRule] = []
    public var settings = LedgerSettings()
    /// Keys of alerts already delivered (prevents repeated notifications).
    public var firedAlertKeys: Set<String> = []
    /// Source record IDs already seen (exact-duplicate guard, survives transaction deletion).
    public var seenSourceRecordIDs: Set<String> = []
    /// SMS/notifications ignored by the parser (OTP, declined, promos) — kept for audit, capped.
    public var ignoredLog: [IgnoredRecord] = []
    /// User-defined SMS formats per bank.
    public var smsTemplates: [SMSTemplate] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, accounts, transactions, balances, budgets, categoryRules, settings, firedAlertKeys,
             seenSourceRecordIDs, ignoredLog, smsTemplates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        transactions = try c.decodeIfPresent([Transaction].self, forKey: .transactions) ?? []
        balances = try c.decodeIfPresent([BalanceSnapshot].self, forKey: .balances) ?? []
        budgets = try c.decodeIfPresent([Budget].self, forKey: .budgets) ?? []
        categoryRules = try c.decodeIfPresent([CategoryRule].self, forKey: .categoryRules) ?? []
        settings = try c.decodeIfPresent(LedgerSettings.self, forKey: .settings) ?? LedgerSettings()
        firedAlertKeys = try c.decodeIfPresent(Set<String>.self, forKey: .firedAlertKeys) ?? []
        seenSourceRecordIDs = try c.decodeIfPresent(Set<String>.self, forKey: .seenSourceRecordIDs) ?? []
        ignoredLog = try c.decodeIfPresent([IgnoredRecord].self, forKey: .ignoredLog) ?? []
        smsTemplates = try c.decodeIfPresent([SMSTemplate].self, forKey: .smsTemplates) ?? []
    }

    public func account(_ id: UUID?) -> Account? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    public func latestBalance(for accountID: UUID) -> BalanceSnapshot? {
        balances.filter { $0.accountID == accountID }.max { $0.date < $1.date }
    }
}

public struct IgnoredRecord: Codable, Hashable, Sendable {
    public var date: Date
    public var source: SourceType
    public var reason: String
    public var preview: String
    public init(date: Date, source: SourceType, reason: String, preview: String) {
        self.date = date
        self.source = source
        self.reason = reason
        self.preview = preview
    }
}
