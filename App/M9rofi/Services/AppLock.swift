import Foundation
import LocalAuthentication
import Observation

/// Face ID / passcode gate. Locks whenever the app leaves the foreground.
@MainActor
@Observable
final class AppLock {
    var isUnlocked = false
    var errorMessage: String?

    func lock() { isUnlocked = false }

    func unlock(required: Bool) async {
        guard required else { isUnlocked = true; return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = String(localized: "Use Passcode")
        var err: NSError?
        // .deviceOwnerAuthentication falls back to the device passcode if Face ID fails.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            errorMessage = err?.localizedDescription
            isUnlocked = false
            return
        }
        do {
            isUnlocked = try await ctx.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: String(localized: "Unlock your financial data"))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            isUnlocked = false
        }
    }
}
