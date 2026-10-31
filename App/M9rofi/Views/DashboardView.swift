import SwiftUI
import Charts
import FinanceCore

struct DashboardView: View {
    @Environment(AppStore.self) private var store
    @State private var showAdd = false
    @State private var showImport = false

    var body: some View {
        let now = Date()
        let d = store.aggregator.dashboard(now: now)
        let recurring = RecurringDetector(state: store.state).detect(now: now)
        ScrollView {
            VStack(spacing: 14) {
                if d.reviewCount > 0 {
                    NavigationLink { ReviewView() } label: {
                        Label("\(d.reviewCount) transactions need review", systemImage: "exclamationmark.triangle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(.orange.opacity(0.15), in: .rect(cornerRadius: 12))
                            .foregroundStyle(.orange)
                    }
                }

                // Hero: month spending
                VStack(alignment: .leading, spacing: 6) {
                    Text("This month's spending").font(.subheadline).foregroundStyle(.secondary)
                    Text(Fmt.money(d.month.spending)).font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                    if let r = d.monthChangeRatio {
                        Label("\(r >= 0 ? "+" : "")\(Fmt.percent(r)) vs same period last month",
                              systemImage: r >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption).foregroundStyle(r > 0 ? .red : .green)
                    }
                    if d.month.pendingAmount > 0 || d.month.unconfirmedAmount > 0 {
                        Text("Not included: pending \(Fmt.money(d.month.pendingAmount)) · under review \(Fmt.money(d.month.unconfirmedAmount))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).background(.tint.opacity(0.08), in: .rect(cornerRadius: 18))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    StatCard(title: "Today", value: Fmt.money(d.today.spending))
                    StatCard(title: "This week", value: Fmt.money(d.week.spending))
                    StatCard(title: "This year", value: Fmt.money(d.year.spending))
                    StatCard(title: "Income (month)", value: Fmt.money(d.month.income), tint: .green)
                    StatCard(title: "Net cash flow", value: Fmt.money(d.month.netCashFlow), tint: d.month.netCashFlow >= 0 ? .green : .red)
                    StatCard(title: "Total balance", value: Fmt.money(d.totalBalance),
                             subtitle: d.balances.contains { $0.1 == nil } ? String(localized: "Some accounts have no balance") : nil)
                    StatCard(title: "Transactions (month)", value: "\(d.month.transactionCount)")
                    StatCard(title: "Daily average", value: Fmt.money(d.month.dailyAverage))
                    StatCard(title: "Top category", value: d.month.topCategory?.category.localizedName ?? "—",
                             subtitle: d.month.topCategory.map { Fmt.money($0.amount) })
                    StatCard(title: "Last month (to date)", value: Fmt.money(d.previousMonthToDate.spending))
                }

                if !d.month.byCategory.isEmpty {
                    GroupBox("Spending by category") {
                        Chart(d.month.byCategory.filter { $0.amount > 0 }) { c in
                            SectorMark(angle: .value("Amount", c.amount.doubleValue), innerRadius: .ratio(0.6), angularInset: 1.5)
                                .foregroundStyle(c.category.color)
                        }
                        .frame(height: 180)
                        ForEach(d.month.byCategory.prefix(6)) { c in
                            HStack {
                                Circle().fill(c.category.color).frame(width: 8, height: 8)
                                Text(c.category.localizedName).font(.subheadline)
                                Spacer()
                                Text(Fmt.money(c.amount)).font(.subheadline.monospacedDigit())
                            }
                        }
                    }
                }

                let budgets = BudgetEngine(state: store.state).status(now: now)
                if !budgets.isEmpty {
                    GroupBox("Budgets") {
                        ForEach(budgets.prefix(4)) { b in BudgetRow(status: b) }
                        NavigationLink("All budgets") { BudgetsView() }.font(.footnote)
                    }
                }

                if let next = recurring.first {
                    GroupBox("Next recurring charge") {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(next.name).font(.headline)
                                Text(Fmt.date(next.nextDate, time: false)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Fmt.money(next.expectedAmount)).monospacedDigit()
                        }
                        NavigationLink("All subscriptions") { SubscriptionsView() }.font(.footnote)
                    }
                }

                GroupBox("Accounts") {
                    ForEach(d.balances, id: \.0.id) { pair in
                        HStack {
                            Text(pair.0.name)
                            Spacer()
                            if let b = pair.1 {
                                VStack(alignment: .trailing) {
                                    Text(Fmt.money(b.balance)).monospacedDigit()
                                    Text(b.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("—").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if d.balances.isEmpty { NavigationLink("Add your accounts") { AccountsView() } }
                }
            }
            .padding()
        }
        .navigationTitle("M9rofi")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showImport = true } label: { Image(systemName: "square.and.arrow.down") }
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { AddTransactionView() }
        .sheet(isPresented: $showImport) { NavigationStack { ImportView() } }
    }
}

struct BudgetRow: View {
    let status: BudgetStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(status.category.localizedName, systemImage: status.category.symbol).font(.subheadline)
                Spacer()
                Text("\(Fmt.money(status.spent, compact: true)) / \(Fmt.money(status.limit, compact: true))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: min(status.ratio, 1))
                .tint(status.ratio >= 1 ? .red : status.ratio >= 0.9 ? .orange : status.ratio >= 0.75 ? .yellow : .green)
            Text(status.remaining >= 0 ? "Remaining \(Fmt.money(status.remaining))" : "Over by \(Fmt.money(-status.remaining))")
                .font(.caption2).foregroundStyle(status.remaining >= 0 ? Color.secondary : Color.red)
        }
        .padding(.vertical, 4)
    }
}
