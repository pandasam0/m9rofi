import SwiftUI
import FinanceCore

struct AccountsView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: Account?

    var body: some View {
        List {
            ForEach(store.state.accounts.filter { !$0.isArchived }) { a in
                Button { editing = a } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(a.name).foregroundStyle(.primary)
                            Text("\(a.institution.displayName) · \(a.type.rawValue)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let b = store.state.latestBalance(for: a.id) {
                            Text(Fmt.money(b.balance)).monospacedDigit().foregroundStyle(.primary)
                        }
                    }
                }
                .swipeActions { Button("Archive", role: .destructive) { store.archive(a.id) } }
            }
            Section {
                Menu {
                    Button("SNB Al Ahli") { editing = Account(name: "الأهلي", institution: .snb, type: .current, smsSenders: ["SNB-AlAhli", "SNB"]) }
                    Button("Barq") { editing = Account(name: "Barq", institution: .barq, type: .wallet, smsSenders: ["Barq"]) }
                    Button("D360") { editing = Account(name: "D360", institution: .d360, type: .current, smsSenders: ["D360"]) }
                    Button("Credit card") { editing = Account(name: "بطاقة ائتمانية", institution: .snb, type: .creditCard) }
                    Button("Cash") { editing = Account(name: "نقد", institution: .cash, type: .cash) }
                    Button("Other") { editing = Account(name: "", institution: .other, type: .current) }
                } label: { Label("Add account", systemImage: "plus") }
            } footer: {
                Text("Card and account last-4 digits link SMS, Apple Pay and statements to the right account and detect transfers between your own accounts. Never enter full card numbers or CVV.")
            }
        }
        .navigationTitle("Accounts")
        .sheet(item: $editing) { AccountEditView(account: $0) }
    }
}

struct AccountEditView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var account: Account
    @State private var cards = ""
    @State private var numbers = ""
    @State private var walletNames = ""
    @State private var senders = ""
    @State private var balance = ""
    @State private var lowBalance = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $account.name)
                Picker("Institution", selection: $account.institution) {
                    ForEach(Institution.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Type", selection: $account.type) {
                    ForEach(AccountType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Section {
                    TextField("Card last 4 (comma separated)", text: $cards).keyboardType(.numbersAndPunctuation)
                    TextField("Account / IBAN last 4", text: $numbers).keyboardType(.numbersAndPunctuation)
                    TextField("Card name in Apple Wallet", text: $walletNames)
                    TextField("SMS sender names", text: $senders)
                } header: { Text("Matching") } footer: { Text("Last 4 digits only.") }
                Section("Balance") {
                    TextField("Current balance", text: $balance).keyboardType(.decimalPad)
                    TextField("Low balance alert below", text: $lowBalance).keyboardType(.decimalPad)
                }
                Toggle("Transactions of this account are imported", isOn: $account.isTracked)
            }
            .navigationTitle(account.name.isEmpty ? "Account" : account.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        account.cardLast4 = Self.last4List(cards)
                        account.accountLast4 = Self.last4List(numbers)
                        account.walletCardNames = Self.list(walletNames)
                        account.smsSenders = Self.list(senders)
                        account.lowBalanceThreshold = TextNormalizer.parseAmount(lowBalance)
                        store.upsert(account)
                        if let b = TextNormalizer.parseAmount(balance) { store.setBalance(account.id, b) }
                        dismiss()
                    }
                    .disabled(account.name.isEmpty)
                }
            }
            .onAppear {
                cards = account.cardLast4.joined(separator: ", ")
                numbers = account.accountLast4.joined(separator: ", ")
                walletNames = account.walletCardNames.joined(separator: ", ")
                senders = account.smsSenders.joined(separator: ", ")
                lowBalance = account.lowBalanceThreshold.map { "\($0)" } ?? ""
            }
        }
    }

    static func list(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == "،" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Keeps only the last 4 digits of each entry — full numbers are never stored.
    static func last4List(_ s: String) -> [String] {
        list(TextNormalizer.normalizeDigits(s)).map { String($0.filter(\.isNumber).suffix(4)) }.filter { $0.count == 4 }
    }
}
