import Foundation
import RepoPromptCore

actor KeyManager {
    private let secureService: SecureKeysService

    /// Simple in-memory store of keys
    private var cache = [AIProviderType: String]()

    init(
        secureService: SecureKeysService = SecureKeysService(
            secureStorage: SecureKeyValueStorageFactory.defaultBackend()
        )
    ) {
        self.secureService = secureService
    }

    /// Lazily loads the key from disk only if not already in the `cache`.
    func getAPIKey(
        for provider: AIProviderType,
        accessMode: SecureStorageAccessMode = .interactive
    ) async throws -> String? {
        if let cached = cache[provider] {
            return cached
        }

        let identifier = provider.secureIdentifier
        let keyFromDisk = try await secureService.getAPIKey(for: identifier, accessMode: accessMode)

        if let k = keyFromDisk {
            cache[provider] = k
        }

        return keyFromDisk
    }

    /// Saves to both in-memory cache and disk.
    func saveAPIKey(
        _ key: String,
        for provider: AIProviderType,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        cache[provider] = key
        let identifier = provider.secureIdentifier
        try secureService.saveAPIKey(key, for: identifier, accessMode: accessMode)
    }

    /// Deletes from both in-memory cache and disk.
    func deleteAPIKey(
        for provider: AIProviderType,
        accessMode: SecureStorageAccessMode = .interactive
    ) throws {
        cache.removeValue(forKey: provider)
        let identifier = provider.secureIdentifier
        try secureService.deleteAPIKey(for: identifier, accessMode: accessMode)
    }
}

extension AIProviderType {
    /// Maps each `AIProviderType` to the secureIdentifier used by `SecureKeysService`.
    var secureIdentifier: String {
        switch self {
        case .anthropic: "AnthropicAPI"
        case .openAI: "OpenAIAPI"
        case .gemini: "GeminiAPI"
        case .openRouter: "OpenRouterAPI"
        case .ollama: "OllamaURL"
        case .azure: "AzureAPI"
        case .deepseek: "DeepSeekAPI"
        case .customProvider: "CustomProviderAPI"
        case .fireworks: "FireworksAPI" // Add Fireworks case
        case .grok: "GrokAPI" // Add Grok case
        case .groq: "GroqAPI" // Add Groq case
        case .claudeCode: "ClaudeCodeAPI" // Add Claude Code case
        case .codex: "CodexCLIAPI"
        case .openCode: "OpenCodeCLIAPI"
        case .cursor: "CursorCLIAPI"
        case .zAI: "ZAIAPI"
        }
    }
}
