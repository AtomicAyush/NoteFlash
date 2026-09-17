import Foundation

/// Minimal Claude Messages API client (raw HTTP; there is no official Swift SDK).
/// Streams responses so long notes and PDFs don't hit request timeouts.
nonisolated struct AnthropicClient: Sendable {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case http(status: Int, message: String)
        case refused
        case truncated
        case emptyResponse
        case stream(String)
        case invalidJSON

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "Add your Claude API key in Settings to generate flashcards."
            case .http(let status, let message):
                switch status {
                case 401: "Claude rejected the API key. Check it in Settings. (\(message))"
                case 429: "Claude is rate limiting requests. Try again in a minute."
                case 529, 500...599: "Claude is temporarily unavailable (\(status)). Try again shortly."
                default: "Claude API error \(status): \(message)"
                }
            case .refused:
                "Claude declined to make flashcards from these notes."
            case .truncated:
                "The response was cut off because the notes are very long. Try splitting them into smaller decks."
            case .emptyResponse:
                "Claude returned an empty response. Please try again."
            case .stream(let message):
                "The Claude response stream failed: \(message)"
            case .invalidJSON:
                "Claude's response couldn't be read. Please try again."
            }
        }
    }

    enum ContentBlock: Encodable, Sendable {
        case text(String)
        case pdf(base64: String)

        private enum CodingKeys: String, CodingKey { case type, text, source }
        private enum SourceKeys: String, CodingKey { case type, mediaType = "media_type", data }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .pdf(let base64):
                try container.encode("document", forKey: .type)
                var source = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
                try source.encode("base64", forKey: .type)
                try source.encode("application/pdf", forKey: .mediaType)
                try source.encode(base64, forKey: .data)
            }
        }
    }

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: [ContentBlock]
        }
        struct Thinking: Encodable {
            let type: String
        }
        struct OutputConfig: Encodable {
            struct Format: Encodable {
                let type: String
                let schema: JSONValue
            }
            let format: Format
        }

        let model: String
        let maxTokens: Int
        let stream: Bool
        let system: String
        let messages: [Message]
        let thinking: Thinking
        let outputConfig: OutputConfig
        let fallbacks: String

        enum CodingKeys: String, CodingKey {
            case model, stream, system, messages, thinking, fallbacks
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }
    }

    private struct StreamEvent: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stopReason: String?

            enum CodingKeys: String, CodingKey {
                case type, text
                case stopReason = "stop_reason"
            }
        }
        let type: String
        let delta: Delta?
        let error: APIErrorBody?
    }

    private struct APIErrorBody: Decodable {
        let type: String?
        let message: String?
    }

    private struct APIErrorEnvelope: Decodable {
        let error: APIErrorBody?
    }

    private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    /// Lets the API re-run a declined request on Anthropic's recommended fallback model.
    private static let fallbackBeta = "server-side-fallback-2026-07-01"

    let apiKey: String
    var model: String = AppConfig.claudeModel

    static func fromKeychain() throws -> AnthropicClient {
        guard let key = KeychainStore.string(for: .anthropicAPIKey), !key.isEmpty else {
            throw ClientError.missingAPIKey
        }
        return AnthropicClient(apiKey: key)
    }

    /// Sends one message whose reply is constrained to `schema`, and decodes it as `T`.
    /// `onTextProgress` receives the number of answer characters streamed so far.
    @concurrent
    func structuredResponse<T: Decodable & Sendable>(
        system: String,
        content: [ContentBlock],
        schema: JSONValue,
        as type: T.Type,
        onTextProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> T {
        let body = RequestBody(
            model: model,
            maxTokens: 64_000,
            stream: true,
            system: system,
            messages: [.init(role: "user", content: content)],
            thinking: .init(type: "adaptive"),
            outputConfig: .init(format: .init(type: "json_schema", schema: schema)),
            fallbacks: "default"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys  // stable schema bytes → schema cache hits

        var request = URLRequest(url: Self.messagesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try encoder.encode(body)

        let text = try await streamText(for: request, onTextProgress: onTextProgress)
        guard !text.isEmpty else { throw ClientError.emptyResponse }
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw ClientError.invalidJSON
        }
    }

    /// Checks that the API key works without spending tokens.
    @concurrent
    func verifyKey() async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models/\(model)")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ClientError.http(status: status, message: Self.errorMessage(from: data))
        }
    }

    private func streamText(for request: URLRequest, onTextProgress: (@Sendable (Int) -> Void)?) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw ClientError.http(status: status, message: Self.errorMessage(from: data))
        }

        let decoder = JSONDecoder()
        var text = ""
        var reportedLength = 0
        var stopReason: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = Data(line.dropFirst(5).utf8)
            guard let event = try? decoder.decode(StreamEvent.self, from: payload) else { continue }
            switch event.type {
            case "content_block_delta":
                // Only text deltas carry the JSON answer; thinking and signature deltas are skipped.
                if event.delta?.type == "text_delta", let chunk = event.delta?.text {
                    text += chunk
                    if let onTextProgress, text.utf8.count - reportedLength >= 200 {
                        reportedLength = text.utf8.count
                        onTextProgress(reportedLength)
                    }
                }
            case "message_delta":
                if let reason = event.delta?.stopReason { stopReason = reason }
            case "error":
                throw ClientError.stream(event.error?.message ?? "Unknown error")
            default:
                break
            }
        }

        switch stopReason {
        case "refusal": throw ClientError.refused
        case "max_tokens": throw ClientError.truncated
        default: return text
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data),
           let message = envelope.error?.message {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}
