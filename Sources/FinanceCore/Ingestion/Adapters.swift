import Foundation

// MARK: - Apple Wallet "Transaction" Shortcuts automation (iOS 17+)

/// Input from the Shortcuts personal automation "Transaction" (Wallet) trigger, which fires when a
/// Wallet card is tapped and exposes Card/Merchant/Amount. It does NOT expose a bank reference or
/// final settlement; the bank SMS / statement later merges into the same transaction via de-duplication.
public enum WalletAutomationAdapter {
    public static func record(merchant: String?, amountText: String, cardName: String?, date: Date) -> RawRecord {
        let normalized = TextNormalizer.normalizeDigits(amountText)
        let money = SMSParser.moneyMatches(in: normalized)
        var amount = money.first?.value
        var currency = money.first?.currency
        if amount == nil {
            let digits = normalized.filter { $0.isNumber || $0 == "." || $0 == "," }
            amount = TextNormalizer.parseAmount(digits)
        }
        if currency == nil {
            let lower = normalized.lowercased()
            currency = SMSParser.currencyAliases.first { lower.contains($0.key) }?.value ?? "SAR"
        }
        let id = "wallet:" + Hashing.fnv1a("\(cardName ?? "")|\(merchant ?? "")|\(amountText)|\(Int(date.timeIntervalSince1970 / 60))")
        return RawRecord(source: .walletAutomation, sourceRecordID: id, amount: amount.map { abs($0) }, currency: currency,
                         direction: .debit, kind: .purchase, status: .completed, date: date, hasTime: true,
                         merchant: merchant, walletCardName: cardName, confidence: amount == nil ? 0.3 : 0.9)
    }
}

// MARK: - Email receipts

/// Extracts a purchase from a receipt / invoice email body (plain text or HTML stripped).
/// Receipts are confirmations of card charges that usually also arrive via SMS → de-duplication merges them.
public enum ReceiptParser {
    public static func record(subject: String, from: String, body: String, date: Date, messageID: String) -> RawRecord? {
        let text = TextNormalizer.normalizeDigits(stripHTML(body))
        let lower = (subject + " " + text).lowercased()
        let receiptWords = ["receipt", "invoice", "your order", "order confirmation", "payment received", "إيصال", "فاتورة", "طلبك", "تم الدفع", "ضريبية"]
        guard SMSParser.has(lower, receiptWords) else { return nil }
        let totalRe = try! NSRegularExpression(
            pattern: #"(?:grand total|total paid|amount paid|order total|total|الإجمالي|المجموع|المبلغ الإجمالي|الاجمالي)[^\d\n]{0,25}?"# + SMSParser.numberPattern,
            options: [.caseInsensitive])
        var amount: Decimal?
        var currency = "SAR"
        let ns = NSRange(text.startIndex..., in: text)
        // Last "total" wins (subtotal appears first).
        if let m = totalRe.matches(in: text, range: ns).last, let r = Range(m.range(at: 1), in: text) {
            amount = TextNormalizer.parseAmount(String(text[r]))
            let full = String(text[Range(m.range, in: text)!]).lowercased()
            if let c = SMSParser.currencyAliases.first(where: { full.contains($0.key) && $0.key.count > 1 }) { currency = c.value }
        } else if let first = SMSParser.moneyMatches(in: text).first {
            amount = first.value; currency = first.currency ?? "SAR"
        }
        guard let amount else { return nil }
        let isRefund = SMSParser.has(lower, ["refund", "استرداد", "credit note", "إشعار دائن"])
        let merchant = senderName(from) ?? subject
        return RawRecord(source: .email, sourceRecordID: "email:\(messageID)", amount: amount, currency: currency,
                         direction: isRefund ? .credit : .debit, kind: isRefund ? .refund : .purchase,
                         status: .completed, date: date, hasTime: true, merchant: merchant, note: subject, confidence: 0.7)
    }

    static func senderName(_ from: String) -> String? {
        // "Netflix <info@account.netflix.com>" → Netflix
        if let lt = from.firstIndex(of: "<") {
            let name = from[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
        }
        if let at = from.firstIndex(of: "@") {
            let domain = from[from.index(after: at)...].split(separator: ".")
            if domain.count >= 2 { return String(domain[domain.count - 2]).capitalized }
        }
        return nil
    }

    public static func stripHTML(_ html: String) -> String {
        guard html.contains("<") else { return html }
        var s = html.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</tr>", with: "\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (e, r) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: e, with: r)
        }
        return s
    }
}

// MARK: - Open Banking (SAMA Open Banking Framework — Account Information Services)

/// Subset of the Account Information transaction resource. The KSA Open Banking standards follow the
/// same resource model as the UK OBIE Read/Write API (Accounts / Balances / Transactions). Field names
/// must be verified against the licensed provider's actual schema before production use.
public struct OBTransactionsResponse: Decodable, Sendable {
    public struct Data: Decodable, Sendable { public var Transaction: [OBTransaction] }
    public var Data: Data
}

public struct OBAmount: Decodable, Sendable {
    public var Amount: String
    public var Currency: String
}

public struct OBTransaction: Decodable, Sendable {
    public var AccountId: String?
    public var TransactionId: String?
    public var TransactionReference: String?
    public var CreditDebitIndicator: String          // "Credit" | "Debit"
    public var Status: String                        // "Booked" | "Pending"
    public var BookingDateTime: String
    public var Amount: OBAmount
    public var ChargeAmount: OBAmount?
    public var TransactionInformation: String?
    public var MerchantDetails: Merchant?
    public var Balance: BalanceInfo?
    public var BankTransactionCode: Code?
    public var ProprietaryBankTransactionCode: PCode?
    public var CurrencyExchange: FX?

    public struct Merchant: Decodable, Sendable { public var MerchantName: String?; public var MerchantCategoryCode: String? }
    public struct BalanceInfo: Decodable, Sendable { public var Amount: OBAmount }
    public struct Code: Decodable, Sendable { public var Code: String?; public var SubCode: String? }
    public struct PCode: Decodable, Sendable { public var Code: String? }
    public struct FX: Decodable, Sendable { public var SourceCurrency: String?; public var InstructedAmount: OBAmount? }
}

public enum OpenBankingMapper {
    public static func records(from data: Foundation.Data, accountID: UUID) throws -> [RawRecord] {
        let resp = try JSONDecoder().decode(OBTransactionsResponse.self, from: data)
        return resp.Data.Transaction.map { record(from: $0, accountID: accountID) }
    }

    public static func record(from t: OBTransaction, accountID: UUID) -> RawRecord {
        let direction: Direction = t.CreditDebitIndicator.lowercased() == "credit" ? .credit : .debit
        let amount = TextNormalizer.parseAmount(t.Amount.Amount)
        let info = t.TransactionInformation ?? ""
        let codeText = [t.BankTransactionCode?.Code, t.BankTransactionCode?.SubCode, t.ProprietaryBankTransactionCode?.Code]
            .compactMap { $0 }.joined(separator: " ")
        var kind = StatementImporter.classify(info + " " + codeText, direction: direction)
        let lowerCodes = codeText.lowercased()
        if lowerCodes.contains("reversal") { kind = .reversal }
        if t.MerchantDetails?.MerchantName != nil, direction == .debit, kind == .unknown { kind = .purchase }
        var date: Date?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = iso.date(from: t.BookingDateTime)
        if date == nil { iso.formatOptions = [.withInternetDateTime]; date = iso.date(from: t.BookingDateTime) }
        var currency = t.Amount.Currency
        var original: Decimal?
        if let fx = t.CurrencyExchange?.InstructedAmount, fx.Currency != t.Amount.Currency {
            original = TextNormalizer.parseAmount(fx.Amount)
            currency = fx.Currency
        }
        let id = t.TransactionId ?? t.TransactionReference ?? Hashing.fnv1a("\(t.BookingDateTime)|\(t.Amount.Amount)|\(info)")
        return RawRecord(
            source: .openBanking, sourceRecordID: "ob:\(id)",
            amount: original ?? amount, currency: currency, baseAmount: original != nil ? amount : nil,
            direction: direction, kind: kind, status: t.Status.lowercased() == "pending" ? .pending : .completed,
            date: date, hasTime: true, merchant: t.MerchantDetails?.MerchantName ?? StatementImporter.cleanDescription(info),
            balanceAfter: t.Balance.flatMap { TextNormalizer.parseAmount($0.Amount.Amount) },
            reference: t.TransactionReference, mcc: t.MerchantDetails?.MerchantCategoryCode, accountID: accountID,
            note: info.isEmpty ? nil : info, confidence: amount == nil || date == nil ? 0.3 : 1)
    }
}

/// Contract for a licensed AIS provider (e.g. an aggregator licensed by SAMA). Implemented in the app
/// layer once a provider contract exists; the core only consumes RawRecords.
public protocol AccountInformationProvider: Sendable {
    var name: String { get }
    func fetchTransactions(accountExternalID: String, since: Date) async throws -> [RawRecord]
    func fetchBalance(accountExternalID: String) async throws -> (Decimal, String, Date)
}

// MARK: - .eml files (Mail → Share / Save, or files exported from any mail client)

public struct EmailMessage: Sendable, Equatable {
    public var subject: String
    public var from: String
    public var date: Date?
    public var messageID: String
    public var body: String
}

public enum EMLParser {
    public static func parse(_ raw: String) -> EmailMessage {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let (headers, body) = split(text)
        let subject = decodeHeader(headers["subject"] ?? "")
        let from = decodeHeader(headers["from"] ?? "")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let dateStr = (headers["date"] ?? "").replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
        let date = f.date(from: dateStr) ?? { f.dateFormat = "d MMM yyyy HH:mm:ss Z"; return f.date(from: dateStr) }()
        let id = headers["message-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) ?? Hashing.fnv1a(raw)
        return EmailMessage(subject: subject, from: from, date: date, messageID: id,
                            body: decodeBody(headers: headers, body: body))
    }

    static func split(_ text: String) -> ([String: String], String) {
        guard let r = text.range(of: "\n\n") else { return ([:], text) }
        var headers: [String: String] = [:]
        var last: String?
        for line in text[..<r.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t", let k = last {
                headers[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].lowercased()
                if headers[k] == nil { headers[k] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
                last = k
            }
        }
        return (headers, String(text[r.upperBound...]))
    }

    static func decodeBody(headers: [String: String], body: String) -> String {
        let ctype = headers["content-type"] ?? "text/plain"
        if ctype.lowercased().contains("multipart"),
           let bRange = ctype.range(of: #"boundary="?([^";]+)"?"#, options: .regularExpression) {
            let boundary = ctype[bRange].replacingOccurrences(of: "boundary=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let parts = body.components(separatedBy: "--" + boundary).dropFirst()
            var html: String?
            for part in parts where !part.hasPrefix("--") {
                let (h, b) = split(part.trimmingCharacters(in: .newlines))
                let pt = (h["content-type"] ?? "text/plain").lowercased()
                if pt.contains("multipart") { let inner = decodeBody(headers: h, body: b); if !inner.isEmpty { return inner } }
                if pt.contains("text/plain") { return decodeTransfer(h, b) }
                if pt.contains("text/html") { html = decodeTransfer(h, b) }
            }
            return html.map(ReceiptParser.stripHTML) ?? ""
        }
        let decoded = decodeTransfer(headers, body)
        return ctype.lowercased().contains("html") ? ReceiptParser.stripHTML(decoded) : decoded
    }

    static func decodeTransfer(_ h: [String: String], _ b: String) -> String {
        switch (h["content-transfer-encoding"] ?? "").lowercased() {
        case "base64":
            let clean = b.filter { !$0.isWhitespace }
            return Data(base64Encoded: clean).map { String(decoding: $0, as: UTF8.self) } ?? b
        case "quoted-printable":
            return quotedPrintable(b)
        default:
            return b
        }
    }

    static func quotedPrintable(_ s: String) -> String {
        var bytes: [UInt8] = []
        let u = Array(s.replacingOccurrences(of: "=\n", with: "").utf8)
        var i = 0
        while i < u.count {
            if u[i] == UInt8(ascii: "="), i + 2 < u.count, let v = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(v); i += 3
            } else { bytes.append(u[i]); i += 1 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// RFC 2047 encoded words: =?UTF-8?B?...?= / =?UTF-8?Q?...?=
    static func decodeHeader(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let full = Range(m.range, in: s), let encR = Range(m.range(at: 2), in: s), let txtR = Range(m.range(at: 3), in: s) else { continue }
            let txt = String(s[txtR])
            let decoded: String
            if s[encR].uppercased() == "B" {
                decoded = Data(base64Encoded: txt).map { String(decoding: $0, as: UTF8.self) } ?? txt
            } else {
                decoded = quotedPrintable(txt.replacingOccurrences(of: "_", with: " "))
            }
            if let outRange = out.range(of: String(s[full])) { out.replaceSubrange(outRange, with: decoded) }
        }
        return out.replacingOccurrences(of: #"\?=\s+=\?"#, with: "", options: .regularExpression)
    }
}
