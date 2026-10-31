import Foundation

/// Source-agnostic candidate transaction produced by any adapter (SMS, statement, wallet, email, open banking).
/// Adapters only extract facts; they never decide totals. The `Ledger` pipeline normalises, de-duplicates,
/// matches transfers and categorises.
public struct RawRecord: Sendable, Hashable {
    public var source: SourceType
    /// Stable identifier inside the source. Used for exact de-duplication.
    public var sourceRecordID: String
    public var amount: Decimal?
    public var currency: String?
    /// SAR amount actually charged when `currency` is foreign.
    public var baseAmount: Decimal?
    public var direction: Direction?
    public var kind: TransactionKind
    public var status: TransactionStatus
    public var date: Date?
    public var hasTime: Bool
    public var merchant: String?
    public var counterparty: String?
    public var cardLast4: String?
    public var accountLast4: String?
    public var counterpartyAccountLast4: String?
    public var balanceAfter: Decimal?
    public var reference: String?
    public var mcc: String?
    public var city: String?
    public var location: GeoPoint?
    /// Explicit account (manual entry, statement import bound to an account, OB account).
    public var accountID: UUID?
    /// Sender / institution hint (SMS sender ID, wallet card name).
    public var institutionHint: String?
    public var walletCardName: String?
    public var categoryHint: Category?
    public var note: String?
    /// 0…1 — how complete the extraction was.
    public var confidence: Double

    public init(source: SourceType, sourceRecordID: String, amount: Decimal? = nil, currency: String? = nil,
                baseAmount: Decimal? = nil, direction: Direction? = nil, kind: TransactionKind = .unknown,
                status: TransactionStatus = .completed, date: Date? = nil, hasTime: Bool = false,
                merchant: String? = nil, counterparty: String? = nil, cardLast4: String? = nil,
                accountLast4: String? = nil, counterpartyAccountLast4: String? = nil, balanceAfter: Decimal? = nil,
                reference: String? = nil, mcc: String? = nil, city: String? = nil, location: GeoPoint? = nil,
                accountID: UUID? = nil, institutionHint: String? = nil, walletCardName: String? = nil,
                categoryHint: Category? = nil, note: String? = nil, confidence: Double = 1) {
        self.source = source
        self.sourceRecordID = sourceRecordID
        self.amount = amount
        self.currency = currency
        self.baseAmount = baseAmount
        self.direction = direction
        self.kind = kind
        self.status = status
        self.date = date
        self.hasTime = hasTime
        self.merchant = merchant
        self.counterparty = counterparty
        self.cardLast4 = cardLast4
        self.accountLast4 = accountLast4
        self.counterpartyAccountLast4 = counterpartyAccountLast4
        self.balanceAfter = balanceAfter
        self.reference = reference
        self.mcc = mcc
        self.city = city
        self.location = location
        self.accountID = accountID
        self.institutionHint = institutionHint
        self.walletCardName = walletCardName
        self.categoryHint = categoryHint
        self.note = note
        self.confidence = confidence
    }
}

public enum ParseOutcome: Sendable, Hashable {
    case record(RawRecord)
    /// Message is not a financial transaction (OTP, declined, marketing, balance-only).
    case ignored(reason: String)
    /// Balance-only notification.
    case balance(accountLast4: String?, cardLast4: String?, balance: Decimal, currency: String, date: Date, institutionHint: String?)
    case unparseable
}
