import XCTest
@testable import FinanceCore

/// Financial accuracy requirements (section 14). Every test asserts exact SAR totals.
final class AccuracyTests: XCTestCase {
    let now = Fx.date("2026-10-28 12:00")

    func month(_ l: Ledger) -> PeriodSummary {
        let agg = Aggregator(state: l.state)
        return agg.summary(agg.interval(.month, containing: now), now: now)
    }

    func testSameSMSTwiceCountsOnce() {
        var l = Fx.ledger()
        _ = l.ingest([Fx.sms(Fx.starbucks)], source: .sms, now: now)
        let r = l.ingest([Fx.sms(Fx.starbucks)], source: .sms, now: now)
        XCTAssertEqual(r.exactDuplicates, 1)
        XCTAssertEqual(l.state.transactions.count, 1)
        XCTAssertEqual(month(l).spending, Decimal(string: "25.50"))
    }

    func testWalletAutomationPlusSMSMerge() {
        var l = Fx.ledger()
        let wallet = WalletAutomationAdapter.record(merchant: "Starbucks", amountText: "SAR 25.50", cardName: "SNB mada", date: Fx.date("2026-10-15 08:14"))
        _ = l.ingest(records: [wallet], now: now)
        let r = l.ingest([Fx.sms(Fx.starbucks)], source: .sms, now: now)
        XCTAssertEqual(r.merged.count, 1)
        XCTAssertEqual(l.state.transactions.count, 1)
        XCTAssertEqual(l.state.transactions[0].sources.count, 2)
        XCTAssertEqual(l.state.transactions[0].accountID, Fx.snbID)
        XCTAssertEqual(month(l).spending, Decimal(string: "25.50"))
    }

    func testStatementAfterSMSDoesNotDoubleCount() {
        var l = Fx.ledger()
        _ = l.ingest([Fx.sms(Fx.starbucks), Fx.sms(Fx.pandaEnglish)], source: .sms, now: now)
        let csv = """
        Date,Description,Debit,Credit,Balance
        15/10/2026,POS PURCHASE STARBUCKS RIYADH,25.50,,4974.50
        16/10/2026,POS PURCHASE PANDA HYPER,120.00,,4854.50
        20/10/2026,POS PURCHASE JARIR BOOKSTORE,300.00,,4554.50
        """
        let res = StatementImporter(timeZone: Fx.tz).importCSV(csv, accountID: Fx.snbID)
        let rep = l.ingest(records: res.records, now: now)
        XCTAssertEqual(rep.merged.count, 2)
        XCTAssertEqual(rep.added.count, 1)
        XCTAssertEqual(month(l).spending, Decimal(string: "445.50"))
        // Re-import the same statement: nothing changes.
        let again = l.ingest(records: StatementImporter(timeZone: Fx.tz).importCSV(csv, accountID: Fx.snbID).records, now: now)
        XCTAssertEqual(again.exactDuplicates, 3)
        XCTAssertEqual(month(l).spending, Decimal(string: "445.50"))
    }

    func testTwoGenuineIdenticalPurchasesBothCount() {
        var l = Fx.ledger()
        let a = Fx.starbucks
        let b = Fx.starbucks.replacingOccurrences(of: "08:15", with: "08:17").replacingOccurrences(of: "4,974.50", with: "4,949.00")
        _ = l.ingest([Fx.sms(a), Fx.sms(b)], source: .sms, now: now)
        XCTAssertEqual(l.state.transactions.count, 2)
        XCTAssertEqual(month(l).spending, 51)
    }

    func testInternalTransferNotSpending() {
        var l = Fx.ledger()
        _ = l.ingest([Fx.sms(Fx.transferToBarq)], source: .sms, now: now)
        _ = l.ingest([Fx.sms(Fx.barqIncoming, sender: "Barq")], source: .sms, now: now)
        let s = month(l)
        XCTAssertEqual(s.spending, 0)
        XCTAssertEqual(s.income, 0)
        XCTAssertEqual(s.incomingTransfers, 0)
        XCTAssertEqual(s.internalTransferCount, 2)
        XCTAssertTrue(l.state.transactions.allSatisfy(\.isInternalTransfer))
        XCTAssertTrue(l.reviewQueue.isEmpty)
    }

    func testTransferPairMatchedByLegsWithoutAccountNumber() {
        var l = Fx.ledger()
        let out = RawRecord(source: .sms, sourceRecordID: "o1", amount: 500, currency: "SAR", direction: .debit, kind: .transferOut,
                            date: Fx.date("2026-10-12 09:00"), hasTime: true, counterparty: "D360 Bank", accountID: Fx.snbID)
        let inn = RawRecord(source: .sms, sourceRecordID: "i1", amount: 500, currency: "SAR", direction: .credit, kind: .transferIn,
                            date: Fx.date("2026-10-12 09:02"), hasTime: true, accountID: Fx.d360ID)
        _ = l.ingest(records: [out, inn], now: now)
        XCTAssertEqual(month(l).spending, 0)
        XCTAssertEqual(l.state.transactions.filter(\.isInternalTransfer).count, 2)
    }

    func testWalletTopUpByCardIsInternal() {
        var l = Fx.ledger()
        let topup = RawRecord(source: .sms, sourceRecordID: "t1", amount: 300, currency: "SAR", direction: .debit, kind: .purchase,
                              date: Fx.date("2026-10-12 09:00"), hasTime: true, merchant: "BARQ", cardLast4: "1234")
        let credit = RawRecord(source: .sms, sourceRecordID: "t2", amount: 300, currency: "SAR", direction: .credit, kind: .transferIn,
                               date: Fx.date("2026-10-12 09:00"), hasTime: true, accountID: Fx.barqID)
        _ = l.ingest(records: [topup, credit], now: now)
        XCTAssertEqual(month(l).spending, 0)
    }

    func testExternalTransferIsSpendingAndIncomingIsNotIncome() {
        var l = Fx.ledger()
        let out = RawRecord(source: .sms, sourceRecordID: "o", amount: 250, currency: "SAR", direction: .debit, kind: .transferOut,
                            date: Fx.date("2026-10-12 09:00"), hasTime: true, counterparty: "Ahmed", accountID: Fx.snbID)
        let inn = RawRecord(source: .sms, sourceRecordID: "i", amount: 400, currency: "SAR", direction: .credit, kind: .transferIn,
                            date: Fx.date("2026-10-13 09:00"), hasTime: true, counterparty: "Khalid", accountID: Fx.snbID)
        _ = l.ingest(records: [out, inn], now: now)
        let s = month(l)
        XCTAssertEqual(s.spending, 250)
        XCTAssertEqual(s.byCategory.first?.category, .transfers)
        XCTAssertEqual(s.income, 0)
        XCTAssertEqual(s.incomingTransfers, 400)
    }

    func testSelfNamedTransferGoesToReview() {
        var l = Fx.ledger()
        let out = RawRecord(source: .sms, sourceRecordID: "o", amount: 2000, currency: "SAR", direction: .debit, kind: .transferOut,
                            date: Fx.date("2026-10-12 09:00"), hasTime: true, counterparty: "SAMI ALHARBI", accountID: Fx.snbID)
        _ = l.ingest(records: [out], now: now)
        XCTAssertEqual(l.reviewQueue.first?.reviewReasons, [.possibleInternalTransfer])
        XCTAssertEqual(month(l).spending, 0)
        XCTAssertEqual(month(l).unconfirmedAmount, 2000)
        l.resolve(l.reviewQueue[0].id, .markInternal)
        XCTAssertEqual(month(l).spending, 0)
        XCTAssertTrue(l.reviewQueue.isEmpty)
    }

    func testCreditCardPaymentNotCountedTwice() {
        var l = Fx.ledger(withCreditCard: true)
        _ = l.ingest([Fx.sms(Fx.netflixUSD)], source: .sms, now: now)        // card purchase 75.30
        let pay = RawRecord(source: .sms, sourceRecordID: "p", amount: Decimal(string: "75.30"), currency: "SAR", direction: .debit,
                            kind: .cardPayment, date: Fx.date("2026-10-25 09:00"), hasTime: true, accountID: Fx.snbID)
        _ = l.ingest(records: [pay], now: now)
        XCTAssertEqual(month(l).spending, Decimal(string: "75.30"))
        XCTAssertTrue(l.reviewQueue.isEmpty)
    }

    func testCardPaymentForUntrackedCardRequiresReview() {
        var l = Fx.ledger()
        let pay = RawRecord(source: .sms, sourceRecordID: "p", amount: 1500, currency: "SAR", direction: .debit,
                            kind: .cardPayment, date: Fx.date("2026-10-25 09:00"), hasTime: true, accountID: Fx.snbID)
        _ = l.ingest(records: [pay], now: now)
        XCTAssertEqual(l.reviewQueue.first?.reviewReasons, [.cardPaymentUntrackedCard])
        XCTAssertEqual(month(l).spending, 0)
        l.resolve(l.reviewQueue[0].id, .countCardPaymentAsExpense)
        XCTAssertEqual(month(l).spending, 1500)
    }

    func testPendingNotCountedThenCompletedOnce() {
        var l = Fx.ledger()
        _ = l.ingest([Fx.sms(Fx.hotelPending)], source: .sms, now: now)
        var s = month(l)
        XCTAssertEqual(s.spending, 0)
        XCTAssertEqual(s.pendingAmount, 850)
        _ = l.ingest([Fx.sms(Fx.hotelCompleted)], source: .sms, now: now)
        s = month(l)
        XCTAssertEqual(l.state.transactions.count, 1)
        XCTAssertEqual(l.state.transactions[0].status, .completed)
        XCTAssertEqual(s.spending, 850)
        XCTAssertEqual(s.pendingAmount, 0)
        XCTAssertEqual(s.byCategory.first?.category, .travel)
    }

    func testRefundReducesSpendingInSameCategory() {
        var l = Fx.ledger()
        _ = l.ingest([Fx.sms(Fx.pandaEnglish), Fx.sms(Fx.starbucks)], source: .sms, now: now)
        _ = l.ingest([Fx.sms(Fx.pandaRefund)], source: .sms, now: now)
        let s = month(l)
        XCTAssertEqual(s.grossExpenses, Decimal(string: "145.50"))
        XCTAssertEqual(s.refunds, 120)
        XCTAssertEqual(s.spending, Decimal(string: "25.50"))
        XCTAssertNil(s.byCategory.first { $0.category == .groceries })
        XCTAssertEqual(l.state.transactions.first { $0.merchantRaw == "PANDA HYPER" && $0.direction == .debit }?.status, .refunded)
    }

    func testReversalCancelsOriginal() {
        var l = Fx.ledger()
        _ = l.ingest([Fx.sms(Fx.starbucks)], source: .sms, now: now)
        _ = l.ingest([Fx.sms(Fx.starbucksReversal)], source: .sms, now: now)
        XCTAssertEqual(month(l).spending, 0)
        XCTAssertTrue(l.reviewQueue.isEmpty)
        XCTAssertEqual(l.state.transactions.first { $0.kind == .purchase }?.status, .reversed)
    }

    func testUnmatchedReversalGoesToReview() {
        var l = Fx.ledger()
        _ = l.ingest([Fx.sms(Fx.starbucksReversal)], source: .sms, now: now)
        XCTAssertEqual(l.reviewQueue.first?.reviewReasons, [.unmatchedReversal])
        XCTAssertEqual(month(l).spending, 0)
        XCTAssertEqual(month(l).refunds, 0)
    }

    func testForeignWithoutSARGoesToReview() {
        var l = Fx.ledger()
        let r = RawRecord(source: .sms, sourceRecordID: "f", amount: 50, currency: "USD", direction: .debit, kind: .purchase,
                          date: Fx.date("2026-10-12 09:00"), hasTime: true, merchant: "AMAZON.COM")
        _ = l.ingest(records: [r], now: now)
        XCTAssertEqual(l.reviewQueue.first?.reviewReasons, [.missingBaseCurrencyAmount])
        XCTAssertEqual(month(l).spending, 0)
        l.resolve(l.reviewQueue[0].id, .confirm(baseAmount: Decimal(string: "188.10")))
        XCTAssertEqual(month(l).spending, Decimal(string: "188.10"))
    }

    func testSalaryIsIncomeAndATMIsNotSpending() {
        var l = Fx.ledger()
        _ = l.ingest([Fx.sms(Fx.salary), Fx.sms(Fx.atm), Fx.sms(Fx.starbucks)], source: .sms, now: now)
        let s = month(l)
        XCTAssertEqual(s.income, 15000)
        XCTAssertEqual(s.cashWithdrawals, 500)
        XCTAssertEqual(s.spending, Decimal(string: "25.50"))
        XCTAssertEqual(s.netCashFlow, Decimal(string: "14974.50"))
    }

    func testAmbiguousDuplicateIsHeldForReview() {
        var l = Fx.ledger()
        // Two identical SMS purchases 1 minute apart (genuine), then one statement row without time.
        let a = Fx.starbucks
        let b = Fx.starbucks.replacingOccurrences(of: "08:15", with: "08:16").replacingOccurrences(of: "4,974.50", with: "4,949.00")
        _ = l.ingest([Fx.sms(a), Fx.sms(b)], source: .sms, now: now)
        let row = RawRecord(source: .statementCSV, sourceRecordID: "s1", amount: Decimal(string: "25.50"), currency: "SAR", direction: .debit,
                            kind: .purchase, date: Fx.date("2026-10-15"), hasTime: false, merchant: "STARBUCKS", accountID: Fx.snbID)
        _ = l.ingest(records: [row], now: now)
        XCTAssertEqual(month(l).spending, 51)
        XCTAssertEqual(l.reviewQueue.first?.reviewReasons, [.possibleDuplicate])
        // User says it's the same as the first one.
        let target = l.reviewQueue[0].linkedTransactionID!
        l.resolve(l.reviewQueue[0].id, .mergeInto(target))
        XCTAssertEqual(l.state.transactions.count, 2)
        XCTAssertEqual(month(l).spending, 51)
    }

    func testLearnedCategoryAppliesToPastAndFuture() {
        var l = Fx.ledger()
        let mk = { (id: String, d: String) in RawRecord(source: .sms, sourceRecordID: id, amount: 40, currency: "SAR", direction: .debit, kind: .purchase,
                                                        date: Fx.date(d), hasTime: true, merchant: "ABU KHALID KITCHEN", cardLast4: "1234") }
        _ = l.ingest(records: [mk("1", "2026-10-01 13:00")], now: now)
        XCTAssertEqual(l.state.transactions[0].category, .dining) // keyword "kitchen"
        l.recategorize(l.state.transactions[0].id, to: .personal)
        _ = l.ingest(records: [mk("2", "2026-10-08 13:00")], now: now)
        XCTAssertTrue(l.state.transactions.allSatisfy { $0.category == .personal })
        XCTAssertEqual(l.state.transactions[1].categorySource, .learnedRule)
    }

    func testDictionaryCategories() {
        let c = Categorizer(rules: [])
        func cat(_ m: String) -> Category {
            c.categorize(Transaction(amount: 10, direction: .debit, kind: .purchase, date: Date(), merchantRaw: m,
                                     merchantKey: TextNormalizer.merchantKey(m))).category
        }
        XCTAssertEqual(cat("STARBUCKS OLAYA"), .coffee)
        XCTAssertEqual(cat("ALDREES 123"), .auto)
        XCTAssertEqual(cat("NETFLIX.COM"), .subscriptions)
        XCTAssertEqual(cat("هايبر بنده"), .groceries)
        XCTAssertNotEqual(cat("SMITH MART"), .shopping) // "h m" (H&M) must not match inside "smith mart"
    }

    func testSettingsChangeAccountingRules() {
        var l = Fx.ledger()
        _ = l.ingest([Fx.sms(Fx.atm)], source: .sms, now: now)
        let out = RawRecord(source: .sms, sourceRecordID: "o", amount: 250, currency: "SAR", direction: .debit, kind: .transferOut,
                            date: Fx.date("2026-10-12 09:00"), hasTime: true, counterparty: "Ahmed", accountID: Fx.snbID)
        _ = l.ingest(records: [out], now: now)
        XCTAssertEqual(month(l).spending, 250)
        l.state.settings.cashWithdrawalsAsSpending = true
        XCTAssertEqual(month(l).spending, 750)
        XCTAssertEqual(month(l).byCategory.first?.category, .cash)
        l.state.settings.countExternalTransfersAsSpending = false
        XCTAssertEqual(month(l).spending, 500)
    }

    func testUserExclusionAndAISuggestionDoesNotOverrideUser() {
        var l = Fx.ledger()
        _ = l.ingest([Fx.sms(Fx.starbucks)], source: .sms, now: now)
        let id = l.state.transactions[0].id
        l.recategorize(id, to: .personal, learn: false)
        l.applyAISuggestion(id, category: .dining, confidence: 0.9)
        XCTAssertEqual(l.state.transactions[0].category, .personal)
        var t = l.state.transactions[0]; t.userExcluded = true; l.update(t)
        XCTAssertEqual(month(l).spending, 0)
    }
}
