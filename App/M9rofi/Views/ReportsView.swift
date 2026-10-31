import SwiftUI
import Charts
import FinanceCore

struct ReportsView: View {
    @Environment(AppStore.self) private var store
    @State private var period: Aggregator.Period = .month
    @State private var anchor = Date()
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        let report = Report.build(state: store.state, period: period, containing: anchor)
        let s = report.summary
        let agg = store.aggregator
        ScrollView {
            VStack(spacing: 14) {
                Picker("Period", selection: $period) {
                    Text("Day").tag(Aggregator.Period.day)
                    Text("Week").tag(Aggregator.Period.week)
                    Text("Month").tag(Aggregator.Period.month)
                    Text("Year").tag(Aggregator.Period.year)
                }
                .pickerStyle(.segmented)

                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.backward") }
                    Spacer()
                    Text("\(report.interval.start.formatted(date: .abbreviated, time: .omitted)) – \(report.interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))")
                        .font(.subheadline)
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.forward") }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    StatCard(title: "Spending", value: Fmt.money(s.spending))
                    StatCard(title: "Income", value: Fmt.money(s.income), tint: .green)
                    StatCard(title: "Net cash flow", value: Fmt.money(s.netCashFlow), tint: s.netCashFlow >= 0 ? .green : .red)
                    StatCard(title: "Refunds", value: Fmt.money(s.refunds))
                    StatCard(title: "Fixed", value: Fmt.money(report.fixed))
                    StatCard(title: "Variable", value: Fmt.money(report.variable))
                }

                if !s.byCategory.isEmpty {
                    GroupBox("Distribution") {
                        Chart(s.byCategory.filter { $0.amount > 0 }) { c in
                            BarMark(x: .value("Amount", c.amount.doubleValue), y: .value("Category", c.category.localizedName))
                                .foregroundStyle(c.category.color)
                                .annotation(position: .trailing) { Text(Fmt.money(c.amount, compact: true)).font(.caption2) }
                        }
                        .chartLegend(.hidden)
                        .frame(height: CGFloat(max(120, s.byCategory.count * 30)))
                    }
                }

                if period == .month || period == .week {
                    GroupBox("Daily spending") {
                        let series = agg.dailySeries(report.interval)
                        Chart(series, id: \.0) { item in
                            BarMark(x: .value("Day", item.0, unit: .day), y: .value("Amount", item.1.doubleValue))
                        }
                        .frame(height: 160)
                    }
                }

                GroupBox("Income vs spending (12 months)") {
                    let months = agg.monthlySeries(months: 12)
                    Chart {
                        ForEach(months, id: \.interval.start) { m in
                            BarMark(x: .value("Month", m.interval.start, unit: .month), y: .value("Spending", m.spending.doubleValue))
                                .foregroundStyle(by: .value("Type", String(localized: "Spending")))
                                .position(by: .value("Type", String(localized: "Spending")))
                            BarMark(x: .value("Month", m.interval.start, unit: .month), y: .value("Income", m.income.doubleValue))
                                .foregroundStyle(by: .value("Type", String(localized: "Income")))
                                .position(by: .value("Type", String(localized: "Income")))
                        }
                    }
                    .frame(height: 200)
                }

                if !s.byMerchant.isEmpty {
                    GroupBox("Top merchants") {
                        ForEach(s.byMerchant.prefix(10)) { m in
                            HStack {
                                Text(m.name).lineLimit(1)
                                Spacer()
                                Text("\(m.count)×").font(.caption).foregroundStyle(.secondary)
                                Text(Fmt.money(m.amount)).monospacedDigit()
                            }
                        }
                    }
                }

                HStack {
                    Button { export(report, pdf: true) } label: { Label("PDF", systemImage: "doc.richtext") }
                    Button { export(report, pdf: false) } label: { Label("Excel", systemImage: "tablecells") }
                }
                .buttonStyle(.borderedProminent)
                if let url = exportURL {
                    ShareLink(item: url) { Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
                if let e = exportError { Text(e).foregroundStyle(.red).font(.footnote) }
            }
            .padding()
        }
        .navigationTitle("Reports")
        .onChange(of: period) { exportURL = nil }
    }

    func shift(_ n: Int) {
        let comp: Calendar.Component = switch period { case .day: .day; case .week: .weekOfYear; case .month: .month; case .year: .year }
        anchor = store.state.settings.calendar.date(byAdding: comp, value: n, to: anchor) ?? anchor
        exportURL = nil
    }

    func export(_ r: Report, pdf: Bool) {
        do {
            let tz = store.state.settings.timeZone
            let stamp = DateFormatting.shortDate(r.interval.start, tz: tz)
            let dir = FileManager.default.temporaryDirectory
            if pdf {
                exportURL = try ReportPDFRenderer.render(r, accounts: store.state.accounts, to: dir.appendingPathComponent("m9rofi-\(stamp).pdf"))
            } else {
                let url = dir.appendingPathComponent("m9rofi-\(stamp).xls")
                try ReportExporter.excel(r, accounts: store.state.accounts, tz: tz).write(to: url, options: .completeFileProtection)
                exportURL = url
            }
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// Renders a printable A4-width report with SwiftUI → PDF.
@MainActor
enum ReportPDFRenderer {
    static func render(_ r: Report, accounts: [Account], to url: URL) throws -> URL {
        let view = ReportPrintView(report: r).frame(width: 595).environment(\.layoutDirection, Fmt.isArabic ? .rightToLeft : .leftToRight)
        let renderer = ImageRenderer(content: view)
        var thrown: Error?
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { thrown = CocoaError(.fileWriteUnknown); return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        if let thrown { throw thrown }
        return url
    }
}

struct ReportPrintView: View {
    let report: Report

    var body: some View {
        let s = report.summary
        VStack(alignment: .leading, spacing: 10) {
            Text(report.title).font(.title.bold())
            Text("\(report.interval.start.formatted(date: .long, time: .omitted)) – \(report.interval.end.addingTimeInterval(-1).formatted(date: .long, time: .omitted))")
                .foregroundStyle(.secondary)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                row("Spending", s.spending)
                row("Refunds", s.refunds)
                row("Income", s.income)
                row("Incoming transfers", s.incomingTransfers)
                row("Net cash flow", s.netCashFlow)
                row("Cash withdrawals", s.cashWithdrawals)
                row("Fixed", report.fixed)
                row("Variable", report.variable)
                row("Daily average", s.dailyAverage)
                row("Pending (not counted)", s.pendingAmount)
                row("Under review (not counted)", s.unconfirmedAmount)
            }
            Divider()
            Text("By category").font(.headline)
            ForEach(s.byCategory) { c in
                HStack { Text(c.category.localizedName); Spacer(); Text("\(c.count)"); Text(Fmt.money(c.amount)).monospacedDigit() }
            }
            if !report.budgets.isEmpty {
                Divider()
                Text("Budgets").font(.headline)
                ForEach(report.budgets) { b in
                    HStack { Text(b.category.localizedName); Spacer(); Text("\(Fmt.money(b.spent)) / \(Fmt.money(b.limit))") }
                }
            }
            Divider()
            Text("Top merchants").font(.headline)
            ForEach(s.byMerchant.prefix(15)) { m in
                HStack { Text(m.name); Spacer(); Text(Fmt.money(m.amount)).monospacedDigit() }
            }
            Divider()
            Text("Transactions").font(.headline)
            ForEach(report.transactions) { t in
                HStack {
                    Text(Fmt.date(t.date, time: t.hasTime)).frame(width: 110, alignment: .leading)
                    Text(t.displayName).lineLimit(1)
                    Spacer()
                    Text((t.direction == .debit ? "−" : "+") + Fmt.money(t.baseAmount ?? t.amount)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(32)
        .background(.white)
        .foregroundStyle(.black)
    }

    @ViewBuilder
    func row(_ title: LocalizedStringKey, _ v: Decimal) -> some View {
        GridRow { Text(title); Text(Fmt.money(v)).monospacedDigit() }
    }
}
