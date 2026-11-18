import Foundation
import Security

/// How the "Editar com IA" transport reaches a model. `manual` is the default:
/// nothing leaves the device and the user copies/pastes between the app and
/// their chat of choice (cards 1 and 2 of AIEditSection).
enum AIProviderKind: String, Codable, CaseIterable {
    /// Copiar/colar — the original offline flow.
    case manual
    /// Serviço compatível com a API de chat do OpenAI (OpenAI, OpenRouter, …).
    case api
    /// Apple Intelligence on-device (iOS 26+, when the SDK/framework exists).
    case appleIntelligence
}

/// Non-secret provider preferences, persisted as JSON in UserDefaults.
/// The API key is NEVER stored here — it lives in the Keychain (ClipKeychain).
struct AIProviderSettings: Codable {
    var kind: AIProviderKind
    var baseURL: String
    var model: String

    init(
        kind: AIProviderKind = .manual,
        baseURL: String = AIProviderSettings.defaultBaseURL,
        model: String = AIProviderSettings.defaultModel
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
    }

    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "gpt-4o-mini"

    private enum CodingKeys: String, CodingKey {
        case kind, baseURL, model
    }

    /// Tolerant decoding: missing keys fall back to defaults so older/broken
    /// payloads never wipe the user's preferences.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(AIProviderKind.self, forKey: .kind) ?? .manual
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
            ?? AIProviderSettings.defaultBaseURL
        model = try container.decodeIfPresent(String.self, forKey: .model)
            ?? AIProviderSettings.defaultModel
    }
}

/// Reads/writes AIProviderSettings under one UserDefaults key.
enum AISettingsStore {
    private static let key = "clipstudio.aiProvider"
    /// Keychain account holding the OpenAI-compatible API key.
    static let apiKeyAccount = "openaiCompat.apiKey"

    static func load() -> AIProviderSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AIProviderSettings.self, from: data) else {
            return AIProviderSettings()
        }
        return settings
    }

    static func save(_ settings: AIProviderSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - API key convenience (Keychain-backed)

    static func loadAPIKey() -> String? {
        ClipKeychain.get(account: apiKeyAccount)
    }

    static func saveAPIKey(_ value: String) {
        ClipKeychain.set(value, account: apiKeyAccount)
    }

    static func removeAPIKey() {
        ClipKeychain.remove(account: apiKeyAccount)
    }
}

/// Minimal generic-password Keychain wrapper. Secrets never go through
/// UserDefaults; an empty value is treated as "no secret stored".
enum ClipKeychain {
    private static let service = "com.clipstudio"

    static func set(_ value: String, account: String) {
        guard !value.isEmpty else {
            remove(account: account)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Simple upsert: drop any previous item, then add.
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
