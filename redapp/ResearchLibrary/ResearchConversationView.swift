import SwiftUI

@MainActor
struct ResearchConversationView: View {
    let runID: UUID
    let initialConversationID: UUID?
    /// A question typed elsewhere (the briefing's Ask bar) to send on open.
    let initialQuestion: String?

    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var conversationID: UUID?
    @State private var turns: [ResearchConversationTurnRecord] = []
    @State private var draft = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var claimsByTurn: [UUID: [ResearchClaimRecord]] = [:]
    @State private var citationsByClaim: [UUID: [ResearchCitationRecord]] = [:]
    @State private var selectedSource: ResearchSourceRecord?
    @FocusState private var isInputFocused: Bool

    init(runID: UUID, conversationID: UUID? = nil, initialQuestion: String? = nil) {
        self.runID = runID
        self.initialConversationID = conversationID
        self.initialQuestion = initialQuestion
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if turns.isEmpty {
                        ContentUnavailableView(
                            "Ask About This Report",
                            systemImage: "bubble.left.and.text.bubble.right",
                            description: Text("Answers use only the saved posts and comments, and each point links to the quotes behind it.")
                        )
                        .padding(.top, 60)
                    }
                    ForEach(turns) { turn in
                        ResearchConversationTurnView(
                            turn: turn,
                            claims: claimsByTurn[turn.id] ?? [],
                            citationsByClaim: citationsByClaim,
                            sourceForID: source,
                            openSource: { selectedSource = $0 }
                        )
                        .id(turn.id)
                    }
                    if isSending {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Reading the saved posts and checking quotes…")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                inputBar
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.count) { _, _ in
                guard let lastID = turns.last?.id else { return }
                withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
            }
        }
        .background(RedappDesign.canvas)
        .navigationTitle("Ask")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedSource) { source in
            NavigationStack { ResearchSourceDetailView(source: source) }
        }
        .task {
            conversationID = initialConversationID
            reload()
            if let initialQuestion,
               turns.isEmpty,
               !initialQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = initialQuestion
                send()
            } else {
                isInputFocused = turns.isEmpty
            }
        }
        .alert("Couldn’t Answer", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var inputBar: some View {
        RedappAskBar(
            placeholder: "Ask a follow-up about this research…",
            text: $draft,
            isBusy: isSending,
            onSubmit: send
        )
        .focused($isInputFocused)
        .frame(maxWidth: RedappDesign.reportWidth)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(RedappDesign.canvas.opacity(0.94))
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        draft = ""
        isSending = true
        errorMessage = nil

        Task {
            var askedTurnID: UUID?
            do {
                let detail = try store.detail(runID: runID)
                let activeConversation: ResearchConversationRecord
                if let conversationID,
                   let existing = try store.conversation(id: conversationID) {
                    activeConversation = existing
                } else {
                    activeConversation = try store.createConversation(
                        runID: runID,
                        title: String(question.prefix(80))
                    )
                    conversationID = activeConversation.id
                }

                askedTurnID = try store.appendTurn(
                    conversationID: activeConversation.id,
                    role: .user,
                    text: question
                ).id
                reload()

                let priorContext = turns.suffix(10).map {
                    "\($0.role.rawValue.uppercased()): \($0.text)"
                }.joined(separator: "\n")
                let result = try await GroundedResearchService.shared.generateReport(
                    instruction: "Answer this follow-up question: \(question)",
                    sources: detail.sources.map(ResearchSourceInput.init(record:)),
                    coverage: detail.run.coverage,
                    conversationContext: priorContext
                )
                let artifact = try store.addArtifact(
                    runID: runID,
                    kind: .conversationAnswer,
                    title: result.response.title,
                    body: result.response.markdown,
                    generationReceipt: result.receipt,
                    coverage: detail.run.coverage,
                    conflicts: result.response.conflicts,
                    missingData: result.response.missingData,
                    claims: result.response.claims
                )
                _ = try store.appendTurn(
                    conversationID: activeConversation.id,
                    role: .assistant,
                    text: result.response.markdown,
                    artifactID: artifact.id,
                    generationReceipt: result.receipt
                )
                reload()
            } catch {
                // Don't leave a question without an answer; give it back to edit.
                if let askedTurnID {
                    try? store.deleteTurn(id: askedTurnID)
                    if let conversationID, (try? store.conversation(id: conversationID)) == nil {
                        self.conversationID = nil
                    }
                    reload()
                }
                if draft.isEmpty { draft = question }
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    private func reload() {
        guard let conversationID else {
            turns = []
            claimsByTurn = [:]
            citationsByClaim = [:]
            return
        }
        do {
            turns = try store.turns(conversationID: conversationID)
            var mappedClaims: [UUID: [ResearchClaimRecord]] = [:]
            var mappedCitations: [UUID: [ResearchCitationRecord]] = [:]
            for turn in turns {
                guard let artifactID = turn.artifactID else { continue }
                let claims = try store.claims(artifactID: artifactID)
                mappedClaims[turn.id] = claims
                for claim in claims {
                    mappedCitations[claim.id] = try store.citations(claimID: claim.id)
                        .filter(\.validated)
                }
            }
            claimsByTurn = mappedClaims
            citationsByClaim = mappedCitations
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func source(_ sourceID: String) -> ResearchSourceRecord? {
        try? store.source(runID: runID, sourceID: sourceID)
    }
}

@MainActor
private struct ResearchConversationTurnView: View {
    let turn: ResearchConversationTurnRecord
    let claims: [ResearchClaimRecord]
    let citationsByClaim: [UUID: [ResearchCitationRecord]]
    let sourceForID: (String) -> ResearchSourceRecord?
    let openSource: (ResearchSourceRecord) -> Void

    var body: some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                RedappEyebrow(turn.role == .user ? "You" : "Answer",
                              color: turn.role == .user ? RedappDesign.accent : RedappDesign.inkSecondary)
                if claims.isEmpty {
                    Text(turn.text)
                        .textSelection(.enabled)
                } else {
                    ForEach(claims) { claim in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(claim.text)
                                .textSelection(.enabled)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ResearchConfidenceBadge(confidence: claim.confidence)
                                    ForEach(citationsByClaim[claim.id] ?? []) { citation in
                                        if let source = sourceForID(citation.sourceID) {
                                            let label = ResearchSourceLabel.text(for: source, quote: citation.supportingQuote)
                                            Button(label) { openSource(source) }
                                                .buttonStyle(RedappChipButtonStyle())
                                                .accessibilityLabel("Open the quote from \(label)")
                                        }
                                    }
                                }
                            }
                            if !claim.conflictingSourceIDs.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        Label("Sources disagree", systemImage: "arrow.triangle.branch")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                        ForEach(claim.conflictingSourceIDs, id: \.self) { sourceID in
                                            if let source = sourceForID(sourceID) {
                                                Button(ResearchSourceLabel.text(for: source)) { openSource(source) }
                                                    .buttonStyle(RedappChipButtonStyle(isFilled: false))
                                            }
                                        }
                                    }
                                }
                            }
                            if let missing = claim.missingDataNote, !missing.isEmpty {
                                Label(missing, systemImage: "questionmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        if claim.id != claims.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(14)
            .foregroundStyle(RedappDesign.ink)
            .background(
                RoundedRectangle(cornerRadius: RedappDesign.Radius.large, style: .continuous)
                    .fill(turn.role == .user ? RedappDesign.accentSoft : RedappDesign.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RedappDesign.Radius.large, style: .continuous)
                    .strokeBorder(turn.role == .user ? Color.clear : RedappDesign.hairline, lineWidth: 1)
            )
            if turn.role != .user { Spacer(minLength: 24) }
        }
    }
}
