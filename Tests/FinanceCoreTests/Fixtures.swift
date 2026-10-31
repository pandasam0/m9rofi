import Foundation
@testable import FinanceCore

/// Synthetic messages modelled on common Saudi bank SMS structure. Real formats must be validated with
/// the user's own (masked) messages; add them to `SMSRealSamplesTests` when available.
enum Fx {
    static let tz = TimeZone(identifier: "Asia/Riyadh")!

    static func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = s.count > 10 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return f.date(from: s)!
    }

    static let snbID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let barqID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let d360ID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let ccID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    static func ledger(withCreditCard: Bool = false) -> Ledger {
        var state = LedgerState()
        state.accounts = [
            Account(id: snbID, name: "الأهلي الجاري", institution: .snb, type: .current, cardLast4: ["1234"], accountLast4: ["5678"],
                    walletCardNames: ["SNB mada"], smsSenders: ["SNB-AlAhli"]),
            Account(id: barqID, name: "Barq", institution: .barq, type: .wallet, cardLast4: ["7777"], accountLast4: ["9012"],
                    walletCardNames: ["Barq"], smsSenders: ["Barq"]),
            Account(id: d360ID, name: "D360", institution: .d360, type: .current, cardLast4: ["3600"], accountLast4: ["3601"], smsSenders: ["D360"])
        ]
        if withCreditCard {
            state.accounts.append(Account(id: ccID, name: "بطاقة ائتمانية", institution: .snb, type: .creditCard, cardLast4: ["4321"]))
        }
        state.settings.ownerNames = ["Sami Alharbi", "سامي الحربي"]
        return Ledger(state: state)
    }

    static let parser = SMSParser(timeZone: tz)

    static func sms(_ text: String, sender: String = "SNB-AlAhli", at: String = "2026-10-15 12:00") -> ParseOutcome {
        parser.parse(text: text, sender: sender, receivedAt: date(at))
    }

    static let starbucks = """
    شراء عبر نقاط البيع
    بطاقة: مدى *1234
    مبلغ: SAR 25.50
    لدى: STARBUCKS
    في: 2026-10-15 08:15
    الرصيد: SAR 4,974.50
    """

    static let pandaEnglish = """
    POS Purchase
    Card: mada **1234
    Amount: SAR 120.00
    At: PANDA HYPER
    Date: 15/10/2026 19:40
    Balance: SAR 4,854.50
    """

    static let transferToBarq = """
    حوالة صادرة
    من حساب: **5678
    مبلغ: 1,000.00 ر.س
    إلى: BARQ ***9012
    في: 2026-10-16 10:00
    """

    static let barqIncoming = """
    حوالة واردة
    مبلغ: SAR 1000
    من: Sami Alharbi
    حساب **9012
    2026-10-16 10:01
    """

    static let salary = """
    إيداع راتب
    مبلغ: SAR 15,000.00
    حساب **5678
    2026-10-27 06:00
    """

    static let otp = "رمز التحقق: 123456 لعملية شراء بمبلغ 50 ريال. لا تشارك الرمز مع أحد"
    static let declined = "عملية شراء مرفوضة بمبلغ SAR 300 لدى NOON بطاقة *1234 - رصيد غير كاف"

    static let netflixUSD = """
    Online Purchase
    Card: Visa *4321
    Amount: USD 20.00 (SAR 75.30)
    At: NETFLIX.COM
    2026-10-10 03:00
    """

    static let pandaRefund = """
    استرداد مبلغ
    مبلغ: SAR 120.00
    لدى: PANDA HYPER
    بطاقة مدى *1234
    2026-10-18 12:00
    """

    static let starbucksReversal = """
    عكس عملية شراء
    مبلغ SAR 25.50
    لدى: STARBUCKS
    بطاقة *1234
    2026-10-15 09:00
    """

    static let atm = """
    سحب نقدي من الصراف الآلي
    مبلغ: ٥٠٠ ريال
    بطاقة مدى *1234
    ٢٠٢٦-١٠-١٧ ٢٠:٠٠
    """

    static let hotelPending = """
    حجز مبلغ (عملية معلقة)
    بطاقة *1234
    مبلغ: SAR 850.00
    لدى: MARRIOTT RIYADH
    2026-10-20 22:00
    """

    static let hotelCompleted = """
    شراء
    بطاقة *1234
    مبلغ: SAR 850.00
    لدى: MARRIOTT RIYADH
    2026-10-22 09:00
    """
}

extension ParseOutcome {
    var record: RawRecord? { if case .record(let r) = self { return r }; return nil }
}
