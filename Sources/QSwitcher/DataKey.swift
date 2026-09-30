import Foundation
import CryptoKit
import Security

/// Ключ данных QSwitcher — личный слой (personal.qsp) и секреты синхронизации (sync-secrets.qsp).
///
/// Свой элемент связки ключей, созданный самим QSwitcher: доступ к нему привязан к подписи
/// приложения («QSwitcher Self-Signed»), поэтому новые сборки с той же подписью разрешения не
/// спрашивают. Ключ защищённого лога (SecureLogCrypto) создавала ещё AutoSwitcher — к нему
/// связка просит разрешение, а пересоздавать его нельзя: старые логи перестанут читаться.
///
/// Нет элемента — создаётся; любая другая ошибка связки — ошибка (ключ НЕ пересоздаётся: иначе
/// всё, что им зашифровано, пропало бы).
enum DataKey {
    private static let service = "local.QSwitcher.data"
    private static let account = "aes-256-v1"
    private static let lock = NSLock()
    private static var cached: SymmetricKey?

    enum Failure: Error, CustomStringConvertible {
        case keychain(OSStatus)
        var description: String {
            switch self {
            case .keychain(let st):
                let msg = SecCopyErrorMessageString(st, nil) as String? ?? ""
                return "связка ключей: \(st) \(msg)"
            }
        }
    }

    static func key() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let k = cached { return k }
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let st = SecItemCopyMatching(query as CFDictionary, &result)
        if st == errSecSuccess, let d = result as? Data, d.count == 32 {
            let k = SymmetricKey(data: d)
            cached = k
            return k
        }
        guard st == errSecItemNotFound else { throw Failure.keychain(st) }
        let k = SymmetricKey(size: .bits256)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "QSwitcher — ключ данных",
            kSecValueData as String: k.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.keychain(added) }
        cached = k
        return k
    }

    /// AES-256-GCM: nonce | шифротекст | тег.
    static func seal(_ plain: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key()).combined else { throw Failure.keychain(errSecParam) }
        return combined
    }

    static func open(_ box: Data) throws -> Data {
        let k = try key()
        return try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: k)
    }
}
