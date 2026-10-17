import AppKit
import Security
import SwiftUI
import XTermXKit

/// Only the salted verifier and expiry are kept. The typed password stays in the settings form.
enum PairingPasswordKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "XTermX.pairing",
         kSecAttrAccount as String: "password-verifier"]
    }
    static func load() throws -> PairingPasswordRecord? {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return try JSONDecoder().decode(PairingPasswordRecord.self, from: data)
    }
    static func save(_ record: PairingPasswordRecord?) throws {
        guard let record else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            return
        }
        let values = [kSecValueData as String: try JSONEncoder().encode(record)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var q = query.merging(values) { _, new in new }
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

struct PairingPasswordSettings: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var reveal = false
    @State private var lifetime = PairingPasswordLifetime.hour
    @State private var error: String?

    var body: some View {
        SettingsCard("Pair with a password", "Use a Mac address and a temporary password when scanning is inconvenient.") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let record = model.server.passwordPairing.record, record.isActive(at: context.date) {
                    HStack {
                        if let expires = record.expiresAt { Text("Available until \(expires.formatted(date: .abbreviated, time: .shortened))") }
                        else { Text("Available until you turn it off") }
                        Spacer()
                        Button("Turn off password", role: .destructive) { configure(nil) }
                    }
                } else { Text("Password pairing is off") }
            }
            HStack {
                Group {
                    if reveal { TextField("New pairing password", text: $password) }
                    else { SecureField("New pairing password", text: $password) }
                }
                Button("Generate password") { password = PasswordPairingGate.generatePassword(); reveal = true }
            }
            Toggle("Show new password", isOn: $reveal)
            Picker("Password lifetime", selection: $lifetime) {
                ForEach(PairingPasswordLifetime.allCases) { value in Text(LocalizedStringKey(value.title)).tag(value) }
            }
            HStack {
                Button("Use this password") {
                    do { configure(try PasswordPairingGate.makeRecord(password: password, lifetime: lifetime)) }
                    catch { self.error = error.localizedDescription }
                }.disabled(!(6...128).contains(password.count))
                if !password.isEmpty {
                    Button("Copy new password") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(password, forType: .string)
                    }
                }
            }
            Text("Copy the new password before leaving this page; it is not stored.").font(.caption)
            Text("At least 6 characters; a generated password is harder to guess. Expiry stops new pairing attempts. Devices already paired keep access until you forget them.")
                .font(.caption)
            Text("On iPhone choose Pair with a password. Use an address from Advanced and Watch port \(model.server.httpPort).")
                .font(.caption)
            if let error = error ?? model.pairingPasswordError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onDisappear { password = ""; reveal = false }
    }

    private func configure(_ record: PairingPasswordRecord?) {
        do {
            try PairingPasswordKeychain.save(record)
            model.server.passwordPairing.record = record
            if record == nil { password = "" }
            error = nil; model.pairingPasswordError = nil
        } catch { self.error = "The pairing password could not be saved in Keychain. Try again." }
    }
}
