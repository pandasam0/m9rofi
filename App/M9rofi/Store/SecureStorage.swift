import Foundation
import CryptoKit
import Security
import FinanceCore

/// Keychain wrapper. Items are device-only (never synced, never in backups) and readable after the first
/// unlock so Shortcuts automations can log transactions while the phone is locked.
enum Keychain {
    static let service = "com.personal.m9rofi"

    static func read(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    static func deleteAll() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
    }
}

/// AES-256-GCM encrypted ledger file. Key lives only in the Keychain; the file additionally uses iOS
/// Data Protection. No network access anywhere in this type.
struct EncryptedLedgerStore {
    static let keyAccount = "ledger.key.v1"
    let url: URL

    init() {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ledger", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        // Exclude from iCloud/iTunes backups: the key is device-only, so a backup could not be decrypted anyway.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        url = dir.appendingPathComponent("ledger.bin")
    }

    private func key() throws -> SymmetricKey {
        if let data = Keychain.read(Self.keyAccount) { return SymmetricKey(data: data) }
        let k = SymmetricKey(size: .bits256)
        let data = k.withUnsafeBytes { Data($0) }
        guard Keychain.write(data, account: Self.keyAccount) else { throw StoreError.keychain }
        return k
    }

    enum StoreError: Error { case keychain, corrupted }

    func load() throws -> LedgerState {
        guard FileManager.default.fileExists(atPath: url.path) else { return LedgerState() }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let plain = try AES.GCM.open(sealed, using: key())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(LedgerState.self, from: plain)
    }

    func save(_ state: LedgerState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let plain = try encoder.encode(state)
        guard let combined = try AES.GCM.seal(plain, using: key()).combined else { throw StoreError.corrupted }
        try combined.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func destroy() {
        try? FileManager.default.removeItem(at: url)
        Keychain.deleteAll()
    }
}
