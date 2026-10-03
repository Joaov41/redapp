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
        #if os(macOS)
        let daemonToken = localDaemonConfigToken()
        if !daemonToken.isEmpty {
            return daemonToken
        }
        #endif

        let preferredToken = sanitized(preferred)
        if !preferredToken.isEmpty {
            return preferredToken
        }

        return sanitized(fallback)
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
        let model: String
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
            model: configuration.model,
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
                message = "Summarize daemon rejected the Mac daemon token. Paste the current token into redapp on the Mac."
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
        _ = try await request(kind: .ping, prompt: nil)
    }

    func generate(
        prompt: String,
        onPartial: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> String {
        let text = try await request(kind: .generate, prompt: prompt)
        if let onPartial, !text.isEmpty {
            await MainActor.run {
                onPartial(text)
            }
        }
        return text
    }

    private func request(kind: RedappSummarizeBridgeRequest.Kind, prompt: String?) async throws -> String {
        let host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = configuration.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw NSError(domain: "RedappSummarizeBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mac bridge host is missing."])
        }
        guard !secret.isEmpty else {
            throw NSError(domain: "RedappSummarizeBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bridge secret/pass is missing."])
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else {
            throw NSError(domain: "RedappSummarizeBridge", code: 5, userInfo: [NSLocalizedDescriptionKey: "Bridge port is invalid."])
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let stream = RedappBridgeLineConnection(connection: connection)
        stream.start()
        defer { stream.cancel() }

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
    }
}

final class RedappPCCGatewayClient: @unchecked Sendable {
    private static let fmURL = URL(fileURLWithPath: "/usr/bin/fm")
    private static let ansiPattern = "\u{001B}\\[[0-9;]*m"
    private static let helperDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".aiassistant-pcc-helper", isDirectory: true)

    private let processQueue = DispatchQueue(label: "redapp.FMPCC.process")
    private var currentProcess: Process?
    private var currentTerminalShellPID: Int32?

    let configuration: RedappPCCGatewayConfiguration

    init(configuration: RedappPCCGatewayConfiguration) {
        self.configuration = configuration
    }

    func ping() async throws {
        _ = try await Self.availabilityDescription()
    }

    func generate(prompt: String) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.fmURL.path) else {
            throw Self.error("Apple PCC is unavailable on this Mac.")
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw Self.error("Apple PCC returned an empty response.")
        }

        let arguments = ["respond", "--model", "pcc", "--no-stream", "--text", trimmedPrompt]
        let result = try await withTaskCancellationHandler {
            let directResult = try await runFM(arguments: arguments)
            if directResult.status != 0, Self.isPCCContextUnavailable(directResult.output) {
                return try await runFMViaTerminalHelper(arguments: arguments)
            }
            return directResult
        } onCancel: {
            self.cancel()
        }

        if Task.isCancelled {
            throw Self.error("Apple PCC request was cancelled.")
        }
        guard result.status == 0 else {
            throw Self.error(Self.userFacingFailureMessage(result.output))
        }

        let output = Self.cleanFMResponse(result.output)
        guard !output.isEmpty else {
            throw Self.error("Apple PCC returned an empty response.")
        }
        return output
    }

    func cancel() {
        let process = processQueue.sync {
            let process = currentProcess
            currentProcess = nil
            return process
        }
        if let process, process.isRunning {
            process.terminate()
        }

        let terminalShellPID = processQueue.sync {
            let pid = currentTerminalShellPID
            currentTerminalShellPID = nil
            return pid
        }
        if let terminalShellPID {
            Self.terminateTerminalJob(shellPID: terminalShellPID)
        }
    }

    static func availabilityDescription() async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: fmURL.path) else {
            throw error("Apple PCC is unavailable on this Mac.")
        }

        let result = try await runProcess(executableURL: fmURL, arguments: ["available", "--model", "pcc"])
        if result.status == 0 {
            let output = stripANSI(result.output)
            return output.isEmpty ? "PCC model available." : output
        }

        let directOutput = stripANSI(result.output)
        if isPCCContextUnavailable(directOutput) {
            let terminalResult = try await runOneShotViaTerminal(arguments: ["available", "--model", "pcc"])
            if terminalResult.status == 0 {
                let terminalOutput = stripANSI(terminalResult.output)
                return terminalOutput.isEmpty ? "PCC model available via Terminal." : "\(terminalOutput) (via Terminal)"
            }
            let terminalOutput = stripANSI(terminalResult.output)
            throw error(terminalOutput.isEmpty ? directOutput : terminalOutput)
        }

        throw error(directOutput.isEmpty ? "PCC model unavailable." : directOutput)
    }

    private func runFM(arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = Self.fmURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let outputBuffer = RedappLockedProcessOutput()
        let fileHandle = pipe.fileHandleForReading
        fileHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputBuffer.append(data)
        }

        setCurrentProcess(process)
        do {
            try process.run()
        } catch {
            fileHandle.readabilityHandler = nil
            clearCurrentProcess(process)
            throw Self.error("Apple PCC is unavailable on this Mac.")
        }

        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.resume(returning: terminatedProcess.terminationStatus)
            }
        }

        fileHandle.readabilityHandler = nil
        outputBuffer.append(fileHandle.readDataToEndOfFile())
        let output = outputBuffer.stringValue()
        clearCurrentProcess(process)
        return (status, Self.stripANSI(output))
    }

    private func setCurrentProcess(_ process: Process?) {
        processQueue.sync {
            currentProcess = process
        }
    }

    private func clearCurrentProcess(_ process: Process) {
        processQueue.sync {
            if currentProcess === process {
                currentProcess = nil
            }
        }
    }

    private func setCurrentTerminalShellPID(_ pid: Int32?) {
        processQueue.sync {
            currentTerminalShellPID = pid
        }
    }

    private func runFMViaTerminalHelper(arguments: [String]) async throws -> (status: Int32, output: String) {
        try await Self.ensureTerminalHelperStarted()

        let jobDirectory = Self.helperDirectory
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: jobDirectory) }

        let scriptURL = jobDirectory.appendingPathComponent("run.zsh")
        let readyURL = jobDirectory.appendingPathComponent("request.ready")
        let outputURL = jobDirectory.appendingPathComponent("output.txt")
        let statusURL = jobDirectory.appendingPathComponent("status.txt")
        let pidURL = jobDirectory.appendingPathComponent("pid.txt")
        let doneURL = jobDirectory.appendingPathComponent("done")

        let command = ([Self.fmURL.path] + arguments).map(Self.shellDisplayArgument).joined(separator: " ")
        let script = """
        #!/bin/zsh
        echo $$ > \(Self.shellDisplayArgument(pidURL.path))
        \(command) > \(Self.shellDisplayArgument(outputURL.path)) 2>&1
        fm_status=$?
        echo $fm_status > \(Self.shellDisplayArgument(statusURL.path))
        touch \(Self.shellDisplayArgument(doneURL.path))
        exit $fm_status
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        try Data().write(to: readyURL, options: .atomic)

        for _ in 0..<1200 {
            if FileManager.default.fileExists(atPath: doneURL.path) {
                break
            }
            if let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
               let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                setCurrentTerminalShellPID(pid)
            }
            if Task.isCancelled {
                cancel()
                throw Self.error("Apple PCC request was cancelled.")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        setCurrentTerminalShellPID(nil)

        guard FileManager.default.fileExists(atPath: doneURL.path) else {
            throw Self.error("Timed out waiting for Terminal to finish the Apple PCC request.")
        }

        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let statusText = (try? String(contentsOf: statusURL, encoding: .utf8)) ?? "1"
        let fmStatus = Int32(statusText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        return (fmStatus, Self.stripANSI(output))
    }

    private static func ensureTerminalHelperStarted() async throws {
        try FileManager.default.createDirectory(
            at: helperDirectory.appendingPathComponent("jobs", isDirectory: true),
            withIntermediateDirectories: true
        )

        let pidURL = helperDirectory.appendingPathComponent("helper.pid")
        if let pid = readPID(from: pidURL), isProcessRunning(pid: pid) {
            return
        }

        try? FileManager.default.removeItem(at: pidURL)
        let helperScriptURL = helperDirectory.appendingPathComponent("helper.zsh")
        let jobsPath = helperDirectory.appendingPathComponent("jobs", isDirectory: true).path
        let helperScript = """
        #!/bin/zsh
        setopt NULL_GLOB
        echo $$ > \(shellDisplayArgument(pidURL.path))
        echo -ne "\\033]0;Aiassistant PCC Helper\\007"
        jobs_dir=\(shellDisplayArgument(jobsPath))
        mkdir -p "$jobs_dir"
        while true; do
          for job_dir in "$jobs_dir"/*; do
            [ -d "$job_dir" ] || continue
            [ -f "$job_dir/request.ready" ] || continue
            [ ! -f "$job_dir/started" ] || continue
            touch "$job_dir/started"
            /bin/zsh "$job_dir/run.zsh" > "$job_dir/helper.log" 2>&1
            touch "$job_dir/done"
          done
          sleep 0.2
        done
        """
        try helperScript.write(to: helperScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperScriptURL.path)

        let appleScript = """
        on run argv
            tell application "Terminal"
                do script "/bin/zsh " & quoted form of item 1 of argv
                delay 0.2
                try
                    set miniaturized of front window to true
                end try
            end tell
        end run
        """
        let launchResult = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScript, helperScriptURL.path]
        )
        guard launchResult.status == 0 else {
            throw error("Apple PCC needs to run through Terminal on this beta. Terminal automation failed: \(stripANSI(launchResult.output))")
        }

        for _ in 0..<40 {
            if let pid = readPID(from: pidURL), isProcessRunning(pid: pid) {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw error("Apple PCC needs to run through Terminal on this beta. Terminal automation failed: Timed out waiting for the persistent PCC helper to start.")
    }

    private static func runOneShotViaTerminal(arguments: [String]) async throws -> (status: Int32, output: String) {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("redapp-FMPCC-Availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let scriptURL = tempDirectory.appendingPathComponent("check-fm-pcc.zsh")
        let outputURL = tempDirectory.appendingPathComponent("output.txt")
        let statusURL = tempDirectory.appendingPathComponent("status.txt")
        let doneURL = tempDirectory.appendingPathComponent("done")

        let command = ([fmURL.path] + arguments).map(shellDisplayArgument).joined(separator: " ")
        let script = """
        #!/bin/zsh
        \(command) > \(shellDisplayArgument(outputURL.path)) 2>&1
        fm_status=$?
        echo $fm_status > \(shellDisplayArgument(statusURL.path))
        touch \(shellDisplayArgument(doneURL.path))
        exit $fm_status
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let appleScript = """
        on run argv
            tell application "Terminal"
                do script "/bin/zsh " & quoted form of item 1 of argv
            end tell
        end run
        """
        let launchResult = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScript, scriptURL.path]
        )
        guard launchResult.status == 0 else {
            throw error("Apple PCC needs to run through Terminal on this beta. Terminal automation failed: \(stripANSI(launchResult.output))")
        }

        for _ in 0..<120 {
            if FileManager.default.fileExists(atPath: doneURL.path) {
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                let statusText = (try? String(contentsOf: statusURL, encoding: .utf8)) ?? "1"
                let fmStatus = Int32(statusText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
                return (fmStatus, stripANSI(output))
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return (1, "Timed out waiting for Terminal to check PCC availability.")
    }

    private static func runProcess(executableURL: URL, arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func stripANSI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: ansiPattern) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex
            .stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPCCContextUnavailable(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("pcc inference is not available in this context")
            || normalized.contains("private cloud compute is not available in this context")
            || normalized.contains("please use the terminal app")
    }

    private static func cleanFMResponse(_ output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Session saved:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func userFacingFailureMessage(_ output: String) -> String {
        if isPCCContextUnavailable(output) {
            return "Apple PCC is unavailable: \(output)"
        }
        if output.localizedCaseInsensitiveContains("quota") || output.localizedCaseInsensitiveContains("rate limit") {
            return "Apple PCC quota is exhausted or rate-limited: \(output)"
        }
        return output.isEmpty ? "Apple PCC failed without an error message." : "Apple PCC failed: \(output)"
    }

    private static func terminateTerminalJob(shellPID: Int32) {
        let shellPIDText = String(shellPID)
        _ = try? runDetachedProcess(executableURL: URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-TERM", "-P", shellPIDText])
        _ = try? runDetachedProcess(executableURL: URL(fileURLWithPath: "/bin/kill"), arguments: ["-TERM", shellPIDText])
    }

    private static func runDetachedProcess(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
    }

    private static func readPID(from url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isProcessRunning(pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-0", String(pid)]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func shellDisplayArgument(_ argument: String) -> String {
        if argument.contains(" ") || argument.contains("\n") || argument.contains("'") || argument.contains("\"") {
            return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        return argument
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "RedappPCCFM", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class RedappLockedProcessOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "redapp.FMPCC.output")
    private var data = Data()

    func append(_ newData: Data) {
        queue.sync {
            data.append(newData)
        }
    }

    func stringValue() -> String {
        queue.sync {
            String(data: data, encoding: .utf8) ?? ""
        }
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
        #if os(macOS)
        let defaultsToken = UserDefaults.standard.string(forKey: "summarizeDaemonToken") ?? ""
        let effectiveToken = RedappSummarizeDaemonTokenResolver.effectiveToken(preferred: defaultsToken, fallback: settings.summarizeDaemonToken)
        #else
        let effectiveToken = RedappSummarizeDaemonTokenResolver.sanitized(settings.summarizeDaemonToken)
        #endif
        return RedappSummarizeDaemonConfiguration(
            host: settings.summarizeDaemonHost,
            port: settings.summarizeDaemonPort,
            token: effectiveToken,
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

    private init() {
        #if os(macOS)
        start(port: 8790)
        #endif
    }

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
