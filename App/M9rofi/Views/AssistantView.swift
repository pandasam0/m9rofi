import SwiftUI
import FinanceCore

struct AssistantView: View {
    @Environment(AppStore.self) private var store
    @State private var input = ""
    @State private var messages: [Message] = []
    @State private var busy = false

    struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
        var caveats: [String] = []
        var transactionIDs: [UUID] = []
    }

    static let examples = ["كم صرفت اليوم؟", "كم صرفت على القهوة هذا الشهر؟", "كم صرفت في المطاعم؟", "كم دفعت على الاشتراكات؟",
                           "ما أكثر شيء استنزف أموالي؟", "كم صرفت في آخر 7 أيام؟", "كم صرفت على السفر خلال السنة؟",
                           "أين يمكنني تقليل مصاريفي؟", "كم يتبقى لي من راتبي؟", "كم يمكنني توفيره شهرياً؟"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            Text("Answers are computed only from your recorded transactions.")
                                .font(.footnote).foregroundStyle(.secondary)
                            FlowExamples(examples: Self.examples) { ask($0) }
                        }
                        ForEach(messages) { m in
                            bubble(m).id(m.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            Divider()
            HStack {
                TextField("Ask about your money…", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { ask(input) }
                Button { ask(input) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            .padding()
        }
        .navigationTitle("Assistant")
        .toolbar {
            if AIAssistant.onDeviceModelAvailable {
                ToolbarItem { Image(systemName: "apple.intelligence").help("On-device model available") }
            }
        }
    }

    @ViewBuilder
    func bubble(_ m: Message) -> some View {
        VStack(alignment: m.fromUser ? .trailing : .leading, spacing: 4) {
            Text(m.text)
                .padding(10)
                .background(m.fromUser ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.background.secondary), in: .rect(cornerRadius: 12))
            ForEach(m.caveats, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if !m.transactionIDs.isEmpty {
                NavigationLink("Show \(m.transactionIDs.count) transactions") { TransactionListByIDs(ids: m.transactionIDs) }
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: m.fromUser ? .trailing : .leading)
    }

    func ask(_ q: String) {
        let question = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        messages.append(Message(fromUser: true, text: question))
        input = ""
        busy = true
        Task {
            let a = await AIAssistant.answer(question, state: store.state)
            messages.append(Message(fromUser: false, text: a.text, caveats: a.caveats, transactionIDs: a.transactionIDs))
            busy = false
        }
    }
}

struct FlowExamples: View {
    let examples: [String]
    let action: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(examples, id: \.self) { e in
                Button(e) { action(e) }.buttonStyle(.bordered).font(.callout)
            }
        }
    }
}

struct TransactionListByIDs: View {
    @Environment(AppStore.self) private var store
    let ids: [UUID]
    var body: some View {
        let set = Set(ids)
        List(store.state.transactions.filter { set.contains($0.id) }.sorted { $0.date > $1.date }) { tx in
            NavigationLink { TransactionDetailView(id: tx.id) } label: { TransactionRow(tx: tx, effect: store.aggregator.effect(of: tx)) }
        }
        .navigationTitle("Transactions")
    }
}
