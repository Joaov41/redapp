import SwiftUI

@MainActor
struct ResearchConversationView: View {
    let runID: UUID
    let initialConversationID: UUID?

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

    init(runID: UUID, conversationID: UUID? = nil) {
        self.runID = runID
        self.initialConversationID = conversationID
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if turns.isEmpty {
                        ContentUnavailableView(
                            "Ask About This Batch",
                            systemImage: "bubble.left.and.text.bubble.right",
                            description: Text("Answers stay scoped to the saved posts and comments and retain claim-level citations.")
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
                            Text("Checking the saved sources…")
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
        .navigationTitle("Saved Batch Q&A")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedSource) { source in
            NavigationStack { ResearchSourceDetailView(source: source) }
        }
        .task {
            conversationID = initialConversationID
            reload()
            isInputFocused = turns.isEmpty
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
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask a follow-up about this saved batch", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send question")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        draft = ""
        isSending = true
        errorMessage = nil

        Task {
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

                _ = try store.appendTurn(
                    conversationID: activeConversation.id,
                    role: .user,
                    text: question
                )
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
                Text(turn.role == .user ? "You" : "Grounded answer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                                            Button(citation.sourceID) { openSource(source) }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                                .accessibilityLabel("Open supporting source \(citation.sourceID)")
                                        }
                                    }
                                }
                            }
                            if !claim.conflictingSourceIDs.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        Label("Conflicting evidence", systemImage: "arrow.triangle.branch")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                        ForEach(claim.conflictingSourceIDs, id: \.self) { sourceID in
                                            if let source = sourceForID(sourceID) {
                                                Button(sourceID) { openSource(source) }
                                                    .buttonStyle(.bordered)
                                                    .controlSize(.small)
                                                    .tint(.orange)
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
            .padding(12)
            .background(turn.role == .user ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if turn.role != .user { Spacer(minLength: 24) }
        }
    }
}
