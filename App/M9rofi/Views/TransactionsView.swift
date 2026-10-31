import SwiftUI
import FinanceCore

struct TransactionsView: View {
    @Environment(AppStore.self) private var store
    @State private var search = ""
    @State private var filterCategory: Category?
    @State private var filterAccount: UUID?
    @State private var showAdd = false

    var body: some View {
        let agg = store.aggregator
        let txs = filtered()
        let grouped = Dictionary(grouping: txs) { Calendar.current.startOfDay(for: $0.date) }
        let days = grouped.keys.sorted(by: >)
        List {
            let reviewCount = store.state.transactions.filter(\.needsReview).count
            if reviewCount > 0 {
                NavigationLink { ReviewView() } label: {
                    Label("Review queue (\(reviewCount))", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            ForEach(days, id: \.self) { day in
                Section {
                    ForEach(grouped[day]!.sorted { $0.date > $1.date }) { tx in
                        NavigationLink { TransactionDetailView(id: tx.id) } label: {
                            TransactionRow(tx: tx, effect: agg.effect(of: tx))
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.delete(tx.id) } label: { Label("Delete", systemImage: "trash") }
                            Button { store.toggleExcluded(tx.id) } label: { Label("Exclude", systemImage: "eye.slash") }.tint(.gray)
                        }
                    }
                } header: {
                    HStack {
                        Text(day.formatted(.dateTime.weekday(.wide).day().month()))
                        Spacer()
                        Text(Fmt.money(agg.summary(DateInterval(start: day, end: day.addingTimeInterval(86400))).spending))
                    }
                }
            }
            if txs.isEmpty {
                ContentUnavailableView("No transactions", systemImage: "tray",
                                       description: Text("Set up the Shortcuts automations or import a statement."))
            }
        }
        .searchable(text: $search)
        .navigationTitle("Transactions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { showAdd = true } label: { Image(systemName: "plus") } }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Category", selection: $filterCategory) {
                        Text("All").tag(Category?.none)
                        ForEach(Category.allCases, id: \.self) { Text($0.localizedName).tag(Category?.some($0)) }
                    }
                    Picker("Account", selection: $filterAccount) {
                        Text("All").tag(UUID?.none)
                        ForEach(store.state.accounts) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
        }
        .sheet(isPresented: $showAdd) { AddTransactionView() }
    }

    func filtered() -> [LedgerTransaction] {
        store.state.transactions.filter { t in
            if let c = filterCategory, t.category != c { return false }
            if let a = filterAccount, t.accountID != a { return false }
            if !search.isEmpty {
                let hay = [t.displayName, t.note ?? "", t.category.localizedName, "\(t.amount)"].joined(separator: " ")
                if !hay.localizedCaseInsensitiveContains(search) { return false }
            }
            return true
        }
    }
}

struct TransactionDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var learn = true

    var body: some View {
        if let tx = store.state.transactions.first(where: { $0.id == id }) {
            let effect = store.aggregator.effect(of: tx)
            Form {
                Section {
                    LabeledContent("Amount", value: Fmt.money(tx.baseAmount ?? tx.amount))
                    if tx.currency != "SAR" { LabeledContent("Original amount", value: "\(tx.amount) \(tx.currency)") }
                    LabeledContent("Type", value: tx.direction == .debit ? String(localized: "Debit") : String(localized: "Credit"))
                    LabeledContent("Kind", value: tx.kind.rawValue)
                    LabeledContent("Status") { Text(tx.status.label) }
                    LabeledContent("Counted as", value: ReportExporterLabel.effect(effect))
                    LabeledContent("Date", value: Fmt.date(tx.date, time: tx.hasTime))
                    if let m = tx.merchantDisplay ?? tx.merchantRaw { LabeledContent("Merchant", value: m) }
                    if let c = tx.counterparty { LabeledContent("Counterparty", value: c) }
                    if let a = store.state.account(tx.accountID) { LabeledContent("Account", value: a.name) }
                    if let card = tx.cardLast4 { LabeledContent("Card", value: "•••• \(card)") }
                    if let r = tx.reference { LabeledContent("Reference", value: r) }
                    if let city = tx.city { LabeledContent("Location", value: city) }
                }
                Section("Category") {
                    CategoryPicker(selection: Binding(get: { tx.category }, set: { store.recategorize(id, to: $0, learn: learn) }))
                    Toggle("Apply to all transactions from this merchant", isOn: $learn)
                    Text("Source: \(tx.categorySource.rawValue) · confidence \(Fmt.percent(tx.categoryConfidence))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !tx.reviewReasons.isEmpty {
                    Section("Needs review") {
                        ForEach(tx.reviewReasons, id: \.self) { Text($0.arabicDescription) }
                        NavigationLink("Resolve") { ReviewDetailView(id: id) }
                    }
                }
                Section("Sources") {
                    ForEach(tx.sources, id: \.recordID) { s in
                        LabeledContent(s.type.label, value: Fmt.date(s.importedAt))
                    }
                }
                if let n = tx.note { Section("Note") { Text(n).font(.footnote) } }
                Section {
                    Button(tx.userExcluded ? "Include in totals" : "Exclude from totals") { store.toggleExcluded(id) }
                    if !tx.isInternalTransfer && (tx.kind == .transferOut || tx.kind == .transferIn) {
                        Button("Mark as internal transfer") { store.resolve(id, .markInternal) }
                    }
                    Button("Delete", role: .destructive) { store.delete(id); dismiss() }
                }
            }
            .navigationTitle(tx.displayName)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Deleted", systemImage: "trash")
        }
    }
}

enum ReportExporterLabel {
    static func effect(_ e: LedgerEffect) -> String {
        let ar = Fmt.isArabic
        switch e {
        case .expense: return ar ? "مصروف" : "Expense"
        case .refund: return ar ? "مبلغ مسترد (يخفض المصروفات)" : "Refund (reduces spending)"
        case .income: return ar ? "دخل" : "Income"
        case .incomingTransfer: return ar ? "تحويل وارد (ليس دخلاً)" : "Incoming transfer (not income)"
        case .cashWithdrawal: return ar ? "سحب نقدي (ليس مصروفاً)" : "Cash withdrawal (not spending)"
        case .internalTransfer: return ar ? "تحويل داخلي (غير محتسب)" : "Internal transfer (not counted)"
        case .pending: return ar ? "معلقة (غير محتسبة)" : "Pending (not counted)"
        case .unconfirmed: return ar ? "قيد المراجعة (غير محتسبة)" : "Under review (not counted)"
        case .excluded: return ar ? "مستبعدة" : "Excluded"
        }
    }
}

struct AddTransactionView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var isExpense = true
    @State private var merchant = ""
    @State private var category: Category = .other
    @State private var account: UUID?
    @State private var date = Date()
    @State private var note = ""
    @State private var kind: TransactionKind = .purchase

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $isExpense) {
                    Text("Expense").tag(true)
                    Text("Income").tag(false)
                }
                .pickerStyle(.segmented)
                TextField("Amount (SAR)", text: $amount).keyboardType(.decimalPad)
                TextField("Merchant / description", text: $merchant)
                CategoryPicker(selection: $category)
                Picker("Account", selection: $account) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.state.accounts.filter { !$0.isArchived }) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                DatePicker("Date", selection: $date)
                TextField("Note", text: $note)
            }
            .navigationTitle("Add transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let v = parseUserAmount(amount) else { return }
                        store.addManual(amount: v, direction: isExpense ? .debit : .credit,
                                        kind: isExpense ? .purchase : (category == .salary ? .income : .transferIn),
                                        date: date, merchant: merchant.isEmpty ? nil : merchant, accountID: account,
                                        category: category == .other && !merchant.isEmpty ? nil : category,
                                        note: note.isEmpty ? nil : note)
                        dismiss()
                    }
                    .disabled(parseUserAmount(amount) == nil)
                }
            }
            .onChange(of: isExpense) { _, exp in category = exp ? .other : .salary }
        }
    }
}
