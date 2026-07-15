import Foundation
import SwiftUI

struct ResearchCommunityCompatibility: Codable, Hashable, Sendable {
    let score: Int
    let feedTypesMatch: Bool
    let timeRangesMatch: Bool
    let captureDistanceDays: Int
    let postCountDifference: Int
    let commentCountDifference: Int
    let warnings: [String]

    static func evaluate(
        base: ResearchRunRecord,
        candidate: ResearchRunRecord
    ) -> ResearchCommunityCompatibility {
        let feedTypesMatch = ResearchStoreNormalization.key(base.sortMode) == ResearchStoreNormalization.key(candidate.sortMode)
        let timeRangesMatch = ResearchStoreNormalization.key(base.timeRange) == ResearchStoreNormalization.key(candidate.timeRange)
        let distance = abs(Calendar.current.dateComponents([.day], from: base.capturedAt, to: candidate.capturedAt).day ?? 0)
        let postDifference = abs(base.coverage.postsAnalyzed - candidate.coverage.postsAnalyzed)
        let commentDifference = abs(base.coverage.commentsAnalyzed - candidate.coverage.commentsAnalyzed)
        var value = 100
        var warnings: [String] = []
        if !feedTypesMatch {
            value -= 22
            warnings.append("The batches use different feed types, so Reddit may have surfaced different kinds of posts.")
        }
        if !timeRangesMatch {
            value -= 12
            warnings.append("The batches use different Top time ranges.")
        }
        if distance > 7 {
            value -= min(24, distance / 3)
            warnings.append("The batches were saved \(distance) days apart, so timing may affect the comparison.")
        }
        if postDifference > 10 {
            value -= min(18, postDifference / 2)
            warnings.append("One batch contains \(postDifference) more analyzed posts than the other.")
        }
        let largerComments = max(base.coverage.commentsAnalyzed, candidate.coverage.commentsAnalyzed)
        if largerComments > 0, commentDifference * 2 > largerComments {
            value -= 12
            warnings.append("The amount of comment discussion differs substantially between the batches.")
        }
        if base.state == .partial || candidate.state == .partial {
            value -= 15
            warnings.append("At least one batch has incomplete coverage.")
        }
        return ResearchCommunityCompatibility(
            score: max(0, value),
            feedTypesMatch: feedTypesMatch,
            timeRangesMatch: timeRangesMatch,
            captureDistanceDays: distance,
            postCountDifference: postDifference,
            commentCountDifference: commentDifference,
            warnings: warnings
        )
    }

    static func score(base: ResearchRunRecord, candidate: ResearchRunRecord) -> Int {
        evaluate(base: base, candidate: candidate).score
    }

    var label: String {
        switch score {
        case 82...: return "Strong match"
        case 62...: return "Useful with caveats"
        default: return "Different samples"
        }
    }
}

private enum ResearchStoreNormalization {
    static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ResearchCommunitySourceReference: Hashable, Sendable {
    enum Side: String, Sendable { case first, second }

    let side: Side
    let runID: UUID
    let subreddit: String
    let sourceID: String

    var encodedID: String {
        "community:\(side.rawValue):\(runID.uuidString):\(subreddit):\(sourceID)"
    }

    static func parse(_ value: String) -> ResearchCommunitySourceReference? {
        let components = value.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard components.count == 5,
              components[0] == "community",
              let side = Side(rawValue: String(components[1])),
              let runID = UUID(uuidString: String(components[2])) else { return nil }
        return ResearchCommunitySourceReference(
            side: side,
            runID: runID,
            subreddit: String(components[3]),
            sourceID: String(components[4])
        )
    }
}

struct ResearchCommunityComparisonGenerationResult: Sendable {
    let response: ValidatedGroundedResponse
    let receipt: ResearchGenerationReceiptInput
    let validationSources: [ResearchSourceInput]
    let coverage: ResearchCoverageInput
}

actor ResearchCommunityComparisonService {
    static let shared = ResearchCommunityComparisonService()

    func generate(
        subject: String,
        first: ResearchRunDetail,
        second: ResearchRunDetail,
        question: String? = nil
    ) async throws -> ResearchCommunityComparisonGenerationResult {
        let firstSources = Self.balancedSources(subject: subject, detail: first, side: .first)
        let secondSources = Self.balancedSources(subject: subject, detail: second, side: .second)
        guard !firstSources.isEmpty, !secondSources.isEmpty else {
            throw GroundedResearchError.noSources
        }
        let sources = firstSources + secondSources
        let coverage = combinedCoverage(first.run.coverage, second.run.coverage)
        let firstName = "r/\(first.run.subreddit)"
        let secondName = "r/\(second.run.subreddit)"
        let comparisonInstruction = """
        Compare how two saved subreddit batches discuss this subject: \(subject)

        First community: \(firstName)
        Second community: \(secondName)

        Write in clear everyday language. Do not treat either saved sample as every member of its community. Do not use added/removed-post language or score-difference analysis. Return 5 to 9 concise claims, using these claimType values so the app can organize the answer:
        - common_ground: views or concerns supported in both communities; cite both sides.
        - first_community: how \(firstName) discusses the subject.
        - second_community: how \(secondName) discusses the subject.
        - biggest_difference: a direct contrast; cite both sides.
        - internal_disagreement: disagreement within either community.

        A common_ground or biggest_difference claim must contain evidence from both saved batches. If one side lacks evidence for a direct comparison, do not guess; explain that in missingData. Every factual claim must cite the supplied saved post or comment IDs. Focus only on the requested subject.
        """
        let instruction: String
        if let question = question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
            instruction = """
            Answer this follow-up question using only the two saved subreddit batches: \(question)

            Original comparison subject: \(subject)
            First community: \(firstName)
            Second community: \(secondName)

            Give a direct everyday-language answer in 2 to 5 concise claims. Use claimType first_community or second_community for a point supported by only one side. Use common_ground or biggest_difference only for a direct two-community statement, and cite evidence from both sides for those claim types. If the saved evidence cannot answer the question, say so in missingData. Every factual claim must cite a supplied saved post or comment ID.
            """
        } else {
            instruction = comparisonInstruction
        }
        let guidance = guidanceText(first: first, second: second)
        let generated = try await GroundedResearchService.shared.generateReport(
            instruction: instruction,
            sources: sources,
            coverage: coverage,
            guidingOverview: guidance,
            balanceAcrossPosts: false,
            maximumSourceCharacters: 26_000,
            promptVersion: 4
        )
        let checked = Self.enforceTwoSidedComparisons(generated.response)
        return ResearchCommunityComparisonGenerationResult(
            response: checked,
            receipt: generated.receipt,
            validationSources: sources,
            coverage: coverage
        )
    }

    static func balancedSources(
        subject: String,
        detail: ResearchRunDetail,
        side: ResearchCommunitySourceReference.Side
    ) -> [ResearchSourceInput] {
        let selected = GroundedResearchService.representativeSources(
            for: subject,
            from: detail.sources.map(ResearchSourceInput.init(record:)),
            characterBudget: 11_500
        )
        return selected.map { source in
            func encode(_ sourceID: String) -> String {
                ResearchCommunitySourceReference(
                    side: side,
                    runID: detail.run.id,
                    subreddit: detail.run.subreddit,
                    sourceID: sourceID
                ).encodedID
            }
            return ResearchSourceInput(
                sourceID: encode(source.sourceID),
                kind: source.kind,
                postSourceID: encode(source.postSourceID),
                parentSourceID: source.parentSourceID.map(encode),
                subreddit: source.subreddit,
                title: source.title,
                permalink: source.permalink,
                author: source.author,
                score: source.score,
                createdAt: source.createdAt,
                depth: source.depth,
                rawMarkdown: source.rawMarkdown,
                mediaURLs: source.mediaURLs,
                sourceOrder: source.sourceOrder
            )
        }
    }

    static func enforceTwoSidedComparisons(
        _ response: ValidatedGroundedResponse
    ) -> ValidatedGroundedResponse {
        var omitted: [String] = []
        let claims = response.claims.filter { claim in
            let type = claim.claimType.lowercased()
            guard type == "common_ground" || type == "biggest_difference" else { return true }
            let sides = Set(claim.citations.compactMap {
                ResearchCommunitySourceReference.parse($0.sourceID)?.side
            })
            guard sides.contains(.first), sides.contains(.second) else {
                omitted.append("A direct comparison was left out because it did not include supporting material from both communities.")
                return false
            }
            return true
        }
        return ValidatedGroundedResponse(
            title: response.title,
            overview: response.overview,
            claims: claims,
            conflicts: response.conflicts,
            missingData: response.missingData + Array(Set(omitted))
        )
    }

    private func guidanceText(first: ResearchRunDetail, second: ResearchRunDetail) -> String? {
        [first, second].compactMap { detail -> String? in
            guard let summary = detail.revisionArtifacts.overallSummary else { return nil }
            let compact = summary.body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return "r/\(detail.run.subreddit): \(String(compact.prefix(3_000)))"
        }.joined(separator: "\n\n").nilIfBlank
    }

    private func combinedCoverage(
        _ first: ResearchCoverageInput,
        _ second: ResearchCoverageInput
    ) -> ResearchCoverageInput {
        first.combined(with: second)
    }
}

@MainActor
struct ResearchCommunityComparisonPickerView: View {
    let baseRunID: UUID
    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var baseRun: ResearchRunRecord?
    @State private var candidates: [ResearchRunRecord] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let baseRun {
                Section("First community") { snapshotRow(baseRun, compatibility: nil) }
                Section {
                    if candidates.isEmpty {
                        ContentUnavailableView(
                            "No Other Communities Saved",
                            systemImage: "person.2.slash",
                            description: Text("Save a batch from another subreddit, then return here to compare it.")
                        )
                    } else {
                        ForEach(candidates) { candidate in
                            NavigationLink(value: ResearchLibraryRoute.communitySetup(
                                firstRunID: baseRun.id,
                                secondRunID: candidate.id
                            )) {
                                snapshotRow(
                                    candidate,
                                    compatibility: ResearchCommunityCompatibility.evaluate(
                                        base: baseRun,
                                        candidate: candidate
                                    )
                                )
                            }
                        }
                    }
                } header: {
                    Text("Choose another community")
                } footer: {
                    Text("Best-matched saved batches appear first. You can still use a comparison with caveats.")
                }
            } else { ProgressView() }
        }
        .navigationTitle("Compare Communities")
        .task { load() }
        .alert("Comparison unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func snapshotRow(
        _ run: ResearchRunRecord,
        compatibility: ResearchCommunityCompatibility?
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("r/\(run.subreddit)").font(.headline)
                Spacer()
                if let compatibility {
                    Text(compatibility.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(compatibility.score >= 82 ? .green : .orange)
                }
            }
            Text(ResearchCaptureLabel.displayName(sortMode: run.sortMode, timeRange: run.timeRange))
                .font(.subheadline)
            Text("\(run.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(run.coverage.postsAnalyzed) posts · \(run.coverage.commentsAnalyzed) comments")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func load() {
        do {
            baseRun = try store.run(id: baseRunID)
            candidates = try store.communityComparisonRuns(for: baseRunID)
        } catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
struct ResearchCommunityComparisonSetupView: View {
    let firstRunID: UUID
    let secondRunID: UUID
    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var first: ResearchRunRecord?
    @State private var second: ResearchRunRecord?
    @State private var subject = ""
    @State private var errorMessage: String?
    @Environment(\.researchLibraryNavigate) private var navigate

    private var trimmedSubject: String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            if let first, let second {
                Section("Communities") {
                    LabeledContent("First", value: "r/\(first.subreddit)")
                    LabeledContent("Second", value: "r/\(second.subreddit)")
                }
                Section("Subject to compare") {
                    TextField("For example: pricing, moderation, or model quality", text: $subject, axis: .vertical)
                    Text("The comparison will stay focused on this subject instead of trying to compare everything in both subreddits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let compatibility = ResearchCommunityCompatibility.evaluate(base: first, candidate: second)
                Section("Comparison quality") {
                    LabeledContent("Match", value: compatibility.label)
                    LabeledContent("Feed type", value: compatibility.feedTypesMatch ? "Same" : "Different")
                    LabeledContent("Saved", value: compatibility.captureDistanceDays == 0 ? "Same day" : "\(compatibility.captureDistanceDays) days apart")
                    if !compatibility.warnings.isEmpty {
                        DisclosureGroup("Things to keep in mind") {
                            ForEach(compatibility.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "info.circle")
                                    .font(.caption)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        createComparison(first: first, second: second, compatibility: compatibility)
                    } label: {
                        Label("Compare how they discuss this", systemImage: "person.2.wave.2")
                    }
                    .disabled(trimmedSubject.count < 3)
                }
            } else { ProgressView() }
        }
        .navigationTitle("Choose a Subject")
        .task { load() }
        .alert("Comparison unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func load() {
        do {
            first = try store.run(id: firstRunID)
            second = try store.run(id: secondRunID)
        } catch { errorMessage = error.localizedDescription }
    }

    private func createComparison(
        first: ResearchRunRecord,
        second: ResearchRunRecord,
        compatibility: ResearchCommunityCompatibility
    ) {
        do {
            let record = try store.createCommunityComparison(
                leftRunID: first.id,
                rightRunID: second.id,
                subject: trimmedSubject,
                compatibilityJSON: ResearchJSON.encode(compatibility)
            )
            navigate(.communityComparison(id: record.id))
        } catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
struct ResearchCommunityComparisonView: View {
    let comparisonID: UUID
    @ObservedObject private var store = ResearchLibraryStore.shared
    @ObservedObject private var jobs = ResearchComparisonGenerationCoordinator.shared
    @Environment(\.researchLibraryMinimizeAction) private var minimizeResearchLibrary
    @State private var record: ResearchCommunityComparisonRecord?
    @State private var first: ResearchRunDetail?
    @State private var second: ResearchRunDetail?
    @State private var artifact: ResearchArtifactRecord?
    @State private var claims: [ResearchClaimRecord] = []
    @State private var followUpArtifacts: [ResearchArtifactRecord] = []
    @State private var followUpClaims: [UUID: [ResearchClaimRecord]] = [:]
    @State private var citations: [UUID: [ResearchCitationRecord]] = [:]
    @State private var question = ""
    @State private var isAskingQuestion = false
    @State private var selectedSource: ResearchSourceRecord?
    @State private var showCompatibility = false
    @State private var errorMessage: String?

    private var jobKey: String { "community:\(comparisonID.uuidString)" }
    private var job: ResearchComparisonGenerationState? { jobs.state(for: jobKey) }

    var body: some View {
        List {
            if let record, let first, let second {
                Section("Compared communities") {
                    communityRow(first)
                    communityRow(second)
                    if let compatibility = ResearchJSON.decode(
                        ResearchCommunityCompatibility.self,
                        from: record.compatibilityJSON
                    ) {
                        DisclosureGroup(isExpanded: $showCompatibility) {
                            LabeledContent("Feed types", value: compatibility.feedTypesMatch ? "Same" : "Different")
                            LabeledContent("Saved", value: compatibility.captureDistanceDays == 0 ? "Same day" : "\(compatibility.captureDistanceDays) days apart")
                            ForEach(compatibility.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "info.circle")
                                    .font(.caption)
                            }
                        } label: {
                            Label(compatibility.label, systemImage: "checkmark.circle")
                        }
                    }
                }

                if let artifact {
                    reportSections(artifact: artifact, first: first, second: second)
                    followUpSection(record: record, first: first, second: second)
                    Section("Share") {
                        ShareLink(item: exportText(record: record, first: first, second: second)) {
                            Label("Share or export comparison", systemImage: "square.and.arrow.up")
                        }
                    }
                } else if let job, job.phase == .running {
                    Section("Creating comparison") {
                        ProgressView(value: job.progress)
                        Text(job.status).foregroundStyle(.secondary)
                        Button {
                            minimizeResearchLibrary()
                        } label: {
                            Label("Minimize and continue browsing", systemImage: "chevron.down")
                        }
                    }
                } else if record.state == .failed {
                    Section("Could not finish") {
                        Text(record.failureMessage ?? "The comparison did not finish.")
                        Button("Try again") { startGeneration(record: record, first: first, second: second) }
                    }
                } else {
                    Section { ProgressView("Preparing comparison…") }
                }
            } else { ProgressView() }
        }
        .navigationTitle(record.map { "\($0.subject)" } ?? "Community Comparison")
        .sheet(item: $selectedSource) { source in
            NavigationStack { ResearchSourceDetailView(source: source) }
        }
        .task { loadAndStartIfNeeded() }
        .onChange(of: job?.phase) { _, phase in
            if phase == .completed || phase == .failed { load() }
        }
        .alert("Community comparison", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func communityRow(_ detail: ResearchRunDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("r/\(detail.run.subreddit)").font(.headline)
            Text("\(ResearchCaptureLabel.displayName(sortMode: detail.run.sortMode, timeRange: detail.run.timeRange)) · \(detail.run.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(detail.run.coverage.postsAnalyzed) posts · \(detail.run.coverage.commentsAnalyzed) comments analyzed")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func followUpSection(
        record: ResearchCommunityComparisonRecord,
        first: ResearchRunDetail,
        second: ResearchRunDetail
    ) -> some View {
        Section {
            TextField("Ask a follow-up question", text: $question, axis: .vertical)
            Button {
                askFollowUp(record: record, first: first, second: second)
            } label: {
                if isAskingQuestion {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Checking both saved batches…")
                    }
                } else {
                    Label("Ask using the same saved evidence", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
            .disabled(isAskingQuestion || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            ForEach(followUpArtifacts) { answer in
                followUpAnswer(answer)
            }
        } header: {
            Text("Ask about both communities")
        } footer: {
            Text("Answers stay limited to these two saved batches and retain their source links.")
        }
    }

    private func followUpAnswer(_ answer: ResearchArtifactRecord) -> some View {
        let prefix = "Community Q&A [\(comparisonID.uuidString)]: "
        return DisclosureGroup(answer.title.replacingOccurrences(of: prefix, with: "")) {
            ForEach(followUpClaims[answer.id] ?? []) { claim in
                claimView(claim)
            }
            ForEach(answer.missingData, id: \.self) { note in
                Label(note, systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func reportSections(
        artifact: ResearchArtifactRecord,
        first: ResearchRunDetail,
        second: ResearchRunDetail
    ) -> some View {
        let groups: [(String, [String])] = [
            ("Common ground", ["common_ground"]),
            ("How r/\(first.run.subreddit) discusses it", ["first_community"]),
            ("How r/\(second.run.subreddit) discusses it", ["second_community"]),
            ("Biggest differences", ["biggest_difference"]),
            ("Disagreements inside the communities", ["internal_disagreement"]),
            ("Other supported points", ["finding"])
        ]
        ForEach(groups, id: \.0) { title, types in
            let matching = claims.filter { types.contains($0.claimType.lowercased()) }
            if !matching.isEmpty {
                Section(title) {
                    ForEach(matching) { claim in claimView(claim) }
                }
            }
        }
        if !artifact.conflicts.isEmpty {
            Section("Where the evidence conflicts") {
                ForEach(artifact.conflicts, id: \.self) { Text($0) }
            }
        }
        if !artifact.missingData.isEmpty {
            Section("What this comparison could not establish") {
                ForEach(artifact.missingData, id: \.self) { Text($0) }
            }
        }
    }

    private func claimView(_ claim: ResearchClaimRecord) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(claim.text).fixedSize(horizontal: false, vertical: true)
            Text(evidenceLabel(claim.confidence))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let claimCitations = citations[claim.id] ?? []
            ForEach(claimCitations) { citation in
                Button {
                    openSource(citation.sourceID)
                } label: {
                    Label(sourceLabel(citation.sourceID), systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
            if let note = claim.missingDataNote, !note.isEmpty {
                Label(note, systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func evidenceLabel(_ confidence: ResearchEvidenceConfidence) -> String {
        switch confidence {
        case .high: return "Supported by several saved sources"
        case .medium: return "Supported by more than one saved source"
        case .low: return "Limited saved evidence"
        case .unverified: return "Not enough saved evidence"
        }
    }

    private func sourceLabel(_ encodedID: String) -> String {
        guard let reference = ResearchCommunitySourceReference.parse(encodedID) else { return encodedID }
        return "r/\(reference.subreddit) · \(reference.sourceID)"
    }

    private func openSource(_ encodedID: String) {
        do {
            guard let reference = ResearchCommunitySourceReference.parse(encodedID) else { return }
            selectedSource = try store.source(runID: reference.runID, sourceID: reference.sourceID)
            if selectedSource == nil { errorMessage = "The saved supporting source is unavailable." }
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadAndStartIfNeeded() {
        load()
        guard let record, let first, let second, artifact == nil else { return }
        let needsStart = record.state == .preparing
            || (record.state == .running && job?.phase != .running)
        guard needsStart else { return }
        startGeneration(record: record, first: first, second: second)
    }

    private func load() {
        do {
            guard let loadedRecord = try store.communityComparison(id: comparisonID) else {
                throw ResearchStoreError.runNotFound
            }
            record = loadedRecord
            first = try store.detail(runID: loadedRecord.leftRunID)
            second = try store.detail(runID: loadedRecord.rightRunID)
            if let artifactID = loadedRecord.artifactID,
               let loadedArtifact = try store.artifacts(runID: loadedRecord.leftRunID).first(where: { $0.id == artifactID }) {
                let allArtifacts = try store.artifacts(runID: loadedRecord.leftRunID)
                artifact = loadedArtifact
                claims = try store.claims(artifactID: artifactID)
                let prefix = "Community Q&A [\(comparisonID.uuidString)]: "
                followUpArtifacts = allArtifacts.filter {
                    $0.kind == .questionAnswer && $0.title.hasPrefix(prefix)
                }.sorted { $0.createdAt > $1.createdAt }
                followUpClaims = try followUpArtifacts.reduce(into: [:]) { result, answer in
                    result[answer.id] = try store.claims(artifactID: answer.id)
                }
                let allClaims = claims + followUpClaims.values.flatMap { $0 }
                citations = try allClaims.reduce(into: [:]) { result, claim in
                    result[claim.id] = try store.citations(claimID: claim.id).filter(\.validated)
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func askFollowUp(
        record: ResearchCommunityComparisonRecord,
        first: ResearchRunDetail,
        second: ResearchRunDetail
    ) {
        let askedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !askedQuestion.isEmpty, !isAskingQuestion else { return }
        isAskingQuestion = true
        Task {
            do {
                let generated = try await ResearchCommunityComparisonService.shared.generate(
                    subject: record.subject,
                    first: first,
                    second: second,
                    question: askedQuestion
                )
                _ = try store.addArtifact(
                    runID: first.run.id,
                    kind: .questionAnswer,
                    title: "Community Q&A [\(comparisonID.uuidString)]: \(askedQuestion)",
                    body: generated.response.markdown,
                    generationReceipt: generated.receipt,
                    coverage: generated.coverage,
                    conflicts: generated.response.conflicts,
                    missingData: generated.response.missingData,
                    claims: generated.response.claims,
                    validationSources: generated.validationSources
                )
                question = ""
                load()
            } catch {
                errorMessage = error.localizedDescription
            }
            isAskingQuestion = false
        }
    }

    private func startGeneration(
        record: ResearchCommunityComparisonRecord,
        first: ResearchRunDetail,
        second: ResearchRunDetail
    ) {
        guard jobs.begin(
            key: jobKey,
            leftRunID: first.run.id,
            rightRunID: second.run.id,
            communityComparisonID: record.id,
            title: "Comparing r/\(first.run.subreddit) and r/\(second.run.subreddit)",
            status: "Selecting balanced evidence from both communities…",
            progress: 0.08
        ) else { return }
        try? store.updateCommunityComparison(id: record.id, state: .running)
#if os(iOS)
        let backgroundHandle = GeminiBackgroundTaskManager.shared.beginLongRunningTask(
            identifier: .summarization,
            title: "Comparing two communities"
        )
        BatchSummaryLiveActivityController.shared.start(subreddit: "Two communities", totalPosts: 4)
#endif
        let task = Task {
            var succeeded = false
            defer {
#if os(iOS)
                backgroundHandle.finish(success: succeeded)
#endif
            }
            do {
#if os(iOS)
                await backgroundHandle.waitForTaskStartIfNeeded()
#endif
                jobs.update(key: jobKey, status: "Reading both saved batches…", progress: 0.24)
#if os(iOS)
                backgroundHandle.reportProgress(fractionCompleted: 0.24)
                BatchSummaryLiveActivityController.shared.update(status: "Reading both communities…", processedPosts: 1, totalPosts: 4, progress: 0.24)
#endif
                if SummaryService.shared.settings.selectedSummaryProvider == .summarizeDaemon {
                    try await SummaryService.shared.testSummarizeDaemonConnection()
                }
                jobs.update(key: jobKey, status: "Writing the plain-language comparison…", progress: 0.45)
#if os(iOS)
                backgroundHandle.reportProgress(fractionCompleted: 0.45)
                BatchSummaryLiveActivityController.shared.update(status: "Writing comparison…", processedPosts: 2, totalPosts: 4, progress: 0.45)
#endif
                let generated = try await ResearchCommunityComparisonService.shared.generate(
                    subject: record.subject,
                    first: first,
                    second: second
                )
                try Task.checkCancellation()
                jobs.update(key: jobKey, status: "Checking source links and saving…", progress: 0.9)
#if os(iOS)
                backgroundHandle.reportProgress(fractionCompleted: 0.9)
#endif
                let saved = try store.addArtifact(
                    runID: first.run.id,
                    kind: .communityComparison,
                    title: "\(record.subject): r/\(first.run.subreddit) and r/\(second.run.subreddit)",
                    body: generated.response.markdown,
                    generationReceipt: generated.receipt,
                    coverage: generated.coverage,
                    conflicts: generated.response.conflicts,
                    missingData: generated.response.missingData,
                    claims: generated.response.claims,
                    validationSources: generated.validationSources
                )
                try store.updateCommunityComparison(id: record.id, state: .ready, artifactID: saved.id)
                succeeded = true
                jobs.complete(key: jobKey, status: "Community comparison ready")
#if os(iOS)
                BatchSummaryLiveActivityController.shared.end(with: "Community comparison ready", processedPosts: 4, totalPosts: 4)
#endif
            } catch {
                let message = error.localizedDescription
                try? store.updateCommunityComparison(id: record.id, state: .failed, failureMessage: message)
                jobs.fail(key: jobKey, message: message)
#if os(iOS)
                BatchSummaryLiveActivityController.shared.cancel(reason: "Community comparison needs attention", processedPosts: 0, totalPosts: 4)
#endif
            }
        }
        jobs.attach(task, to: jobKey)
#if os(iOS)
        backgroundHandle.registerCancellationHandler { task.cancel() }
#endif
    }

    private func exportText(
        record: ResearchCommunityComparisonRecord,
        first: ResearchRunDetail,
        second: ResearchRunDetail
    ) -> String {
        var text = "# \(record.subject): r/\(first.run.subreddit) and r/\(second.run.subreddit)\n\n"
        text += "- r/\(first.run.subreddit): \(first.run.coverage.postsAnalyzed) posts, \(first.run.coverage.commentsAnalyzed) comments analyzed\n"
        text += "- r/\(second.run.subreddit): \(second.run.coverage.postsAnalyzed) posts, \(second.run.coverage.commentsAnalyzed) comments analyzed\n\n"
        for claim in claims {
            let refs = (citations[claim.id] ?? []).map { "[\(sourceLabel($0.sourceID))]" }.joined(separator: " ")
            text += "- \(claim.text) \(refs)\n"
        }
        for answer in followUpArtifacts.reversed() {
            let questionTitle = answer.title.replacingOccurrences(
                of: "Community Q&A [\(comparisonID.uuidString)]: ",
                with: ""
            )
            text += "\n## Follow-up: \(questionTitle)\n\n"
            for claim in followUpClaims[answer.id] ?? [] {
                let refs = (citations[claim.id] ?? []).map { "[\(sourceLabel($0.sourceID))]" }.joined(separator: " ")
                text += "- \(claim.text) \(refs)\n"
            }
        }
        if let artifact, !artifact.missingData.isEmpty {
            text += "\n## What this comparison could not establish\n\n"
            text += artifact.missingData.map { "- \($0)" }.joined(separator: "\n")
        }
        return text
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
