import Foundation

/// RFC 4180 CSV reader (quoted fields, escaped quotes, CRLF, BOM, `;` or `,` or tab delimiter auto-detect).
public enum CSVReader {
    public static func parse(_ text: String) -> [[String]] {
        var s = text
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        let firstLine = s.prefix { $0 != "\n" && $0 != "\r\n" }
        let delimiter: Character = [";", "\t", ","].max { a, b in
            firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
        } ?? ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var it = s.makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? it.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    if let next = it.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else { field.append(ch) }
                continue
            }
            switch ch {
            case "\"": inQuotes = true
            case delimiter: row.append(field); field = ""
            case "\n", "\r\n", "\r":
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            default: field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
    }
}

/// Maps statement columns to fields. Auto-detected from header names (Arabic/English), user-editable.
public struct ColumnMapping: Codable, Hashable, Sendable {
    public var date: Int?
    public var time: Int?
    public var description: Int?
    public var amount: Int?        // single signed amount column
    public var debit: Int?         // separate debit column
    public var credit: Int?        // separate credit column
    public var balance: Int?
    public var currency: Int?
    public var reference: Int?
    public var headerRow: Int

    public init(date: Int? = nil, time: Int? = nil, description: Int? = nil, amount: Int? = nil, debit: Int? = nil,
                credit: Int? = nil, balance: Int? = nil, currency: Int? = nil, reference: Int? = nil, headerRow: Int = 0) {
        self.date = date; self.time = time; self.description = description; self.amount = amount
        self.debit = debit; self.credit = credit; self.balance = balance; self.currency = currency
        self.reference = reference; self.headerRow = headerRow
    }

    public var isUsable: Bool { date != nil && (amount != nil || debit != nil || credit != nil) }

    static let synonyms: [(WritableKeyPath<ColumnMapping, Int?>, [String])] = [
        (\.date, ["تاريخ العملية", "تاريخ", "date", "transaction date", "posting date", "value date", "booking date"]),
        (\.time, ["الوقت", "time"]),
        (\.description, ["الوصف", "البيان", "التفاصيل", "تفاصيل العملية", "description", "details", "narrative", "particulars", "merchant", "التاجر"]),
        (\.debit, ["مدين", "خصم", "سحب", "المبلغ المدين", "debit", "withdrawal", "withdrawals", "money out", "paid out"]),
        (\.credit, ["دائن", "إيداع", "ايداع", "المبلغ الدائن", "credit", "deposit", "deposits", "money in", "paid in"]),
        (\.amount, ["المبلغ", "مبلغ", "amount", "transaction amount", "value"]),
        (\.balance, ["الرصيد", "رصيد", "balance", "running balance"]),
        (\.currency, ["العملة", "currency"]),
        (\.reference, ["المرجع", "رقم المرجع", "رقم العملية", "reference", "ref", "ref no", "transaction id"])
    ]

    /// Finds the header row in the first 15 rows and maps columns.
    public static func detect(rows: [[String]]) -> ColumnMapping? {
        for (ri, row) in rows.prefix(15).enumerated() {
            var map = ColumnMapping(headerRow: ri)
            var used = Set<Int>()
            for (kp, names) in synonyms {
                // Prefer exact match, then contains.
                let idx = row.indices.first { i in !used.contains(i) && names.contains(row[i].lowercased()) }
                    ?? row.indices.first { i in !used.contains(i) && names.contains { row[i].lowercased().contains($0) } }
                if let idx { map[keyPath: kp] = idx; used.insert(idx) }
            }
            if map.isUsable { return map }
        }
        return nil
    }
}

public struct StatementImportResult: Sendable {
    public var records: [RawRecord]
    public var skippedRows: [(row: Int, reason: String)]
    public var mapping: ColumnMapping?
    public var closingBalance: (Decimal, Date)?
}

/// Converts tabular statements (CSV, Excel exported as CSV, PDF text) into RawRecords bound to one account.
public struct StatementImporter: Sendable {
    public var timeZone: TimeZone
    public init(timeZone: TimeZone = TimeZone(identifier: "Asia/Riyadh")!) { self.timeZone = timeZone }

    public func importRows(_ rows: [[String]], accountID: UUID, source: SourceType, mapping: ColumnMapping? = nil,
                           defaultCurrency: String = "SAR") -> StatementImportResult {
        guard let map = mapping ?? ColumnMapping.detect(rows: rows) else {
            return StatementImportResult(records: [], skippedRows: [(0, "لم يتم التعرف على أعمدة الكشف")], mapping: nil, closingBalance: nil)
        }
        let dp = DateParser(timeZone: timeZone)
        var records: [RawRecord] = []
        var skipped: [(Int, String)] = []
        var closing: (Decimal, Date)?
        var occurrence: [String: Int] = [:]
        for (i, row) in rows.enumerated() where i > map.headerRow {
            func cell(_ c: Int?) -> String? {
                guard let c, c < row.count else { return nil }
                let v = row[c].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            guard let dateStr = cell(map.date) else { skipped.append((i, "بدون تاريخ")); continue }
            guard let (date, hasTime) = dp.parse(dateStr + " " + (cell(map.time) ?? "")) else {
                skipped.append((i, "تاريخ غير مفهوم: \(dateStr)")); continue
            }
            var signed: Decimal?
            if let a = cell(map.amount).flatMap(Self.amount) { signed = a }
            if let d = cell(map.debit).flatMap(Self.amount), d != 0 { signed = -abs(d) }
            if let c = cell(map.credit).flatMap(Self.amount), c != 0 { signed = abs(c) }
            guard let value = signed, value != 0 else { skipped.append((i, "بدون مبلغ")); continue }
            let desc = cell(map.description) ?? ""
            let balance = cell(map.balance).flatMap(Self.amount)
            let currency = cell(map.currency)?.uppercased() ?? defaultCurrency
            let direction: Direction = value < 0 ? .debit : .credit
            let kind = Self.classify(desc, direction: direction)
            let ref = cell(map.reference)
            // Stable ID: reference if present, else content hash + occurrence counter (identical rows on the same day are real).
            let base = ref.map { "ref:\($0)" } ?? Hashing.fnv1a("\(accountID)|\(dateStr)|\(value)|\(desc)")
            let n = occurrence[base, default: 0]; occurrence[base] = n + 1
            let id = "stmt:\(accountID.uuidString.prefix(8)):\(base):\(n)"
            let merchant = Self.cleanDescription(desc)
            let isTransfer = kind == .transferIn || kind == .transferOut || kind == .income
            records.append(RawRecord(
                source: source, sourceRecordID: id, amount: abs(value), currency: currency,
                direction: direction, kind: kind, status: .completed, date: date, hasTime: hasTime,
                merchant: isTransfer ? nil : merchant, counterparty: isTransfer ? merchant : nil,
                counterpartyAccountLast4: SMSParser.counterpartyAccount(in: desc),
                balanceAfter: balance, reference: ref, accountID: accountID,
                note: desc.isEmpty ? nil : desc, confidence: kind == .unknown ? 0.7 : 1))
            if let balance, closing == nil || date >= closing!.1 { closing = (balance, date) }
        }
        return StatementImportResult(records: records, skippedRows: skipped, mapping: map, closingBalance: closing)
    }

    public func importCSV(_ text: String, accountID: UUID, mapping: ColumnMapping? = nil) -> StatementImportResult {
        importRows(CSVReader.parse(text), accountID: accountID, source: .statementCSV, mapping: mapping)
    }

    /// PDF statements: the app extracts text per line with PDFKit; lines that start with a date and contain
    /// at least one amount become rows. Layouts vary per bank — unrecognised lines are reported, not guessed.
    public func importPDFText(_ lines: [String], accountID: UUID) -> StatementImportResult {
        let dp = DateParser(timeZone: timeZone)
        var records: [RawRecord] = []
        var skipped: [(Int, String)] = []
        var prevBalance: Decimal?
        var closing: (Decimal, Date)?
        var occurrence: [String: Int] = [:]
        let amountRe = try! NSRegularExpression(pattern: #"-?\(?\d{1,3}(?:,\d{3})*\.\d{2}\)?"#)
        for (i, raw) in lines.enumerated() {
            let line = TextNormalizer.normalizeDigits(raw)
            guard let (date, hasTime) = dp.parse(String(line.prefix(24))) else { continue }
            let ns = NSRange(line.startIndex..., in: line)
            let amounts = amountRe.matches(in: line, range: ns).compactMap { Range($0.range, in: line).map { String(line[$0]) } }
                .compactMap(TextNormalizer.parseAmount)
            guard !amounts.isEmpty else { skipped.append((i, "سطر بتاريخ دون مبلغ")); continue }
            // Typical layouts: [amount, balance] or [debit, credit, balance] with one empty.
            let txAmount = amounts.count >= 2 ? amounts[amounts.count - 2] : amounts[0]
            let balance: Decimal? = amounts.count >= 2 ? amounts.last : nil
            var direction: Direction?
            if txAmount < 0 { direction = .debit }
            if let balance, let prev = prevBalance {
                let delta = balance - prev
                if delta == abs(txAmount) { direction = .credit } else if delta == -abs(txAmount) { direction = .debit }
            }
            var desc = amountRe.stringByReplacingMatches(in: line, range: ns, withTemplate: " ")
            if let dm = try? NSRegularExpression(pattern: #"^\s*[\d/\-.: ]+(?:[AaPp][Mm])?"#) {
                desc = dm.stringByReplacingMatches(in: desc, range: NSRange(desc.startIndex..., in: desc), withTemplate: "")
            }
            desc = desc.split(separator: " ").joined(separator: " ")
            if direction == nil {
                let lower = desc.lowercased()
                if SMSParser.has(lower, SMSParser.creditWords) { direction = .credit }
                else if SMSParser.has(lower, SMSParser.debitWords) || SMSParser.has(lower, SMSParser.kindRules.last!.1) { direction = .debit }
            }
            if let balance { prevBalance = balance; closing = (balance, date) }
            let kind = direction.map { Self.classify(desc, direction: $0) } ?? .unknown
            let base = Hashing.fnv1a("\(accountID)|\(line)")
            let n = occurrence[base, default: 0]; occurrence[base] = n + 1
            records.append(RawRecord(
                source: .statementPDF, sourceRecordID: "pdf:\(base):\(n)", amount: abs(txAmount), currency: "SAR",
                direction: direction, kind: kind, status: .completed, date: date, hasTime: hasTime,
                merchant: Self.cleanDescription(desc), balanceAfter: balance, accountID: accountID, note: desc,
                confidence: direction == nil ? 0.4 : 0.8))
        }
        return StatementImportResult(records: records, skippedRows: skipped, mapping: nil, closingBalance: closing)
    }

    static func amount(_ s: String) -> Decimal? {
        var t = TextNormalizer.normalizeDigits(s)
        for token in ["SAR", "SR", "ر.س", "ريال"] { t = t.replacingOccurrences(of: token, with: "") }
        t = t.trimmingCharacters(in: .whitespaces)
        var negative = false
        if t.hasSuffix("-") { negative = true; t.removeLast() }
        if t.hasSuffix("DR") || t.hasSuffix("Dr") { negative = true; t = String(t.dropLast(2)) }
        if t.hasSuffix("CR") || t.hasSuffix("Cr") { t = String(t.dropLast(2)) }
        guard let v = TextNormalizer.parseAmount(t) else { return nil }
        return negative ? -abs(v) : v
    }

    static func classify(_ desc: String, direction: Direction) -> TransactionKind {
        let lower = TextNormalizer.normalizeDigits(desc).lowercased()
        for (k, words) in SMSParser.kindRules where SMSParser.has(lower, words) {
            // Direction from the statement column is authoritative.
            switch (k, direction) {
            case (.transferIn, .debit): return .transferOut
            case (.transferOut, .credit): return .transferIn
            case (.purchase, .credit), (.billPayment, .credit), (.fee, .credit): return .refund
            case (.income, .debit): return .transferOut
            default: return k
            }
        }
        return direction == .debit ? .purchase : .unknown
    }

    static func cleanDescription(_ desc: String) -> String? {
        var s = desc
        for noise in ["شراء عبر نقاط البيع", "شراء انترنت", "شراء إنترنت", "عملية شراء", "POS PURCHASE", "POS Purchase", "PURCHASE",
                      "Purchase", "Apple Pay", "APPLE PAY", "mada", "MADA", "مدى", "-"] {
            s = s.replacingOccurrences(of: noise, with: " ")
        }
        s = s.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
