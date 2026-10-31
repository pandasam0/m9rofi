import Foundation

/// How a single transaction affects totals. This is the ONLY place accounting rules live.
public enum LedgerEffect: Equatable, Sendable {
    case expense(Decimal, Category)
    case refund(Decimal, Category)          // reduces spending in category
    case income(Decimal, Category)
    case incomingTransfer(Decimal)          // money received from third parties — not income
    case cashWithdrawal(Decimal)            // move to cash, not spending (default)
    case internalTransfer                   // between own accounts / card settlement
    case pending(Decimal)                   // authorised, not posted
    case unconfirmed(Decimal)               // in review queue
    case excluded                           // reversed, cancelled, user-excluded
}

public struct CategoryTotal: Sendable, Equatable, Identifiable {
    public var id: Category { category }
    public var category: Category
    public var amount: Decimal
    public var count: Int
}

public struct MerchantTotal: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var name: String
    public var amount: Decimal
    public var count: Int
}

public struct PeriodSummary: Sendable, Equatable {
    public var interval: DateInterval
    /// Net spending = gross expenses − refunds.
    public var spending: Decimal = 0
    public var grossExpenses: Decimal = 0
    public var refunds: Decimal = 0
    public var income: Decimal = 0
    public var incomingTransfers: Decimal = 0
    public var cashWithdrawals: Decimal = 0
    public var pendingAmount: Decimal = 0
    public var pendingCount = 0
    public var unconfirmedAmount: Decimal = 0
    public var unconfirmedCount = 0
    public var internalTransferCount = 0
    /// Count of transactions that affect spending/income.
    public var transactionCount = 0
    public var byCategory: [CategoryTotal] = []
    public var byMerchant: [MerchantTotal] = []
    public var dailyAverage: Decimal = 0
    public var netCashFlow: Decimal { income - spending }
    public var topCategory: CategoryTotal? { byCategory.first }
}

public struct Aggregator: Sendable {
    public let state: LedgerState
    public init(state: LedgerState) { self.state = state }

    var calendar: Calendar { state.settings.calendar }

    public func effect(of t: Transaction) -> LedgerEffect {
        let s = state.settings
        if t.userExcluded || t.status == .reversed || t.kind == .reversal { return .excluded }
        if t.needsReview { return .unconfirmed(t.baseAmount ?? 0) }
        guard let amount = t.baseAmount else { return .unconfirmed(0) }
        if t.status == .pending { return .pending(amount) }
        if t.isInternalTransfer || t.category == .internalTransfer { return .internalTransfer }
        switch (t.kind, t.direction) {
        case (.cardPayment, _):
            return .internalTransfer
        case (.cashWithdrawal, .debit):
            return s.cashWithdrawalsAsSpending ? .expense(amount, .cash) : .cashWithdrawal(amount)
        case (.transferOut, .debit):
            return s.countExternalTransfersAsSpending ? .expense(amount, t.category.isExpense ? t.category : .transfers) : .excluded
        case (.refund, .credit), (.reversal, .credit):
            return .refund(amount, t.category.isExpense ? t.category : .other)
        case (.income, .credit):
            return .income(amount, t.category == .otherIncome ? .otherIncome : .salary)
        case (_, .credit):
            // Only explicit income or a user-assigned income category counts as income.
            if t.categorySource == .user || t.categorySource == .learnedRule, t.category == .salary || t.category == .otherIncome {
                return .income(amount, t.category)
            }
            if t.category.isExpense && (t.categorySource == .user || t.categorySource == .learnedRule) {
                return .refund(amount, t.category) // user said this credit offsets a spending category
            }
            return .incomingTransfer(amount)
        case (_, .debit):
            return .expense(amount, t.category.isExpense ? t.category : .other)
        }
    }

    public func transactions(in interval: DateInterval) -> [Transaction] {
        state.transactions.filter { interval.contains($0.date) && $0.date < interval.end }
    }

    public func summary(_ interval: DateInterval, now: Date = Date(), category: Category? = nil,
                        accountID: UUID? = nil, merchantKey: String? = nil) -> PeriodSummary {
        var sum = PeriodSummary(interval: interval)
        var cat: [Category: (Decimal, Int)] = [:]
        var merch: [String: (String, Decimal, Int)] = [:]
        for t in transactions(in: interval) {
            if let accountID, t.accountID != accountID { continue }
            if let merchantKey, !(t.merchantKey ?? "").contains(merchantKey) { continue }
            let e = effect(of: t)
            if let category {
                switch e {
                case .expense(_, let c) where c == category, .refund(_, let c) where c == category: break
                default: continue
                }
            }
            switch e {
            case let .expense(a, c):
                sum.grossExpenses += a; sum.transactionCount += 1
                cat[c, default: (0, 0)].0 += a; cat[c, default: (0, 0)].1 += 1
                let key = t.merchantKey.flatMap { $0.isEmpty ? nil : $0 } ?? t.displayName
                merch[key, default: (t.displayName, 0, 0)].1 += a
                merch[key, default: (t.displayName, 0, 0)].2 += 1
            case let .refund(a, c):
                sum.refunds += a; sum.transactionCount += 1
                cat[c, default: (0, 0)].0 -= a
                if let key = t.merchantKey, merch[key] != nil { merch[key]!.1 -= a }
            case let .income(a, _):
                sum.income += a; sum.transactionCount += 1
            case let .incomingTransfer(a):
                sum.incomingTransfers += a; sum.transactionCount += 1
            case let .cashWithdrawal(a):
                sum.cashWithdrawals += a; sum.transactionCount += 1
            case .internalTransfer:
                sum.internalTransferCount += 1
            case let .pending(a):
                if t.direction == .debit { sum.pendingAmount += a }
                sum.pendingCount += 1
            case let .unconfirmed(a):
                sum.unconfirmedAmount += a; sum.unconfirmedCount += 1
            case .excluded:
                break
            }
        }
        sum.spending = sum.grossExpenses - sum.refunds
        sum.byCategory = cat.map { CategoryTotal(category: $0.key, amount: $0.value.0, count: $0.value.1) }
            .filter { $0.amount != 0 }
            .sorted { $0.amount > $1.amount }
        sum.byMerchant = merch.map { MerchantTotal(key: $0.key, name: $0.value.0, amount: $0.value.1, count: $0.value.2) }
            .filter { $0.amount > 0 }
            .sorted { $0.amount > $1.amount }
        let effectiveEnd = min(interval.end, max(interval.start, now))
        let days = max(1, Int(ceil(effectiveEnd.timeIntervalSince(interval.start) / 86400)))
        sum.dailyAverage = (sum.spending / Decimal(days)).rounded(2)
        return sum
    }

    // MARK: Periods

    public enum Period: String, CaseIterable, Sendable { case day, week, month, year }

    public func interval(_ p: Period, containing date: Date) -> DateInterval {
        let comp: Calendar.Component = switch p { case .day: .day; case .week: .weekOfYear; case .month: .month; case .year: .year }
        return calendar.dateInterval(of: comp, for: date)!
    }

    public func previous(_ p: Period, before date: Date) -> DateInterval {
        let cur = interval(p, containing: date)
        return interval(p, containing: cur.start.addingTimeInterval(-1))
    }

    public func lastDays(_ n: Int, now: Date) -> DateInterval {
        let startToday = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(n - 1), to: startToday)!
        let end = calendar.date(byAdding: .day, value: 1, to: startToday)!
        return DateInterval(start: start, end: end)
    }

    /// Same elapsed portion of the previous month (fair month-over-month comparison).
    public func previousMonthToDate(now: Date) -> DateInterval {
        let cur = interval(.month, containing: now)
        let prev = previous(.month, before: now)
        let elapsed = now.timeIntervalSince(cur.start)
        return DateInterval(start: prev.start, end: min(prev.end, prev.start.addingTimeInterval(elapsed)))
    }

    // MARK: Dashboard

    public struct Dashboard: Sendable {
        public var today: PeriodSummary
        public var week: PeriodSummary
        public var month: PeriodSummary
        public var year: PeriodSummary
        public var previousMonthToDate: PeriodSummary
        public var totalBalance: Decimal
        public var balances: [(Account, BalanceSnapshot?)]
        public var reviewCount: Int
        /// (current − previous) / previous; nil if previous = 0.
        public var monthChangeRatio: Double?
    }

    public func dashboard(now: Date = Date()) -> Dashboard {
        let month = summary(interval(.month, containing: now), now: now)
        let prev = summary(previousMonthToDate(now: now), now: now)
        let balances = state.accounts.filter { !$0.isArchived }.map { ($0, state.latestBalance(for: $0.id)) }
        let total = balances.reduce(Decimal(0)) { acc, pair in
            guard let b = pair.1, b.currency == state.settings.baseCurrency else { return acc }
            // Credit card balance reported as outstanding debt reduces net balance.
            return pair.0.type == .creditCard ? acc - abs(b.balance) : acc + b.balance
        }
        var change: Double?
        if prev.spending != 0 {
            change = NSDecimalNumber(decimal: (month.spending - prev.spending) / prev.spending).doubleValue
        }
        return Dashboard(today: summary(interval(.day, containing: now), now: now),
                         week: summary(interval(.week, containing: now), now: now),
                         month: month,
                         year: summary(interval(.year, containing: now), now: now),
                         previousMonthToDate: prev, totalBalance: total, balances: balances,
                         reviewCount: state.transactions.filter(\.needsReview).count, monthChangeRatio: change)
    }

    /// Monthly series for charts (oldest first).
    public func monthlySeries(months: Int, now: Date = Date()) -> [PeriodSummary] {
        var out: [PeriodSummary] = []
        var cursor = interval(.month, containing: now)
        for _ in 0..<months {
            out.append(summary(cursor, now: now))
            cursor = interval(.month, containing: cursor.start.addingTimeInterval(-1))
        }
        return out.reversed()
    }

    public func dailySeries(_ interval: DateInterval, now: Date = Date()) -> [(Date, Decimal)] {
        var out: [(Date, Decimal)] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end && day <= now {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            out.append((day, summary(DateInterval(start: day, end: next), now: now).spending))
            day = next
        }
        return out
    }

    /// Fixed (recurring) vs variable spending for an interval.
    public func fixedVsVariable(_ interval: DateInterval, recurring: [RecurringSeries]) -> (fixed: Decimal, variable: Decimal) {
        let keys = Set(recurring.map(\.merchantKey))
        var fixed: Decimal = 0, variable: Decimal = 0
        for t in transactions(in: interval) {
            if case let .expense(a, _) = effect(of: t) {
                if let k = t.merchantKey, keys.contains(k) { fixed += a } else { variable += a }
            }
        }
        return (fixed, variable)
    }
}

extension Decimal {
    public func rounded(_ scale: Int, _ mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var v = self
        var r = Decimal()
        NSDecimalRound(&r, &v, scale, mode)
        return r
    }

    public var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}
