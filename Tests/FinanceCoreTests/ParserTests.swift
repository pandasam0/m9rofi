import XCTest
@testable import FinanceCore

final class ParserTests: XCTestCase {
    func testArabicDigitsAndAmounts() {
        XCTAssertEqual(TextNormalizer.parseAmount("١٬٢٣٤٫٥٠"), Decimal(string: "1234.50"))
        XCTAssertEqual(TextNormalizer.parseAmount("1,000.00"), 1000)
        XCTAssertEqual(TextNormalizer.parseAmount("(45.10)"), Decimal(string: "-45.10"))
        XCTAssertNil(TextNormalizer.parseAmount("12a"))
    }

    func testArabicPurchase() throws {
        let r = try XCTUnwrap(Fx.sms(Fx.starbucks).record)
        XCTAssertEqual(r.kind, .purchase)
        XCTAssertEqual(r.direction, .debit)
        XCTAssertEqual(r.amount, Decimal(string: "25.50"))
        XCTAssertEqual(r.currency, "SAR")
        XCTAssertEqual(r.merchant, "STARBUCKS")
        XCTAssertEqual(r.cardLast4, "1234")
        XCTAssertEqual(r.balanceAfter, Decimal(string: "4974.50"))
        XCTAssertEqual(r.date, Fx.date("2026-10-15 08:15"))
        XCTAssertTrue(r.hasTime)
    }

    func testEnglishPurchase() throws {
        let r = try XCTUnwrap(Fx.sms(Fx.pandaEnglish).record)
        XCTAssertEqual(r.kind, .purchase)
        XCTAssertEqual(r.amount, 120)
        XCTAssertEqual(r.merchant, "PANDA HYPER")
        XCTAssertEqual(r.date, Fx.date("2026-10-15 19:40"))
        XCTAssertEqual(r.balanceAfter, Decimal(string: "4854.50"))
    }

    func testIgnoresOTPAndDeclined() {
        XCTAssertEqual(Fx.sms(Fx.otp), .ignored(reason: "otp"))
        XCTAssertEqual(Fx.sms(Fx.declined), .ignored(reason: "declined"))
    }

    func testForeignCurrencyCapturesSARCharge() throws {
        let r = try XCTUnwrap(Fx.sms(Fx.netflixUSD).record)
        XCTAssertEqual(r.currency, "USD")
        XCTAssertEqual(r.amount, 20)
        XCTAssertEqual(r.baseAmount, Decimal(string: "75.30"))
        XCTAssertEqual(r.cardLast4, "4321")
    }

    func testTransferOutWithCounterpartyAccount() throws {
        let r = try XCTUnwrap(Fx.sms(Fx.transferToBarq).record)
        XCTAssertEqual(r.kind, .transferOut)
        XCTAssertEqual(r.direction, .debit)
        XCTAssertEqual(r.amount, 1000)
        XCTAssertEqual(r.accountLast4, "5678")
        XCTAssertEqual(r.counterpartyAccountLast4, "9012")
    }

    func testSalaryAndATMWithArabicDigits() throws {
        let s = try XCTUnwrap(Fx.sms(Fx.salary).record)
        XCTAssertEqual(s.kind, .income)
        XCTAssertEqual(s.direction, .credit)
        XCTAssertEqual(s.amount, 15000)
        let a = try XCTUnwrap(Fx.sms(Fx.atm).record)
        XCTAssertEqual(a.kind, .cashWithdrawal)
        XCTAssertEqual(a.amount, 500)
        XCTAssertEqual(a.date, Fx.date("2026-10-17 20:00"))
    }

    func testPendingRefundReversal() throws {
        XCTAssertEqual(Fx.sms(Fx.hotelPending).record?.status, .pending)
        XCTAssertEqual(Fx.sms(Fx.pandaRefund).record?.kind, .refund)
        XCTAssertEqual(Fx.sms(Fx.pandaRefund).record?.direction, .credit)
        XCTAssertEqual(Fx.sms(Fx.starbucksReversal).record?.kind, .reversal)
    }

    func testShortKeywordsNeedWordBoundary() throws {
        let r = try XCTUnwrap(Fx.sms("Purchase at RIYADH TREATMENT CENTER\nAmount: SAR 300.00\nCard *1234").record)
        XCTAssertEqual(r.kind, .purchase) // "treatment" must not trigger "atm"
    }

    func testBalanceOnlyMessage() {
        guard case let .balance(acc, _, bal, _, _, _) = Fx.sms("رصيد حسابك **5678 هو SAR 3,210.00") else {
            return XCTFail("expected balance")
        }
        XCTAssertEqual(acc, "5678")
        XCTAssertEqual(bal, 3210)
    }

    func testCustomTemplateWins() throws {
        let t = SMSTemplate(name: "Barq spend", senders: ["Barq"],
                            pattern: #"دفعت (?<amount>[\d.,]+) (?<currency>ريال) في (?<merchant>.+?)\."#, kind: .purchase, direction: .debit)
        let p = SMSParser(timeZone: Fx.tz, templates: [t])
        let r = try XCTUnwrap(p.parse(text: "دفعت 18.00 ريال في كوفي ديو.", sender: "Barq", receivedAt: Fx.date("2026-10-15 10:00")).record)
        XCTAssertEqual(r.amount, 18)
        XCTAssertEqual(r.merchant, "كوفي ديو")
        XCTAssertEqual(r.kind, .purchase)
    }

    func testCSVStatementDetection() {
        let csv = """
        \u{FEFF}التاريخ,البيان,مدين,دائن,الرصيد
        2026-10-15,"POS PURCHASE STARBUCKS, RIYADH",25.50,,4974.50
        2026-10-15,POS PURCHASE PANDA HYPER,120.00,,4854.50
        2026-10-27,SALARY OCTOBER,,15000.00,19854.50
        """
        let res = StatementImporter(timeZone: Fx.tz).importCSV(csv, accountID: Fx.snbID)
        XCTAssertEqual(res.records.count, 3)
        XCTAssertEqual(res.records[0].direction, .debit)
        XCTAssertEqual(res.records[0].amount, Decimal(string: "25.50"))
        XCTAssertEqual(res.records[0].merchant, "STARBUCKS, RIYADH")
        XCTAssertEqual(res.records[2].kind, .income)
        XCTAssertEqual(res.records[2].direction, .credit)
        XCTAssertFalse(res.records[0].hasTime)
        XCTAssertEqual(res.closingBalance?.0, Decimal(string: "19854.50"))
    }

    func testPDFTextLines() {
        let lines = [
            "Statement of Account",
            "01/10/2026 Opening balance 5,000.00",
            "15/10/2026 POS PURCHASE STARBUCKS 25.50 4,974.50",
            "16/10/2026 INCOMING TRANSFER 200.00 5,174.50"
        ]
        let res = StatementImporter(timeZone: Fx.tz).importPDFText(lines, accountID: Fx.snbID)
        let tx = res.records.filter { $0.amount != 5000 }
        XCTAssertEqual(tx.count, 2)
        XCTAssertEqual(tx[0].direction, .debit)
        XCTAssertEqual(tx[1].direction, .credit)
        XCTAssertEqual(tx[1].kind, .transferIn)
    }

    func testWalletAutomationAmountFormats() {
        let a = WalletAutomationAdapter.record(merchant: "Starbucks", amountText: "SAR 25.50", cardName: "SNB mada", date: Fx.date("2026-10-15 08:14"))
        XCTAssertEqual(a.amount, Decimal(string: "25.50"))
        XCTAssertEqual(a.currency, "SAR")
        let b = WalletAutomationAdapter.record(merchant: "X", amountText: "‏٢٥٫٥٠ ر.س", cardName: nil, date: Fx.date("2026-10-15 08:14"))
        XCTAssertEqual(b.amount, Decimal(string: "25.50"))
        XCTAssertEqual(b.currency, "SAR")
    }

    func testReceiptEmail() throws {
        let r = try XCTUnwrap(ReceiptParser.record(subject: "Your receipt from Apple", from: "Apple <no_reply@email.apple.com>",
                                                   body: "<p>Subtotal SAR 18.26</p><p>VAT SAR 2.73</p><p>Total SAR 20.99</p>",
                                                   date: Fx.date("2026-10-05 10:00"), messageID: "m1"))
        XCTAssertEqual(r.amount, Decimal(string: "20.99"))
        XCTAssertEqual(r.merchant, "Apple")
    }

    func testOpenBankingMapping() throws {
        let json = """
        {"Data":{"Transaction":[
          {"TransactionId":"T1","CreditDebitIndicator":"Debit","Status":"Booked","BookingDateTime":"2026-10-15T08:15:00+03:00",
           "Amount":{"Amount":"25.50","Currency":"SAR"},"TransactionInformation":"POS STARBUCKS",
           "MerchantDetails":{"MerchantName":"STARBUCKS","MerchantCategoryCode":"5814"}},
          {"TransactionId":"T2","CreditDebitIndicator":"Credit","Status":"Pending","BookingDateTime":"2026-10-16T10:00:00+03:00",
           "Amount":{"Amount":"1000.00","Currency":"SAR"},"TransactionInformation":"Incoming transfer"}
        ]}}
        """
        let recs = try OpenBankingMapper.records(from: Data(json.utf8), accountID: Fx.snbID)
        XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(recs[0].kind, .purchase)
        XCTAssertEqual(recs[0].mcc, "5814")
        XCTAssertEqual(recs[1].status, .pending)
        XCTAssertEqual(recs[1].kind, .transferIn)
    }
}

final class EMLTests: XCTestCase {
    func testMultipartQuotedPrintable() throws {
        let eml = """
        From: Jahez <noreply@jahez.net>
        Subject: =?UTF-8?B?2YHYp9iq2YjYsdipINi32YTYqNmD?=
        Date: Mon, 12 Oct 2026 20:15:00 +0300
        Message-ID: <abc123@jahez.net>
        Content-Type: multipart/alternative; boundary="XYZ"

        --XYZ
        Content-Type: text/plain; charset=UTF-8
        Content-Transfer-Encoding: quoted-printable

        Order total: SAR 64.50=0AThank you
        --XYZ--
        """
        let m = EMLParser.parse(eml)
        XCTAssertEqual(m.subject, "فاتورة طلبك")
        XCTAssertEqual(m.messageID, "abc123@jahez.net")
        XCTAssertNotNil(m.date)
        let r = try XCTUnwrap(ReceiptParser.record(subject: m.subject, from: m.from, body: m.body, date: m.date!, messageID: m.messageID))
        XCTAssertEqual(r.amount, Decimal(string: "64.50"))
        XCTAssertEqual(r.merchant, "Jahez")
    }

    func testOldStateWithoutNewKeysDecodes() throws {
        let json = #"{"accounts":[],"transactions":[],"settings":{"baseCurrency":"SAR"}}"#
        let s = try JSONDecoder().decode(LedgerState.self, from: Data(json.utf8))
        XCTAssertEqual(s.settings.timeZoneID, "Asia/Riyadh")
        XCTAssertTrue(s.smsTemplates.isEmpty)
    }
}
