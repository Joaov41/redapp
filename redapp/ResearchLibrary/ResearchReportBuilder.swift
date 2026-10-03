import Foundation

/// Builds the two parts of a saved report that are not created when a batch is
/// saved: the overview of all post summaries and the key points linked to
/// quotes. Builds run here rather than in a view, so leaving the report doesn't
/// cancel them and opening it twice doesn't start a second build.
@MainActor
final class ResearchReportBuilder: ObservableObject {
    static let shared = ResearchReportBuilder()

    enum Phase: Equatable {
        case writingOverview
        case linkingKeyPoints
        case failed(String)

        var statusText: String {
            switch self {
            case .writingOverview: return "Reading every saved post summary…"
            case .linkingKeyPoints: return "Finding key points and linking them to quotes…"
            case .failed(let message): return message
            }
        }

        var isRunning: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    @Published private(set) var phases: [UUID: Phase] = [:]
    /// Reports already built automatically in this session, so a failure isn't
    /// retried every time the report is opened.
    private var automaticAttempts = Set<UUID>()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    private var store: ResearchLibraryStore { .shared }

    func phase(for runID: UUID) -> Phase? {
        phases[runID]
    }

    /// Whether this report is missing parts that can be built from what was saved.
    func needsBuild(_ detail: ResearchRunDetail) -> Bool {
        let artifacts = detail.revisionArtifacts
        let canWriteOverview = artifacts.overallSummary == nil && !artifacts.postSummaries.isEmpty
        let canLinkKeyPoints = artifacts.sourceLinkedReport == nil && !detail.sources.isEmpty
        return canWriteOverview || canLinkKeyPoints
    }

    /// Automatic builds skip Web AI, which needs the person to paste replies.
    var canBuildAutomatically: Bool {
        SummaryService.shared.settings.selectedSummaryProvider != .webAI
    }

    func buildAutomaticallyIfNeeded(_ detail: ResearchRunDetail) {
        let runID = detail.run.id
        guard canBuildAutomatically,
              needsBuild(detail),
              phases[runID] == nil,
              automaticAttempts.insert(runID).inserted else { return }
        build(runID: runID, rebuildKeyPoints: false)
    }

    func build(runID: UUID, rebuildKeyPoints: Bool) {
        guard phases[runID]?.isRunning != true else { return }
        phases[runID] = .writingOverview
        tasks[runID] = Task {
            do {
                let detail = try store.detail(runID: runID)
                let overview = try await ensureOverview(for: detail)
                let refreshed = try store.detail(runID: runID)
                if (rebuildKeyPoints || refreshed.revisionArtifacts.sourceLinkedReport == nil),
                   !refreshed.sources.isEmpty {
                    phases[runID] = .linkingKeyPoints
                    try await createKeyPoints(for: refreshed, guidingOverview: overview?.body)
                }
                phases[runID] = nil
            } catch is CancellationError {
                phases[runID] = nil
            } catch {
                phases[runID] = .failed(error.localizedDescription)
            }
            tasks[runID] = nil
        }
    }

    func dismissFailure(runID: UUID) {
        if case .failed = phases[runID] { phases[runID] = nil }
    }

    // MARK: Overview

    private func ensureOverview(for detail: ResearchRunDetail) async throws -> ResearchArtifactRecord? {
        let artifacts = detail.revisionArtifacts
        if let existing = artifacts.completeOverview ?? artifacts.overallSummary {
            return existing
        }
        let postSummaries = artifacts.postSummaries
        guard !postSummaries.isEmpty else { return nil }

        let service = SummaryService.shared
        let provider = service.settings.selectedSummaryProvider
        let basePrompt = Self.overviewPrompt(from: postSummaries, detail: detail)
        let prompt = provider == .applePCCGateway
            ? basePrompt + "\n\nReturn only a readable overview in plain natural-language Markdown. Do not return JSON, a property list, or a code block."
            : basePrompt
        let startedAt = Date()
        let generated: String
        if provider == .webAI {
            generated = try await AppState.shared.performWebAIRequestAsync(
                title: "Report Overview",
                prompt: prompt
            )
        } else {
            generated = try await service.summarize(text: prompt)
        }
        try Task.checkCancellation()

        let rawBody = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = provider == .applePCCGateway
            ? QuestionAnswerTextFormatter.displayText(from: rawBody)
            : rawBody
        guard !body.isEmpty else { throw GroundedResearchError.invalidResponse }

        // Another build may have finished while the model was working.
        if let existing = try store.detail(runID: detail.run.id).revisionArtifacts.completeOverview {
            return existing
        }
        return try store.addArtifact(
            runID: detail.run.id,
            kind: .overallReport,
            title: "Overall Summary",
            body: body,
            generationReceipt: ResearchGenerationReceiptFactory.make(
                settings: service.settings,
                startedAt: startedAt,
                completedAt: Date(),
                promptVersion: 2,
                responseSchemaVersion: 0
            ),
            coverage: detail.run.coverage,
            legacyUncited: true
        )
    }

    static func overviewPrompt(
        from postSummaries: [ResearchArtifactRecord],
        detail: ResearchRunDetail
    ) -> String {
        let inputBudget = 50_000
        let perSummaryLimit = max(120, min(1_200, inputBudget / max(postSummaries.count, 1)))
        let entries = postSummaries.enumerated().map { index, artifact in
            """
            Post \(index + 1): \(artifact.title)
            Saved summary: \(String(artifact.body.prefix(perSummaryLimit)))
            """
        }.joined(separator: "\n\n---\n\n")

        return """
        Create a complete, plain-language overview of this saved Reddit batch.

        The input contains \(postSummaries.count) saved post summaries. Consider every numbered summary before writing. Combine related posts into themes, explain the overall tone, identify repeated concerns and disagreements, and mention important minority topics so that the result is not based on only a few posts. Do not claim that every user agrees. Do not invent details.

        Start with one short paragraph that a reader could understand on its own. Then use clear Markdown headings and short paragraphs. Do not output a table or a post-by-post list.

        \(entries)
        """
    }

    // MARK: Key points

    private func createKeyPoints(
        for detail: ResearchRunDetail,
        guidingOverview: String?
    ) async throws {
        let result = try await GroundedResearchService.shared.generateReport(
            instruction: "Using the overview only to decide what matters, produce 8 to 12 representative key points. Cover the major recurring themes, meaningful disagreement, and important minority topics. Prefer support from different posts. When a recurring point is supported by multiple posts, cite at least two different posts. Every point and quotation must still be supported by the saved Reddit sources. Do not claim that these linked examples are exhaustive.",
            sources: detail.sources.map(ResearchSourceInput.init(record:)),
            coverage: detail.run.coverage,
            guidingOverview: guidingOverview,
            balanceAcrossPosts: true,
            promptVersion: 4
        )
        try Task.checkCancellation()
        try store.addArtifact(
            runID: detail.run.id,
            kind: .overallReport,
            title: result.response.title,
            body: result.response.markdown,
            generationReceipt: result.receipt,
            coverage: detail.run.coverage,
            conflicts: result.response.conflicts,
            missingData: result.response.missingData,
            claims: result.response.claims
        )
    }
}
