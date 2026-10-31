import Foundation

public enum AccountType: String, Codable, CaseIterable, Sendable {
    case current, savings, creditCard, wallet, prepaid, cash
}

public enum Institution: String, Codable, CaseIterable, Sendable {
    case snb, barq, d360, applePayCash, cash, other

    public var displayName: String {
        switch self {
        case .snb: return "البنك الأهلي SNB"
        case .barq: return "Barq"
        case .d360: return "D360"
        case .applePayCash: return "Apple Cash"
        case .cash: return "نقد"
        case .other: return "أخرى"
        }
    }
}

/// A user-owned account, card or wallet.
public struct Account: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var institution: Institution
    public var customInstitutionName: String?
    public var type: AccountType
    public var currency: String
    /// Last 4 digits of cards linked to this account (mada, Visa, virtual cards).
    public var cardLast4: [String]
    /// Last 4 digits of the account number / IBAN. Used to detect internal transfers.
    public var accountLast4: [String]
    /// Card names as shown in Apple Wallet (used by the Wallet "Transaction" Shortcut automation).
    public var walletCardNames: [String]
    /// SMS sender IDs that belong to this institution.
    public var smsSenders: [String]
    /// When false, this account's own transactions are not fed into the app (e.g. a credit card
    /// whose purchases are not imported). Affects how settlement payments are counted.
    public var isTracked: Bool
    public var lowBalanceThreshold: Decimal?
    public var isArchived: Bool

    public init(id: UUID = UUID(), name: String, institution: Institution, customInstitutionName: String? = nil,
                type: AccountType, currency: String = "SAR", cardLast4: [String] = [], accountLast4: [String] = [],
                walletCardNames: [String] = [], smsSenders: [String] = [], isTracked: Bool = true,
                lowBalanceThreshold: Decimal? = nil, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.institution = institution
        self.customInstitutionName = customInstitutionName
        self.type = type
        self.currency = currency
        self.cardLast4 = cardLast4
        self.accountLast4 = accountLast4
        self.walletCardNames = walletCardNames
        self.smsSenders = smsSenders
        self.isTracked = isTracked
        self.lowBalanceThreshold = lowBalanceThreshold
        self.isArchived = isArchived
    }
}

/// A balance reported by a source at a point in time.
public struct BalanceSnapshot: Codable, Hashable, Sendable {
    public var accountID: UUID
    public var balance: Decimal
    public var currency: String
    public var date: Date
    public var source: SourceType

    public init(accountID: UUID, balance: Decimal, currency: String, date: Date, source: SourceType) {
        self.accountID = accountID
        self.balance = balance
        self.currency = currency
        self.date = date
        self.source = source
    }
}
