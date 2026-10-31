import SwiftUI
import FinanceCore

struct BudgetsView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: Category?
    @State private var value = ""

    var body: some View {
        let engine = BudgetEngine(state: store.state)
        let status = engine.status()
        let suggestions = engine.suggestions()
        List {
            Section("This month") {
                ForEach(status) { b in
                    BudgetRow(status: b)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = b.category; value = "\(b.limit)" }
                        .swipeActions { Button("Remove", role: .destructive) { store.setBudget(b.category, nil) } }
                }
                if status.isEmpty { Text("No budgets yet").foregroundStyle(.secondary) }
            }
            let missing = suggestions.filter { s in !status.contains { $0.category == s.category } }
            if !missing.isEmpty {
                Section {
                    ForEach(missing, id: \.category) { s in
                        HStack {
                            Label(s.category.localizedName, systemImage: s.category.symbol)
                            Spacer()
                            Text(Fmt.money(s.monthlyLimit, compact: true)).monospacedDigit()
                            Button("Add") { store.setBudget(s.category, s.monthlyLimit) }.buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("Suggested from your history")
                } footer: {
                    Text("Median of the last 3 complete months, rounded up to 50 SAR.")
                }
            }
            Section("Add budget") {
                Menu {
                    ForEach(Category.expenseCategories.filter { c in !status.contains { $0.category == c } }, id: \.self) { c in
                        Button(c.localizedName) { editing = c; value = "" }
                    }
                } label: { Label("Choose category", systemImage: "plus") }
            }
            Section {
                Text("Alerts at \(store.state.settings.budgetThresholds.map { "\($0)%" }.joined(separator: " · "))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Budgets")
        .alert("Monthly budget", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Amount (SAR)", text: $value).keyboardType(.decimalPad)
            Button("Save") { if let c = editing { store.setBudget(c, parseUserAmount(value)) }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        } message: {
            Text(editing?.localizedName ?? "")
        }
    }
}

struct SubscriptionsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let series = RecurringDetector(state: store.state).detect()
        List {
            Section {
                LabeledContent("Monthly cost", value: Fmt.money(RecurringDetector.monthlyCost(series)))
                LabeledContent("Yearly cost", value: Fmt.money(RecurringDetector.monthlyCost(series) * 12))
            }
            Section("Detected recurring payments") {
                ForEach(series) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(s.name, systemImage: s.category.symbol).font(.headline)
                            Spacer()
                            Text(Fmt.money(s.expectedAmount)).monospacedDigit()
                        }
                        HStack {
                            Text(s.cadence.arabicName)
                            Text("·")
                            Text("Next: \(Fmt.date(s.nextDate, time: false))")
                            Spacer()
                            Text("\(s.occurrences)×")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if s.confidence < 0.6 { Text("Low confidence").font(.caption2).foregroundStyle(.orange) }
                    }
                }
                if series.isEmpty {
                    Text("Recurring payments appear after 2–3 charges from the same merchant.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Subscriptions")
    }
}
