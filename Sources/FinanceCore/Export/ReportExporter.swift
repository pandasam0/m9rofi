import Foundation

/// Report data shared by PDF (rendered in the app) and spreadsheet exports.
public struct Report: Sendable {
    public var title: String
    public var interval: DateInterval
    public var summary: PeriodSummary
    public var transactions: [Transaction]
    public var effects: [UUID: LedgerEffect]
    public var budgets: [BudgetStatus]
    public var recurring: [RecurringSeries]
    public var fixed: Decimal
    public var variable: Decimal

    public static func build(state: LedgerState, period: Aggregator.Period, containing date: Date, now: Date = Date()) -> Report {
        let agg = Aggregator(state: state)
        let iv = agg.interval(period, containing: date)
        let txs = agg.transactions(in: iv).sorted { $0.date < $1.date }
        let recurring = RecurringDetector(state: state).detect(now: now)
        let fv = agg.fixedVsVariable(iv, recurring: recurring)
        let title: String = switch period {
        case .day: "تقرير يومي"
        case .week: "تقرير أسبوعي"
        case .month: "تقرير شهري"
        case .year: "تقرير سنوي"
        }
        return Report(title: title, interval: iv, summary: agg.summary(iv, now: now), transactions: txs,
                      effects: Dictionary(uniqueKeysWithValues: txs.map { ($0.id, agg.effect(of: $0)) }),
                      budgets: period == .month ? BudgetEngine(state: state).status(now: min(now, iv.end.addingTimeInterval(-1))) : [],
                      recurring: recurring, fixed: fv.fixed, variable: fv.variable)
    }
}

public enum ReportExporter {
    static func effectLabel(_ e: LedgerEffect?) -> String {
        switch e {
        case .expense: return "مصروف"
        case .refund: return "مسترد"
        case .income: return "دخل"
        case .incomingTransfer: return "تحويل وارد"
        case .cashWithdrawal: return "سحب نقدي"
        case .internalTransfer: return "تحويل داخلي"
        case .pending: return "معلقة"
        case .unconfirmed: return "قيد المراجعة"
        case .excluded, .none: return "مستبعدة"
        }
    }

    static func statusLabel(_ s: TransactionStatus) -> String {
        switch s { case .pending: "معلقة"; case .completed: "مكتملة"; case .reversed: "ملغاة"; case .refunded: "مستردة" }
    }

    static let header = ["التاريخ", "الجهة", "التصنيف", "المبلغ", "العملة", "المبلغ بالريال", "النوع", "الأثر", "الحالة", "الحساب", "المصدر", "ملاحظة"]

    static func rows(_ r: Report, accounts: [Account], tz: TimeZone) -> [[String]] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH:mm"
        return r.transactions.map { t in
            let signed = t.direction == .debit ? -(t.baseAmount ?? 0) : (t.baseAmount ?? 0)
            return [f.string(from: t.date), t.displayName, t.category.arabicName, "\(t.amount)", t.currency, "\(signed)",
                    t.kind.rawValue, effectLabel(r.effects[t.id]), statusLabel(t.status),
                    accounts.first { $0.id == t.accountID }?.name ?? "", t.sources.map(\.type.rawValue).joined(separator: "+"), t.note ?? ""]
        }
    }

    /// UTF-8 CSV with BOM (Excel opens Arabic correctly).
    public static func csv(_ r: Report, accounts: [Account], tz: TimeZone) -> Data {
        func esc(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let lines = ([header] + rows(r, accounts: accounts, tz: tz)).map { $0.map(esc).joined(separator: ",") }
        return Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Excel workbook (SpreadsheetML 2003 XML, `.xls`) with Summary, Categories, Transactions sheets.
    /// Opens in Excel, Numbers and Google Sheets without third-party libraries.
    public static func excel(_ r: Report, accounts: [Account], tz: TimeZone) -> Data {
        func x(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func row(_ cells: [String], numericFrom: Set<Int> = []) -> String {
            "<Row>" + cells.enumerated().map { i, c in
                if numericFrom.contains(i), Decimal(string: c) != nil { return "<Cell><Data ss:Type=\"Number\">\(c)</Data></Cell>" }
                return "<Cell><Data ss:Type=\"String\">\(x(c))</Data></Cell>"
            }.joined() + "</Row>"
        }
        func sheet(_ name: String, _ rows: [String]) -> String {
            "<Worksheet ss:Name=\"\(x(name))\" ss:RightToLeft=\"1\"><Table>" + rows.joined() + "</Table><WorksheetOptions xmlns=\"urn:schemas-microsoft-com:office:excel\"><DisplayRightToLeft/></WorksheetOptions></Worksheet>"
        }
        let s = r.summary
        let summaryRows = [
            row(["البند", "القيمة"]),
            row(["الفترة", DateFormatting.shortDate(r.interval.start, tz: tz) + " → " + DateFormatting.shortDate(r.interval.end.addingTimeInterval(-1), tz: tz)]),
            row(["صافي المصروفات", "\(s.spending)"], numericFrom: [1]),
            row(["المبالغ المستردة", "\(s.refunds)"], numericFrom: [1]),
            row(["الدخل", "\(s.income)"], numericFrom: [1]),
            row(["تحويلات واردة", "\(s.incomingTransfers)"], numericFrom: [1]),
            row(["صافي التدفق النقدي", "\(s.netCashFlow)"], numericFrom: [1]),
            row(["سحب نقدي", "\(s.cashWithdrawals)"], numericFrom: [1]),
            row(["مصروفات ثابتة", "\(r.fixed)"], numericFrom: [1]),
            row(["مصروفات متغيرة", "\(r.variable)"], numericFrom: [1]),
            row(["متوسط الإنفاق اليومي", "\(s.dailyAverage)"], numericFrom: [1]),
            row(["عدد العمليات", "\(s.transactionCount)"], numericFrom: [1]),
            row(["معلقة (غير محتسبة)", "\(s.pendingAmount)"], numericFrom: [1]),
            row(["قيد المراجعة (غير محتسبة)", "\(s.unconfirmedAmount)"], numericFrom: [1])
        ]
        let catRows = [row(["التصنيف", "المبلغ", "عدد العمليات"])] + s.byCategory.map { row([$0.category.arabicName, "\($0.amount)", "\($0.count)"], numericFrom: [1, 2]) }
        let merchantRows = [row(["الجهة", "المبلغ", "عدد العمليات"])] + s.byMerchant.prefix(50).map { row([$0.name, "\($0.amount)", "\($0.count)"], numericFrom: [1, 2]) }
        let txRows = [row(header)] + rows(r, accounts: accounts, tz: tz).map { row($0, numericFrom: [3, 5]) }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <?mso-application progid="Excel.Sheet"?>
        <Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
        \(sheet("الملخص", summaryRows))\(sheet("التصنيفات", catRows))\(sheet("المتاجر", merchantRows))\(sheet("العمليات", txRows))
        </Workbook>
        """
        return Data(xml.utf8)
    }
}
