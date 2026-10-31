import Foundation

public enum QueryPeriod: Codable, Sendable, Equatable {
    case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear, lastDays(Int), allTime

    public var arabicLabel: String {
        switch self {
        case .today: return "اليوم"
        case .yesterday: return "أمس"
        case .thisWeek: return "هذا الأسبوع"
        case .lastWeek: return "الأسبوع الماضي"
        case .thisMonth: return "هذا الشهر"
        case .lastMonth: return "الشهر الماضي"
        case .thisYear: return "هذه السنة"
        case .lastYear: return "السنة الماضية"
        case .lastDays(let n): return "آخر \(n) أيام"
        case .allTime: return "كل الفترات"
        }
    }
}

public enum QueryIntent: String, Codable, Sendable, CaseIterable {
    case totalSpending, categorySpending, merchantSpending, topCategory, topMerchants, subscriptions,
         savingsTips, remainingSalary, savingsCapacity, income, transactionCount, balance, unknown
}

/// Structured query. Produced by the deterministic parser or by an on-device LLM; numbers always come
/// from `Aggregator`, never from the model.
public struct FinanceQuery: Codable, Sendable, Equatable {
    public var intent: QueryIntent
    public var category: Category?
    public var merchant: String?
    public var period: QueryPeriod
    public init(intent: QueryIntent, category: Category? = nil, merchant: String? = nil, period: QueryPeriod = .thisMonth) {
        self.intent = intent; self.category = category; self.merchant = merchant; self.period = period
    }
}

public struct QueryAnswer: Sendable, Equatable {
    public var text: String
    public var value: Decimal?
    public var transactionIDs: [UUID]
    public var caveats: [String]
    public var query: FinanceQuery
}

public struct QueryEngine: Sendable {
    public let state: LedgerState
    public init(state: LedgerState) { self.state = state }

    // MARK: Parsing

    static func normalizeArabic(_ s: String) -> String {
        var t = TextNormalizer.normalizeDigits(s).lowercased()
        let map: [Character: Character] = ["أ": "ا", "إ": "ا", "آ": "ا", "ة": "ه", "ى": "ي", "ؤ": "و", "ئ": "ي"]
        t = String(t.map { map[$0] ?? $0 })
        t.unicodeScalars.removeAll { (0x064B...0x065F).contains($0.value) || $0.value == 0x0640 } // harakat, tatweel
        t = t.replacingOccurrences(of: "؟", with: " ").replacingOccurrences(of: "?", with: " ")
        return " " + t.split(separator: " ").joined(separator: " ") + " "
    }

    static let categorySynonyms: [(Category, [String])] = [
        (.coffee, ["قهوه", "القهوه", "كوفي", "كافيه", "coffee", "cafe"]),
        (.dining, ["مطاعم", "المطاعم", "مطعم", "اكل", "الاكل", "توصيل", "restaurant", "restaurants", "dining", "food", "eating out"]),
        (.groceries, ["بقاله", "البقاله", "سوبرماركت", "مقاضي", "المقاضي", "groceries", "grocery", "supermarket"]),
        (.shopping, ["تسوق", "التسوق", "ملابس", "الملابس", "shopping", "clothes"]),
        (.auto, ["بنزين", "البنزين", "وقود", "سياره", "السياره", "fuel", "petrol", "gas", " car "]),
        (.transport, ["مواصلات", "المواصلات", "اوبر", "كريم", "تاكسي", "transport", "taxi", "uber"]),
        (.subscriptions, ["اشتراكات", "الاشتراكات", "اشتراك", "subscriptions", "subscription"]),
        (.entertainment, ["ترفيه", "الترفيه", "العاب", "الالعاب", "entertainment", "games", "gaming"]),
        (.travel, ["سفر", "السفر", "فنادق", "الفنادق", "فندق", "طيران", "travel", "hotels", "hotel", "flights"]),
        (.health, ["صحه", "الصحه", "رياضه", "الرياضه", "صيدليه", "نادي", "health", "gym", "pharmacy", "fitness"]),
        (.bills, ["فواتير", "الفواتير", "فاتوره", "كهرباء", "خدمات", "bills", "utilities"]),
        (.transfers, ["تحويلات", "التحويلات", "حوالات", "transfers"]),
        (.cash, ["سحب نقدي", "السحب النقدي", "كاش", "نقد", "cash"]),
        (.personal, ["شخصيه", "الشخصيه", "personal"])
    ]

    public func parse(_ question: String) -> FinanceQuery {
        let q = Self.normalizeArabic(question)
        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) } }

        let period = parsePeriod(q)
        let category = Self.categorySynonyms.first { has($0.1) }?.0
        let merchant = matchMerchant(q)

        let intent: QueryIntent
        if has(["تقليل", "اقلل", "اخفض", "اوفر فيه", "reduce", "cut down", "cut back", "where can i save"]) { intent = .savingsTips }
        else if has(["راتب", "الراتب", "راتبي", "salary"]) && has(["يتبقي", "يتبقى", "باقي", "متبقي", "بقي", "left", "remain"]) { intent = .remainingSalary }
        else if has(["توفير", "توفيره", "اوفر", "ادخر", "ادخار", "save", "saving"]) { intent = .savingsCapacity }
        else if has(["استنزف", "اكثر شي", "اكثر تصنيف", "اعلي تصنيف", "اكبر مصروف", "most", "biggest", "top category"]) {
            intent = has(["متجر", "محل", "merchant", "store", "جهه"]) ? .topMerchants : .topCategory
        }
        else if has(["متاجر", "المتاجر", "merchants", "stores"]) { intent = .topMerchants }
        else if has(["رصيد", "رصيدي", "الرصيد", "balance"]) { intent = .balance }
        else if has(["كم عمليه", "عدد العمليات", "how many transactions", "number of transactions"]) { intent = .transactionCount }
        else if has(["دخل", "دخلي", "الدخل", "income", "earned"]) { intent = .income }
        else if category == .subscriptions { intent = .subscriptions }
        else if let _ = merchant { intent = .merchantSpending }
        else if category != nil { intent = .categorySpending }
        else if has(["صرف", "صرفت", "مصروف", "مصاريف", "مصروفات", "انفقت", "دفعت", "spent", "spend", "spending", "expenses", "paid"]) { intent = .totalSpending }
        else { intent = .unknown }
        return FinanceQuery(intent: intent, category: category, merchant: merchant, period: period)
    }

    func parsePeriod(_ q: String) -> QueryPeriod {
        if let re = try? NSRegularExpression(pattern: #"(?:اخر|خلال|last|past)\s*(\d+)\s*(?:يوم|ايام|days?)"#),
           let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)), let r = Range(m.range(at: 1), in: q), let n = Int(q[r]) {
            return .lastDays(max(1, min(n, 3660)))
        }
        func has(_ w: [String]) -> Bool { w.contains { q.contains($0) } }
        if has(["اخر اسبوع", "last 7", "past week"]) { return .lastDays(7) }
        if has(["اخر شهر", "past month", "last 30"]) { return .lastDays(30) }
        if has([" امس ", "البارحه", "yesterday"]) { return .yesterday }
        if has([" اليوم ", "today"]) { return .today }
        if has(["الاسبوع الماضي", "الاسبوع اللي فات", "last week"]) { return .lastWeek }
        if has(["الاسبوع", "اسبوع", "this week", "week"]) { return .thisWeek }
        if has(["الشهر الماضي", "الشهر اللي فات", "last month", "previous month"]) { return .lastMonth }
        if has(["السنه الماضيه", "العام الماضي", "last year"]) { return .lastYear }
        if has(["السنه", "العام", "this year", "year"]) { return .thisYear }
        if has(["كل الوقت", "منذ البدايه", "all time", "ever"]) { return .allTime }
        return .thisMonth
    }

    func matchMerchant(_ q: String) -> String? {
        let keys = Set(state.transactions.compactMap(\.merchantKey)).filter { $0.count >= 3 }
        // Longest key that appears as whole words in the question.
        return keys.filter { q.contains(" " + Self.normalizeArabic($0).trimmingCharacters(in: .whitespaces) + " ") }
            .max { $0.count < $1.count }
    }

    // MARK: Answering

    public func interval(for p: QueryPeriod, now: Date) -> DateInterval {
        let agg = Aggregator(state: state)
        switch p {
        case .today: return agg.interval(.day, containing: now)
        case .yesterday: return agg.previous(.day, before: now)
        case .thisWeek: return agg.interval(.week, containing: now)
        case .lastWeek: return agg.previous(.week, before: now)
        case .thisMonth: return agg.interval(.month, containing: now)
        case .lastMonth: return agg.previous(.month, before: now)
        case .thisYear: return agg.interval(.year, containing: now)
        case .lastYear: return agg.previous(.year, before: now)
        case .lastDays(let n): return agg.lastDays(n, now: now)
        case .allTime:
            let start = state.transactions.map(\.date).min() ?? now
            return DateInterval(start: start, end: now.addingTimeInterval(1))
        }
    }

    public func answer(_ question: String, now: Date = Date()) -> QueryAnswer {
        answer(parse(question), now: now)
    }

    public func answer(_ q: FinanceQuery, now: Date = Date()) -> QueryAnswer {
        let agg = Aggregator(state: state)
        let iv = interval(for: q.period, now: now)
        let sar = { MoneyFormatter.sar($0) }
        let p = q.period.arabicLabel

        func caveats(_ s: PeriodSummary) -> [String] {
            var c: [String] = []
            if s.pendingCount > 0 { c.append("لا يشمل \(s.pendingCount) عمليات معلقة بقيمة \(sar(s.pendingAmount)).") }
            if s.unconfirmedCount > 0 { c.append("\(s.unconfirmedCount) عمليات بقيمة \(sar(s.unconfirmedAmount)) بانتظار مراجعتك ولم تُحتسب.") }
            return c
        }
        func ids(_ filter: (Transaction) -> Bool) -> [UUID] {
            agg.transactions(in: iv).filter(filter).sorted { $0.date > $1.date }.map(\.id)
        }
        func isSpend(_ t: Transaction) -> Bool {
            switch agg.effect(of: t) { case .expense, .refund: return true; default: return false }
        }

        switch q.intent {
        case .totalSpending:
            let s = agg.summary(iv, now: now)
            var text = "صرفت \(sar(s.spending)) \(p) في \(s.byCategory.reduce(0) { $0 + $1.count }) عملية."
            if s.refunds > 0 { text += " (بعد خصم مبالغ مستردة \(sar(s.refunds)))" }
            if let top = s.topCategory { text += "\nأعلى تصنيف: \(top.category.arabicName) بـ \(sar(top.amount))." }
            return QueryAnswer(text: text, value: s.spending, transactionIDs: ids(isSpend), caveats: caveats(s), query: q)

        case .categorySpending, .subscriptions:
            guard let c = q.category else { return answer(FinanceQuery(intent: .totalSpending, period: q.period), now: now) }
            let s = agg.summary(iv, now: now, category: c)
            var text = "صرفت على \(c.arabicName) \(sar(s.spending)) \(p) في \(s.transactionCount) عملية."
            if s.transactionCount > 0 { text += " متوسط العملية \(sar((s.spending / Decimal(s.transactionCount)).rounded(2)))." }
            if let m = s.byMerchant.first { text += "\nأكثر جهة: \(m.name) بـ \(sar(m.amount))." }
            if c == .subscriptions {
                let series = RecurringDetector(state: state).detect(now: now)
                if !series.isEmpty {
                    text += "\nالاشتراكات المكتشفة (\(series.count)) بتكلفة شهرية تقريبية \(sar(RecurringDetector.monthlyCost(series))):"
                    for r in series.prefix(10) { text += "\n• \(r.name): \(sar(r.expectedAmount)) \(r.cadence.arabicName)، القادم \(DateFormatting.shortDate(r.nextDate, tz: state.settings.timeZone))" }
                }
            }
            return QueryAnswer(text: text, value: s.spending, transactionIDs: ids { isSpend($0) && $0.category == c }, caveats: caveats(s), query: q)

        case .merchantSpending:
            guard let m = q.merchant else { return answer(FinanceQuery(intent: .totalSpending, period: q.period), now: now) }
            let s = agg.summary(iv, now: now, merchantKey: m)
            let name = s.byMerchant.first?.name ?? m
            return QueryAnswer(text: "صرفت لدى \(name) \(sar(s.spending)) \(p) في \(s.transactionCount) عملية.", value: s.spending,
                               transactionIDs: ids { isSpend($0) && ($0.merchantKey ?? "").contains(m) }, caveats: caveats(s), query: q)

        case .topCategory:
            let s = agg.summary(iv, now: now)
            guard let top = s.topCategory, s.spending > 0 else {
                return QueryAnswer(text: "لا توجد مصروفات مسجلة \(p).", value: 0, transactionIDs: [], caveats: caveats(s), query: q)
            }
            let share = Int((top.amount.doubleValue / s.spending.doubleValue * 100).rounded())
            var text = "أكثر ما استنزف أموالك \(p): \(top.category.arabicName) بـ \(sar(top.amount)) (\(share)% من الإنفاق)."
            for c in s.byCategory.dropFirst().prefix(4) { text += "\n• \(c.category.arabicName): \(sar(c.amount))" }
            if let m = s.byMerchant.first { text += "\nأعلى جهة: \(m.name) بـ \(sar(m.amount)) في \(m.count) عملية." }
            return QueryAnswer(text: text, value: top.amount, transactionIDs: ids { isSpend($0) && $0.category == top.category }, caveats: caveats(s), query: q)

        case .topMerchants:
            let s = agg.summary(iv, now: now)
            var text = "أكثر الجهات استهلاكاً لأموالك \(p):"
            for (i, m) in s.byMerchant.prefix(10).enumerated() { text += "\n\(i + 1). \(m.name): \(sar(m.amount)) (\(m.count))" }
            if s.byMerchant.isEmpty { text = "لا توجد مصروفات مسجلة \(p)." }
            return QueryAnswer(text: text, value: s.byMerchant.first?.amount, transactionIDs: [], caveats: caveats(s), query: q)

        case .income:
            let s = agg.summary(iv, now: now)
            var text = "دخلك \(p): \(sar(s.income))."
            if s.incomingTransfers > 0 { text += "\nتحويلات واردة من آخرين (غير محتسبة كدخل): \(sar(s.incomingTransfers))." }
            text += "\nصافي التدفق النقدي: \(sar(s.netCashFlow))."
            return QueryAnswer(text: text, value: s.income, transactionIDs: ids { if case .income = agg.effect(of: $0) { return true }; return false },
                               caveats: caveats(s), query: q)

        case .transactionCount:
            let s = agg.summary(iv, now: now)
            return QueryAnswer(text: "عدد العمليات المحتسبة \(p): \(s.transactionCount)، منها \(s.byCategory.reduce(0) { $0 + $1.count }) مصروفات.",
                               value: Decimal(s.transactionCount), transactionIDs: [], caveats: caveats(s), query: q)

        case .balance:
            let d = agg.dashboard(now: now)
            var text = "إجمالي أرصدتك: \(sar(d.totalBalance))."
            for (a, b) in d.balances {
                if let b { text += "\n• \(a.name): \(sar(b.balance)) (آخر تحديث \(DateFormatting.shortDate(b.date, tz: state.settings.timeZone)))" }
                else { text += "\n• \(a.name): لا يوجد رصيد مسجل" }
            }
            return QueryAnswer(text: text, value: d.totalBalance, transactionIDs: [], caveats: [], query: q)

        case .remainingSalary:
            return remainingSalary(now: now, query: q)

        case .savingsCapacity:
            return savingsCapacity(now: now, query: q)

        case .savingsTips:
            return savingsTips(now: now, query: q)

        case .unknown:
            return QueryAnswer(text: "لم أفهم السؤال. أمثلة: «كم صرفت اليوم؟»، «كم صرفت على القهوة هذا الشهر؟»، «ما أكثر شيء استنزف أموالي؟»، «كم يتبقى من راتبي؟»",
                               value: nil, transactionIDs: [], caveats: [], query: q)
        }
    }

    func remainingSalary(now: Date, query: FinanceQuery) -> QueryAnswer {
        let agg = Aggregator(state: state)
        let salaries = state.transactions.filter {
            if case let .income(_, c) = agg.effect(of: $0), c == .salary, $0.date <= now { return true }; return false
        }
        guard let last = salaries.max(by: { $0.date < $1.date }), let amount = last.baseAmount else {
            return QueryAnswer(text: "لا يوجد راتب مسجل. عند وصول رسالة الراتب أو استيراد الكشف سيُحسب المتبقي تلقائياً.",
                               value: nil, transactionIDs: [], caveats: [], query: query)
        }
        let s = agg.summary(DateInterval(start: last.date, end: now.addingTimeInterval(1)), now: now)
        let remaining = amount - s.spending
        let cal = state.settings.calendar
        let nextSalary = cal.date(byAdding: .month, value: 1, to: last.date)!
        let daysLeft = max(1, cal.dateComponents([.day], from: now, to: nextSalary).day ?? 1)
        var text = "آخر راتب: \(MoneyFormatter.sar(amount)) بتاريخ \(DateFormatting.shortDate(last.date, tz: state.settings.timeZone))."
        text += "\nصرفت منذ ذلك: \(MoneyFormatter.sar(s.spending))."
        text += "\nالمتبقي: \(MoneyFormatter.sar(remaining))."
        if remaining > 0 { text += "\nالمتاح يومياً حتى الراتب القادم (~\(daysLeft) يوم): \(MoneyFormatter.sar((remaining / Decimal(daysLeft)).rounded(2)))." }
        var cav: [String] = []
        if s.pendingCount > 0 { cav.append("عمليات معلقة غير محتسبة: \(MoneyFormatter.sar(s.pendingAmount)).") }
        if s.unconfirmedCount > 0 { cav.append("عمليات بانتظار المراجعة: \(MoneyFormatter.sar(s.unconfirmedAmount)).") }
        return QueryAnswer(text: text, value: remaining, transactionIDs: [last.id], caveats: cav, query: query)
    }

    func lastCompleteMonths(_ n: Int, now: Date) -> [PeriodSummary] {
        let agg = Aggregator(state: state)
        var out: [PeriodSummary] = []
        var cur = agg.previous(.month, before: now)
        for _ in 0..<n {
            out.append(agg.summary(cur, now: now))
            cur = agg.previous(.month, before: cur.start)
        }
        // Drop months before the first transaction (no data ≠ zero spending).
        let first = state.transactions.map(\.date).min() ?? now
        return out.filter { $0.interval.end > first }
    }

    func savingsCapacity(now: Date, query: FinanceQuery) -> QueryAnswer {
        let months = lastCompleteMonths(3, now: now)
        guard !months.isEmpty else {
            return QueryAnswer(text: "لا توجد بيانات لشهر كامل بعد. أحتاج شهراً مكتملاً على الأقل.", value: nil, transactionIDs: [], caveats: [], query: query)
        }
        let n = Decimal(months.count)
        let income = (months.reduce(0) { $0 + $1.income } / n).rounded(2)
        let spend = (months.reduce(0) { $0 + $1.spending } / n).rounded(2)
        guard income > 0 else {
            return QueryAnswer(text: "متوسط إنفاقك الشهري \(MoneyFormatter.sar(spend)) لكن لا يوجد دخل مسجل لحساب التوفير. صنّف الراتب كـ «الراتب».",
                               value: nil, transactionIDs: [], caveats: [], query: query)
        }
        let capacity = income - spend
        let rate = Int((capacity.doubleValue / income.doubleValue * 100).rounded())
        var text = "بناءً على آخر \(months.count) أشهر مكتملة:\nمتوسط الدخل \(MoneyFormatter.sar(income))، متوسط الإنفاق \(MoneyFormatter.sar(spend))."
        text += capacity > 0 ? "\nيمكنك توفير نحو \(MoneyFormatter.sar(capacity)) شهرياً (\(rate)% من الدخل)."
                             : "\nإنفاقك يتجاوز دخلك بـ \(MoneyFormatter.sar(-capacity)) شهرياً."
        let tips = savingsTips(now: now, query: query)
        if let v = tips.value, v > 0 { text += "\nبتطبيق التخفيضات المقترحة يمكن رفعها إلى \(MoneyFormatter.sar(capacity + v))." }
        return QueryAnswer(text: text, value: capacity, transactionIDs: [], caveats: [], query: query)
    }

    func savingsTips(now: Date, query: FinanceQuery) -> QueryAnswer {
        let agg = Aggregator(state: state)
        let months = lastCompleteMonths(3, now: now)
        guard !months.isEmpty else {
            return QueryAnswer(text: "أحتاج شهراً مكتملاً من البيانات على الأقل لاقتراح تخفيضات.", value: nil, transactionIDs: [], caveats: [], query: query)
        }
        let current = agg.summary(agg.interval(.month, containing: now), now: now)
        let monthStart = agg.interval(.month, containing: now)
        let elapsed = max(0.1, now.timeIntervalSince(monthStart.start) / monthStart.duration)
        var avg: [Category: Decimal] = [:]
        for m in months { for c in m.byCategory { avg[c.category, default: 0] += c.amount / Decimal(months.count) } }
        var lines: [String] = []
        var potential: Decimal = 0
        // 1. Categories trending above their average this month.
        for c in current.byCategory where c.category.isExpense && c.category != .transfers {
            let projected = (c.amount / Decimal(elapsed)).rounded(0)
            let base = avg[c.category] ?? 0
            if base > 0, projected > base * Decimal(1.2), projected - base >= 100 {
                lines.append("• \(c.category.arabicName): متوقع \(MoneyFormatter.sar(projected)) هذا الشهر مقابل متوسط \(MoneyFormatter.sar(base.rounded(0))).")
                potential += projected - base
            }
        }
        // 2. Discretionary categories: 20% cut of the average.
        for c in [Category.dining, .coffee, .shopping, .entertainment] {
            if let a = avg[c], a >= 200 {
                let cut = (a * Decimal(0.2)).rounded(0)
                lines.append("• تخفيض \(c.arabicName) بنسبة 20% يوفّر \(MoneyFormatter.sar(cut)) شهرياً (المتوسط \(MoneyFormatter.sar(a.rounded(0)))).")
                potential += cut
            }
        }
        // 3. Subscriptions.
        let subs = RecurringDetector(state: state).detect(now: now)
        if !subs.isEmpty {
            let cost = RecurringDetector.monthlyCost(subs)
            lines.append("• لديك \(subs.count) مدفوعات متكررة بـ \(MoneyFormatter.sar(cost)) شهرياً. راجع: " + subs.prefix(5).map(\.name).joined(separator: "، ") + ".")
        }
        // 4. Top merchant.
        if let m = months.first?.byMerchant.first {
            lines.append("• أعلى جهة الشهر الماضي: \(m.name) بـ \(MoneyFormatter.sar(m.amount)) في \(m.count) عملية.")
        }
        let text = lines.isEmpty ? "إنفاقك ضمن معدلاته المعتادة ولا توجد بنود واضحة للتخفيض."
                                 : "أين يمكنك تقليل مصاريفك:\n" + lines.joined(separator: "\n") + "\nالتوفير المحتمل: \(MoneyFormatter.sar(potential.rounded(0))) شهرياً."
        return QueryAnswer(text: text, value: potential.rounded(0), transactionIDs: [], caveats: [], query: query)
    }
}
