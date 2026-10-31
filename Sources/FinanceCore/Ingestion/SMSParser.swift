import Foundation

/// User-defined template for a specific bank message format. Takes priority over the generic parser.
/// Named groups supported: amount, currency, merchant, card, account, date, balance, counterparty.
public struct SMSTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Sender IDs this template applies to (case-insensitive). Empty = any sender.
    public var senders: [String]
    public var pattern: String
    public var kind: TransactionKind
    public var direction: Direction

    public init(id: UUID = UUID(), name: String, senders: [String], pattern: String, kind: TransactionKind, direction: Direction) {
        self.id = id
        self.name = name
        self.senders = senders
        self.pattern = pattern
        self.kind = kind
        self.direction = direction
    }
}

/// Generic Arabic/English bank SMS & notification parser.
///
/// iOS does not allow apps to read SMS. Text reaches this parser through:
///  - Shortcuts personal automation "Message" trigger → `Log Bank Message` App Intent
///  - Manual paste / share sheet
/// Formats differ per bank and change over time. Unknown formats return low confidence and go to review
/// rather than being guessed.
public struct SMSParser: Sendable {
    public var timeZone: TimeZone
    public var templates: [SMSTemplate]

    public init(timeZone: TimeZone = TimeZone(identifier: "Asia/Riyadh")!, templates: [SMSTemplate] = []) {
        self.timeZone = timeZone
        self.templates = templates
    }

    // MARK: Keyword tables (lowercased, digits normalised)

    static let otpWords = ["رمز التحقق", "رمز التفعيل", "كلمة المرور لمرة واحدة", "otp", "verification code",
                           "one time password", "one-time password", "لا تشارك", "do not share", "رمز الدخول", "passcode"]
    static let declinedWords = ["مرفوضة", "مرفوض", "تم رفض", "رفض العملية", "declined", "rejected", "insufficient",
                                "رصيد غير كاف", "الرصيد غير كاف", "فشلت", "failed", "غير ناجحة", "unsuccessful"]
    static let promoWords = ["عرض خاص", "احصل على", "offer", "promo", "cashback offer", "تمويل شخصي", "سجل الآن", "قسّط"]

    static let kindRules: [(TransactionKind, [String])] = [
        (.reversal, ["عكس", "معكوسة", "reversal", "reversed", "إلغاء العملية", "الغاء العملية", "ملغاة", "cancelled", "canceled", "void"]),
        (.refund, ["استرداد", "مسترد", "استرجاع", "refund", "refunded", "merchant credit"]),
        (.cardPayment, ["سداد بطاقة", "سداد البطاقة", "سداد مستحقات البطاقة", "credit card payment", "card payment received", "payment to card", "سداد الائتمانية"]),
        (.income, ["راتب", "الراتب", "salary", "payroll", "رواتب"]),
        (.cashWithdrawal, ["سحب نقدي", "سحب صراف", "صراف آلي", "سحب من الصراف", "atm withdrawal", "cash withdrawal", "atm"]),
        (.cashDeposit, ["إيداع نقدي", "ايداع نقدي", "cash deposit"]),
        (.transferIn, ["حوالة واردة", "تحويل وارد", "حوالة محلية واردة", "حوالة دولية واردة", "incoming transfer", "transfer received",
                       "received a transfer", "inward transfer", "إيداع حوالة", "ايداع حوالة", "استلام حوالة"]),
        (.transferOut, ["حوالة صادرة", "تحويل صادر", "حوالة محلية صادرة", "حوالة دولية", "outgoing transfer", "outward transfer",
                        "transfer to", "تحويل إلى", "تحويل الى", "حوالة إلى", "حوالة الى", "حوالة داخلية", "حوالة فورية", "sarie", "سريع", "transfer sent"]),
        (.billPayment, ["سداد فاتورة", "سداد فواتير", "سداد", "sadad", "bill payment", "فاتورة", "مدفوعات حكومية", "government payment"]),
        (.fee, ["رسوم", "عمولة", "fee", "charges", "commission"]),
        (.purchase, ["شراء", "purchase", "pos", "نقاط البيع", "مدى", "mada", "apple pay", "ابل باي", "أبل باي", "online", "عبر الإنترنت",
                     "عبر الانترنت", "e-commerce", "دفع", "payment at", "spent", "مشتريات"])
    ]

    static let debitWords = ["خصم", "مدين", "debited", "debit", "deducted", "spent", "سحب", "صادرة", "دفع"]
    static let creditWords = ["إيداع", "ايداع", "دائن", "credited", "credit", "أضيف", "اضافة", "إضافة", "واردة", "received", "deposited"]
    static let pendingWords = ["معلقة", "معلق", "قيد المعالجة", "قيد التنفيذ", "pending", "pre-auth", "preauth", "authorization hold", "حجز مبلغ", "محجوز"]

    static let currencyAliases: [String: String] = [
        "sar": "SAR", "sr": "SAR", "ر.س": "SAR", "ر س": "SAR", "رس": "SAR", "ريال": "SAR", "ريال سعودي": "SAR", "rs": "SAR",
        "usd": "USD", "$": "USD", "دولار": "USD", "eur": "EUR", "€": "EUR", "يورو": "EUR", "gbp": "GBP", "£": "GBP",
        "aed": "AED", "درهم": "AED", "kwd": "KWD", "bhd": "BHD", "qar": "QAR", "omr": "OMR", "egp": "EGP", "try": "TRY",
        "jod": "JOD", "inr": "INR", "jpy": "JPY", "cny": "CNY"
    ]

    static let balanceLabels = ["الرصيد", "رصيد", "balance", "bal", "avail", "المتاح", "available"]
    static let feeLabels = ["رسوم", "fee", "عمولة", "vat", "ضريبة"]
    static let merchantLabels = ["لدى:", "لدى", "عند:", "عند", "التاجر:", "التاجر", "merchant:", "merchant", "at:", " at ", "من:", "from:", "في متجر", "المتجر:", "من "]
    static let counterpartyOutLabels = ["إلى:", "الى:", "إلى", "الى", "to:", " to ", "المستفيد:", "المستفيد", "beneficiary:", "beneficiary", "لصالح"]
    static let counterpartyInLabels = ["من:", "from:", "المرسل:", "المرسل", "sender:", "by:", " from "]

    // MARK: Parse

    public func parse(text: String, sender: String? = nil, receivedAt: Date) -> ParseOutcome {
        let normalized = TextNormalizer.normalizeDigits(text)
        let lower = normalized.lowercased()
        guard lower.contains(where: { $0.isNumber }) else { return .ignored(reason: "no numbers") }

        if Self.has(lower, Self.otpWords) { return .ignored(reason: "otp") }
        if Self.has(lower, Self.declinedWords) { return .ignored(reason: "declined") }
        if Self.has(lower, Self.promoWords) && Self.moneyMatches(in: normalized).isEmpty {
            return .ignored(reason: "promotion")
        }

        let recordID = "sms:" + Hashing.fnv1a(normalized.trimmingCharacters(in: .whitespacesAndNewlines))

        if let r = applyTemplates(normalized, sender: sender, receivedAt: receivedAt, recordID: recordID) {
            return .record(r)
        }

        // Kind
        var kind: TransactionKind = .unknown
        for (k, words) in Self.kindRules where Self.has(lower, words) {
            kind = k
            break
        }
        // Both "incoming" and "outgoing" transfer phrases present → resolve by debit/credit verbs.
        if kind == .transferIn || kind == .transferOut {
            let inHit = Self.has(lower, Self.kindRules.first { $0.0 == .transferIn }!.1)
            let outHit = Self.has(lower, Self.kindRules.first { $0.0 == .transferOut }!.1)
            if inHit && outHit {
                let d = Self.has(lower, Self.debitWords), c = Self.has(lower, Self.creditWords)
                kind = (d && !c) ? .transferOut : (c && !d) ? .transferIn : .unknown
            }
        }
        // "سحب" alone near "صراف" handled above; generic "حوالة"/"transfer" without direction:
        if kind == .unknown, lower.contains("حوالة") || lower.contains("تحويل") || lower.contains("transfer") {
            kind = Self.has(lower, Self.creditWords) ? .transferIn : .transferOut
        }

        // Money
        let money = Self.moneyMatches(in: normalized)
        var amount: Decimal?, currency: String?, baseAmount: Decimal?, balance: Decimal?, balanceCurrency: String?
        for m in money {
            let end = normalized.index(normalized.startIndex, offsetBy: m.offset)
            let start = normalized.index(end, offsetBy: -min(28, m.offset))
            let before = normalized[start..<end].lowercased()
            if Self.balanceLabels.contains(where: before.contains) && !before.contains("مبلغ") && !before.contains("amount") {
                if balance == nil { balance = m.value; balanceCurrency = m.currency }
                continue
            }
            if Self.feeLabels.contains(where: before.contains), amount != nil { continue }
            if amount == nil {
                amount = m.value; currency = m.currency
            } else if baseAmount == nil, currency != nil, currency != "SAR", m.currency == "SAR" {
                baseAmount = m.value
            }
        }
        var confidence = 1.0
        if currency == nil, amount != nil {
            // No currency token at all. Domestic Saudi bank messages default to SAR.
            currency = "SAR"; confidence -= 0.2
        }

        if kind == .unknown && amount == nil {
            if let balance {
                let (acc, card) = (Self.capture(Self.accountRegex, in: normalized), Self.capture(Self.cardRegex, in: normalized))
                let date = DateParser(timeZone: timeZone).parse(normalized)?.0 ?? receivedAt
                return .balance(accountLast4: acc, cardLast4: card, balance: balance, currency: balanceCurrency ?? "SAR",
                                date: date, institutionHint: sender)
            }
            return .unparseable
        }

        // Direction
        var direction: Direction?
        switch kind {
        case .purchase, .billPayment, .fee, .transferOut, .cardPayment, .cashWithdrawal: direction = .debit
        case .transferIn, .income, .refund, .cashDeposit: direction = .credit
        case .reversal, .unknown:
            let d = Self.has(lower, Self.debitWords), c = Self.has(lower, Self.creditWords)
            if d != c { direction = d ? .debit : .credit }
            else if kind == .reversal { direction = .credit }
        }
        // A card payment message from the card issuer side is a credit to the card account.
        if kind == .cardPayment, Self.has(lower, Self.creditWords), !Self.has(lower, Self.debitWords) {
            direction = .credit
        }
        if kind == .unknown { confidence -= 0.4 }

        let status: TransactionStatus = Self.has(lower, Self.pendingWords) ? .pending : .completed
        // Authorisation holds ("حجز مبلغ") are card debits even without a purchase verb.
        if kind == .unknown && status == .pending && direction == nil {
            kind = .purchase; direction = .debit; confidence += 0.4
        }

        // Parties
        var merchant: String?, counterparty: String?
        switch kind {
        case .transferOut:
            counterparty = Self.labelledValue(in: normalized, labels: Self.counterpartyOutLabels)
        case .transferIn, .income:
            counterparty = Self.labelledValue(in: normalized, labels: Self.counterpartyInLabels)
        default:
            merchant = Self.labelledValue(in: normalized, labels: Self.merchantLabels)
        }
        if kind == .purchase && merchant == nil { confidence -= 0.2 }

        let card = Self.capture(Self.cardRegex, in: normalized)
        let account = Self.capture(Self.accountRegex, in: normalized) ?? Self.capture(Self.accountLineRegex, in: normalized)
        let cpAccount = Self.counterpartyAccount(in: normalized)
        let reference = Self.capture(Self.referenceRegex, in: normalized)

        var date = receivedAt, hasTime = true
        if let parsed = DateParser(timeZone: timeZone).parse(normalized) {
            (date, hasTime) = parsed
        }

        return .record(RawRecord(
            source: .sms, sourceRecordID: recordID, amount: amount, currency: currency, baseAmount: baseAmount,
            direction: direction, kind: kind, status: status, date: date, hasTime: hasTime,
            merchant: merchant, counterparty: counterparty, cardLast4: card, accountLast4: account,
            counterpartyAccountLast4: cpAccount, balanceAfter: balance, reference: reference,
            institutionHint: sender, confidence: max(0, confidence)))
    }

    // MARK: Templates

    private func applyTemplates(_ text: String, sender: String?, receivedAt: Date, recordID: String) -> RawRecord? {
        for t in templates {
            if !t.senders.isEmpty {
                guard let sender, t.senders.contains(where: { $0.caseInsensitiveCompare(sender) == .orderedSame }) else { continue }
            }
            guard let re = try? NSRegularExpression(pattern: t.pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func g(_ name: String) -> String? {
                let r = m.range(withName: name)
                guard r.location != NSNotFound, let rr = Range(r, in: text) else { return nil }
                let v = text[rr].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            guard let amountStr = g("amount"), let amount = TextNormalizer.parseAmount(amountStr) else { continue }
            let currency = g("currency").flatMap { Self.currencyAliases[$0.lowercased()] } ?? "SAR"
            let parsedDate = g("date").flatMap { DateParser(timeZone: timeZone).parse($0) }
            return RawRecord(source: .sms, sourceRecordID: recordID, amount: amount, currency: currency,
                             direction: t.direction, kind: t.kind,
                             status: Self.has(text.lowercased(), Self.pendingWords) ? .pending : .completed,
                             date: parsedDate?.0 ?? receivedAt, hasTime: parsedDate?.1 ?? true,
                             merchant: g("merchant"), counterparty: g("counterparty"), cardLast4: g("card").map { String($0.suffix(4)) },
                             accountLast4: g("account").map { String($0.suffix(4)) },
                             balanceAfter: g("balance").flatMap(TextNormalizer.parseAmount), institutionHint: sender, confidence: 1)
        }
        return nil
    }

    // MARK: Helpers

    /// Keyword test. Short Latin keywords require word boundaries ("atm" must not match "treatment").
    static func has(_ lower: String, _ words: [String]) -> Bool {
        for w in words {
            if w.allSatisfy({ $0.isASCII && $0.isLetter }) && w.count <= 6 {
                if let re = boundaryCache[w] ?? (try? NSRegularExpression(pattern: "\\b" + w + "\\b")),
                   re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil { return true }
            } else if lower.contains(w) {
                return true
            }
        }
        return false
    }
    static let boundaryCache: [String: NSRegularExpression] = {
        var c: [String: NSRegularExpression] = [:]
        let all = otpWords + declinedWords + promoWords + debitWords + creditWords + pendingWords + kindRules.flatMap { $0.1 }
        for w in all where w.allSatisfy({ $0.isASCII && $0.isLetter }) && w.count <= 6 {
            c[w] = try? NSRegularExpression(pattern: "\\b" + w + "\\b")
        }
        return c
    }()

    struct MoneyMatch { let value: Decimal; let currency: String?; let offset: Int }

    static let currencyTokenPattern: String = {
        let tokens = currencyAliases.keys.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }
        return "(" + tokens.joined(separator: "|") + ")"
    }()
    static let numberPattern = #"(\d{1,3}(?:,\d{3})+(?:\.\d{1,3})?|\d+(?:\.\d{1,3})?)"#
    static let moneyBefore = try! NSRegularExpression(pattern: currencyTokenPattern + #"\s*[:.]?\s*"# + numberPattern, options: [.caseInsensitive])
    static let moneyAfter = try! NSRegularExpression(pattern: numberPattern + #"\s*"# + currencyTokenPattern + #"(?![a-z])"#, options: [.caseInsensitive])
    static let labelledAmount = try! NSRegularExpression(pattern: #"(?:مبلغ|بمبلغ|بقيمة|المبلغ|amount|amt)\s*[:：]?\s*"# + numberPattern, options: [.caseInsensitive])

    /// All money amounts in the text, ordered by position. Character offsets (not UTF-16).
    static func moneyMatches(in text: String) -> [MoneyMatch] {
        var results: [(Range<String.Index>, MoneyMatch)] = []
        let ns = NSRange(text.startIndex..., in: text)
        func add(_ range: Range<String.Index>, _ numStr: Substring, _ cur: Substring?) {
            guard let v = TextNormalizer.parseAmount(String(numStr)) else { return }
            if results.contains(where: { $0.0.overlaps(range) }) { return }
            // Ignore numbers that are clearly years / card digits without currency
            let currency = cur.flatMap { currencyAliases[$0.lowercased()] }
            results.append((range, MoneyMatch(value: v, currency: currency, offset: text.distance(from: text.startIndex, to: range.lowerBound))))
        }
        for m in moneyBefore.matches(in: text, range: ns) {
            guard let r = Range(m.range, in: text), let c = Range(m.range(at: 1), in: text), let n = Range(m.range(at: 2), in: text) else { continue }
            add(r, text[n], text[c])
        }
        for m in moneyAfter.matches(in: text, range: ns) {
            guard let r = Range(m.range, in: text), let n = Range(m.range(at: 1), in: text), let c = Range(m.range(at: 2), in: text) else { continue }
            add(r, text[n], text[c])
        }
        for m in labelledAmount.matches(in: text, range: ns) {
            guard let r = Range(m.range, in: text), let n = Range(m.range(at: 1), in: text) else { continue }
            add(r, text[n], nil)
        }
        return results.sorted { $0.1.offset < $1.1.offset }.map { $0.1 }
    }

    static let cardRegex = try! NSRegularExpression(
        pattern: #"(?:بطاقة|البطاقة|card|مدى|mada|visa|فيزا|ماستركارد|mastercard|credit card|الائتمانية)[^\d\n]{0,25}?[*xX#•.]+\s*(\d{4})(?!\d)|(?:بطاقة|البطاقة|card)\s*(?:رقم|no\.?|number)?\s*[:：]?\s*(\d{4})(?!\d)"#,
        options: [.caseInsensitive])
    static let accountRegex = try! NSRegularExpression(
        pattern: #"(?:من حساب|حساب|الحساب|account|acct|a/c|ac)[^\d\n]{0,15}?[*xX#•.]+\s*(\d{4})(?!\d)|(?:من حساب|حساب|الحساب|account|a/c)\s*(?:رقم|no\.?)?\s*[:：]?\s*\d*?(\d{4})(?!\d)"#,
        options: [.caseInsensitive])
    /// SNB style: a line "من 2002*" = debited account last 4.
    static let accountLineRegex = try! NSRegularExpression(pattern: #"^\s*من\s*\*?(\d{4})\*?\s*$"#, options: [.anchorsMatchLines])
    static let referenceRegex = try! NSRegularExpression(
        pattern: #"(?:مرجع|الرقم المرجعي|رقم العملية|رقم المرجع|ref(?:erence)?(?:\s*no)?\.?)\s*[:：#]?\s*([A-Za-z0-9]{5,})"#,
        options: [.caseInsensitive])
    static let ibanRegex = try! NSRegularExpression(pattern: #"SA\d{2}[\d\s]{18,26}"#, options: [.caseInsensitive])

    static func capture(_ re: NSRegularExpression, in text: String) -> String? {
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for i in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) { return String(text[r]) }
        }
        return nil
    }

    static func counterpartyAccount(in text: String) -> String? {
        if let m = ibanRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range, in: text) {
            let digits = text[r].filter(\.isNumber)
            return String(digits.suffix(4))
        }
        let lower = text.lowercased()
        for label in ["إلى", "الى", "to", "للحساب", "المستفيد"] {
            guard let range = lower.range(of: label) else { continue }
            let tail = String(lower[range.upperBound...].prefix(40))
            if let re = try? NSRegularExpression(pattern: #"[*xX#•]+\s*(\d{4})(?!\d)"#),
               let m = re.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
               let r = Range(m.range(at: 1), in: tail) {
                return String(tail[r])
            }
        }
        return nil
    }

    /// Value after the first matching label, up to end of line or a known separator.
    static func labelledValue(in text: String, labels: [String]) -> String? {
        let lines = text.components(separatedBy: CharacterSet.newlines)
        for label in labels {
            for line in lines {
                guard let r = line.range(of: label, options: [.caseInsensitive]) else { continue }
                var value = String(line[r.upperBound...])
                // Cut at next field marker
                for stop in [" في ", " on ", " بتاريخ", " date", " بمبلغ", " مبلغ", " amount", " بطاقة", " card", " رصيد", " balance",
                             " الرصيد", " SAR", " ر.س", " ريال", ",", "،", " via ", " عبر "] {
                    if let s = value.range(of: stop, options: [.caseInsensitive]) { value = String(value[..<s.lowerBound]) }
                }
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: " :：-.*\t"))
                if value.count >= 2, value.count <= 60, value.contains(where: { $0.isLetter }) { return value }
            }
        }
        return nil
    }
}

public enum Hashing {
    /// FNV-1a 64-bit, hex. Deterministic across platforms (Swift's `hashValue` is not).
    public static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
