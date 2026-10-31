import AppIntents
import FinanceCore

// iOS gives third-party apps NO access to SMS, Wallet history or other apps' notifications.
// These intents are the official bridge: the user creates Shortcuts personal automations that pass
// the data to the app. See docs/SHORTCUTS_SETUP.md.

/// Automation: "When I get a message from <bank sender>" → Log Bank Message (Message = Shortcut Input).
struct LogBankMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Bank Message"
    static let description = IntentDescription("Parses a bank SMS or notification text and records the transaction.")
    static let openAppWhenRun = false

    @Parameter(title: "Message") var message: String
    @Parameter(title: "Sender") var sender: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let r = AppStore.shared.ingestMessage(message, sender: sender)
        return .result(value: Self.summary(r))
    }

    static func summary(_ r: IngestReport) -> String {
        if r.exactDuplicates > 0 { return "مسجلة مسبقاً" }
        if !r.merged.isEmpty { return "دُمجت مع عملية موجودة" }
        if !r.flaggedForReview.isEmpty { return "أضيفت لقائمة المراجعة" }
        if !r.added.isEmpty { return "تم التسجيل" }
        if r.balancesUpdated > 0 { return "تم تحديث الرصيد" }
        return "ليست عملية مالية"
    }
}

/// Automation: Wallet "Transaction" trigger (iOS 17+) → Log Wallet Payment (Merchant / Amount / Card from Shortcut Input).
struct LogWalletPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Apple Pay Payment"
    static let description = IntentDescription("Records an Apple Pay tap from the Wallet Transaction automation.")
    static let openAppWhenRun = false

    @Parameter(title: "Merchant") var merchant: String?
    @Parameter(title: "Amount") var amount: String
    @Parameter(title: "Card") var card: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let r = AppStore.shared.ingestWallet(merchant: merchant, amountText: amount, cardName: card)
        return .result(value: LogBankMessageIntent.summary(r))
    }
}

/// "Hey Siri, ask M9rofi how much I spent today"
struct AskFinanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Finance Assistant"
    static let openAppWhenRun = false

    @Parameter(title: "Question") var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let a = await AIAssistant.answer(question, state: AppStore.shared.state)
        let text = ([a.text] + a.caveats).joined(separator: "\n")
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct TodaySpendingIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Spending"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let a = QueryEngine(state: AppStore.shared.state).answer(FinanceQuery(intent: .totalSpending, period: .today))
        return .result(value: a.text, dialog: IntentDialog(stringLiteral: a.text))
    }
}

struct M9rofiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TodaySpendingIntent(), phrases: ["How much did I spend today in \(.applicationName)",
                                                             "كم صرفت اليوم في \(.applicationName)"],
                    shortTitle: "Today's Spending", systemImageName: "creditcard")
        AppShortcut(intent: AskFinanceIntent(), phrases: ["Ask \(.applicationName)", "اسأل \(.applicationName)"],
                    shortTitle: "Ask", systemImageName: "bubble.left.and.text.bubble.right")
    }
}
