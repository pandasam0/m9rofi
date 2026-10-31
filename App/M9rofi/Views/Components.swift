import SwiftUI
import FinanceCore

/// SwiftUI also declares `Transaction`; always refer to the ledger type through this alias.
typealias LedgerTransaction = FinanceCore.Transaction
/// ObjectiveC also exports `Category` on Apple platforms.
typealias Category = FinanceCore.Category

enum Fmt {
    static func money(_ v: Decimal, compact: Bool = false) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = compact ? 0 : 2
        f.maximumFractionDigits = compact ? 0 : 2
        let n = f.string(from: NSDecimalNumber(decimal: v)) ?? "\(v)"
        return isArabic ? "\(n) ر.س" : "SAR \(n)"
    }

    static var isArabic: Bool { Locale.current.language.languageCode?.identifier != "en" }

    static func date(_ d: Date, time: Bool = true) -> String {
        d.formatted(time ? .dateTime.day().month(.abbreviated).hour().minute() : .dateTime.day().month(.abbreviated).year())
    }

    static func percent(_ r: Double) -> String { "\(Int((r * 100).rounded()))%" }
}

extension Category {
    var localizedName: String { displayName(arabic: Fmt.isArabic) }
    var color: Color {
        switch self {
        case .dining: .orange
        case .coffee: .brown
        case .groceries: .green
        case .shopping: .pink
        case .auto: .red
        case .transport: .indigo
        case .subscriptions: .purple
        case .entertainment: .mint
        case .travel: .cyan
        case .health: .teal
        case .bills: .yellow
        case .transfers: .blue
        case .cash: .gray
        case .personal: Color(red: 0.6, green: 0.4, blue: 0.8)
        case .other: .secondary
        case .salary, .otherIncome: .green
        case .internalTransfer: .gray
        }
    }
}

extension TransactionStatus {
    var label: LocalizedStringKey {
        switch self { case .pending: "Pending"; case .completed: "Completed"; case .reversed: "Reversed"; case .refunded: "Refunded" }
    }
}

extension SourceType {
    var label: String {
        switch self {
        case .manual: "يدوي"
        case .sms: "رسالة بنكية"
        case .walletAutomation: "Apple Pay"
        case .statementCSV: "كشف CSV"
        case .statementPDF: "كشف PDF"
        case .statementExcel: "كشف Excel"
        case .email: "بريد"
        case .openBanking: "مصرفية مفتوحة"
        case .financeKit: "FinanceKit"
        }
    }
}

struct StatCard: View {
    let title: LocalizedStringKey
    let value: String
    var subtitle: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(tint).minimumScaleFactor(0.6).lineLimit(1)
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

struct TransactionRow: View {
    let tx: LedgerTransaction
    let effect: LedgerEffect

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tx.category.symbol)
                .frame(width: 34, height: 34)
                .background(tx.category.color.opacity(0.18), in: .circle)
                .foregroundStyle(tx.category.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.displayName).font(.body).lineLimit(1)
                HStack(spacing: 4) {
                    Text(tx.category.localizedName)
                    Text("·")
                    Text(Fmt.date(tx.date, time: tx.hasTime))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountText).font(.body.monospacedDigit()).foregroundStyle(amountColor).strikethrough(isStruck)
                if let badge { Text(badge).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: .capsule) }
            }
        }
    }

    var amountText: String {
        let v = tx.baseAmount ?? tx.amount
        let sign = tx.direction == .debit ? "−" : "+"
        let base = Fmt.money(v)
        return tx.currency == "SAR" ? sign + base : "\(sign)\(base) (\(tx.amount) \(tx.currency))"
    }

    var amountColor: Color {
        switch effect {
        case .income, .refund, .incomingTransfer: .green
        case .internalTransfer, .excluded, .cashWithdrawal: .secondary
        case .pending, .unconfirmed: .orange
        case .expense: .primary
        }
    }

    var isStruck: Bool { if case .excluded = effect { return true }; return false }

    var badge: String? {
        switch effect {
        case .internalTransfer: return Fmt.isArabic ? "تحويل داخلي" : "Internal"
        case .pending: return Fmt.isArabic ? "معلقة" : "Pending"
        case .unconfirmed: return Fmt.isArabic ? "مراجعة" : "Review"
        case .excluded: return Fmt.isArabic ? "مستبعدة" : "Excluded"
        case .cashWithdrawal: return Fmt.isArabic ? "سحب نقدي" : "Cash"
        case .incomingTransfer: return Fmt.isArabic ? "تحويل وارد" : "Transfer in"
        case .refund: return Fmt.isArabic ? "مسترد" : "Refund"
        default: return nil
        }
    }
}

struct CategoryPicker: View {
    @Binding var selection: Category
    var body: some View {
        Picker("Category", selection: $selection) {
            ForEach(Category.allCases, id: \.self) { c in
                Label(c.localizedName, systemImage: c.symbol).tag(c)
            }
        }
    }
}

/// Parses user-typed amounts (Arabic or Latin digits).
func parseUserAmount(_ s: String) -> Decimal? {
    guard let v = TextNormalizer.parseAmount(s), v > 0 else { return nil }
    return v
}
