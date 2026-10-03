import Foundation

actor CoreAIMLXLocalService {
    static let shared = CoreAIMLXLocalService()

    static let defaultModelRepo = "mlx-community/gemma-4-e2b-it-4bit"
    static let defaultContextTokens = 2_048
    static let maxContextTokens = 4_096
    static let contextTooLargeDomain = "CoreAIMLXLocalService.ContextTooLarge"
    static let externalModelBookmarkKey = "CoreAIMLXExternalModelBookmark"
    static let externalModelPathKey = "CoreAIMLXExternalModelPath"

    struct BenchmarkSnapshot: Sendable {
        let timeToFirstToken: Double?
        let decodeTokensPerSecond: Double
        let decodeTokens: Int
    }

    private var lastBenchmarkSnapshot: BenchmarkSnapshot?

    private final class ThroughputAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var firstTokenAt: Date?
        private var tokenCount = 0

        func recordToken(now: Date) {
            lock.lock()
            if firstTokenAt == nil {
                firstTokenAt = now
            }
            tokenCount += 1
            lock.unlock()
        }

        func snapshot() -> (firstTokenAt: Date?, tokenCount: Int) {
            lock.lock()
            let snapshot = (firstTokenAt, tokenCount)
            lock.unlock()
            return snapshot
        }
    }

    func preloadModel(
        modelID: String,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        let normalized = Self.normalizedModelID(modelID)
        if normalized.hasPrefix("external:") {
            try await MLXLocalService.shared.preloadModelFromDirectory(Self.resolveExternalModelDirectory())
        } else {
            try await MLXLocalService.shared.preloadModel(
                modelID: normalized,
                progressHandler: onProgress ?? { _ in }
            )
        }
    }

    func unloadAllModels() async {
        await MLXLocalService.shared.unloadAllModels()
        lastBenchmarkSnapshot = nil
    }

    func resetConversation() async throws {
        // mlx-swift-lm constructs a fresh prompt per generation in this app path.
    }

    func promptFits(
        _ prompt: String,
        maxOutputTokens: Int,
        maxContextTokens configuredContextTokens: Int?
    ) -> Bool {
        let contextBudget = resolvedContextTokens(configuredContextTokens)
        return estimatedTokenCount(for: prompt) + max(1, maxOutputTokens) <= contextBudget
    }

    func generateTextStreaming(
        prompt: String,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens configuredContextTokens: Int?,
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let contextBudget = resolvedContextTokens(configuredContextTokens)
        let promptTokens = estimatedTokenCount(for: prompt)
        let outputBudget = max(1, maxOutputTokens)
        guard promptTokens + outputBudget <= contextBudget else {
            throw Self.contextTooLargeError(
                promptTokens: promptTokens,
                outputTokens: outputBudget,
                contextTokens: contextBudget
            )
        }

        let start = Date()
        let accumulator = ThroughputAccumulator()

        let normalized = Self.normalizedModelID(modelID)
        let result: String
        if normalized.hasPrefix("external:") {
            result = try await MLXLocalService.shared.generateTextStreaming(
                prompt: prompt,
                modelDirectory: Self.resolveExternalModelDirectory(),
                maxOutputTokens: outputBudget,
                maxContextTokens: contextBudget,
                onToken: { token in
                    accumulator.recordToken(now: Date())
                    onToken(token)
                }
            )
        } else {
            result = try await MLXLocalService.shared.generateTextStreaming(
                prompt: prompt,
                modelID: normalized,
                maxOutputTokens: outputBudget,
                maxContextTokens: contextBudget,
                onToken: { token in
                    accumulator.recordToken(now: Date())
                    onToken(token)
                }
            )
        }

        let elapsed = max(Date().timeIntervalSince(start), 0.0001)
        let benchmark = accumulator.snapshot()
        lastBenchmarkSnapshot = BenchmarkSnapshot(
            timeToFirstToken: benchmark.firstTokenAt.map { $0.timeIntervalSince(start) },
            decodeTokensPerSecond: Double(benchmark.tokenCount) / elapsed,
            decodeTokens: benchmark.tokenCount
        )

        return result
    }

    func lastBenchmark() -> BenchmarkSnapshot? {
        lastBenchmarkSnapshot
    }

    private func resolvedContextTokens(_ configured: Int?) -> Int {
        guard let configured, configured > 0 else {
            return Self.defaultContextTokens
        }
        return min(max(512, configured), Self.maxContextTokens)
    }

    private func estimatedTokenCount(for text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    static func normalizedModelID(_ modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultModelRepo }
        if trimmed.hasPrefix("external:") { return trimmed }
        if trimmed.hasPrefix("litert-community/") || trimmed.hasSuffix(".litertlm") {
            return defaultModelRepo
        }
        let lowercased = trimmed.lowercased()
        if lowercased == "mlx-community/gemma4-e2b-it-text-int4"
            || lowercased == "mlx-community/gemma4-e2b-it-int4"
            || lowercased == "mlx-community/gemma-4-e2b-it-text-int4" {
            return defaultModelRepo
        }
        return trimmed
    }

    static func contextTooLargeError(promptTokens: Int, outputTokens: Int, contextTokens: Int) -> NSError {
        NSError(
            domain: contextTooLargeDomain,
            code: 413,
            userInfo: [
                NSLocalizedDescriptionKey: "CoreAI MLX Local context is too small for this request (\(promptTokens + outputTokens) estimated tokens needed, \(contextTokens) available). Choose another provider for this large batch."
            ]
        )
    }

    static func isContextTooLargeError(_ error: Error) -> Bool {
        (error as NSError).domain == contextTooLargeDomain
    }

    private static func resolveExternalModelDirectory() throws -> URL {
        guard let bookmarkData = UserDefaults.standard.data(forKey: externalModelBookmarkKey) else {
            throw NSError(
                domain: "CoreAIMLXBookmark",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "External CoreAI MLX model bookmark not found. Download or reselect the model folder in Settings."]
            )
        }

        var isStale = false
        #if os(iOS)
        let url = try URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #else
        let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        #endif
        guard !isStale else {
            throw NSError(
                domain: "CoreAIMLXBookmark",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "External CoreAI MLX model bookmark is stale. Download or reselect the model folder in Settings."]
            )
        }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) else {
            throw NSError(
                domain: "CoreAIMLXBookmark",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Selected CoreAI MLX model folder is missing config.json."]
            )
        }
        return url
    }
}
