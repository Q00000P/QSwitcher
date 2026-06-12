import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// Криптография для логов на базе симметричного ключа в Keychain.
///
/// Почему не «чистый» Secure Enclave persistent key: он требует entitlement
/// keychain-access-groups, который с ad-hoc подписью (без платного Apple Developer
/// аккаунта) ломает запуск приложения (SIGKILL). Поэтому используем обычный Keychain.
///
/// Схема:
///   1. При первом запуске генерится случайный 256-битный ключ (SymmetricKey).
///   2. Ключ хранится в Keychain с атрибутами:
///        - kSecAttrAccessibleWhenUnlockedThisDeviceOnly — доступен только когда
///          мак разблокирован, НЕ мигрирует на другие устройства, НЕ уходит в iCloud.
///   3. Контент шифруется AES-256-GCM этим ключом.
///
/// Стойкость:
///   - Сам Keychain зашифрован системным ключом, защищённым Secure Enclave чипа.
///     То есть ключ всё равно в итоге под защитой Enclave — просто на уровне системы.
///   - Привязка к устройству: украли диск/мак — Keychain недоступен на другой машине.
///   - Доступ только в разблокированной сессии владельца.
///   - Стёрли мак / переустановили систему — ключ пропал, логи нечитаемы навсегда.
///
/// Для модели угроз «кража диска/мака» + «чужой за разблокированным маком (защита
/// блокировкой экрана)» это эквивалентно чистому Enclave, но работает с ad-hoc подписью.
enum SecureLogCrypto {

    private static let keychainAccount = "securelog-master-key"
    private static let keychainService = "local.AutoSwitcher.securelog"

    enum CryptoError: Error {
        case keyGenerationFailed(OSStatus)
        case keyLoadFailed(OSStatus)
        case encryptionFailed(String)
        case decryptionFailed(String)
    }

    static var isAvailable: Bool { true }  // Keychain есть всегда

    // MARK: - Key lifecycle

    /// Получить (или создать) мастер-ключ из Keychain.
    private static func masterKey() throws -> SymmetricKey {
        if let existing = try? loadKey() {
            return existing
        }
        return try createKey()
    }

    private static func loadKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw CryptoError.keyLoadFailed(status)
        }
        return SymmetricKey(data: data)
    }

    private static func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        // Удаляем старый если был (на случай частичного состояния)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: keyData,
            // Доступен только при разблокированном устройстве, не мигрирует
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CryptoError.keyGenerationFailed(status)
        }
        return key
    }

    // MARK: - Encrypt / Decrypt

    /// Зашифровать блок. Возвращает self-contained blob (nonce+ciphertext+tag).
    static func encrypt(_ plaintext: Data) throws -> Data {
        let key = try masterKey()
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else {
                throw CryptoError.encryptionFailed("combined nil")
            }
            return combined
        } catch let e as CryptoError {
            throw e
        } catch {
            throw CryptoError.encryptionFailed(error.localizedDescription)
        }
    }

    /// Расшифровать блок.
    static func decrypt(_ ciphertext: Data) throws -> Data {
        let key = try masterKey()
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key)
        } catch let e as CryptoError {
            throw e
        } catch {
            throw CryptoError.decryptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Touch ID gate

    /// Запросить Touch ID / пароль для защищённого действия.
    static func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Ввести пароль"
        var authError: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard ctx.canEvaluatePolicy(policy, error: &authError) else {
            // Если биометрия/пароль совсем недоступны — не блокируем намертво
            DispatchQueue.main.async { completion(true) }
            return
        }
        ctx.evaluatePolicy(policy, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }
}
