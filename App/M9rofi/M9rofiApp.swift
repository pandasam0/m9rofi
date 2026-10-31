import SwiftUI
import FinanceCore

@main
struct M9rofiApp: App {
    @State private var store = AppStore.shared
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(store)
                    .blur(radius: lock.isUnlocked && scenePhase == .active ? 0 : 20)
                    .disabled(!lock.isUnlocked)
                if !lock.isUnlocked || scenePhase != .active {
                    LockView(lock: lock, required: store.state.settings.faceIDEnabled)
                }
            }
            .task {
                await lock.unlock(required: store.state.settings.faceIDEnabled)
                await NotificationService.shared.requestAuthorization()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: lock.lock()
                case .active where !lock.isUnlocked:
                    Task { await lock.unlock(required: store.state.settings.faceIDEnabled) }
                default: break
                }
            }
        }
    }
}

struct LockView: View {
    let lock: AppLock
    let required: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(.tint)
            Text("M9rofi").font(.title.bold())
            if let e = lock.errorMessage { Text(e).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if !lock.isUnlocked {
                Button {
                    Task { await lock.unlock(required: required) }
                } label: {
                    Label("Unlock", systemImage: "faceid").frame(maxWidth: 220)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial)
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        TabView {
            NavigationStack { DashboardView() }
                .tabItem { Label("Dashboard", systemImage: "chart.pie.fill") }
            NavigationStack { TransactionsView() }
                .tabItem { Label("Transactions", systemImage: "list.bullet.rectangle") }
                .badge(store.state.transactions.filter(\.needsReview).count)
            NavigationStack { AssistantView() }
                .tabItem { Label("Assistant", systemImage: "sparkles") }
            NavigationStack { ReportsView() }
                .tabItem { Label("Reports", systemImage: "chart.bar.xaxis") }
            NavigationStack { MoreView() }
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .overlay(alignment: .top) {
            if let e = store.loadError {
                Text(e).font(.footnote).padding(8).background(.red.opacity(0.9), in: .rect(cornerRadius: 8)).foregroundStyle(.white).padding()
            }
        }
    }
}
