import Foundation

public enum Direction: String, Codable, Sendable { case debit, credit }

/// Economic nature of a transaction. Determines how it affects totals (see `LedgerEffect`).
public enum TransactionKind: String, Codable, CaseIterable, Sendable {
    case purchase          // POS / online / Apple Pay purchase
    case billPayment       // SADAD / utility bill
    case fee               // bank fee, VAT on fee
    case transferOut       // outgoing transfer (internal or external — resolved by TransferMatcher)
    case transferIn        // incoming transfer (internal or external)
    case income            // salary or explicit income
    case refund            // merchant refund
    case reversal          // bank reversal/cancellation of an earlier transaction
    case cardPayment       // payment towards a credit card balance
    case cashWithdrawal    // ATM withdrawal
    case cashDeposit       // cash deposit
    case unknown
}

public enum TransactionStatus: String, Codable, Sendable {
    case pending      // معلقة — authorised, not posted
    case completed    // مكتملة
    case reversed     // ملغاة / معكوسة — excluded from totals
    case refunded     // مستردة بالكامل — original purchase fully refunded (refund itself carries the credit)
}

public enum SourceType: String, Codable, CaseIterable, Sendable {
    case manual, sms, walletAutomation, statementCSV, statementPDF, statementExcel, email, openBanking, financeKit
}

public struct SourceRef: Codable, Hashable, Sendable {
    public var type: SourceType
    /// Stable ID within the source (bank reference, OB TransactionId, hash of SMS text).
    public var recordID: String
    public var importedAt: Date

    public init(type: SourceType, recordID: String, importedAt: Date) {
        self.type = type
        self.recordID = recordID
        self.importedAt = importedAt
    }
}

public enum CategorySource: String, Codable, Sendable {
    case user, learnedRule, merchantDictionary, mcc, keyword, ai, kindDefault, none
}

public enum ReviewReason: String, Codable, Sendable, CaseIterable {
    case missingAmount
    case unknownDirection
    case missingBaseCurrencyAmount     // foreign currency, SAR charge unknown
    case possibleDuplicate
    case unmatchedReversal
    case cardPaymentUntrackedCard
    case possibleInternalTransfer
    case lowParseConfidence
    case unknownAccount

    public var arabicDescription: String {
        switch self {
        case .missingAmount: return "المبلغ غير واضح"
        case .unknownDirection: return "لا يُعرف إن كانت العملية خصماً أم إيداعاً"
        case .missingBaseCurrencyAmount: return "عملية بعملة أجنبية دون مبلغ الخصم بالريال"
        case .possibleDuplicate: return "قد تكون مكررة"
        case .unmatchedReversal: return "إلغاء/عكس لم تُعرف عمليته الأصلية"
        case .cardPaymentUntrackedCard: return "سداد بطاقة ائتمانية غير مرتبطة بالتطبيق"
        case .possibleInternalTransfer: return "قد يكون تحويلاً بين حساباتك"
        case .lowParseConfidence: return "بيانات المصدر غير مكتملة"
        case .unknownAccount: return "الحساب غير معروف"
        }
    }
}

public struct GeoPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

public struct Transaction: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Always positive. Sign comes from `direction`.
    public var amount: Decimal
    public var currency: String
    /// Amount in base currency (SAR) actually debited/credited. Required for totals.
    public var baseAmount: Decimal?
    public var direction: Direction
    public var kind: TransactionKind
    public var status: TransactionStatus
    public var date: Date
    /// False when the source only provided a date (statements). Affects duplicate matching windows.
    public var hasTime: Bool
    public var merchantRaw: String?
    /// Normalised merchant key used for learning and grouping.
    public var merchantKey: String?
    public var merchantDisplay: String?
    public var counterparty: String?
    public var accountID: UUID?
    public var cardLast4: String?
    public var accountLast4: String?
    public var counterpartyAccountLast4: String?
    public var category: Category
    public var categorySource: CategorySource
    public var categoryConfidence: Double
    public var mcc: String?
    public var location: GeoPoint?
    public var city: String?
    public var reference: String?
    public var note: String?
    public var sources: [SourceRef]
    /// Transfer counterpart, refund → original purchase, reversal → original.
    public var linkedTransactionID: UUID?
    public var isInternalTransfer: Bool
    public var reviewReasons: [ReviewReason]
    public var balanceAfter: Decimal?
    public var userExcluded: Bool
    public var createdAt: Date

    public var needsReview: Bool { !reviewReasons.isEmpty }

    public init(id: UUID = UUID(), amount: Decimal, currency: String = "SAR", baseAmount: Decimal? = nil,
                direction: Direction, kind: TransactionKind, status: TransactionStatus = .completed,
                date: Date, hasTime: Bool = true, merchantRaw: String? = nil, merchantKey: String? = nil,
                merchantDisplay: String? = nil, counterparty: String? = nil, accountID: UUID? = nil,
                cardLast4: String? = nil, accountLast4: String? = nil, counterpartyAccountLast4: String? = nil,
                category: Category = .other, categorySource: CategorySource = .none, categoryConfidence: Double = 0,
                mcc: String? = nil, location: GeoPoint? = nil, city: String? = nil, reference: String? = nil,
                note: String? = nil, sources: [SourceRef] = [], linkedTransactionID: UUID? = nil,
                isInternalTransfer: Bool = false, reviewReasons: [ReviewReason] = [], balanceAfter: Decimal? = nil,
                userExcluded: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.amount = amount
        self.currency = currency
        self.baseAmount = baseAmount ?? (currency == "SAR" ? amount : nil)
        self.direction = direction
        self.kind = kind
        self.status = status
        self.date = date
        self.hasTime = hasTime
        self.merchantRaw = merchantRaw
        self.merchantKey = merchantKey
        self.merchantDisplay = merchantDisplay
        self.counterparty = counterparty
        self.accountID = accountID
        self.cardLast4 = cardLast4
        self.accountLast4 = accountLast4
        self.counterpartyAccountLast4 = counterpartyAccountLast4
        self.category = category
        self.categorySource = categorySource
        self.categoryConfidence = categoryConfidence
        self.mcc = mcc
        self.location = location
        self.city = city
        self.reference = reference
        self.note = note
        self.sources = sources
        self.linkedTransactionID = linkedTransactionID
        self.isInternalTransfer = isInternalTransfer
        self.reviewReasons = reviewReasons
        self.balanceAfter = balanceAfter
        self.userExcluded = userExcluded
        self.createdAt = createdAt
    }

    public var displayName: String {
        merchantDisplay ?? merchantRaw ?? counterparty ?? category.arabicName
    }
}
