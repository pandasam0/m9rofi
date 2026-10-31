import Foundation
import FinanceCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Finance assistant.
/// 1. Deterministic parser (`QueryEngine.parse`) — works offline on every iOS version.
/// 2. If the question is not understood and Apple Intelligence's on-device model is available (iOS 26+),
///    the model only converts the question into a structured `FinanceQuery`.
/// 3. All numbers are computed by `QueryEngine.answer` from recorded transactions.
@MainActor
enum AIAssistant {
    static func answer(_ question: String, state: LedgerState) async -> QueryAnswer {
        let engine = QueryEngine(state: state)
        var query = engine.parse(question)
        if query.intent == .unknown, let llm = await structuredQuery(question) {
            query = llm
        }
        return engine.answer(query)
    }

    static var onDeviceModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static func structuredQuery(_ question: String) async -> FinanceQuery? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), onDeviceModelAvailable {
            do {
                let session = LanguageModelSession(instructions: """
                Convert a personal-finance question (Arabic or English) into a structured query. \
                Never answer the question and never produce amounts.
                """)
                let r = try await session.respond(to: question, generating: LLMQuery.self)
                return r.content.toQuery()
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// Category suggestion for transactions the deterministic categoriser could not place.
    static func suggestCategory(merchant: String) async -> Category? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), onDeviceModelAvailable {
            do {
                let session = LanguageModelSession(instructions: "Classify a Saudi merchant name into one spending category.")
                let r = try await session.respond(to: merchant, generating: LLMCategory.self)
                return Category(rawValue: r.content.category)
            } catch { return nil }
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct LLMQuery {
    @Guide(description: "What the user asks", .anyOf(QueryIntent.allCases.map(\.rawValue)))
    var intent: String
    @Guide(description: "Spending category if mentioned, else none", .anyOf(Category.expenseCategories.map(\.rawValue) + ["none"]))
    var category: String
    @Guide(description: "Time period", .anyOf(["today", "yesterday", "thisWeek", "lastWeek", "thisMonth", "lastMonth", "thisYear", "lastYear", "lastDays", "allTime"]))
    var period: String
    @Guide(description: "Number of days when period is lastDays, otherwise 0")
    var days: Int

    func toQuery() -> FinanceQuery {
        let p: QueryPeriod = switch period {
        case "today": .today
        case "yesterday": .yesterday
        case "thisWeek": .thisWeek
        case "lastWeek": .lastWeek
        case "lastMonth": .lastMonth
        case "thisYear": .thisYear
        case "lastYear": .lastYear
        case "lastDays": .lastDays(max(1, days))
        case "allTime": .allTime
        default: .thisMonth
        }
        return FinanceQuery(intent: QueryIntent(rawValue: intent) ?? .unknown, category: Category(rawValue: category), period: p)
    }
}

@available(iOS 26.0, *)
@Generable
struct LLMCategory {
    @Guide(description: "Category", .anyOf(Category.expenseCategories.map(\.rawValue)))
    var category: String
}
#endif
