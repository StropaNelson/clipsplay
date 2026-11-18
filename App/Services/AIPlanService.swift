import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Errors surfaced by the direct-send card, all in Portuguese.
enum AIPlanServiceError: LocalizedError {
    /// The endpoint string can't be turned into a URL at all.
    case invalidEndpoint
    /// Endpoint is not https.
    case insecureEndpoint
    /// HTTP 401.
    case unauthorized
    /// Any other non-2xx HTTP status, with a summarized body.
    case server(Int, String)
    /// Transport failed or the response wasn't HTTP.
    case noResponse
    /// The response had no usable message content.
    case emptyAnswer
    /// Provider unavailable (with the reason shown to the user).
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Endereço de API inválido."
        case .insecureEndpoint: return "Use um endereço https."
        case .unauthorized: return "Chave inválida ou sem acesso (401)."
        case .server(let code, let body): return "Erro do serviço (\(code)): \(body)"
        case .noResponse: return "Sem resposta do servidor."
        case .emptyAnswer: return "A IA respondeu, mas sem conteúdo."
        case .unavailable(let reason): return reason
        }
    }
}

/// Transport layer for "Editar com IA": sends a ClipBrief plus a free-text
/// request to a provider and returns the raw .clipplan text, which then flows
/// through the same parse→validate→preview path as a pasted JSON.
enum AIPlanService {
    /// Total per-request timeout (also the URLSession resource timeout).
    static let requestTimeout: TimeInterval = 120

    // MARK: - Apple Intelligence capability surface (compile- and runtime-gated)

    /// True only when the FoundationModels framework exists in the SDK AND the
    /// device runs iOS 26+. Drives whether the picker shows the option at all.
    static var appleIntelligenceSupported: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    /// Human-readable availability for the picker hint (e.g. "Ative a Apple
    /// Intelligence nos Ajustes"). Meaningful only when supported is true.
    static var appleIntelligenceLabel: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return AppleIntelligencePlanProvider.availabilityLabel
        }
        #endif
        return "Requer iOS 26 neste iPad."
    }

    /// Whether a request could actually be sent right now.
    static var appleIntelligenceReady: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return AppleIntelligencePlanProvider.isAvailable
        }
        #endif
        return false
    }

    // MARK: - Request

    /// Sends the brief (same JSON the manual flow produces) plus the user's
    /// request to the configured provider; returns the raw plan text.
    static func requestPlan(
        brief: ClipBrief,
        requestText: String,
        previousPlanJSON: String?,
        settings: AIProviderSettings,
        apiKey: String?
    ) async throws -> String {
        switch settings.kind {
        case .manual:
            throw AIPlanServiceError.unavailable("Modo manual: copie o pacote no cartão 1 e cole a resposta no cartão 2.")
        case .api:
            return try await requestPlanViaAPI(
                baseURL: settings.baseURL,
                model: settings.model,
                apiKey: apiKey,
                systemPrompt: ClipPromptGenerator.prompt(for: brief),
                userMessage: userMessage(brief: brief, requestText: requestText, previousPlanJSON: previousPlanJSON)
            )
        case .appleIntelligence:
            // The on-device context window (~4k tokens) can't hold the full
            // brief + prompt: send a compact brief and a mini prompt instead.
            let compactBrief = ClipBriefBuilder.compact(brief)
            let miniPrompt = ClipPromptGenerator.miniPrompt(for: compactBrief)
            let compactUser = compactUserMessage(brief: compactBrief, requestText: requestText)
            guard miniPrompt.count + compactUser.count <= appleIntelligenceBudget else {
                throw AIPlanServiceError.unavailable("Pedido muito grande para Apple Intelligence neste vídeo — use API ou Manual.")
            }
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                do {
                    let content = try await AppleIntelligencePlanProvider.requestPlan(
                        systemPrompt: miniPrompt,
                        userMessage: compactUser
                    )
                    return ClipPlanParser.extractJSON(from: content) ?? stripCodeFences(content)
                } catch let error as AIPlanServiceError {
                    throw error
                } catch {
                    try Task.checkCancellation()
                    // The FoundationModels window-overflow error type isn't
                    // stable across SDKs — match on the message instead.
                    let message = error.localizedDescription.lowercased()
                    if message.contains("context") || message.contains("window") || message.contains("exceed") {
                        throw AIPlanServiceError.unavailable("O pedido não coube no limite do Apple Intelligence. Use pedidos curtos, desligue a transcrição no cartão 1, ou escolha API/Manual.")
                    }
                    throw AIPlanServiceError.unavailable("Apple Intelligence não conseguiu processar este pedido — tente mais curto ou use API/Manual.")
                }
            }
            #endif
            throw AIPlanServiceError.unavailable("Apple Intelligence indisponível neste iPad.")
        }
    }

    /// Rough character budget for the mini prompt + compact brief + pedido that
    /// keeps the whole request inside the on-device model's context window.
    static let appleIntelligenceBudget = 7000

    /// "user" message for the compact path: just the shrunken brief + pedido.
    static func compactUserMessage(brief: ClipBrief, requestText: String) -> String {
        """
        \(ClipBriefBuilder.encode(brief))

        Pedido: \(requestText)
        """
    }

    // MARK: - OpenAI-compatible API path

    private static func requestPlanViaAPI(
        baseURL: String,
        model: String,
        apiKey: String?,
        systemPrompt: String,
        userMessage: String
    ) async throws -> String {
        let url = try completionsURL(baseURL: baseURL)
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = requestBody(
            model: resolvedModel.isEmpty ? AIProviderSettings.defaultModel : resolvedModel,
            systemPrompt: systemPrompt,
            userMessage: userMessage
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = apiKey, !key.isEmpty {
            // The key is only ever placed in this header — never logged.
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            throw AIPlanServiceError.noResponse
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIPlanServiceError.noResponse
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw AIPlanServiceError.unauthorized
        default:
            throw AIPlanServiceError.server(http.statusCode, summarize(data))
        }

        guard let content = choicesContent(data) else {
            throw AIPlanServiceError.emptyAnswer
        }
        return ClipPlanParser.extractJSON(from: content) ?? stripCodeFences(content)
    }

    /// "user" message: brief JSON + pedido + plano anterior (or "nenhum").
    static func userMessage(brief: ClipBrief, requestText: String, previousPlanJSON: String?) -> String {
        let previous: String
        if let plan = previousPlanJSON,
           !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            previous = plan
        } else {
            previous = "nenhum"
        }
        return """
        \(ClipBriefBuilder.encode(brief))

        Pedido: \(requestText)

        Plano anterior (se houver): \(previous)
        """
    }

    /// chat/completions payload. Deliberately no "response_format": not every
    /// OpenAI-compatible provider accepts it.
    static func requestBody(model: String, systemPrompt: String, userMessage: String) -> [String: Any] {
        [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "temperature": 0.3
        ]
    }

    /// {baseURL}/chat/completions — trims, defaults an empty base to OpenAI and
    /// requires https.
    static func completionsURL(baseURL: String) throws -> URL {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.isEmpty { trimmed = AIProviderSettings.defaultBaseURL }
        guard let url = URL(string: trimmed + "/chat/completions") else {
            throw AIPlanServiceError.invalidEndpoint
        }
        guard url.scheme?.lowercased() == "https" else {
            throw AIPlanServiceError.insecureEndpoint
        }
        return url
    }

    /// Some models wrap the JSON in ```json fences despite instructions.
    /// Kept as a thin wrapper — the real logic lives in ClipPlanParser, which
    /// also recovers the JSON when the model answers with prose around it.
    static func stripCodeFences(_ text: String) -> String {
        ClipPlanParser.stripCodeFences(text)
    }

    /// First ~`limit` characters of an error body, flattened to one line.
    static func summarize(_ data: Data, limit: Int = 180) -> String {
        guard let raw = String(data: data, encoding: .utf8) else { return "corpo ilegível" }
        let text = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "corpo vazio" }
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…"
    }

    // MARK: - Response decoding

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
            }
            var message: Message?
        }
        var choices: [Choice]?
    }

    /// choices[0].message.content — nil when absent or effectively empty.
    static func choicesContent(_ data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
              let content = decoded.choices?.first?.message?.content else {
            return nil
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content
    }
}

// MARK: - Apple Intelligence (fully compile-gated)

#if canImport(FoundationModels)
/// On-device path (iOS 26+). This whole type only exists where the SDK ships
/// FoundationModels — on older SDKs it compiles to nothing and the picker
/// option is hidden via AIPlanService.appleIntelligenceSupported.
///
/// VERIFY on the real SDK: names below follow the WWDC25 FoundationModels API —
/// `SystemLanguageModel.default.availability` (`.available` /
/// `.unavailable(reason)` with `.deviceNotEligible`,
/// `.appleIntelligenceNotEnabled`, `.modelNotReady`),
/// `LanguageModelSession(instructions:)` (uses the default model) and
/// `session.respond(to:)` returning a response whose `.content` is the String.
@available(iOS 26.0, *)
enum AppleIntelligencePlanProvider {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    static var availabilityLabel: String {
        // VERIFY: Availability.UnavailableReason member names on the real SDK.
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Disponível neste iPad."
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "Este iPad não é compatível com Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Ative a Apple Intelligence nos Ajustes."
            case .modelNotReady:
                return "O modelo ainda está sendo preparado — tente de novo em instantes."
            default:
                return "Apple Intelligence indisponível no momento."
            }
        }
    }

    static func requestPlan(systemPrompt: String, userMessage: String) async throws -> String {
        guard isAvailable else {
            throw AIPlanServiceError.unavailable(availabilityLabel)
        }
        // VERIFY: confirm `LanguageModelSession(instructions:)` exists and
        // defaults to SystemLanguageModel.default; otherwise pass
        // `model: SystemLanguageModel.default` explicitly.
        let session = LanguageModelSession(instructions: systemPrompt)
        // VERIFY: `respond(to:)` returns `LanguageModelSession.Response<String>`
        // whose `.content` is the generated String.
        let response = try await session.respond(to: userMessage)
        return response.content
    }
}
#endif
