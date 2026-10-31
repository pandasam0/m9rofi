import Foundation

// MARK: - Recurring payments / subscriptions

public enum Cadence: String, Codable, Sendable {
    case weekly, monthly, quarterly, yearly
    var days: Double { switch self { case .weekly: 7; case .monthly: 30.44; case .quarterly: 91.3; case .yearly: 365.25 } }
    var tolerance: Double { switch self { case .weekly: 1.5; case .monthly: 4; case .quarterly: 8; case .yearly: 12 } }
    public var arabicName: String { switch self { case .weekly: "أسبوعي"; case .monthly: "شهري"; case .quarterly: "ربع سنوي"; case .yearly: "سنوي" } }
}

public struct RecurringSeries: Sendable, Identifiable, Equatable {
    public var id: String { merchantKey }
    public var merchantKey: String
    public var name: String
    public var category: Category
    public var cadence: Cadence
    public var lastDate: Date
    public var lastAmount: Decimal
    public var expectedAmount: Decimal
    public var nextDate: Date
    public var occurrences: Int
    /// 0…1
    public var confidence: Double
    public var accountID: UUID?
}

public struct RecurringDetector: Sendable {
    public let state: LedgerState
    public init(state: LedgerState) { self.state = state }

    public func detect(now: Date = Date()) -> [RecurringSeries] {
        let agg = Aggregator(state: state)
        let cal = state.settings.calendar
        var groups: [String: [Transaction]] = [:]
        for t in state.transactions {
            guard let key = t.merchantKey, !key.isEmpty, case .expense = agg.effect(of: t) else { continue }
            groups[key, default: []].append(t)
        }
        var out: [RecurringSeries] = []
        for (key, txs) in groups {
            let sorted = txs.sorted { $0.date < $1.date }
            // Cluster by amount (±7%): the same merchant can have a subscription and ad-hoc purchases.
            var clusters: [[Transaction]] = []
            for t in sorted {
                if let i = clusters.firstIndex(where: { c in
                    let ref = c.last!.baseAmount ?? 0
                    let a = t.baseAmount ?? 0
                    return ref > 0 && abs((a - ref).doubleValue) / ref.doubleValue <= 0.07
                }) { clusters[i].append(t) } else { clusters.append([t]) }
            }
            let knownSubscription = Categorizer.dictionaryMatch(key) == .subscriptions
            for c in clusters {
                let minCount = knownSubscription ? 2 : 3
                guard c.count >= minCount else { continue }
                let gaps = zip(c.dropFirst(), c).map { $0.date.timeIntervalSince($1.date) / 86400 }
                guard let median = gaps.sorted()[safe: gaps.count / 2] else { continue }
                guard let cadence = [Cadence.weekly, .monthly, .quarterly, .yearly].first(where: { abs(median - $0.days) <= $0.tolerance }) else { continue }
                let regular = gaps.filter { abs($0 - cadence.days) <= cadence.tolerance * 1.5 }.count
                let regularity = Double(regular) / Double(gaps.count)
                guard regularity >= 0.6 else { continue }
                let last = c.last!
                let comp: DateComponents = switch cadence {
                case .weekly: DateComponents(day: 7)
                case .monthly: DateComponents(month: 1)
                case .quarterly: DateComponents(month: 3)
                case .yearly: DateComponents(year: 1)
                }
                var next = cal.date(byAdding: comp, to: last.date)!
                // Series that stopped (missed 2 cycles) are not reported.
                if now.timeIntervalSince(next) / 86400 > cadence.days * 1.5 { continue }
                while next < cal.startOfDay(for: now) { next = cal.date(byAdding: comp, to: next)! }
                let amounts = c.suffix(3).compactMap(\.baseAmount)
                let expected = amounts.isEmpty ? (last.baseAmount ?? 0) : (amounts.reduce(0, +) / Decimal(amounts.count)).rounded(2)
                var confidence = min(1, 0.4 + 0.15 * Double(c.count) ) * regularity
                if knownSubscription { confidence = min(1, confidence + 0.2) }
                out.append(RecurringSeries(merchantKey: key, name: last.displayName, category: last.category, cadence: cadence,
                                           lastDate: last.date, lastAmount: last.baseAmount ?? 0, expectedAmount: expected,
                                           nextDate: next, occurrences: c.count, confidence: confidence, accountID: last.accountID))
            }
        }
        return out.sorted { $0.nextDate < $1.nextDate }
    }

    /// Normalised monthly cost of all detected recurring payments.
    public static func monthlyCost(_ series: [RecurringSeries]) -> Decimal {
        let total: Decimal = series.reduce(Decimal(0)) { (acc: Decimal, s: RecurringSeries) -> Decimal in
            let factor: Decimal
            switch s.cadence {
            case .weekly: factor = Decimal(52) / Decimal(12)
            case .monthly: factor = 1
            case .quarterly: factor = Decimal(1) / Decimal(3)
            case .yearly: factor = Decimal(1) / Decimal(12)
            }
            return acc + s.expectedAmount * factor
        }
        return total.rounded(2)
    }
}

// MARK: - Budgets

public struct BudgetStatus: Sendable, Identifiable, Equatable {
    public var id: Category { category }
    public var category: Category
    public var limit: Decimal
    public var spent: Decimal
    public var remaining: Decimal { limit - spent }
    public var ratio: Double { limit > 0 ? spent.doubleValue / limit.doubleValue : 0 }
    /// Highest threshold crossed (50/75/90/100) or nil.
    public var crossedThreshold: Int?
    /// Linear projection to month end.
    public var projected: Decimal
}

public struct BudgetEngine: Sendable {
    public let state: LedgerState
    public init(state: LedgerState) { self.state = state }

    public func status(now: Date = Date()) -> [BudgetStatus] {
        let agg = Aggregator(state: state)
        let month = agg.interval(.month, containing: now)
        let summary = agg.summary(month, now: now)
        let elapsed = max(1, now.timeIntervalSince(month.start)) / month.duration
        return state.budgets.map { b in
            let spent = summary.byCategory.first { $0.category == b.category }?.amount ?? 0
            let ratio = b.monthlyLimit > 0 ? spent.doubleValue / b.monthlyLimit.doubleValue * 100 : 0
            let crossed = state.settings.budgetThresholds.sorted().last { ratio >= Double($0) }
            let projected = (spent / Decimal(min(1, elapsed))).rounded(0)
            return BudgetStatus(category: b.category, limit: b.monthlyLimit, spent: spent, crossedThreshold: crossed, projected: projected)
        }.sorted { $0.ratio > $1.ratio }
    }

    /// Suggested monthly budgets: median of the last 3 complete months, rounded up to 50 SAR.
    public func suggestions(now: Date = Date()) -> [Budget] {
        let agg = Aggregator(state: state)
        var months: [PeriodSummary] = []
        var cursor = agg.previous(.month, before: now)
        for _ in 0..<3 {
            months.append(agg.summary(cursor, now: now))
            cursor = agg.previous(.month, before: cursor.start)
        }
        var result: [Budget] = []
        for c in Category.expenseCategories where c != .transfers && c != .cash {
            let values = months.map { m in m.byCategory.first { $0.category == c }?.amount ?? 0 }.sorted()
            let median = values[1]
            guard median > 0 else { continue }
            let rounded = (NSDecimalNumber(decimal: median / 50).doubleValue.rounded(.up)) * 50
            result.append(Budget(category: c, monthlyLimit: Decimal(rounded)))
        }
        return result
    }
}

// MARK: - Anomalies

public struct Anomaly: Sendable, Equatable, Identifiable {
    public var id: UUID { transactionID }
    public var transactionID: UUID
    public var reason: String
    public var amount: Decimal
    public var typical: Decimal?
}

public struct AnomalyDetector: Sendable {
    public let state: LedgerState
    public init(state: LedgerState) { self.state = state }

    /// Flags expenses far above the merchant's or category's history (robust: median + MAD).
    public func check(_ t: Transaction) -> Anomaly? {
        let agg = Aggregator(state: state)
        guard case let .expense(amount, category) = agg.effect(of: t) else { return nil }
        let history = state.transactions.filter { $0.id != t.id && $0.date < t.date }
        let merchantHist = history.filter { $0.merchantKey != nil && $0.merchantKey == t.merchantKey }
            .compactMap { if case let .expense(a, _) = agg.effect(of: $0) { return a } else { return nil } }
        if merchantHist.count >= 4, let (median, mad) = Self.robust(merchantHist) {
            let limit = median + max(mad * 5, median * 2)
            if amount > limit {
                return Anomaly(transactionID: t.id, reason: "مبلغ أعلى بكثير من المعتاد لدى \(t.displayName)", amount: amount, typical: median)
            }
            return nil
        }
        let catHist = history.compactMap { tx -> Decimal? in
            if case let .expense(a, c) = agg.effect(of: tx), c == category { return a } else { return nil }
        }
        if catHist.count >= 8, let (median, mad) = Self.robust(catHist) {
            let limit = median + max(mad * 8, median * 4)
            if amount > limit && amount >= 200 {
                return Anomaly(transactionID: t.id, reason: "مصروف كبير غير معتاد في \(category.arabicName)", amount: amount, typical: median)
            }
        } else if merchantHist.isEmpty && amount >= 2000 {
            return Anomaly(transactionID: t.id, reason: "مبلغ كبير لدى جهة جديدة", amount: amount, typical: nil)
        }
        return nil
    }

    static func robust(_ values: [Decimal]) -> (Decimal, Decimal)? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let median = s[s.count / 2]
        let dev = s.map { abs($0 - median) }.sorted()
        return (median, dev[dev.count / 2])
    }
}

// MARK: - Alerts

public enum AlertKind: String, Codable, Sendable {
    case newExpense, unusual, budget, upcomingCharge, lowBalance, duplicate, staleAccount, review
}

public struct FinanceAlert: Sendable, Equatable, Identifiable {
    /// Stable key — an alert with the same key is delivered once.
    public var id: String
    public var kind: AlertKind
    public var title: String
    public var body: String
    /// Deliver at this time (nil = now).
    public var fireDate: Date?
}

public struct AlertEngine: Sendable {
    public let state: LedgerState
    public init(state: LedgerState) { self.state = state }

    /// Alerts not yet delivered. Caller records delivered keys in `state.firedAlertKeys`.
    public func pending(now: Date = Date(), newTransactionIDs: [UUID] = []) -> [FinanceAlert] {
        var out: [FinanceAlert] = []
        let agg = Aggregator(state: state)
        let fmt = MoneyFormatter.self
        let cal = state.settings.calendar
        let monthKey = { (d: Date) -> String in let c = cal.dateComponents([.year, .month], from: d); return "\(c.year!)-\(c.month!)" }(now)

        for id in newTransactionIDs {
            guard let t = state.transactions.first(where: { $0.id == id }) else { continue }
            if t.reviewReasons.contains(.possibleDuplicate) {
                out.append(.init(id: "dup:\(id)", kind: .duplicate, title: "عملية قد تكون مكررة",
                                 body: "\(fmt.sar(t.baseAmount ?? t.amount)) – \(t.displayName). لم تُحتسب حتى تراجعها.", fireDate: nil))
            } else if t.needsReview {
                out.append(.init(id: "rev:\(id)", kind: .review, title: "عملية تحتاج مراجعة",
                                 body: "\(t.displayName): \(t.reviewReasons.map(\.arabicDescription).joined(separator: "، "))", fireDate: nil))
            } else if case let .expense(a, c) = agg.effect(of: t) {
                out.append(.init(id: "new:\(id)", kind: .newExpense, title: "مصروف جديد: \(fmt.sar(a))",
                                 body: "\(t.displayName) · \(c.arabicName)", fireDate: nil))
            }
            if let an = AnomalyDetector(state: state).check(t) {
                out.append(.init(id: "unusual:\(id)", kind: .unusual, title: "عملية غير معتادة",
                                 body: "\(an.reason): \(fmt.sar(an.amount))" + (an.typical.map { " (المعتاد \(fmt.sar($0)))" } ?? ""), fireDate: nil))
            }
        }

        for b in BudgetEngine(state: state).status(now: now) {
            guard let th = b.crossedThreshold else { continue }
            let body = th >= 100
                ? "تجاوزت ميزانية \(b.category.arabicName): \(fmt.sar(b.spent)) من \(fmt.sar(b.limit))"
                : "استهلكت \(th)% من ميزانية \(b.category.arabicName). المتبقي \(fmt.sar(b.remaining))"
            out.append(.init(id: "budget:\(monthKey):\(b.category.rawValue):\(th)", kind: .budget, title: "تنبيه الميزانية", body: body, fireDate: nil))
        }

        for s in RecurringDetector(state: state).detect(now: now) where s.confidence >= 0.5 {
            let notice = cal.date(byAdding: .day, value: -state.settings.upcomingChargeNoticeDays, to: s.nextDate)!
            let day = cal.dateComponents([.year, .month, .day], from: s.nextDate)
            out.append(.init(id: "upcoming:\(s.merchantKey):\(day.year!)-\(day.month!)-\(day.day!)", kind: .upcomingCharge,
                             title: "خصم قادم: \(s.name)",
                             body: "\(fmt.sar(s.expectedAmount)) متوقع بتاريخ \(DateFormatting.shortDate(s.nextDate, tz: state.settings.timeZone))",
                             fireDate: max(notice, now)))
        }

        for a in state.accounts where !a.isArchived {
            let latest = state.latestBalance(for: a.id)
            if let threshold = a.lowBalanceThreshold, let bal = latest, bal.balance < threshold {
                out.append(.init(id: "low:\(a.id):\(Int(bal.date.timeIntervalSince1970))", kind: .lowBalance,
                                 title: "رصيد منخفض", body: "\(a.name): \(fmt.sar(bal.balance))", fireDate: nil))
            }
            let lastActivity = max(latest?.date ?? .distantPast,
                                   state.transactions.filter { $0.accountID == a.id }.map(\.createdAt).max() ?? .distantPast)
            let days = now.timeIntervalSince(lastActivity) / 86400
            if a.isTracked, lastActivity != .distantPast, days >= Double(state.settings.staleAccountDays) {
                let week = Int(now.timeIntervalSince1970 / (7 * 86400))
                out.append(.init(id: "stale:\(a.id):\(week)", kind: .staleAccount, title: "حساب لم يُحدّث",
                                 body: "لا توجد بيانات جديدة من \(a.name) منذ \(Int(days)) يوم. استورد كشفاً أو تحقق من الاختصار.", fireDate: nil))
            }
        }
        return out.filter { !state.firedAlertKeys.contains($0.id) }
    }
}

// MARK: - Formatting

public enum MoneyFormatter {
    public static func sar(_ v: Decimal, arabic: Bool = true) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        let s = f.string(from: NSDecimalNumber(decimal: v)) ?? "\(v)"
        return arabic ? "\(s) ر.س" : "SAR \(s)"
    }
}

public enum DateFormatting {
    public static func shortDate(_ d: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
