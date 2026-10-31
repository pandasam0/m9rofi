import Foundation

public struct IngestReport: Sendable, Equatable {
    public var added: [UUID] = []
    public var merged: [UUID] = []
    public var exactDuplicates = 0
    public var flaggedForReview: [UUID] = []
    public var ignored = 0
    public var unparseable = 0
    public var balancesUpdated = 0
    public var internalTransfersMatched = 0
    public init() {}
}

public enum ReviewResolution: Sendable, Equatable {
    /// Accept the transaction as-is (clears review reasons). Optional corrected values.
    case confirm(amount: Decimal? = nil, baseAmount: Decimal? = nil, direction: Direction? = nil)
    /// It is the same as an existing transaction: merge sources into it and remove this one.
    case mergeInto(UUID)
    /// It is an internal transfer between own accounts.
    case markInternal
    /// Credit-card payment for an untracked card: count the payment itself as spending.
    case countCardPaymentAsExpense
    /// Not a real transaction.
    case delete
}

/// The single source of truth. All sources feed `ingest`, all screens read `state` via `Aggregator`.
/// Value type → deterministic and fully unit-testable.
public struct Ledger: Sendable {
    public var state: LedgerState

    public init(state: LedgerState = LedgerState()) { self.state = state }

    var calendar: Calendar { state.settings.calendar }

    // MARK: - Ingest

    public mutating func ingest(_ outcomes: [ParseOutcome], source: SourceType, now: Date = Date()) -> IngestReport {
        var report = IngestReport()
        var records: [RawRecord] = []
        for o in outcomes {
            switch o {
            case .record(let r): records.append(r)
            case .ignored(let reason):
                report.ignored += 1
                appendIgnored(IgnoredRecord(date: now, source: source, reason: reason, preview: ""))
            case .unparseable:
                report.unparseable += 1
            case let .balance(acc, card, balance, currency, date, hint):
                if let id = resolveAccount(accountID: nil, card: card, account: acc, walletName: nil, hint: hint) {
                    if addBalance(BalanceSnapshot(accountID: id, balance: balance, currency: currency, date: date, source: source)) {
                        report.balancesUpdated += 1
                    }
                }
            }
        }
        let r = ingest(records: records, now: now)
        report.added += r.added
        report.merged += r.merged
        report.exactDuplicates += r.exactDuplicates
        report.flaggedForReview += r.flaggedForReview
        report.balancesUpdated += r.balancesUpdated
        report.internalTransfersMatched += r.internalTransfersMatched
        return report
    }

    public mutating func ingest(records: [RawRecord], now: Date = Date()) -> IngestReport {
        var report = IngestReport()
        // Process chronologically so pending→completed and transfer pairs resolve naturally.
        for record in records.sorted(by: { ($0.date ?? now) < ($1.date ?? now) }) {
            ingestOne(record, now: now, report: &report)
        }
        return report
    }

    private mutating func ingestOne(_ r: RawRecord, now: Date, report: inout IngestReport) {
        // 1. Exact duplicate (same source record seen before, even if the transaction was later deleted).
        if state.seenSourceRecordIDs.contains(r.sourceRecordID) { report.exactDuplicates += 1; return }
        state.seenSourceRecordIDs.insert(r.sourceRecordID)

        var tx = makeTransaction(from: r, now: now)

        // 2. Balance snapshot
        if let bal = r.balanceAfter, let acc = tx.accountID {
            if addBalance(BalanceSnapshot(accountID: acc, balance: bal, currency: state.account(acc)?.currency ?? "SAR",
                                          date: tx.date, source: r.source)) { report.balancesUpdated += 1 }
        }

        // 3. Reversals cancel an earlier transaction instead of adding money.
        if tx.kind == .reversal {
            if let originalIdx = findReversalTarget(for: tx) {
                state.transactions[originalIdx].status = .reversed
                tx.linkedTransactionID = state.transactions[originalIdx].id
                tx.status = .reversed
                tx.category = state.transactions[originalIdx].category
            } else {
                tx.reviewReasons.append(.unmatchedReversal)
            }
            insert(tx, report: &report)
            return
        }

        // 4. Cross-source duplicate / pending→completed merge.
        if tx.reviewReasons.isEmpty || tx.reviewReasons == [.lowParseConfidence] {
            switch findDuplicate(of: tx) {
            case .match(let idx):
                merge(tx, into: idx)
                report.merged.append(state.transactions[idx].id)
                return
            case .ambiguous(let candidateID):
                tx.reviewReasons.append(.possibleDuplicate)
                tx.linkedTransactionID = candidateID
            case .none:
                break
            }
        }

        // 5. Refund → link original purchase and inherit its category.
        if tx.kind == .refund, let idx = findRefundTarget(for: tx) {
            tx.linkedTransactionID = state.transactions[idx].id
            tx.category = state.transactions[idx].category
            tx.categorySource = state.transactions[idx].categorySource
            tx.categoryConfidence = state.transactions[idx].categoryConfidence
            if let a = tx.baseAmount, let b = state.transactions[idx].baseAmount, a >= b {
                state.transactions[idx].status = .refunded
            }
        }

        // 6. Internal transfer / card payment detection.
        if [.transferOut, .transferIn, .cardPayment, .purchase, .cashDeposit, .unknown].contains(tx.kind) {
            if matchInternalTransfer(&tx) { report.internalTransfersMatched += 1 }
        }
        if tx.kind == .cardPayment && !tx.isInternalTransfer {
            let hasTrackedCard = state.accounts.contains { $0.type == .creditCard && $0.isTracked && !$0.isArchived }
            if hasTrackedCard || tx.direction == .credit { tx.isInternalTransfer = true }
            else { tx.reviewReasons.append(.cardPaymentUntrackedCard) }
        }

        // 7. Categorise.
        if tx.categorySource == .none {
            applyCategory(&tx)
        }
        insert(tx, report: &report)
    }

    private mutating func insert(_ tx: Transaction, report: inout IngestReport) {
        state.transactions.append(tx)
        report.added.append(tx.id)
        if tx.needsReview { report.flaggedForReview.append(tx.id) }
    }

    func makeTransaction(from r: RawRecord, now: Date) -> Transaction {
        var reasons: [ReviewReason] = []
        if r.amount == nil || r.amount == 0 { reasons.append(.missingAmount) }
        if r.direction == nil { reasons.append(.unknownDirection) }
        let currency = (r.currency ?? "SAR").uppercased()
        var base = r.baseAmount
        if base == nil, currency == state.settings.baseCurrency { base = r.amount }
        if base == nil, r.amount != nil { reasons.append(.missingBaseCurrencyAmount) }
        if r.confidence < 0.5 { reasons.append(.lowParseConfidence) }

        let accountID = resolveAccount(accountID: r.accountID, card: r.cardLast4, account: r.accountLast4,
                                       walletName: r.walletCardName, hint: r.institutionHint)
        let merchantName = r.merchant.map(TextNormalizer.titleCaseMerchant)
        let keySource = r.merchant ?? r.counterparty
        var tx = Transaction(
            amount: abs(r.amount ?? 0), currency: currency, baseAmount: base.map { abs($0) },
            direction: r.direction ?? .debit, kind: r.kind, status: r.status, date: r.date ?? now, hasTime: r.hasTime,
            merchantRaw: r.merchant, merchantKey: keySource.map(TextNormalizer.merchantKey),
            merchantDisplay: merchantName, counterparty: r.counterparty, accountID: accountID,
            cardLast4: r.cardLast4, accountLast4: r.accountLast4, counterpartyAccountLast4: r.counterpartyAccountLast4,
            mcc: r.mcc, location: r.location, city: r.city, reference: r.reference, note: r.note,
            sources: [SourceRef(type: r.source, recordID: r.sourceRecordID, importedAt: now)],
            reviewReasons: reasons, balanceAfter: r.balanceAfter, createdAt: now)
        if let hint = r.categoryHint {
            tx.category = hint; tx.categorySource = .user; tx.categoryConfidence = 1
        }
        return tx
    }

    // MARK: - Account resolution

    public func resolveAccount(accountID: UUID?, card: String?, account: String?, walletName: String?, hint: String?) -> UUID? {
        if let accountID { return accountID }
        let active = state.accounts.filter { !$0.isArchived }
        if let card, let a = active.first(where: { $0.cardLast4.contains(card) }) { return a.id }
        if let account, let a = active.first(where: { $0.accountLast4.contains(account) }) { return a.id }
        if let walletName {
            let w = walletName.lowercased()
            if let a = active.first(where: { $0.walletCardNames.contains { n in w.contains(n.lowercased()) || n.lowercased().contains(w) } }) {
                return a.id
            }
        }
        if let hint {
            let matches = active.filter { $0.smsSenders.contains { $0.caseInsensitiveCompare(hint) == .orderedSame } }
            if matches.count == 1 { return matches[0].id }
        }
        return nil
    }

    // MARK: - Duplicate detection

    enum DuplicateResult { case none, match(Int), ambiguous(UUID) }

    func findDuplicate(of tx: Transaction) -> DuplicateResult {
        let incomingSource = tx.sources.first!.type
        var scored: [(Int, Double)] = []
        for (i, c) in state.transactions.enumerated() {
            guard c.direction == tx.direction, c.kind != .reversal, c.status != .reversed, !c.userExcluded else { continue }
            let pendingUpgrade = c.status == .pending && tx.status == .completed
            // Same source type can only merge as pending→completed.
            if c.sources.contains(where: { $0.type == incomingSource }) && !pendingUpgrade { continue }
            guard let s = duplicateScore(c, tx, pendingUpgrade: pendingUpgrade) else { continue }
            scored.append((i, s))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return .none }
        let competitors = scored.filter { $0.0 != best.0 && $0.1 > best.1 - 0.2 }
        if best.1 >= 0.6 && competitors.isEmpty { return .match(best.0) }
        if best.1 >= 0.3 { return .ambiguous(state.transactions[best.0].id) }
        return .none
    }

    /// nil = cannot be the same transaction.
    func duplicateScore(_ a: Transaction, _ b: Transaction, pendingUpgrade: Bool) -> Double? {
        // Amount must agree in original currency, or in SAR.
        let sameOriginal = a.currency == b.currency && a.amount == b.amount
        let sameBase = a.baseAmount != nil && a.baseAmount == b.baseAmount
        guard sameOriginal || sameBase else { return nil }
        if let x = a.accountID, let y = b.accountID, x != y { return nil }
        if let x = a.cardLast4, let y = b.cardLast4, x != y { return nil }
        if let x = a.reference, let y = b.reference {
            return x == y ? 1.0 : nil
        }
        var score = 0.0
        let dt = abs(a.date.timeIntervalSince(b.date))
        if a.hasTime && b.hasTime {
            if dt <= 15 * 60 { score += 0.45 }
            else if dt <= 3 * 3600 { score += 0.2 }
            else if pendingUpgrade && dt <= 5 * 86400 { score += 0.2 }
            else { return nil }
        } else {
            // Statement rows carry posting date: allow up to 4 days drift.
            guard dt <= 4 * 86400 + 12 * 3600 else { return nil }
            score += dt <= 36 * 3600 ? 0.3 : 0.15
        }
        let sim = TextNormalizer.similarity(a.merchantRaw ?? a.counterparty ?? a.note, b.merchantRaw ?? b.counterparty ?? b.note)
        let aHasName = (a.merchantRaw ?? a.counterparty) != nil, bHasName = (b.merchantRaw ?? b.counterparty) != nil
        if sim >= 0.5 { score += 0.4 }
        else if !aHasName || !bHasName { score += 0.1 }
        else if sim < 0.2 { score -= 0.3 }
        if a.accountID != nil && a.accountID == b.accountID { score += 0.15 }
        if a.cardLast4 != nil && a.cardLast4 == b.cardLast4 { score += 0.15 }
        if a.kind == b.kind { score += 0.05 }
        return score
    }

    mutating func merge(_ incoming: Transaction, into idx: Int) {
        var t = state.transactions[idx]
        t.sources.append(contentsOf: incoming.sources)
        if t.status == .pending && incoming.status == .completed {
            t.status = .completed
            // Posted amount is authoritative (FX settlement may differ from authorisation).
            if incoming.baseAmount != nil { t.baseAmount = incoming.baseAmount }
        }
        if t.baseAmount == nil { t.baseAmount = incoming.baseAmount; t.reviewReasons.removeAll { $0 == .missingBaseCurrencyAmount } }
        if t.merchantRaw == nil { t.merchantRaw = incoming.merchantRaw; t.merchantDisplay = incoming.merchantDisplay; t.merchantKey = incoming.merchantKey }
        if !t.hasTime && incoming.hasTime { t.date = incoming.date; t.hasTime = true }
        t.accountID = t.accountID ?? incoming.accountID
        t.cardLast4 = t.cardLast4 ?? incoming.cardLast4
        t.accountLast4 = t.accountLast4 ?? incoming.accountLast4
        t.reference = t.reference ?? incoming.reference
        t.mcc = t.mcc ?? incoming.mcc
        t.location = t.location ?? incoming.location
        t.city = t.city ?? incoming.city
        t.balanceAfter = t.balanceAfter ?? incoming.balanceAfter
        t.counterparty = t.counterparty ?? incoming.counterparty
        t.counterpartyAccountLast4 = t.counterpartyAccountLast4 ?? incoming.counterpartyAccountLast4
        if t.kind == .unknown { t.kind = incoming.kind }
        if t.categorySource == .none || (t.categoryConfidence < 0.75 && t.categorySource != .user && t.categorySource != .learnedRule) {
            applyCategory(&t)
        }
        state.transactions[idx] = t
    }

    // MARK: - Reversal / refund

    func findReversalTarget(for tx: Transaction) -> Int? {
        let window: TimeInterval = 45 * 86400
        let candidates = state.transactions.indices.filter { i in
            let c = state.transactions[i]
            guard c.status != .reversed, c.kind != .reversal, c.date <= tx.date.addingTimeInterval(3600),
                  tx.date.timeIntervalSince(c.date) <= window else { return false }
            let amountOK = (c.currency == tx.currency && c.amount == tx.amount) || (c.baseAmount != nil && c.baseAmount == tx.baseAmount)
            guard amountOK else { return false }
            if let x = c.accountID, let y = tx.accountID, x != y { return false }
            if let x = c.cardLast4, let y = tx.cardLast4, x != y { return false }
            if tx.merchantRaw != nil && c.merchantRaw != nil && TextNormalizer.similarity(c.merchantRaw, tx.merchantRaw) < 0.3 { return false }
            return true
        }
        // Most recent candidate; ambiguity across distinct merchants → nil (review).
        guard let best = candidates.max(by: { state.transactions[$0].date < state.transactions[$1].date }) else { return nil }
        if tx.merchantRaw == nil && Set(candidates.compactMap { state.transactions[$0].merchantKey }).count > 1 { return nil }
        return best
    }

    func findRefundTarget(for tx: Transaction) -> Int? {
        guard tx.merchantRaw != nil, let amount = tx.baseAmount else { return nil }
        return state.transactions.indices.filter { i in
            let c = state.transactions[i]
            return c.direction == .debit && (c.kind == .purchase || c.kind == .billPayment) && c.status != .reversed
                && c.date <= tx.date && tx.date.timeIntervalSince(c.date) <= 180 * 86400
                && (c.baseAmount ?? 0) >= amount
                && TextNormalizer.similarity(c.merchantRaw, tx.merchantRaw) >= 0.5
        }.max { state.transactions[$0].date < state.transactions[$1].date }
    }

    // MARK: - Internal transfers

    func ownedIdentifiers(excluding accountID: UUID?) -> Set<String> {
        var s = Set<String>()
        for a in state.accounts where a.id != accountID { s.formUnion(a.accountLast4); s.formUnion(a.cardLast4) }
        return s
    }

    func institutionNames(of account: Account) -> [String] {
        var names = [account.name.lowercased()]
        switch account.institution {
        case .snb: names += ["snb", "alahli", "الأهلي", "الاهلي", "ncb"]
        case .barq: names += ["barq", "برق"]
        case .d360: names += ["d360", "d 360", "دي 360"]
        case .applePayCash: names += ["apple cash"]
        default: break
        }
        if let c = account.customInstitutionName { names.append(c.lowercased()) }
        return names
    }

    /// Returns true when a counterpart transaction was found and linked.
    mutating func matchInternalTransfer(_ tx: inout Transaction) -> Bool {
        // a) Destination/source account number belongs to the user.
        if let cp = tx.counterpartyAccountLast4, ownedIdentifiers(excluding: tx.accountID).contains(cp),
           tx.kind != .purchase {
            tx.isInternalTransfer = true
        }
        // b) Opposite leg in another owned account.
        guard let amount = tx.baseAmount else { return false }
        let opposite: Direction = tx.direction == .debit ? .credit : .debit
        let candidates = state.transactions.indices.filter { i in
            let c = state.transactions[i]
            guard c.direction == opposite, c.linkedTransactionID == nil, c.baseAmount == amount, c.status != .reversed,
                  !c.needsReview || c.reviewReasons == [.possibleInternalTransfer],
                  let ca = c.accountID, let ta = tx.accountID, ca != ta else { return false }
            // Both legs of an own transfer are near-simultaneous; statements (date only) allow 3 days.
            let dt = abs(c.date.timeIntervalSince(tx.date))
            guard dt <= ((c.hasTime && tx.hasTime) ? 6 * 3600 : 3 * 86400) else { return false }
            let (debit, credit) = tx.direction == .debit ? (tx, c) : (c, tx)
            return isTransferPair(debit: debit, credit: credit)
        }
        if let idx = candidates.min(by: { abs(state.transactions[$0].date.timeIntervalSince(tx.date)) < abs(state.transactions[$1].date.timeIntervalSince(tx.date)) }) {
            state.transactions[idx].isInternalTransfer = true
            state.transactions[idx].linkedTransactionID = tx.id
            state.transactions[idx].reviewReasons.removeAll { $0 == .possibleInternalTransfer }
            state.transactions[idx].category = .internalTransfer
            state.transactions[idx].categorySource = .kindDefault
            tx.isInternalTransfer = true
            tx.linkedTransactionID = state.transactions[idx].id
            tx.category = .internalTransfer
            tx.categorySource = .kindDefault
            return true
        }
        if tx.isInternalTransfer {
            tx.category = .internalTransfer; tx.categorySource = .kindDefault
            return false
        }
        // c) Counterparty name is the owner → probably own account elsewhere: ask.
        if tx.kind == .transferOut || tx.kind == .transferIn, let cp = tx.counterparty?.lowercased(),
           state.settings.ownerNames.contains(where: { !$0.isEmpty && cp.contains($0.lowercased()) }) {
            tx.reviewReasons.append(.possibleInternalTransfer)
        }
        return false
    }

    func isTransferPair(debit: Transaction, credit: Transaction) -> Bool {
        let creditKinds: Set<TransactionKind> = [.transferIn, .unknown, .cardPayment, .cashDeposit]
        guard creditKinds.contains(credit.kind) else { return false }
        switch debit.kind {
        case .transferOut, .unknown:
            return true
        case .cardPayment:
            return state.account(credit.accountID)?.type == .creditCard || credit.kind == .cardPayment
        case .purchase:
            // Wallet top-up paid by card: merchant is the receiving wallet (e.g. "BARQ").
            guard let receiver = state.account(credit.accountID), let m = debit.merchantKey else { return false }
            return institutionNames(of: receiver).contains { !$0.isEmpty && m.contains($0) }
        default:
            return false
        }
    }

    // MARK: - Categories

    func applyCategory(_ tx: inout Transaction) {
        if tx.isInternalTransfer { tx.category = .internalTransfer; tx.categorySource = .kindDefault; tx.categoryConfidence = 1; return }
        let d = Categorizer(rules: state.categoryRules).categorize(tx)
        tx.category = d.category
        tx.categorySource = d.source
        tx.categoryConfidence = d.confidence
    }

    /// User correction. With `learn`, every past and future transaction of the same merchant follows.
    public mutating func recategorize(_ id: UUID, to category: Category, learn: Bool = true) {
        guard let idx = state.transactions.firstIndex(where: { $0.id == id }) else { return }
        state.transactions[idx].category = category
        state.transactions[idx].categorySource = .user
        state.transactions[idx].categoryConfidence = 1
        if category == .internalTransfer { state.transactions[idx].isInternalTransfer = true }
        guard learn, let key = state.transactions[idx].merchantKey, !key.isEmpty else { return }
        state.categoryRules.removeAll { $0.merchantKey == key }
        state.categoryRules.append(CategoryRule(merchantKey: key, category: category))
        for i in state.transactions.indices where state.transactions[i].merchantKey == key
            && state.transactions[i].categorySource != .user && !state.transactions[i].isInternalTransfer {
            state.transactions[i].category = category
            state.transactions[i].categorySource = .learnedRule
            state.transactions[i].categoryConfidence = 1
        }
    }

    /// Apply an external (AI) category suggestion for low-confidence transactions only.
    public mutating func applyAISuggestion(_ id: UUID, category: Category, confidence: Double) {
        guard let idx = state.transactions.firstIndex(where: { $0.id == id }),
              state.transactions[idx].categoryConfidence < 0.75,
              ![.user, .learnedRule].contains(state.transactions[idx].categorySource) else { return }
        state.transactions[idx].category = category
        state.transactions[idx].categorySource = .ai
        state.transactions[idx].categoryConfidence = min(confidence, 0.7)
    }

    // MARK: - Manual entry & editing

    @discardableResult
    public mutating func addManual(amount: Decimal, currency: String = "SAR", baseAmount: Decimal? = nil,
                                   direction: Direction = .debit, kind: TransactionKind = .purchase, date: Date,
                                   merchant: String?, accountID: UUID?, category: Category?, note: String? = nil,
                                   now: Date = Date()) -> IngestReport {
        let r = RawRecord(source: .manual, sourceRecordID: "manual:\(UUID().uuidString)", amount: amount, currency: currency,
                          baseAmount: baseAmount, direction: direction, kind: kind, status: .completed, date: date,
                          hasTime: true, merchant: merchant, accountID: accountID, categoryHint: category, note: note)
        return ingest(records: [r], now: now)
    }

    public mutating func update(_ tx: Transaction) {
        guard let idx = state.transactions.firstIndex(where: { $0.id == tx.id }) else { return }
        state.transactions[idx] = tx
    }

    public mutating func delete(_ id: UUID) {
        if let t = state.transactions.first(where: { $0.id == id }) {
            // Restore links
            for i in state.transactions.indices where state.transactions[i].linkedTransactionID == id {
                state.transactions[i].linkedTransactionID = nil
                if t.kind == .reversal { state.transactions[i].status = .completed }
                if t.isInternalTransfer && state.transactions[i].isInternalTransfer
                    && state.transactions[i].counterpartyAccountLast4 == nil {
                    var u = state.transactions[i]
                    u.isInternalTransfer = false
                    applyCategory(&u)
                    state.transactions[i] = u
                }
            }
        }
        state.transactions.removeAll { $0.id == id }
    }

    // MARK: - Review queue

    public var reviewQueue: [Transaction] {
        state.transactions.filter(\.needsReview).sorted { $0.date > $1.date }
    }

    public mutating func resolve(_ id: UUID, _ resolution: ReviewResolution) {
        guard let idx = state.transactions.firstIndex(where: { $0.id == id }) else { return }
        switch resolution {
        case let .confirm(amount, baseAmount, direction):
            if let amount { state.transactions[idx].amount = amount
                if state.transactions[idx].currency == state.settings.baseCurrency { state.transactions[idx].baseAmount = amount } }
            if let baseAmount { state.transactions[idx].baseAmount = baseAmount }
            if let direction { state.transactions[idx].direction = direction }
            let t = state.transactions[idx]
            if t.amount == 0 || t.baseAmount == nil { return } // still incomplete
            if t.reviewReasons.contains(.possibleDuplicate) { state.transactions[idx].linkedTransactionID = nil }
            state.transactions[idx].reviewReasons = []
            if t.reviewReasons.contains(.possibleInternalTransfer) { /* user says it is NOT internal */ }
            applyCategoryIfNeeded(idx)
        case .mergeInto(let target):
            guard let tIdx = state.transactions.firstIndex(where: { $0.id == target }) else { return }
            var incoming = state.transactions[idx]
            incoming.reviewReasons = []
            merge(incoming, into: tIdx)
            state.transactions.remove(at: idx)
        case .markInternal:
            state.transactions[idx].isInternalTransfer = true
            state.transactions[idx].category = .internalTransfer
            state.transactions[idx].categorySource = .user
            state.transactions[idx].reviewReasons = []
        case .countCardPaymentAsExpense:
            state.transactions[idx].kind = .billPayment
            state.transactions[idx].isInternalTransfer = false
            state.transactions[idx].reviewReasons = []
            state.transactions[idx].category = .bills
            state.transactions[idx].categorySource = .user
        case .delete:
            delete(id)
        }
    }

    private mutating func applyCategoryIfNeeded(_ idx: Int) {
        guard state.transactions[idx].categorySource == .none else { return }
        var u = state.transactions[idx]
        applyCategory(&u)
        state.transactions[idx] = u
    }

    // MARK: - Balances

    @discardableResult
    mutating func addBalance(_ b: BalanceSnapshot) -> Bool {
        if state.balances.contains(where: { $0.accountID == b.accountID && $0.date == b.date && $0.balance == b.balance }) { return false }
        state.balances.append(b)
        // Keep last 200 snapshots per account.
        let forAccount = state.balances.filter { $0.accountID == b.accountID }
        if forAccount.count > 200 {
            let cutoff = forAccount.sorted { $0.date > $1.date }[199].date
            state.balances.removeAll { $0.accountID == b.accountID && $0.date < cutoff }
        }
        return true
    }

    public mutating func setBalance(accountID: UUID, balance: Decimal, date: Date) {
        addBalance(BalanceSnapshot(accountID: accountID, balance: balance, currency: state.account(accountID)?.currency ?? "SAR",
                                   date: date, source: .manual))
    }

    mutating func appendIgnored(_ r: IgnoredRecord) {
        state.ignoredLog.append(r)
        if state.ignoredLog.count > 500 { state.ignoredLog.removeFirst(state.ignoredLog.count - 500) }
    }

    // MARK: - Accounts

    public mutating func upsert(_ account: Account) {
        if let i = state.accounts.firstIndex(where: { $0.id == account.id }) { state.accounts[i] = account }
        else { state.accounts.append(account) }
        // Re-resolve transactions without an account.
        for i in state.transactions.indices where state.transactions[i].accountID == nil {
            let t = state.transactions[i]
            state.transactions[i].accountID = resolveAccount(accountID: nil, card: t.cardLast4, account: t.accountLast4, walletName: nil, hint: nil)
        }
    }

    public mutating func eraseAllData() {
        state = LedgerState()
    }
}
