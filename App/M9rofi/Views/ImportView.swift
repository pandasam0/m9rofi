import SwiftUI
import UniformTypeIdentifiers
import FinanceCore

struct ImportView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var accountID: UUID?
    @State private var pendingURL: URL?
    @State private var preview: FileImportService.Preview?
    @State private var resultText: String?
    @State private var pasted = ""
    @State private var error: String?

    static let types: [UTType] = [.commaSeparatedText, .pdf, .plainText, .emailMessage, .text,
                                  UTType(filenameExtension: "xlsx") ?? .data, UTType(filenameExtension: "eml") ?? .data]

    var body: some View {
        Form {
            Section {
                Picker("Statement account", selection: $accountID) {
                    Text("Select").tag(UUID?.none)
                    ForEach(store.state.accounts.filter { !$0.isArchived }) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Button { showPicker = true } label: { Label("Choose file (CSV, Excel, PDF, .eml)", systemImage: "doc.badge.plus") }
            } header: { Text("Statement / receipt file") } footer: {
                Text("Overlapping statements are safe to import: already-recorded transactions are merged, not duplicated.")
            }

            if let p = preview {
                Section("Preview") {
                    LabeledContent("Transactions found", value: "\(p.records.count)")
                    if let m = p.result?.mapping {
                        Text("Columns: date \(m.date.map { "\($0 + 1)" } ?? "—"), description \(m.description.map { "\($0 + 1)" } ?? "—"), debit \(m.debit.map { "\($0 + 1)" } ?? "—"), credit \(m.credit.map { "\($0 + 1)" } ?? "—"), amount \(m.amount.map { "\($0 + 1)" } ?? "—")")
                            .font(.caption)
                    }
                    ForEach(p.messages, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    ForEach(Array(p.records.prefix(5).enumerated()), id: \.offset) { _, r in
                        HStack {
                            Text(r.merchant ?? r.counterparty ?? r.note ?? "—").lineLimit(1)
                            Spacer()
                            Text("\(r.direction == .credit ? "+" : "−")\(r.amount.map { "\($0)" } ?? "?")").monospacedDigit()
                        }
                        .font(.caption)
                    }
                    Button("Import \(p.records.count) transactions") {
                        let r = store.ingest(records: p.records, closingBalance: p.result?.closingBalance, accountID: accountID)
                        resultText = summary(r)
                        preview = nil
                    }
                    .disabled(p.records.isEmpty)
                }
            }

            Section {
                TextEditor(text: $pasted).frame(minHeight: 120)
                Button("Process messages") {
                    var total = IngestReport()
                    for block in pasted.components(separatedBy: "\n\n") where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let r = store.ingestMessage(block, sender: nil)
                        total.added += r.added; total.merged += r.merged; total.exactDuplicates += r.exactDuplicates
                        total.flaggedForReview += r.flaggedForReview; total.ignored += r.ignored
                    }
                    resultText = summary(total)
                    pasted = ""
                }
                .disabled(pasted.isEmpty)
            } header: { Text("Paste bank messages") } footer: {
                Text("Separate messages with an empty line. OTP, declined and promotional messages are ignored.")
            }

            if let resultText { Section("Result") { Text(resultText) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Import")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: Self.types, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): pendingURL = urls.first; loadPreview()
            case .failure(let e): error = e.localizedDescription
            }
        }
        .onChange(of: accountID) { if pendingURL != nil { loadPreview() } }
    }

    func loadPreview() {
        guard let url = pendingURL else { return }
        do {
            preview = try FileImportService.preview(url: url, accountID: accountID, settings: store.state.settings, templates: store.state.smsTemplates)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func summary(_ r: IngestReport) -> String {
        Fmt.isArabic
            ? "أضيفت \(r.added.count) · دُمجت \(r.merged.count) · مكررة \(r.exactDuplicates) · للمراجعة \(r.flaggedForReview.count) · تحويلات داخلية \(r.internalTransfersMatched) · متجاهلة \(r.ignored)"
            : "Added \(r.added.count) · merged \(r.merged.count) · duplicates \(r.exactDuplicates) · review \(r.flaggedForReview.count) · internal \(r.internalTransfersMatched) · ignored \(r.ignored)"
    }
}
