import SwiftUI
import UniformTypeIdentifiers
import FinanceCore

struct MoreView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List {
            Section {
                NavigationLink { AccountsView() } label: { Label("Accounts", systemImage: "building.columns") }
                NavigationLink { BudgetsView() } label: { Label("Budgets", systemImage: "target") }
                NavigationLink { SubscriptionsView() } label: { Label("Subscriptions", systemImage: "arrow.triangle.2.circlepath") }
                NavigationLink { ReviewView() } label: { Label("Review queue", systemImage: "exclamationmark.triangle") }
                NavigationLink { ImportView() } label: { Label("Import", systemImage: "square.and.arrow.down") }
            }
            Section {
                NavigationLink { ConnectSourcesView() } label: { Label("Connect data sources", systemImage: "link") }
                NavigationLink { TemplatesView() } label: { Label("Bank message formats", systemImage: "text.badge.checkmark") }
                NavigationLink { IgnoredLogView() } label: { Label("Ignored messages", systemImage: "eye.slash") }
            }
            Section { NavigationLink { SettingsView() } label: { Label("Settings & privacy", systemImage: "lock.shield") } }
        }
        .navigationTitle("More")
    }
}

/// Honest status of every source, per iOS and Saudi market constraints.
struct ConnectSourcesView: View {
    var body: some View {
        List {
            source("Bank SMS (SNB, Barq, D360…)", "Available via Shortcuts automation",
                   "iOS does not let apps read SMS. Create a personal automation in Shortcuts: Message → sender contains your bank → action “Log Bank Message”. Set it to run immediately.", .green)
            source("Apple Pay", "Available via Shortcuts Wallet automation",
                   "Shortcuts → Automation → Transaction → choose cards → action “Log Apple Pay Payment” with Merchant, Amount, Card from Shortcut Input. The bank SMS later merges into the same transaction.", .green)
            source("Bank statements", "Available: CSV, Excel, PDF",
                   "Download the e-statement from the bank app and import it. Re-importing overlapping periods is safe.", .green)
            source("Email receipts", "Available: .eml import",
                   "Share or save the email as .eml and import it. Direct Gmail/Outlook sync requires your own OAuth client (planned phase).", .yellow)
            source("Open Banking (SAMA)", "Requires a licensed provider",
                   "Account Information Services in Saudi Arabia are offered only through SAMA-licensed providers under a commercial agreement. The app contains the data mapper; a provider contract and server are needed to activate it.", .orange)
            source("Other apps' notifications", "Not possible on iOS",
                   "iOS has no API to read notifications of other apps. Use the bank's SMS alerts instead.", .red)
            source("Apple Wallet history / FinanceKit", "Not available for Saudi cards",
                   "FinanceKit requires an Apple entitlement and covers Apple Card / Apple Cash (US), not mada or Saudi bank cards.", .red)
        }
        .navigationTitle("Data sources")
    }

    func source(_ title: LocalizedStringKey, _ status: LocalizedStringKey, _ detail: LocalizedStringKey, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Circle().fill(color).frame(width: 10, height: 10); Text(title).font(.headline) }
            Text(status).font(.subheadline).foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct TemplatesView: View {
    @Environment(AppStore.self) private var store
    @State private var name = ""
    @State private var sender = ""
    @State private var pattern = ""
    @State private var kind: TransactionKind = .purchase
    @State private var sample = ""

    var body: some View {
        Form {
            Section {
                Text("The built-in parser understands common Arabic/English bank formats. If a bank's message is parsed wrongly, add a template with named groups: (?<amount>…), (?<currency>…), (?<merchant>…), (?<card>…), (?<date>…), (?<balance>…).")
                    .font(.caption)
            }
            ForEach(store.state.smsTemplates) { t in
                VStack(alignment: .leading) {
                    Text(t.name).font(.headline)
                    Text(t.pattern).font(.caption.monospaced()).lineLimit(2)
                }
                .swipeActions { Button("Delete", role: .destructive) { store.setTemplates(store.state.smsTemplates.filter { $0.id != t.id }) } }
            }
            Section("New template") {
                TextField("Name", text: $name)
                TextField("Sender", text: $sender)
                TextField("Regex pattern", text: $pattern, axis: .vertical).font(.caption.monospaced())
                Picker("Kind", selection: $kind) { ForEach(TransactionKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField("Sample message to test", text: $sample, axis: .vertical)
                if !sample.isEmpty { Text(testResult).font(.caption) }
                Button("Add") {
                    let dir: Direction = [.transferIn, .income, .refund, .cashDeposit].contains(kind) ? .credit : .debit
                    store.setTemplates(store.state.smsTemplates + [SMSTemplate(name: name, senders: sender.isEmpty ? [] : [sender], pattern: pattern, kind: kind, direction: dir)])
                    name = ""; pattern = ""; sample = ""
                }
                .disabled(name.isEmpty || (try? NSRegularExpression(pattern: pattern)) == nil)
            }
        }
        .navigationTitle("Message formats")
    }

    var testResult: String {
        let dir: Direction = [.transferIn, .income, .refund, .cashDeposit].contains(kind) ? .credit : .debit
        let p = SMSParser(timeZone: store.state.settings.timeZone,
                          templates: pattern.isEmpty ? [] : [SMSTemplate(name: "test", senders: [], pattern: pattern, kind: kind, direction: dir)])
        switch p.parse(text: sample, sender: nil, receivedAt: Date()) {
        case .record(let r):
            return "✓ \(r.kind.rawValue) \(r.direction?.rawValue ?? "?") \(r.amount.map { "\($0)" } ?? "?") \(r.currency ?? "") · \(r.merchant ?? r.counterparty ?? "-") · card \(r.cardLast4 ?? "-") · confidence \(Int(r.confidence * 100))%"
        case .ignored(let reason): return "Ignored: \(reason)"
        case .balance(_, _, let b, _, _, _): return "Balance only: \(b)"
        case .unparseable: return "Not recognised"
        }
    }
}

struct IgnoredLogView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        List(store.state.ignoredLog.reversed(), id: \.self) { r in
            VStack(alignment: .leading) {
                Text(r.reason).font(.caption.bold())
                Text(r.preview).font(.caption).foregroundStyle(.secondary)
                Text(Fmt.date(r.date)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .navigationTitle("Ignored messages")
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var confirmErase = false
    @State private var backupURL: URL?
    @State private var showRestore = false
    @State private var ownerNames = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section("Security") {
                Toggle("Require Face ID", isOn: Binding(get: { store.state.settings.faceIDEnabled },
                                                        set: { v in store.updateSettings { $0.faceIDEnabled = v } }))
                Text("Data is encrypted with AES-256-GCM. The key is stored in the iOS Keychain on this device only. Nothing is uploaded; the app makes no network requests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Accounting rules") {
                Toggle("Count transfers to other people as spending", isOn: Binding(get: { store.state.settings.countExternalTransfersAsSpending },
                                                                                   set: { v in store.updateSettings { $0.countExternalTransfersAsSpending = v } }))
                Toggle("Count ATM withdrawals as spending", isOn: Binding(get: { store.state.settings.cashWithdrawalsAsSpending },
                                                                         set: { v in store.updateSettings { $0.cashWithdrawalsAsSpending = v } }))
                TextField("Your name as it appears on transfers", text: $ownerNames)
                    .onSubmit { store.updateSettings { $0.ownerNames = AccountEditView.list(ownerNames) } }
            }
            Section("Notifications") {
                Toggle("Notify on every new expense", isOn: Binding(get: { store.state.settings.notifyNewExpense },
                                                                   set: { v in store.updateSettings { $0.notifyNewExpense = v } }))
                Stepper("Stale account alert after \(store.state.settings.staleAccountDays) days",
                        value: Binding(get: { store.state.settings.staleAccountDays }, set: { v in store.updateSettings { $0.staleAccountDays = v } }), in: 1...60)
                Stepper("Subscription reminder \(store.state.settings.upcomingChargeNoticeDays) days before",
                        value: Binding(get: { store.state.settings.upcomingChargeNoticeDays }, set: { v in store.updateSettings { $0.upcomingChargeNoticeDays = v } }), in: 0...14)
            }
            Section {
                Button("Export backup (JSON)") {
                    do { backupURL = try store.exportBackup() } catch { message = error.localizedDescription }
                }
                if let backupURL { ShareLink(item: backupURL) { Label("Share backup", systemImage: "square.and.arrow.up") } }
                Button("Restore from backup") { showRestore = true }
            } header: { Text("Backup") } footer: {
                Text("The backup file is NOT encrypted. Store it only in a place you trust (e.g. an encrypted drive). Optional encrypted iCloud sync is planned.")
            }
            Section {
                Button("Delete all data", role: .destructive) { confirmErase = true }
            }
            if let message { Text(message).font(.footnote) }
        }
        .navigationTitle("Settings")
        .onAppear { ownerNames = store.state.settings.ownerNames.joined(separator: ", ") }
        .confirmationDialog("Delete all transactions, accounts, budgets, rules and the encryption key?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { store.eraseEverything(); message = String(localized: "All data deleted.") }
        }
        .fileImporter(isPresented: $showRestore, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try store.restoreBackup(from: url); message = String(localized: "Backup restored.") } catch { message = error.localizedDescription }
        }
    }
}
