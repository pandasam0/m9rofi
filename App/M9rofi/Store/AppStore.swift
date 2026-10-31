import Foundation
import Observation
import FinanceCore

/// Main-actor façade over the value-type `Ledger`. Every mutation persists and refreshes alerts.
@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    private(set) var ledger: Ledger
    private(set) var loadError: String?
    var lastReport: IngestReport?
    private let store = EncryptedLedgerStore()

    var state: LedgerState { ledger.state }
    var aggregator: Aggregator { Aggregator(state: ledger.state) }
    var isArabic: Bool { Locale.current.language.languageCode?.identifier != "en" }

    private init() {
        do {
            ledger = Ledger(state: try EncryptedLedgerStore().load())
        } catch {
            // Never overwrite an unreadable file silently: keep it and start read-only in memory.
            ledger = Ledger()
            loadError = "تعذر فتح البيانات المشفرة: \(error.localizedDescription)"
        }
    }

    // MARK: Persistence

    private func persist() {
        guard loadError == nil else { return }
        do { try store.save(ledger.state) } catch { loadError = "تعذر حفظ البيانات: \(error.localizedDescription)" }
    }

    private func commit(_ report: IngestReport? = nil) {
        if let report { lastReport = report }
        persist()
        Task { await NotificationService.shared.deliver(store: self, newTransactionIDs: report?.added ?? []) }
    }

    func markAlertsFired(_ keys: [String]) {
        ledger.state.firedAlertKeys.formUnion(keys)
        persist()
    }

    // MARK: Ingestion entry points (all sources)

    @discardableResult
    func ingestMessage(_ text: String, sender: String?, receivedAt: Date = Date()) -> IngestReport {
        let parser = SMSParser(timeZone: state.settings.timeZone, templates: state.smsTemplates)
        let outcome = parser.parse(text: text, sender: sender, receivedAt: receivedAt)
        let report = ledger.ingest([outcome], source: .sms)
        if case .ignored(let reason) = outcome, let i = ledger.state.ignoredLog.indices.last {
            ledger.state.ignoredLog[i].preview = String(text.prefix(80))
            ledger.state.ignoredLog[i].reason = reason
        }
        commit(report)
        return report
    }

    @discardableResult
    func ingestWallet(merchant: String?, amountText: String, cardName: String?, date: Date = Date()) -> IngestReport {
        let r = WalletAutomationAdapter.record(merchant: merchant, amountText: amountText, cardName: cardName, date: date)
        let report = ledger.ingest(records: [r])
        commit(report)
        return report
    }

    @discardableResult
    func ingest(records: [RawRecord], closingBalance: (Decimal, Date)? = nil, accountID: UUID? = nil) -> IngestReport {
        let report = ledger.ingest(records: records)
        if let (bal, date) = closingBalance, let accountID { ledger.setBalance(accountID: accountID, balance: bal, date: date) }
        commit(report)
        return report
    }

    func addManual(amount: Decimal, direction: Direction, kind: TransactionKind, date: Date, merchant: String?,
                   accountID: UUID?, category: Category?, note: String?) {
        commit(ledger.addManual(amount: amount, direction: direction, kind: kind, date: date, merchant: merchant,
                                accountID: accountID, category: category, note: note))
    }

    // MARK: Editing

    func recategorize(_ id: UUID, to c: Category, learn: Bool) { ledger.recategorize(id, to: c, learn: learn); commit() }
    func resolve(_ id: UUID, _ r: ReviewResolution) { ledger.resolve(id, r); commit() }
    func delete(_ id: UUID) { ledger.delete(id); commit() }
    func update(_ tx: LedgerTransaction) { ledger.update(tx); commit() }
    func toggleExcluded(_ id: UUID) {
        guard var t = state.transactions.first(where: { $0.id == id }) else { return }
        t.userExcluded.toggle()
        ledger.update(t); commit()
    }
    func upsert(_ a: Account) { ledger.upsert(a); commit() }
    func archive(_ id: UUID) {
        guard var a = state.account(id) else { return }
        a.isArchived = true
        ledger.upsert(a); commit()
    }
    func setBalance(_ id: UUID, _ v: Decimal) { ledger.setBalance(accountID: id, balance: v, date: Date()); commit() }
    func setBudget(_ c: Category, _ limit: Decimal?) {
        ledger.state.budgets.removeAll { $0.category == c }
        if let limit, limit > 0 { ledger.state.budgets.append(Budget(category: c, monthlyLimit: limit)) }
        commit()
    }
    func updateSettings(_ f: (inout LedgerSettings) -> Void) { f(&ledger.state.settings); commit() }
    func setTemplates(_ t: [SMSTemplate]) { ledger.state.smsTemplates = t; commit() }
    func applyAISuggestion(_ id: UUID, _ c: Category, _ conf: Double) { ledger.applyAISuggestion(id, category: c, confidence: conf); persist() }

    // MARK: Privacy

    func eraseEverything() {
        ledger.eraseAllData()
        store.destroy()
        NotificationService.shared.removeAll()
        loadError = nil
    }

    /// Plain JSON backup — only on explicit user request, shared via the system share sheet.
    func exportBackup() throws -> URL {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("m9rofi-backup.json")
        try enc.encode(state).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func restoreBackup(from url: URL) throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        ledger = Ledger(state: try dec.decode(LedgerState.self, from: Data(contentsOf: url)))
        loadError = nil
        persist()
    }
}
