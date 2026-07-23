import Foundation
import Network

enum QuestionAnswerTextFormatter {
    static func displayText(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return response }

        let candidate = removingJSONCodeFence(from: trimmed)
        let repairedCandidate = repairingInvalidJSONEscapes(in: candidate)
        guard
            let data = repairedCandidate.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return response
        }

        for key in ["answer", "response", "content", "text", "result"] {
            if let text = dictionary[key] as? String {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }

        if dictionary.count == 1, let value = dictionary.values.first,
           let text = readableText(from: value), !text.isEmpty {
            return text
        }

        return response
    }

    private static func removingJSONCodeFence(from text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```") else { return text }
        var lines = text.components(separatedBy: .newlines)
        guard lines.count >= 3 else { return text }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func repairingInvalidJSONEscapes(in text: String) -> String {
        text.replacingOccurrences(
            of: #"\\(?=[^"\\/bfnrtu])"#,
            with: #"\\\\"#,
            options: .regularExpression
        )
    }

    private static func readableText(from value: Any, depth: Int = 0) -> String? {
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let values = value as? [Any] {
            let rendered = values.compactMap { readableText(from: $0, depth: depth + 1) }
            return rendered.isEmpty ? nil : rendered.joined(separator: "\n\n")
        }
        if let dictionary = value as? [String: Any] {
            if let topic = dictionary["topic"] as? String,
               let summary = dictionary["summary"] as? String {
                let heading = String(repeating: "#", count: min(6, depth + 2))
                var output = "\(heading) \(topic)\n\n\(summary)"
                if let keyPoints = dictionary["key_points"] as? [String], !keyPoints.isEmpty {
                    output += "\n\n" + keyPoints.map { "- \($0)" }.joined(separator: "\n")
                }
                return output
            }

            let rendered = dictionary.keys.sorted().compactMap { key -> String? in
                guard let nested = dictionary[key],
                      let text = readableText(from: nested, depth: depth + 1),
                      !text.isEmpty else { return nil }
                let label = key.replacingOccurrences(of: "_", with: " ")
                let heading = String(repeating: "#", count: min(6, depth + 2))
                return "\(heading) \(label.prefix(1).uppercased())\(label.dropFirst())\n\n\(text)"
            }
            return rendered.isEmpty ? nil : rendered.joined(separator: "\n\n")
        }
        return nil
    }
}

struct RedappSummarizeDaemonConfiguration {
    var host: String
    var port: Int
    var token: String
    var model: String

    var baseURL: URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmedHost
        components.port = port
        return components.url
    }
}

struct RedappSummarizeBridgeConfiguration {
    var host: String
    var port: Int
    var secret: String
}

struct RedappPCCGatewayConfiguration {
    var host: String
    var port: Int
    var token: String
    var model: String

    init(host: String, port: Int, token: String, model: String) {
        self.host = host
        self.port = port
        self.token = token
        self.model = model
    }

    init(settings: AppSettings) {
        self.init(
            host: settings.pccGatewayHost,
            port: settings.pccGatewayPort,
            token: settings.pccGatewayToken,
            model: settings.pccGatewayModel
        )
    }

    var baseURL: URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmedHost
        components.port = port
        return components.url
    }
}

private struct RedappSummarizeBridgeEndpointCandidate {
    let endpoint: NWEndpoint
    let description: String
}

private final class RedappBridgeDiscoveryState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func complete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

private enum RedappSummarizeBridgeEndpointResolver {
    static let serviceType = "_redapp-sum._tcp"

    static func candidates(host: String, port: NWEndpoint.Port) async -> [RedappSummarizeBridgeEndpointCandidate] {
        var candidates: [RedappSummarizeBridgeEndpointCandidate] = []

        #if os(iOS)
        if let discoveredEndpoint = await discoverEndpoint(timeoutSeconds: 2) {
            candidates.append(
                RedappSummarizeBridgeEndpointCandidate(
                    endpoint: discoveredEndpoint,
                    description: "discovered Mac bridge"
                )
            )
        }
        #endif

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHost.isEmpty {
            candidates.append(
                RedappSummarizeBridgeEndpointCandidate(
                    endpoint: .hostPort(host: NWEndpoint.Host(trimmedHost), port: port),
                    description: "\(trimmedHost):\(port)"
                )
            )
        }

        return candidates
    }

    #if os(iOS)
    private static func discoverEndpoint(timeoutSeconds: TimeInterval) async -> NWEndpoint? {
        await withCheckedContinuation { continuation in
            let state = RedappBridgeDiscoveryState()
            let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
            let browser = NWBrowser(for: descriptor, using: browserParameters())

            let finish: @Sendable (NWEndpoint?) -> Void = { endpoint in
                guard state.complete() else { return }
                browser.cancel()
                continuation.resume(returning: endpoint)
            }

            browser.browseResultsChangedHandler = { results, _ in
                guard let endpoint = results.first?.endpoint else { return }
                finish(endpoint)
            }
            browser.stateUpdateHandler = { browserState in
                if case .failed = browserState {
                    finish(nil)
                }
            }
            browser.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                finish(nil)
            }
        }
    }

    private static func browserParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }
    #endif
}

enum RedappSummarizeDaemonTokenResolver {
    static func sanitized(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.lowercased().hasPrefix("bearer ") {
            return String(trimmed.dropFirst(7)).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }

        return trimmed
    }

    static func localDaemonConfigToken() -> String {
        #if os(macOS)
        let configURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".summarize/daemon.json")

        guard
            let data = try? Data(contentsOf: configURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = object["token"] as? String
        else {
            return ""
        }

        return sanitized(token)
        #else
        return ""
        #endif
    }

    static func effectiveToken(preferred: String, fallback: String = "") -> String {
        let preferredToken = sanitized(preferred)
        if !preferredToken.isEmpty {
            return preferredToken
        }

        let fallbackToken = sanitized(fallback)
        if !fallbackToken.isEmpty {
            return fallbackToken
        }

        #if os(macOS)
        let daemonToken = localDaemonConfigToken()
        if !daemonToken.isEmpty {
            return daemonToken
        }
        #endif

        return ""
    }
}

private struct RedappSummarizeBridgeRequest: Codable {
    enum Kind: String, Codable {
        case ping
        case generate
    }

    let kind: Kind
    let secret: String
    let prompt: String?
}

private struct RedappSummarizeBridgeResponse: Codable {
    let ok: Bool
    let text: String?
    let error: String?
}

private final class RedappBridgeLineConnection {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.start(queue: .global(qos: .userInitiated))
    }

    func startAndWaitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume(returning: ())
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(
                        throwing: NSError(
                            domain: "RedappSummarizeBridge",
                            code: 9,
                            userInfo: [NSLocalizedDescriptionKey: "Bridge connection was cancelled."]
                        )
                    )
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    func cancel() {
        connection.cancel()
    }

    func sendLine(_ data: Data) async throws {
        var payload = data
        payload.append(0x0A)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    func receiveLine(maxBytes: Int = 12_000_000) async throws -> Data {
        var buffer = Data()
        while true {
            let (chunk, isComplete) = try await receiveChunk()
            if let newlineIndex = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk[..<newlineIndex])
                return buffer
            }
            buffer.append(chunk)
            if buffer.count > maxBytes {
                throw NSError(domain: "RedappSummarizeBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bridge response is too large."])
            }
            if isComplete {
                guard !buffer.isEmpty else {
                    throw NSError(domain: "RedappSummarizeBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: "Bridge closed without a response."])
                }
                return buffer
            }
        }
    }

    private func receiveChunk() async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (data ?? Data(), isComplete))
            }
        }
    }
}

struct RedappSummarizeDaemonHTTPClient {
    struct SummarizeRequest: Encodable {
        let url: String
        let title: String
        let text: String
        let truncated: Bool
        let model: String?
        let length: String
        let language: String
        let mode: String
        let noCache: Bool
        let maxCharacters: Int
    }

    private struct SummarizeStartResponse: Decodable {
        let ok: Bool?
        let id: String?
        let error: String?
    }

    private struct SummarizeErrorEvent: Decodable {
        let message: String
    }

    private struct SummarizeChunkEvent: Decodable {
        let text: String
    }

    private struct AgentMessage: Encodable {
        let role: String
        let content: String
        let timestamp: Double
    }

    private struct AgentRequest: Encodable {
        let url: String
        let title: String
        let pageContent: String
        let messages: [AgentMessage]
        let automationEnabled: Bool
    }

    private struct AgentAssistant: Decodable {
        let content: String?
        let text: String?
    }

    private struct AgentResponse: Decodable {
        let ok: Bool?
        let assistant: AgentAssistant?
        let error: String?
    }

    let configuration: RedappSummarizeDaemonConfiguration

    private func sanitizedDaemonToken(_ rawValue: String) -> String {
        RedappSummarizeDaemonTokenResolver.sanitized(rawValue)
    }

    private func typedDaemonToken() -> String {
        #if os(macOS)
        let defaultsToken = UserDefaults.standard.string(forKey: "summarizeDaemonToken") ?? ""
        return RedappSummarizeDaemonTokenResolver.effectiveToken(preferred: defaultsToken, fallback: configuration.token)
        #else
        return sanitizedDaemonToken(configuration.token)
        #endif
    }

    private func endpoint(_ path: String, baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        return components?.url ?? baseURL.appendingPathComponent(path)
    }

    private func agentEndpoint(baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/agent"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "format", value: "json")]
        return components?.url ?? baseURL.appendingPathComponent("v1/agent")
    }

    func ping() async throws {
        guard let baseURL = configuration.baseURL else {
            throw NSError(domain: "RedappSummarizeDaemon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Summarize daemon host is missing."])
        }
        let token = typedDaemonToken()
        guard !token.isEmpty else {
            throw NSError(domain: "RedappSummarizeDaemon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Summarize daemon token is missing. Paste the token from your daemon setup."])
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/ping"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await NetworkService.shared.responsiveSession.data(for: request)
        try validateHTTPResponse(data: data, response: response, fallback: "Summarize daemon ping failed.")
    }

    func generate(
        prompt: String,
        onPartial: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> String {
        guard let baseURL = configuration.baseURL else {
            throw NSError(domain: "RedappSummarizeDaemon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Summarize daemon host is missing."])
        }
        let token = typedDaemonToken()
        guard !token.isEmpty else {
            throw NSError(domain: "RedappSummarizeDaemon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Summarize daemon token is missing. Paste the token from your daemon setup."])
        }

        let body = AgentRequest(
            url: "https://redapp.local/summary",
            title: "redapp",
            pageContent: "redapp summary request",
            messages: [
                AgentMessage(
                    role: "user",
                    content: prompt,
                    timestamp: Date().timeIntervalSince1970 * 1000
                )
            ],
            automationEnabled: false
        )
        let requestBody = try JSONEncoder().encode(body)

        var request = URLRequest(url: agentEndpoint(baseURL: baseURL))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = requestBody

        let (responseData, response) = try await NetworkService.shared.responsiveSession.data(for: request)
        try validateHTTPResponse(data: responseData, response: response, fallback: "Summarize daemon request failed.")
        let agentResponse = try JSONDecoder().decode(AgentResponse.self, from: responseData)
        guard agentResponse.ok != false else {
            throw NSError(domain: "RedappSummarizeDaemon", code: 3, userInfo: [NSLocalizedDescriptionKey: agentResponse.error ?? "Summarize daemon request failed."])
        }
        let output = (agentResponse.assistant?.content ?? agentResponse.assistant?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw NSError(domain: "RedappSummarizeDaemon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Summarize daemon returned no output."])
        }
        if let onPartial {
            await MainActor.run {
                onPartial(output)
            }
        }
        return output
    }

    private func validateHTTPResponse(data: Data, response: URLResponse, fallback: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? fallback
            let message: String
            if httpResponse.statusCode == 401 || body.contains("\"unauthorized\"") {
                message = "Summarize daemon rejected the Mac daemon token. Check that redapp on the Mac is using the same saved token as the running Summarize daemon; an older saved token can cause this even if another app works."
            } else if
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let error = object["error"] as? String,
                !error.isEmpty {
                message = error
            } else {
                message = body
            }
            throw NSError(
                domain: "RedappSummarizeDaemon",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

struct RedappSummarizeBridgeClient {
    let configuration: RedappSummarizeBridgeConfiguration

    func ping() async throws {
        _ = try await request(kind: .ping, prompt: nil, timeoutSeconds: 10)
    }

    func generate(
        prompt: String,
        onPartial: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> String {
        let text = try await request(kind: .generate, prompt: prompt, timeoutSeconds: 120)
        if let onPartial, !text.isEmpty {
            await MainActor.run {
                onPartial(text)
            }
        }
        return text
    }

    private func request(
        kind: RedappSummarizeBridgeRequest.Kind,
        prompt: String?,
        timeoutSeconds: UInt64
    ) async throws -> String {
        let host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = configuration.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else {
            throw NSError(domain: "RedappSummarizeBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bridge secret/pass is missing."])
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else {
            throw NSError(domain: "RedappSummarizeBridge", code: 5, userInfo: [NSLocalizedDescriptionKey: "Bridge port is invalid."])
        }
        let candidates = await RedappSummarizeBridgeEndpointResolver.candidates(host: host, port: port)
        guard !candidates.isEmpty else {
            throw NSError(
                domain: "RedappSummarizeBridge",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "No Mac bridge found. Open redapp on the Mac, keep both devices on the same Wi-Fi, or enter the Mac's current LAN IP."
                ]
            )
        }
        let targetDescription = candidates.map(\.description).joined(separator: ", ")

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await performRequest(candidates: candidates, secret: secret, kind: kind, prompt: prompt)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw NSError(
                    domain: "RedappSummarizeBridge",
                    code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Cannot reach Mac bridge. Tried \(targetDescription). Keep redapp open on the Mac and make sure both devices are on the same Wi-Fi."
                    ]
                )
            }

            guard let result = try await group.next() else {
                throw NSError(domain: "RedappSummarizeBridge", code: 8, userInfo: [NSLocalizedDescriptionKey: "Mac bridge did not return a response."])
            }
            group.cancelAll()
            return result
        }
    }

    private func performRequest(
        candidates: [RedappSummarizeBridgeEndpointCandidate],
        secret: String,
        kind: RedappSummarizeBridgeRequest.Kind,
        prompt: String?
    ) async throws -> String {
        var lastError: Error?
        for candidate in candidates {
            do {
                return try await performRequest(endpoint: candidate.endpoint, secret: secret, kind: kind, prompt: prompt)
            } catch {
                if !shouldTryNextEndpoint(after: error) {
                    throw error
                }
                lastError = error
            }
        }

        let targetDescription = candidates.map(\.description).joined(separator: ", ")
        throw NSError(
            domain: "RedappSummarizeBridge",
            code: 7,
            userInfo: [
                NSLocalizedDescriptionKey: "Cannot reach Mac bridge. Tried \(targetDescription). \(lastError?.localizedDescription ?? "No bridge responded.")"
            ]
        )
    }

    private func shouldTryNextEndpoint(after error: Error) -> Bool {
        let nsError = error as NSError
        return !(nsError.domain == "RedappSummarizeBridge" && nsError.code == 6)
    }

    private func performRequest(
        endpoint: NWEndpoint,
        secret: String,
        kind: RedappSummarizeBridgeRequest.Kind,
        prompt: String?
    ) async throws -> String {
        let connection = NWConnection(to: endpoint, using: tcpParameters())
        let stream = RedappBridgeLineConnection(connection: connection)

        return try await withTaskCancellationHandler {
            defer { stream.cancel() }
            try await stream.startAndWaitUntilReady()

            let request = RedappSummarizeBridgeRequest(
                kind: kind,
                secret: secret,
                prompt: prompt
            )
            try await stream.sendLine(JSONEncoder().encode(request))
            let responseData = try await stream.receiveLine()
            let response = try JSONDecoder().decode(RedappSummarizeBridgeResponse.self, from: responseData)
            guard response.ok else {
                throw NSError(domain: "RedappSummarizeBridge", code: 6, userInfo: [NSLocalizedDescriptionKey: response.error ?? "Mac bridge failed."])
            }
            return response.text ?? ""
        } onCancel: {
            stream.cancel()
        }
    }

    private func tcpParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        #if os(iOS)
        parameters.includePeerToPeer = true
        #endif
        return parameters
    }
}

struct RedappPCCGatewayClient {
    private struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    private struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message?
        }

        let choices: [Choice]?
        let error: GatewayError?
    }

    private struct GatewayError: Decodable {
        let type: String?
        let message: String?
    }

    let configuration: RedappPCCGatewayConfiguration

    func ping() async throws {
        guard let baseURL = configuration.baseURL else {
            throw NSError(domain: "RedappPCCGateway", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple PCC Gateway host is missing."])
        }
        let token = normalizedToken()
        guard !token.isEmpty else {
            throw NSError(domain: "RedappPCCGateway", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple PCC Gateway token is missing. Paste the token printed by scripts/start-fm-pcc-gateway.command."])
        }

        var request = URLRequest(url: endpoint("/health", baseURL: baseURL))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await NetworkService.shared.responsiveSession.data(for: request)
        try validateHTTPResponse(data: data, response: response, fallback: "Apple PCC Gateway health check failed.")
    }

    func generate(prompt: String) async throws -> String {
        guard let baseURL = configuration.baseURL else {
            throw NSError(domain: "RedappPCCGateway", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple PCC Gateway host is missing."])
        }
        let token = normalizedToken()
        guard !token.isEmpty else {
            throw NSError(domain: "RedappPCCGateway", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple PCC Gateway token is missing. Paste the token printed by scripts/start-fm-pcc-gateway.command."])
        }
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "pcc"
            : configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)

        let body = ChatCompletionRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: prompt)],
            stream: false
        )
        var request = URLRequest(url: endpoint("/v1/chat/completions", baseURL: baseURL))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await NetworkService.shared.responsiveSession.data(for: request)
        try validateHTTPResponse(data: data, response: response, fallback: "Apple PCC Gateway request failed.")
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        if let message = decoded.error?.message, !message.isEmpty {
            throw NSError(domain: "RedappPCCGateway", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let output = decoded.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else {
            throw NSError(domain: "RedappPCCGateway", code: 4, userInfo: [NSLocalizedDescriptionKey: "Apple PCC Gateway returned no output."])
        }
        return output
    }

    private func normalizedToken() -> String {
        RedappSummarizeDaemonTokenResolver.sanitized(configuration.token)
    }

    private func endpoint(_ path: String, baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        return components?.url ?? baseURL.appendingPathComponent(path)
    }

    private func validateHTTPResponse(data: Data, response: URLResponse, fallback: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = errorMessage(from: data, statusCode: httpResponse.statusCode, fallback: fallback)
            throw NSError(
                domain: "RedappPCCGateway",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Apple PCC Gateway error \(httpResponse.statusCode): \(message)"]
            )
        }
    }

    private func errorMessage(from data: Data, statusCode: Int, fallback: String) -> String {
        if statusCode == 401 {
            return "Missing or invalid gateway token. Use the token printed by scripts/start-fm-pcc-gateway.command."
        }
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any] {
            let type = error["type"] as? String
            let message = error["message"] as? String
            return [type, message].compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }.joined(separator: ": ")
        }
        if let body = String(data: data, encoding: .utf8), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        return fallback
    }
}

enum RedappSummarizeProviderClient {
    static func ping(settings: AppSettings) async throws {
        #if os(iOS)
        if !settings.summarizeBridgeSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await RedappSummarizeBridgeClient(configuration: bridgeConfiguration(from: settings)).ping()
            return
        }
        #endif
        try await RedappSummarizeDaemonHTTPClient(configuration: daemonConfiguration(from: settings)).ping()
    }

    static func generate(
        prompt: String,
        settings: AppSettings,
        onPartial: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> String {
        #if os(iOS)
        if !settings.summarizeBridgeSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await RedappSummarizeBridgeClient(configuration: bridgeConfiguration(from: settings))
                .generate(prompt: prompt, onPartial: onPartial)
        }
        #endif
        return try await RedappSummarizeDaemonHTTPClient(configuration: daemonConfiguration(from: settings))
            .generate(prompt: prompt, onPartial: onPartial)
    }

    static func daemonConfiguration(from settings: AppSettings) -> RedappSummarizeDaemonConfiguration {
        RedappSummarizeDaemonConfiguration(
            host: settings.summarizeDaemonHost,
            port: settings.summarizeDaemonPort,
            token: RedappSummarizeDaemonTokenResolver.effectiveToken(preferred: settings.summarizeDaemonToken),
            model: settings.summarizeDaemonModel
        )
    }

    static func bridgeConfiguration(from settings: AppSettings) -> RedappSummarizeBridgeConfiguration {
        RedappSummarizeBridgeConfiguration(
            host: settings.summarizeBridgeHost,
            port: settings.summarizeBridgePort,
            secret: settings.summarizeBridgeSecret
        )
    }

    static func daemonConfigurationFromRedappDefaults() -> RedappSummarizeDaemonConfiguration {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: "summarizeDaemonHost") ?? "127.0.0.1"
        let storedPort = defaults.integer(forKey: "summarizeDaemonPort")
        let port = storedPort > 0 ? storedPort : 8787
        let model = defaults.string(forKey: "summarizeDaemonModel") ?? "gpt-fast"
        let token = RedappSummarizeDaemonTokenResolver.effectiveToken(
            preferred: defaults.string(forKey: "summarizeDaemonToken") ?? ""
        )
        return RedappSummarizeDaemonConfiguration(
            host: host,
            port: port,
            token: token,
            model: model
        )
    }
}

final class RedappSummarizeBridgeServer {
    static let shared = RedappSummarizeBridgeServer()

    private var listener: NWListener?
    private var activePort: Int?
    private var retryWorkItem: DispatchWorkItem?

    private init() {}

    func reconfigure(settings: AppSettings) {
        #if os(macOS)
        let port = min(max(settings.summarizeBridgePort, 1), 65_535)
        guard activePort != port || listener == nil else { return }
        stop()
        start(port: port)
        #endif
    }

    private func stop() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        listener?.cancel()
        listener = nil
        activePort = nil
    }

    private func start(port: Int) {
        #if os(macOS)
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: endpointPort)
            listener.service = NWListener.Service(name: "redapp", type: "_redapp-sum._tcp")
            listener.newConnectionHandler = { connection in
                Task {
                    await self.handle(connection: connection)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    print("Redapp Summarize bridge listening on port \(port)")
                case .failed(let error):
                    self.handleListenerFailure(listener, port: port, error: error)
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            self.activePort = port
            print("Redapp Summarize bridge starting on port \(port)")
        } catch {
            print("Redapp Summarize bridge failed to start: \(error.localizedDescription)")
            scheduleRetry(port: port)
        }
        #endif
    }

    private func handleListenerFailure(_ failedListener: NWListener, port: Int, error: NWError) {
        guard listener === failedListener else { return }
        print("Redapp Summarize bridge failed on port \(port): \(error.localizedDescription)")
        listener = nil
        activePort = nil
        scheduleRetry(port: port)
    }

    private func scheduleRetry(port: Int) {
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.start(port: port)
        }
        retryWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func handle(connection: NWConnection) async {
        let stream = RedappBridgeLineConnection(connection: connection)
        stream.start()
        defer { stream.cancel() }

        do {
            let requestData = try await stream.receiveLine(maxBytes: 2_000_000)
            let request = try JSONDecoder().decode(RedappSummarizeBridgeRequest.self, from: requestData)
            let expectedSecret = UserDefaults.standard
                .string(forKey: "macBridgeSecret")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let daemonConfiguration = RedappSummarizeProviderClient.daemonConfigurationFromRedappDefaults()

            let bridgeSecretMatches = !expectedSecret.isEmpty && request.secret == expectedSecret
            guard bridgeSecretMatches else {
                try await send(error: "Bridge authentication failed. Check the bridge secret/pass.", stream: stream)
                return
            }

            switch request.kind {
            case .ping:
                try await RedappSummarizeDaemonHTTPClient(configuration: daemonConfiguration).ping()
                try await send(text: "Mac bridge connected. Summarize daemon connected.", stream: stream)
            case .generate:
                guard let prompt = request.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    try await send(error: "Bridge request was missing prompt text.", stream: stream)
                    return
                }
                let output = try await RedappSummarizeDaemonHTTPClient(configuration: daemonConfiguration)
                    .generate(prompt: prompt, onPartial: nil)
                try await send(text: output, stream: stream)
            }
        } catch {
            try? await send(error: error.localizedDescription, stream: stream)
        }
    }

    private func send(text: String, stream: RedappBridgeLineConnection) async throws {
        let response = RedappSummarizeBridgeResponse(ok: true, text: text, error: nil)
        try await stream.sendLine(JSONEncoder().encode(response))
    }

    private func send(error: String, stream: RedappBridgeLineConnection) async throws {
        let response = RedappSummarizeBridgeResponse(ok: false, text: nil, error: error)
        try await stream.sendLine(JSONEncoder().encode(response))
    }

}
