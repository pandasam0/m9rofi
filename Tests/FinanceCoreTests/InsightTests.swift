import XCTest
@testable import FinanceCore

final class InsightTests: XCTestCase {
    let now = Fx.date("2026-10-28 12:00")

    /// 4 months of history: salary, Netflix monthly, coffee, groceries.
    func historyLedger() -> Ledger {
        var l = Fx.ledger()
        var recs: [RawRecord] = []
        var n = 0
        func add(_ amount: Decimal, _ dir: Direction, _ kind: TransactionKind, _ d: String, _ m: String?) {
            n += 1
            recs.append(RawRecord(source: .sms, sourceRecordID: "h\(n)", amount: amount, currency: "SAR", direction: dir, kind: kind,
                                  date: Fx.date(d), hasTime: true, merchant: m, cardLast4: "1234", accountLast4: dir == .credit ? "5678" : nil))
        }
        for (mo, day) in [("07", "27"), ("08", "27"), ("09", "27"), ("10", "27")] {
            add(15000, .credit, .income, "2026-\(mo)-\(day) 06:00", nil)
        }
        for mo in ["07", "08", "09", "10"] {
            add(Decimal(string: "56.99")!, .debit, .purchase, "2026-\(mo)-05 03:00", "NETFLIX.COM")
            for d in stride(from: 1, through: 25, by: 3) {
                add(18, .debit, .purchase, "2026-\(mo)-\(String(format: "%02d", d)) 08:00", "BARNS")
            }
            add(400, .debit, .purchase, "2026-\(mo)-10 18:00", "TAMIMI MARKETS")
        }
        _ = l.ingest(records: recs, now: now)
        return l
    }

    func testRecurringDetectsNetflixMonthly() throws {
        let l = historyLedger()
        let series = RecurringDetector(state: l.state).detect(now: now)
        let netflix = try XCTUnwrap(series.first { $0.merchantKey.contains("netflix") })
        XCTAssertEqual(netflix.cadence, .monthly)
        XCTAssertEqual(netflix.expectedAmount, Decimal(string: "56.99"))
        XCTAssertEqual(netflix.nextDate, Fx.date("2026-11-05 03:00"))
        XCTAssertEqual(netflix.category, .subscriptions)
    }

    func testBudgetThresholdsAndAlertsOnce() throws {
        var l = historyLedger()
        l.state.budgets = [Budget(category: .coffee, monthlyLimit: 200), Budget(category: .groceries, monthlyLimit: 1000)]
        let status = BudgetEngine(state: l.state).status(now: now)
        let coffee = try XCTUnwrap(status.first { $0.category == .coffee })
        XCTAssertEqual(coffee.spent, 162) // 9 × 18
        XCTAssertEqual(coffee.crossedThreshold, 75)
        XCTAssertEqual(coffee.remaining, 38)
        let groceries = try XCTUnwrap(status.first { $0.category == .groceries })
        XCTAssertNil(groceries.crossedThreshold) // 40%
        let alerts = AlertEngine(state: l.state).pending(now: now).filter { $0.kind == .budget }
        XCTAssertEqual(alerts.count, 1)
        l.state.firedAlertKeys.insert(alerts[0].id)
        XCTAssertTrue(AlertEngine(state: l.state).pending(now: now).filter { $0.kind == .budget }.isEmpty)
    }

    func testBudgetSuggestions() {
        let l = historyLedger()
        let s = BudgetEngine(state: l.state).suggestions(now: now)
        XCTAssertEqual(s.first { $0.category == .coffee }?.monthlyLimit, 200)       // 162 → 200
        XCTAssertEqual(s.first { $0.category == .groceries }?.monthlyLimit, 400)
    }

    func testAnomaly() {
        var l = historyLedger()
        let big = RawRecord(source: .sms, sourceRecordID: "big", amount: 300, currency: "SAR", direction: .debit, kind: .purchase,
                            date: Fx.date("2026-10-27 09:00"), hasTime: true, merchant: "BARNS", cardLast4: "1234")
        let rep = l.ingest(records: [big], now: now)
        let t = l.state.transactions.first { $0.id == rep.added[0] }!
        XCTAssertNotNil(AnomalyDetector(state: l.state).check(t))
        let normal = l.state.transactions.first { $0.merchantKey == "barns" && $0.baseAmount == 18 && $0.date > Fx.date("2026-10-01") }!
        XCTAssertNil(AnomalyDetector(state: l.state).check(normal))
    }

    func testQueries() {
        let l = historyLedger()
        let q = QueryEngine(state: l.state)
        XCTAssertEqual(q.parse("كم صرفت على القهوة هذا الشهر؟"), FinanceQuery(intent: .categorySpending, category: .coffee, period: .thisMonth))
        XCTAssertEqual(q.parse("كم صرفت في آخر ٧ أيام"), FinanceQuery(intent: .totalSpending, period: .lastDays(7)))
        XCTAssertEqual(q.parse("ما أكثر شيء استنزف أموالي؟").intent, .topCategory)
        XCTAssertEqual(q.parse("كم يتبقى لي من راتبي؟").intent, .remainingSalary)
        XCTAssertEqual(q.parse("كم يمكنني توفيره شهرياً؟").intent, .savingsCapacity)
        XCTAssertEqual(q.parse("أين يمكنني تقليل مصاريفي؟").intent, .savingsTips)
        XCTAssertEqual(q.parse("كم صرفت على السفر خلال السنة؟"), FinanceQuery(intent: .categorySpending, category: .travel, period: .thisYear))
        XCTAssertEqual(q.parse("كم دفعت على الاشتراكات؟").intent, .subscriptions)
        XCTAssertEqual(q.parse("How much did I spend today?").period, .today)
        XCTAssertEqual(q.parse("كم صرفت في barns").intent, .merchantSpending)

        XCTAssertEqual(q.answer("كم صرفت على القهوة هذا الشهر؟", now: now).value, 162)
        // October: Netflix 56.99 + coffee 162 + groceries 400
        XCTAssertEqual(q.answer("كم صرفت هذا الشهر", now: now).value, Decimal(string: "618.99"))
        XCTAssertEqual(q.answer("كم يتبقى من راتبي", now: now).value, 15000) // nothing spent since 27 Oct 06:00
        XCTAssertEqual(q.answer("كم يمكنني توفيره", now: now).value, Decimal(string: "14381.01"))
        XCTAssertEqual(q.answer("ما أكثر شيء استنزف أموالي", now: now).value, 400)
    }

    func testDashboardAndMonthComparison() {
        var l = historyLedger()
        l.setBalance(accountID: Fx.snbID, balance: 12000, date: now)
        l.setBalance(accountID: Fx.barqID, balance: 500, date: now)
        let d = Aggregator(state: l.state).dashboard(now: now)
        XCTAssertEqual(d.totalBalance, 12500)
        XCTAssertEqual(d.month.spending, Decimal(string: "618.99"))
        XCTAssertEqual(d.month.income, 15000)
        XCTAssertEqual(d.month.topCategory?.category, .groceries)
        XCTAssertEqual(d.previousMonthToDate.spending, Decimal(string: "618.99"))
        XCTAssertEqual(d.monthChangeRatio, 0)
    }

    func testExports() {
        let l = historyLedger()
        let r = Report.build(state: l.state, period: .month, containing: now, now: now)
        let csv = String(decoding: ReportExporter.csv(r, accounts: l.state.accounts, tz: Fx.tz), as: UTF8.self)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}التاريخ"))
        XCTAssertEqual(csv.split(separator: "\r\n").count, 1 + r.transactions.count)
        let xls = String(decoding: ReportExporter.excel(r, accounts: l.state.accounts, tz: Fx.tz), as: UTF8.self)
        XCTAssertTrue(xls.contains("<Worksheet ss:Name=\"العمليات\""))
        XCTAssertTrue(xls.contains("618.99"))
    }

    func testStateRoundTripsThroughJSON() throws {
        let l = historyLedger()
        let data = try JSONEncoder().encode(l.state)
        let decoded = try JSONDecoder().decode(LedgerState.self, from: data)
        XCTAssertEqual(decoded.transactions, l.state.transactions)
        let agg = Aggregator(state: decoded)
        XCTAssertEqual(agg.summary(agg.interval(.month, containing: now), now: now).spending, Decimal(string: "618.99"))
    }
}
