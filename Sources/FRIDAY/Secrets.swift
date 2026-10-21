import Foundation
import Security

/// API tokens for evolved abilities (GitHub, Linear, ...). Stored in the Keychain, asked for with a native hidden-input
/// dialog (which also works when running as `FRIDAY --mcp`). Never hard-code a secret.
enum Secrets {
    private static let service = "com.friday.app.secrets"

    static func get(_ name: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ name: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// The stored secret, or a native secure prompt (answer is saved). Returns nil if the user cancels.
    static func ask(_ name: String, why: String) -> String? {
        if let s = get(name) { return s }
        func lit(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let script = "tell current application\nactivate\ndisplay dialog \(lit(why)) default answer \"\" with hidden answer with title \"F.R.I.D.A.Y\" buttons {\"Cancel\", \"Save\"} default button \"Save\" cancel button \"Cancel\" giving up after 180\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0, !text.contains("gave up:true"), let r = text.range(of: "text returned:") else { return nil }
        let value = text[r.upperBound...].components(separatedBy: ", gave up").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        set(name, value)
        return value
    }
}
