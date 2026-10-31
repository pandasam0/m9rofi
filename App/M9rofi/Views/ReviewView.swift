import SwiftUI
import FinanceCore

/// Uncertain transactions. None of these are included in totals until resolved.
struct ReviewView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let queue = store.ledger.reviewQueue
        List {
            Section {
                Text("These transactions are NOT included in your totals until you confirm them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(queue) { tx in
                NavigationLink { ReviewDetailView(id: tx.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        TransactionRow(tx: tx, effect: store.aggregator.effect(of: tx))
                        Text(tx.reviewReasons.map(\.arabicDescription).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if queue.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal")
            }
        }
        .navigationTitle("Review")
    }
}

struct ReviewDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var amount = ""
    @State private var baseAmount = ""
    @State private var direction: Direction = .debit

    var body: some View {
        if let tx = store.state.transactions.first(where: { $0.id == id }) {
            Form {
                Section("Issue") {
                    ForEach(tx.reviewReasons, id: \.self) { Label($0.arabicDescription, systemImage: "exclamationmark.triangle") }
                }
                Section("Transaction") {
                    TransactionRow(tx: tx, effect: store.aggregator.effect(of: tx))
                    if let n = tx.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                    ForEach(tx.sources, id: \.recordID) { Text($0.type.label).font(.caption) }
                }

                if tx.reviewReasons.contains(.possibleDuplicate), let other = store.state.transactions.first(where: { $0.id == tx.linkedTransactionID }) {
                    Section("Possible duplicate of") {
                        TransactionRow(tx: other, effect: store.aggregator.effect(of: other))
                        Button("Same transaction — merge") { store.resolve(id, .mergeInto(other.id)); dismiss() }
                        Button("Different transaction — count it") { store.resolve(id, .confirm()); dismiss() }
                    }
                }

                if tx.reviewReasons.contains(.missingAmount) || tx.reviewReasons.contains(.missingBaseCurrencyAmount)
                    || tx.reviewReasons.contains(.unknownDirection) || tx.reviewReasons.contains(.lowParseConfidence) {
                    Section("Complete the details") {
                        if tx.reviewReasons.contains(.missingAmount) {
                            TextField("Amount", text: $amount).keyboardType(.decimalPad)
                        }
                        if tx.currency != "SAR" {
                            TextField("Charged amount in SAR (from bank statement)", text: $baseAmount).keyboardType(.decimalPad)
                        }
                        Picker("Direction", selection: $direction) {
                            Text("Debit (money out)").tag(Direction.debit)
                            Text("Credit (money in)").tag(Direction.credit)
                        }
                        Button("Confirm") {
                            store.resolve(id, .confirm(amount: parseUserAmount(amount), baseAmount: parseUserAmount(baseAmount), direction: direction))
                            if store.state.transactions.first(where: { $0.id == id })?.needsReview == false { dismiss() }
                        }
                    }
                }

                if tx.reviewReasons.contains(.possibleInternalTransfer) {
                    Section("Is this a transfer to your own account?") {
                        Button("Yes — internal transfer (not spending)") { store.resolve(id, .markInternal); dismiss() }
                        Button("No — payment to someone else") { store.resolve(id, .confirm()); dismiss() }
                    }
                }

                if tx.reviewReasons.contains(.cardPaymentUntrackedCard) {
                    Section("Credit card payment") {
                        Text("If you add the credit card as an account and import its purchases, this payment is not spending. If the card is not tracked, the payment itself represents the spending.")
                            .font(.footnote)
                        Button("Card is tracked — not spending") { store.resolve(id, .markInternal); dismiss() }
                        Button("Count the payment as spending") { store.resolve(id, .countCardPaymentAsExpense); dismiss() }
                    }
                }

                if tx.reviewReasons.contains(.unmatchedReversal) {
                    Section("Reversal") {
                        Text("The original transaction was not found. Keeping this excluded is safe: the reversal and the original cancel each other.")
                            .font(.footnote)
                        Button("Keep excluded") {
                            var t = tx; t.reviewReasons = []; t.userExcluded = true; store.update(t); dismiss()
                        }
                    }
                }

                Section {
                    Button("Not a real transaction — delete", role: .destructive) { store.resolve(id, .delete); dismiss() }
                }
            }
            .navigationTitle("Review")
            .onAppear {
                direction = tx.direction
                if tx.amount > 0 { amount = "\(tx.amount)" }
            }
        } else {
            ContentUnavailableView("Resolved", systemImage: "checkmark")
        }
    }
}
