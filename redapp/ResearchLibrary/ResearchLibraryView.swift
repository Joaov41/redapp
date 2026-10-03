import AVFoundation
import SwiftUI

struct ResearchLibraryMinimizeActionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var researchLibraryMinimizeAction: () -> Void {
        get { self[ResearchLibraryMinimizeActionKey.self] }
        set { self[ResearchLibraryMinimizeActionKey.self] = newValue }
    }
}

extension View {
    func researchLibraryExperimentalGlassSurface() -> some View {
        modifier(ResearchLibraryExperimentalGlassSurfaceModifier())
    }
}

private struct ResearchLibraryExperimentalGlassSurfaceModifier: ViewModifier {
    @AppStorage("experimentalSettingsGlassEnabled") private var experimentalAppGlassEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        // Every library list sits on the app's reading canvas.
        content
            .scrollContentBackground(.hidden)
            .background(RedappDesign.canvas)
    }
}

enum ResearchLibraryRoute: Hashable {
    case item(id: UUID)
    case run(id: UUID)
    case artifact(runID: UUID, artifactID: UUID)
    case comparison(leftRunID: UUID, rightRunID: UUID)
    case communitySetup(firstRunID: UUID, secondRunID: UUID)
    case communityComparison(id: UUID)
    case conversation(runID: UUID, conversationID: UUID?)
    case ask(runID: UUID, question: String)
    case sources(runID: UUID)
    case source(runID: UUID, sourceID: String)
}

private struct ResearchLibraryNavigateActionKey: EnvironmentKey {
    static let defaultValue: (ResearchLibraryRoute) -> Void = { _ in }
}

extension EnvironmentValues {
    var researchLibraryNavigate: (ResearchLibraryRoute) -> Void {
        get { self[ResearchLibraryNavigateActionKey.self] }
        set { self[ResearchLibraryNavigateActionKey.self] = newValue }
    }
}

@MainActor
struct ResearchLibraryView: View {
    let initialComparison: ResearchComparisonGenerationState?
    let onMinimize: () -> Void
    let onClose: () -> Void
    @ObservedObject private var store = ResearchLibraryStore.shared
    @ObservedObject private var comparisonJobs = ResearchComparisonGenerationCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @Binding private var navigationPath: NavigationPath
    @State private var searchText = ""
    @State private var selectedTags = Set<String>()
    @State private var communityComparisons: [ResearchCommunityComparisonRecord] = []
    @State private var communityComparisonPendingDeletion: ResearchCommunityComparisonRecord?
    @State private var itemPendingDeletion: ResearchItemRecord?
    @State private var errorMessage: String?

    /// When embedded in the app shell the library has no sheet chrome
    /// (minimize/close) and the host supplies the NavigationStack.
    let isEmbedded: Bool

    init(
        navigationPath: Binding<NavigationPath>,
        initialComparison: ResearchComparisonGenerationState? = nil,
        isEmbedded: Bool = false,
        onMinimize: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        _navigationPath = navigationPath
        self.initialComparison = initialComparison
        self.isEmbedded = isEmbedded
        self.onMinimize = onMinimize
        self.onClose = onClose
    }

    private var availableTags: [String] {
        Array(Set(store.items.flatMap(\.tags))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

#if os(macOS)
    private var librarySearchText: Binding<String> {
        Binding(
            get: { searchText },
            set: { newValue in
                searchText = newValue
                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !navigationPath.isEmpty {
                    navigationPath = NavigationPath()
                }
            }
        )
    }
#endif

    var body: some View {
        Group {
            if isEmbedded {
                libraryList
            } else {
                NavigationStack(path: $navigationPath) {
                    libraryList
                }
            }
        }
        .environment(\.researchLibraryMinimizeAction, minimize)
        .environment(\.researchLibraryNavigate, { route in
            navigationPath.append(route)
        })
        .task(id: initialComparison?.id) {
            guard let initialComparison, navigationPath.isEmpty else { return }
            if let comparisonID = initialComparison.communityComparisonID {
                navigationPath.append(ResearchLibraryRoute.communityComparison(id: comparisonID))
            } else {
                navigationPath.append(
                    ResearchLibraryRoute.comparison(
                        leftRunID: initialComparison.leftRunID,
                        rightRunID: initialComparison.rightRunID
                    )
                )
            }
        }
    }

    private var libraryList: some View {
            List {
#if os(macOS)
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search saved research", text: librarySearchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .listRowBackground(Color.clear)
#endif
                if let storageFailure = store.storageFailure {
                    Section {
                        RedappInlineMessage(
                            title: "Research Library isn’t saving",
                            message: storageFailure,
                            kind: .error
                        )
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if !comparisonJobs.activeJobs.isEmpty {
                    Section("Comparison in progress") {
                        ForEach(comparisonJobs.activeJobs) { job in
                            NavigationLink(value: job.communityComparisonID.map {
                                ResearchLibraryRoute.communityComparison(id: $0)
                            } ?? ResearchLibraryRoute.comparison(
                                leftRunID: job.leftRunID,
                                rightRunID: job.rightRunID
                            )) {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text(job.title)
                                            .font(.headline)
                                    }
                                    ProgressView(value: job.progress)
                                    Text(job.status)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }

                if !communityComparisons.isEmpty {
                    Section("Community comparisons") {
                        ForEach(communityComparisons) { comparison in
                            NavigationLink(value: ResearchLibraryRoute.communityComparison(id: comparison.id)) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(comparison.subject)
                                        .font(.headline)
                                    if let names = communityNames(for: comparison) {
                                        Text(names)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(comparisonStatus(comparison))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    communityComparisonPendingDeletion = comparison
                                } label: {
                                    Label("Delete Comparison…", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    communityComparisonPendingDeletion = comparison
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if !availableTags.isEmpty {
                    Section("Tags") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(availableTags, id: \.self) { tag in
                                    Button {
                                        if !selectedTags.insert(tag).inserted {
                                            selectedTags.remove(tag)
                                        }
                                    } label: {
                                        Label(tag, systemImage: selectedTags.contains(tag) ? "checkmark.circle.fill" : "tag")
                                    }
                                    .buttonStyle(RedappChipButtonStyle(isFilled: selectedTags.contains(tag)))
                                }
                            }
                        }
                    }
                }

                Section {
                    if store.items.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "No Saved Research" : "No Matches",
                            systemImage: "books.vertical",
                            description: Text(
                                searchText.isEmpty
                                    ? "Summarize a subreddit, then tap Save. Its report, posts and comments will be kept here so you can read, compare and ask about them later."
                                    : "Try a different search or tag filter."
                            )
                        )
                    } else {
                        ForEach(store.items) { item in
                            NavigationLink(value: ResearchLibraryRoute.item(id: item.id)) {
                                ResearchLibraryRow(
                                    item: item,
                                    snapshotCount: (try? store.runs(itemID: item.id).count) ?? 1
                                )
                            }
                            .contextMenu {
                                Button {
                                    perform { try store.setPinned(item.pinnedAt == nil, itemID: item.id) }
                                } label: {
                                    Label(item.pinnedAt == nil ? "Pin" : "Unpin", systemImage: "pin")
                                }
                                Button(role: .destructive) {
                                    itemPendingDeletion = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                // Not `.destructive`: the row stays until the deletion is confirmed.
                                Button {
                                    itemPendingDeletion = item
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(RedappDesign.negative)
                            }
                        }
                    }
                } header: {
                    Text("Saved feeds")
                }
            }
            .researchLibraryExperimentalGlassSurface()
            .listStyle(.insetGrouped)
            .navigationTitle("Research Library")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search reports, posts, comments, authors"
            )
            .modifier(ResearchLibraryDestinations(isEnabled: !isEmbedded))
            .task(id: ResearchSearchRequest(query: searchText, tags: selectedTags)) {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                store.reload(searchText: searchText, tags: selectedTags)
                communityComparisons = (try? store.communityComparisons()) ?? []
            }
            .refreshable {
                store.reload(searchText: searchText, tags: selectedTags)
                communityComparisons = (try? store.communityComparisons()) ?? []
            }
            .alert("Research Library", isPresented: Binding(
                get: { errorMessage != nil || store.lastError != nil },
                set: { if !$0 { errorMessage = nil; store.lastError = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil; store.lastError = nil }
            } message: {
                Text(errorMessage ?? store.lastError ?? "Unknown error")
            }
            .researchItemDeletionConfirmation(item: $itemPendingDeletion) { _ in
                communityComparisons = (try? store.communityComparisons()) ?? []
            }
            .alert("Delete community comparison?", isPresented: Binding(
                get: { communityComparisonPendingDeletion != nil },
                set: { if !$0 { communityComparisonPendingDeletion = nil } }
            )) {
                Button("Cancel", role: .cancel) {
                    communityComparisonPendingDeletion = nil
                }
                Button("Delete", role: .destructive) {
                    deletePendingCommunityComparison()
                }
            } message: {
                Text("This removes the comparison and its generated answers. Both saved feeds stay in the Research Library.")
            }
            // Toolbar items must be attached inside the NavigationStack to render.
            .toolbar {
                if !isEmbedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: minimize) {
                        Label("Minimize", systemImage: "chevron.down")
                    }
                    .accessibilityHint("Keeps the Research Library available while you browse")
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 10) {
                        if comparisonJobs.hasActiveJobs {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Comparison in progress")
                        }
                        Button("Close", action: close)
                            .fontWeight(.semibold)
                    }
                }
                }
            }
    }

    private func minimize() {
        onMinimize()
        dismiss()
    }

    private func close() {
        onClose()
        dismiss()
    }

    private func communityNames(for comparison: ResearchCommunityComparisonRecord) -> String? {
        guard let first = try? store.run(id: comparison.leftRunID),
              let second = try? store.run(id: comparison.rightRunID) else { return nil }
        return "r/\(first.subreddit) and r/\(second.subreddit)"
    }

    private func comparisonStatus(_ comparison: ResearchCommunityComparisonRecord) -> String {
        switch comparison.state {
        case .preparing, .running: return "Comparison in progress"
        case .ready: return "Ready · \(comparison.updatedAt.formatted(date: .abbreviated, time: .shortened))"
        case .failed: return "Needs attention"
        }
    }

    private func deletePendingCommunityComparison() {
        guard let comparison = communityComparisonPendingDeletion else { return }
        communityComparisonPendingDeletion = nil
        let jobKey = "community:\(comparison.id.uuidString)"
        comparisonJobs.cancelAndDismiss(key: jobKey)
        do {
            try store.deleteCommunityComparison(id: comparison.id)
            communityComparisons.removeAll { $0.id == comparison.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { errorMessage = error.localizedDescription }
    }
}

/// Every Research Library route. Applied once to whichever NavigationStack
/// hosts the library (the legacy sheet or the app shell's workspace).
struct ResearchLibraryDestinations: ViewModifier {
    var isEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.navigationDestination(for: ResearchLibraryRoute.self) { route in
                switch route {
                // A saved feed and a single snapshot open the same report screen.
                case .item(let id):
                    ResearchItemBriefingLoader(itemID: id)
                case .run(let id):
                    ResearchBriefingView(runID: id)
                case .artifact(let runID, let artifactID):
                    ResearchSavedArtifactView(runID: runID, artifactID: artifactID)
                case .comparison(let leftRunID, let rightRunID):
                    ResearchComparisonView(leftRunID: leftRunID, rightRunID: rightRunID)
                case .communitySetup(let firstRunID, let secondRunID):
                    ResearchCommunityComparisonSetupView(
                        firstRunID: firstRunID,
                        secondRunID: secondRunID
                    )
                case .communityComparison(let id):
                    ResearchCommunityComparisonView(comparisonID: id)
                case .conversation(let runID, let conversationID):
                    ResearchConversationView(runID: runID, conversationID: conversationID)
                case .ask(let runID, let question):
                    ResearchConversationView(runID: runID, initialQuestion: question)
                case .sources(let runID):
                    ResearchSourcesListView(runID: runID)
                case .source(let runID, let sourceID):
                    ResearchSavedSourceRouteView(runID: runID, sourceID: sourceID)
                }
            }
        } else {
            content
        }
    }
}

private struct ResearchSearchRequest: Equatable {
    let query: String
    let tags: Set<String>
}

@MainActor
private struct ResearchLibraryRow: View {
    let item: ResearchItemRecord
    let snapshotCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.headline)
                Spacer()
                if item.pinnedAt != nil {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Pinned")
                }
            }
            Text(
                (item.subreddit == "home" ? "Home feed" : "r/\(item.subreddit)")
                    + " · "
                    + ResearchCaptureLabel.displayName(scope: item.scope)
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !item.tags.isEmpty {
                Text(item.tags.map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .lineLimit(2)
            }
            Text(
                snapshotCount > 1
                    ? "Saved \(snapshotCount) times · updated \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                    : "Updated \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))"
            )
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// One saved answer or report (a Q&A answer, a "what changed" report, a
/// podcast script…), opened from the report's Ask tab.
@MainActor
private struct ResearchSavedArtifactView: View {
    let runID: UUID
    let artifactID: UUID
    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var detail: ResearchRunDetail?
    @State private var artifact: ResearchArtifactRecord?
    @State private var claims: [ResearchClaimRecord] = []
    @State private var citationsByClaim: [UUID: [ResearchCitationRecord]] = [:]
    @State private var selectedSource: ResearchSourceRecord?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let detail, let artifact {
                ResearchArtifactView(
                    runID: runID,
                    artifact: artifact,
                    claims: claims,
                    citationsByClaim: citationsByClaim,
                    speechAsset: detail.offlineAssets.first {
                        $0.kind == .speech && $0.artifactID == artifact.id && $0.state == .ready
                    },
                    sourceForID: { sourceID in
                        if let reference = ResearchComparisonSourceReference.parse(sourceID),
                           let source = try? store.source(runID: reference.runID, sourceID: reference.sourceID) {
                            return source
                        }
                        return detail.sources.first { $0.sourceID == sourceID }
                    },
                    openSource: { selectedSource = $0 },
                    onOfflineChange: reload,
                    presentation: .expanded,
                    showsSourceLinkNotice: true
                )
            } else {
                ProgressView()
            }
        }
        .researchLibraryExperimentalGlassSurface()
        .navigationTitle(artifact?.kind.displayName ?? "Saved Report")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedSource) { source in
            NavigationStack { ResearchSourceDetailView(source: source) }
        }
        .task { reload() }
        .alert("Research Library", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func reload() {
        do {
            let loaded = try store.detail(runID: runID)
            detail = loaded
            artifact = loaded.artifacts.first { $0.id == artifactID }
            if artifact == nil { errorMessage = "This saved report is no longer available." }
            claims = try store.claims(artifactID: artifactID)
            citationsByClaim = try claims.reduce(into: [:]) { result, claim in
                result[claim.id] = try store.citations(claimID: claim.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct ResearchSourcesListView: View {
    let runID: UUID
    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var sources: [ResearchSourceRecord] = []
    @State private var errorMessage: String?

    var body: some View {
        List(sources) { source in
            NavigationLink(value: ResearchLibraryRoute.source(
                runID: runID,
                sourceID: source.sourceID
            )) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: source.kind == .post ? "doc.text" : "text.bubble")
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.title ?? source.author.map { "u/\($0)" } ?? source.sourceID)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                        Text(source.sourceID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            }
        }
        .researchLibraryExperimentalGlassSurface()
        .navigationTitle("Saved Sources")
        .task {
            do {
                sources = try store.sources(runID: runID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Sources unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }
}

@MainActor
private struct ResearchSavedSourceRouteView: View {
    let runID: UUID
    let sourceID: String
    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var source: ResearchSourceRecord?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let source {
                ResearchSourceDetailView(source: source, showsDoneButton: false)
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                source = try store.source(runID: runID, sourceID: sourceID)
                if source == nil {
                    errorMessage = "The saved source is no longer available."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Source unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }
}

private enum ResearchArtifactPresentation {
    case disclosure
    case expanded
}

private enum ResearchSpeechActivity: Equatable {
    case idle
    case preparing(current: Int, total: Int)
    case playing(current: Int, total: Int)
    case saving(completed: Int, total: Int)

    var isPlayback: Bool {
        switch self {
        case .preparing, .playing: true
        case .idle, .saving: false
        }
    }

    var isBusy: Bool { self != .idle }

    var progress: Double? {
        switch self {
        case .idle:
            nil
        case let .preparing(current, total):
            total > 0 ? Double(max(0, current - 1)) / Double(total) : 0
        case let .playing(current, total):
            total > 0 ? Double(current) / Double(total) : 0
        case let .saving(completed, total):
            total > 0 ? Double(completed) / Double(total) : 0
        }
    }

    var statusText: String? {
        switch self {
        case .idle:
            nil
        case let .preparing(current, total):
            "Preparing \(current) of \(total)"
        case let .playing(current, total):
            "Playing \(current) of \(total)"
        case let .saving(completed, total):
            "Saving \(completed) of \(total)"
        }
    }
}

@MainActor
private struct ResearchArtifactView: View {
    let runID: UUID
    let artifact: ResearchArtifactRecord
    let claims: [ResearchClaimRecord]
    let citationsByClaim: [UUID: [ResearchCitationRecord]]
    let speechAsset: ResearchOfflineAssetRecord?
    let sourceForID: (String) -> ResearchSourceRecord?
    let openSource: (ResearchSourceRecord) -> Void
    let onOfflineChange: () -> Void
    let presentation: ResearchArtifactPresentation
    let showsSourceLinkNotice: Bool
    @State private var speechSaved = false
    @State private var speechError: String?
    @State private var offlineSpeechPlayer: AVAudioPlayer?
    @State private var speechActivity: ResearchSpeechActivity = .idle
    @State private var speechTask: Task<Void, Never>?
    @State private var speechOperationID: UUID?

    var body: some View {
        Group {
            switch presentation {
            case .disclosure:
                DisclosureGroup {
                    artifactContent
                } label: {
                    artifactHeader
                }
            case .expanded:
                VStack(alignment: .leading, spacing: 12) {
                    artifactHeader
                    Divider()
                    artifactContent
                }
                .padding(.vertical, 4)
            }
        }
        .alert("Speech Unavailable", isPresented: Binding(
            get: { speechError != nil },
            set: { if !$0 { speechError = nil } }
        )) {
            Button("OK", role: .cancel) { speechError = nil }
        } message: {
            Text(speechError ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var artifactContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if artifact.legacyUncited && showsSourceLinkNotice {
                Label(
                    "This was written without quotes, so its points can’t open the original posts or comments.",
                    systemImage: "info.circle"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if claims.isEmpty {
                MarkdownTextView(content: displayBody, fontScale: 0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(claims) { claim in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(claim.text)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ResearchConfidenceBadge(confidence: claim.confidence)
                                ForEach((citationsByClaim[claim.id] ?? []).filter(\.validated)) { citation in
                                    if let source = sourceForID(citation.sourceID) {
                                        Button(ResearchSourceLabel.text(for: source, quote: citation.supportingQuote)) {
                                            openSource(source)
                                        }
                                            .buttonStyle(RedappChipButtonStyle())
                                    }
                                }
                            }
                        }
                        if !claim.conflictingSourceIDs.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    Label("Sources disagree", systemImage: "arrow.triangle.branch")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                    ForEach(claim.conflictingSourceIDs, id: \.self) { sourceID in
                                        if let source = sourceForID(sourceID) {
                                            Button(ResearchSourceLabel.text(for: source)) {
                                                openSource(source)
                                            }
                                                .buttonStyle(RedappChipButtonStyle(isFilled: false))
                                        }
                                    }
                                }
                            }
                        }
                        if let note = claim.missingDataNote, !note.isEmpty {
                            Label(note, systemImage: "questionmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                }
                DisclosureGroup("What do the support labels mean?") {
                    Text("They show how many quotes from different posts back up a point. Thin support doesn’t mean a point is wrong: there may be few quotes, they may come from one post, sources may disagree, or some content couldn’t be loaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
            }
            if artifact.kind == .postSummary {
                postSummaryEvidence
            }
            ForEach(artifact.conflicts, id: \.self) {
                Label($0, systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(artifact.missingData, id: \.self) {
                Label(readableMissingData($0), systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayBody: String {
        let body = artifact.kind == .postSummary
            ? ResearchPostSummaryPresentation.displayMarkdown(from: artifact.body)
            : artifact.body
        guard artifactWasGeneratedByPCC else { return body }
        return QuestionAnswerTextFormatter.displayText(from: body)
    }

    private var artifactWasGeneratedByPCC: Bool {
        guard let receipt = artifact.generationReceipt else { return false }
        return [receipt.requestedProvider, receipt.actualProvider, receipt.route]
            .contains { $0.localizedCaseInsensitiveContains("PCC") }
    }

    @ViewBuilder
    private var postSummaryEvidence: some View {
        let sourceIDs = ResearchPostSummaryPresentation.sourceIDs(in: artifact.body)
        let linkedSourceIDs = sourceIDs.filter { sourceForID($0) != nil }
        if !linkedSourceIDs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Evidence from \(linkedSourceIDs.count) saved sources", systemImage: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(linkedSourceIDs, id: \.self) { sourceID in
                            if let source = sourceForID(sourceID) {
                                Button(evidenceLabel(for: source)) {
                                    openSource(source)
                                }
                                .buttonStyle(RedappChipButtonStyle())
                                .help("Open \(sourceID)")
                            }
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func evidenceLabel(for source: ResearchSourceRecord) -> String {
        if source.kind == .post { return "Original post" }
        if let author = source.author, !author.isEmpty { return "u/\(author)" }
        return "Comment"
    }

    private func readableMissingData(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("outside this model request's context budget") {
            return "Only part of the saved material could be used for these linked key points. Use the complete overview and individual post summaries for the full batch."
        }
        return message
    }

    private var artifactHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(artifact.title)
                    .font(.headline)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(artifact.kind.displayName) · \(artifact.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer()
            if SummaryService.shared.settings.localTTSEngine == .kokoro {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 14) {
                        Button {
                            startSpeechPlayback()
                        } label: {
                            Image(systemName: "play.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(speechActivity.isBusy)
                        .accessibilityLabel("Read report aloud")

                        Button {
                            stopSpeechOperation()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Stop report speech")

                        Button {
                            saveSpeechOffline()
                        } label: {
                            Image(systemName: speechSaved || speechAsset != nil ? "checkmark.circle.fill" : "arrow.down.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(speechActivity.isBusy || speechSaved || speechAsset != nil)
                        .accessibilityLabel(
                            speechSaved || speechAsset != nil ? "Spoken version saved offline" : "Save spoken version for offline"
                        )
                    }

                    if let statusText = speechActivity.statusText,
                       let progress = speechActivity.progress {
                        VStack(alignment: .trailing, spacing: 2) {
                            ProgressView(value: progress)
                                .frame(width: 92)
                            Text(statusText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func startSpeechPlayback() {
        stopSpeechOperation()
        let operationID = UUID()
        speechOperationID = operationID
        let settings = SummaryService.shared.settings
        let plainText = MarkdownTextView.extractPlainText(from: displayBody)
        let chunks = KokoroTTSService.shared.speechChunks(from: plainText)

        guard !chunks.isEmpty else {
            speechError = KokoroTTSServiceError.emptyText.localizedDescription
            return
        }

        speechTask = Task {
            do {
                try configureResearchSpeechAudioSession()
                let playbackToken = KokoroTTSService.shared.newPlaybackToken()

                if let speechAsset {
                    speechActivity = .preparing(current: 1, total: 1)
                    let url = try await ResearchOfflinePackManager.shared.localURL(
                        relativePath: speechAsset.relativePath
                    )
                    let data = try Data(contentsOf: url)
                    try await playSpeechData(
                        data,
                        current: 1,
                        total: 1,
                        playbackToken: playbackToken
                    )
                } else {
                    try await playResearchSpeechChunks(
                        chunks,
                        voice: settings.kokoroVoice,
                        speed: Float(settings.kokoroSpeed),
                        playbackToken: playbackToken
                    ) { current, total in
                        speechActivity = .preparing(current: current, total: total)
                    } playData: { data, current, total, token in
                        try await playSpeechData(
                            data,
                            current: current,
                            total: total,
                            playbackToken: token
                        )
                    }
                }
            } catch is CancellationError {
                // Stop is a normal user action.
            } catch {
                if speechOperationID == operationID {
                    speechError = error.localizedDescription
                }
            }
            finishSpeechOperation(operationID)
        }
    }

    private func saveSpeechOffline() {
        stopSpeechOperation()
        let operationID = UUID()
        speechOperationID = operationID
        let settings = SummaryService.shared.settings
        let plainText = MarkdownTextView.extractPlainText(from: displayBody)
        let chunkCount = KokoroTTSService.shared.speechChunks(from: plainText).count

        guard chunkCount > 0 else {
            speechError = KokoroTTSServiceError.emptyText.localizedDescription
            return
        }

        speechActivity = .saving(completed: 0, total: chunkCount)
        speechTask = Task {
            do {
                let data = try await KokoroTTSService.shared.synthesizeChunked(
                    text: plainText,
                    voice: settings.kokoroVoice,
                    speed: Float(settings.kokoroSpeed)
                ) { completed, total in
                    guard speechOperationID == operationID else { return }
                    speechActivity = .saving(completed: completed, total: total)
                }
                try Task.checkCancellation()
                _ = try await ResearchOfflinePackManager.shared.saveSpeech(
                    data,
                    runID: runID,
                    artifactID: artifact.id,
                    voice: settings.kokoroVoice,
                    speed: settings.kokoroSpeed
                )
                guard speechOperationID == operationID else { return }
                speechSaved = true
                onOfflineChange()
            } catch is CancellationError {
                // Leaving the report or stopping the operation cancels a partial save.
            } catch {
                if speechOperationID == operationID {
                    speechError = error.localizedDescription
                }
            }
            finishSpeechOperation(operationID)
        }
    }

    private func configureResearchSpeechAudioSession() throws {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP]
            )
        } catch {
            try audioSession.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
            )
        }
        try audioSession.setActive(true)
        #endif
    }

    private func playSpeechData(
        _ data: Data,
        current: Int,
        total: Int,
        playbackToken: UUID
    ) async throws {
        try Task.checkCancellation()
        guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
            throw CancellationError()
        }
        let player = try AVAudioPlayer(data: data)
        guard player.prepareToPlay() else {
            throw NSError(
                domain: "ResearchLibraryPlayback",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The speech audio could not be prepared for playback."]
            )
        }
        offlineSpeechPlayer = player
        speechActivity = .playing(current: current, total: total)
        guard player.play() else {
            throw NSError(
                domain: "ResearchLibraryPlayback",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The speech audio could not start playing."]
            )
        }

        while player.isPlaying {
            try Task.checkCancellation()
            guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
                player.stop()
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func stopSpeechOperation() {
        speechOperationID = nil
        speechTask?.cancel()
        speechTask = nil
        offlineSpeechPlayer?.stop()
        offlineSpeechPlayer = nil
        KokoroTTSService.shared.cancelPlayback()
        speechActivity = .idle
    }

    private func finishSpeechOperation(_ operationID: UUID) {
        guard speechOperationID == operationID else { return }
        speechOperationID = nil
        speechTask = nil
        offlineSpeechPlayer = nil
        speechActivity = .idle
    }
}

@MainActor
struct ResearchSourceDetailView: View {
    let source: ResearchSourceRecord
    var showsDoneButton = true
    @Environment(\.dismiss) private var dismiss

    private var redditURL: URL? {
        if let url = URL(string: source.permalink), url.scheme != nil { return url }
        return URL(string: "https://www.reddit.com\(source.permalink)")
    }

    var body: some View {
        List {
            Section("Source") {
                LabeledContent("ID", value: source.sourceID)
                LabeledContent("Type", value: source.kind.rawValue.capitalized)
                if let author = source.author { LabeledContent("Author", value: "u/\(author)") }
                if let score = source.score { LabeledContent("Score", value: "\(score)") }
                if let redditURL {
                    Link(destination: redditURL) {
                        Label("Open supporting \(source.kind.rawValue)", systemImage: "arrow.up.right.square")
                    }
                }
            }
            Section(source.title ?? "Saved content") {
                Text(source.rawMarkdown.isEmpty ? "No text content" : source.rawMarkdown)
                    .textSelection(.enabled)
            }
        }
        .researchLibraryExperimentalGlassSurface()
        .navigationTitle(source.kind == .post ? "Supporting Post" : "Supporting Comment")
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ResearchComparisonGenerationState: Equatable, Identifiable {
    enum Phase: Equatable {
        case running
        case completed
        case failed
    }

    var id: String
    var leftRunID: UUID
    var rightRunID: UUID
    var communityComparisonID: UUID?
    var title: String
    var phase: Phase
    var status: String
    var progress: Double
    var updatedAt: Date
}

@MainActor
final class ResearchComparisonGenerationCoordinator: ObservableObject {
    static let shared = ResearchComparisonGenerationCoordinator()

    @Published private(set) var states: [String: ResearchComparisonGenerationState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    var hasActiveJobs: Bool {
        states.values.contains { $0.phase == .running }
    }

    var activeJobs: [ResearchComparisonGenerationState] {
        states.values
            .filter { $0.phase == .running }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var latestStatusJob: ResearchComparisonGenerationState? {
        let running = states.values.filter { $0.phase == .running }
        return (running.isEmpty ? Array(states.values) : running)
            .max { $0.updatedAt < $1.updatedAt }
    }

    func state(for key: String) -> ResearchComparisonGenerationState? {
        states[key]
    }

    func begin(
        key: String,
        leftRunID: UUID,
        rightRunID: UUID,
        communityComparisonID: UUID? = nil,
        title: String,
        status: String,
        progress: Double
    ) -> Bool {
        guard states[key]?.phase != .running else { return false }
        states[key] = ResearchComparisonGenerationState(
            id: key,
            leftRunID: leftRunID,
            rightRunID: rightRunID,
            communityComparisonID: communityComparisonID,
            title: title,
            phase: .running,
            status: status,
            progress: progress,
            updatedAt: Date()
        )
        return true
    }

    func attach(_ task: Task<Void, Never>, to key: String) {
        tasks[key] = task
    }

    func update(key: String, status: String, progress: Double) {
        guard var state = states[key], state.phase == .running else { return }
        state.status = status
        state.progress = max(0, min(1, progress))
        state.updatedAt = Date()
        states[key] = state
    }

    func complete(key: String, status: String) {
        tasks.removeValue(forKey: key)
        guard var state = states[key] else { return }
        state.phase = .completed
        state.status = status
        state.progress = 1
        state.updatedAt = Date()
        states[key] = state
    }

    func fail(key: String, message: String) {
        tasks.removeValue(forKey: key)
        guard var state = states[key] else { return }
        state.phase = .failed
        state.status = message
        state.progress = 0
        state.updatedAt = Date()
        states[key] = state
    }

    func dismissStatus(key: String) {
        guard states[key]?.phase != .running else { return }
        states.removeValue(forKey: key)
    }

    func cancelAndDismiss(key: String) {
        tasks.removeValue(forKey: key)?.cancel()
        states.removeValue(forKey: key)
    }
}

private enum ResearchComparisonGenerationError: LocalizedError {
    case summarizeBridgeUnavailable

    var errorDescription: String? {
        switch self {
        case .summarizeBridgeUnavailable:
            return "The comparison could not reach the configured Codex / Summarize service. Check that the bridge or daemon is available, then try again."
        }
    }
}

@MainActor
struct ResearchComparisonView: View {
    let leftRunID: UUID
    let rightRunID: UUID
    @ObservedObject private var store = ResearchLibraryStore.shared
    @ObservedObject private var comparisonJobs = ResearchComparisonGenerationCoordinator.shared
    @Environment(\.researchLibraryMinimizeAction) private var minimizeResearchLibrary
    @State private var left: ResearchRunDetail?
    @State private var right: ResearchRunDetail?
    @State private var difference: ResearchRevisionDiff?
    @State private var changeReport: ResearchArtifactRecord?
    @State private var changeClaims: [ResearchClaimRecord] = []
    @State private var changeCitations: [UUID: [ResearchCitationRecord]] = [:]
    @State private var selectedSource: ResearchSourceRecord?
    @State private var areAddedSourcesExpanded = false
    @State private var areEarlierOnlySourcesExpanded = false
    @State private var areEditedSourcesExpanded = false
    @State private var areScoreChangesExpanded = false
    @State private var showsDetails = false
    @State private var errorMessage: String?

    private var generationKey: String {
        [leftRunID.uuidString, rightRunID.uuidString].sorted().joined(separator: ":")
    }

    private var generationState: ResearchComparisonGenerationState? {
        comparisonJobs.state(for: generationKey)
    }

    private var isGeneratingReport: Bool {
        generationState?.phase == .running
    }

    private var generationStatus: String {
        generationState?.status ?? "Preparing a balanced comparison…"
    }

    private var generationProgress: Double {
        generationState?.progress ?? 0
    }

    var body: some View {
        List {
            if let left, let right, let difference {
                comparisonContextSection(left: left, right: right)
                subredditProgressSection(difference)
                if difference.hasChanges {
                    Section {
                        Button {
                            withAnimation { showsDetails.toggle() }
                        } label: {
                            Label(
                                showsDetails ? "Hide the exact differences" : "Show the exact differences",
                                systemImage: showsDetails ? "chevron.up" : "chevron.down"
                            )
                        }
                    } footer: {
                        if !showsDetails {
                            Text(detailsSummary(difference))
                        }
                    }
                }
                if showsDetails {
                exactChangesSection(difference)

                if !difference.added.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $areAddedSourcesExpanded) {
                            ForEach(difference.added) { delta in
                                sourceChangeRow(
                                    delta,
                                    snapshotLabel: snapshotName(right),
                                    runID: difference.newRunID,
                                    systemImage: "doc.text",
                                    tint: RedappDesign.accent
                                )
                            }
                        } label: {
                            HStack {
                                Label(laterOnlySourcesTitle, systemImage: "rectangle.stack")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(difference.added.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !difference.removed.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $areEarlierOnlySourcesExpanded) {
                            ForEach(difference.removed) { delta in
                                sourceChangeRow(
                                    delta,
                                    snapshotLabel: snapshotName(left),
                                    runID: difference.oldRunID,
                                    systemImage: "doc.text",
                                    tint: RedappDesign.accent
                                )
                            }
                        } label: {
                            HStack {
                                Label(earlierOnlySourcesTitle, systemImage: "rectangle.stack")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(difference.removed.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !difference.edited.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $areEditedSourcesExpanded) {
                            ForEach(difference.edited) { delta in
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(
                                        delta.displayTitle,
                                        systemImage: delta.kind == .post ? "doc.text" : "text.bubble"
                                    )
                                    .font(.headline)
                                    HStack {
                                        sourceButton(
                                            title: snapshotName(left),
                                            runID: difference.oldRunID,
                                            sourceID: delta.sourceID
                                        )
                                        sourceButton(
                                            title: snapshotName(right),
                                            runID: difference.newRunID,
                                            sourceID: delta.sourceID
                                        )
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        } label: {
                            HStack {
                                Label("Edited sources", systemImage: "pencil.and.list.clipboard")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(difference.edited.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !difference.scoreChanges.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $areScoreChangesExpanded) {
                            ForEach(difference.scoreChanges) { delta in
                                Button {
                                    openSource(runID: difference.newRunID, sourceID: delta.sourceID)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(delta.displayTitle)
                                                .foregroundStyle(.primary)
                                            Text(sourceKindDescription(delta.kind, author: delta.newSource.author))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(scoreLabel(delta.oldScore))
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "arrow.right")
                                            .foregroundStyle(.tertiary)
                                        Text(scoreLabel(delta.newScore))
                                            .fontWeight(.semibold)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Label("Score changes", systemImage: "chart.line.uptrend.xyaxis")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(difference.scoreChanges.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text("Scores show how much attention a post or comment got, not whether it is right.")
                    }
                }

                if !difference.coverageChanges.isEmpty {
                    Section("Collection changes") {
                        ForEach(difference.coverageChanges) { delta in
                            comparisonRow(delta.title, left: delta.oldValue, right: delta.newValue)
                        }
                    }
                }

                }
            } else {
                ProgressView()
            }
        }
        .researchLibraryExperimentalGlassSurface()
        .navigationTitle(comparesDifferentFilters ? "Compare Feeds" : "How It Changed")
        .toolbar {
            if isGeneratingReport {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        minimizeResearchLibrary()
                    } label: {
                        Label("Minimize", systemImage: "chevron.down")
                    }
                    .accessibilityHint("Continues the comparison in the background")
                }
            }
        }
        .task {
            loadComparison()
            switch generationState?.phase {
            case .completed:
                comparisonJobs.dismissStatus(key: generationKey)
            case .failed:
                errorMessage = generationState?.status
            case .running, .none:
                break
            }
        }
        .onChange(of: generationState?.phase) { _, phase in
            switch phase {
            case .completed:
                loadComparison()
                comparisonJobs.dismissStatus(key: generationKey)
            case .failed:
                errorMessage = generationState?.status
            case .running, .none:
                break
            }
        }
        .sheet(item: $selectedSource) { source in
            NavigationStack { ResearchSourceDetailView(source: source) }
        }
        .alert("Comparison unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                    if generationState?.phase == .failed {
                        comparisonJobs.dismissStatus(key: generationKey)
                    }
                }
            }
        )) {
            Button("OK", role: .cancel) {
                errorMessage = nil
                if generationState?.phase == .failed {
                    comparisonJobs.dismissStatus(key: generationKey)
                }
            }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    /// One line saying what the hidden details contain.
    private func detailsSummary(_ difference: ResearchRevisionDiff) -> String {
        var parts: [String] = []
        if !difference.added.isEmpty { parts.append("\(difference.added.count) only in the later one") }
        if !difference.removed.isEmpty { parts.append("\(difference.removed.count) only in the earlier one") }
        if !difference.edited.isEmpty { parts.append("\(difference.edited.count) edited") }
        if !difference.scoreChanges.isEmpty { parts.append("\(difference.scoreChanges.count) with new scores") }
        guard !parts.isEmpty else { return "Only the amount of collected content changed." }
        return "Posts and comments: " + parts.joined(separator: ", ") + "."
    }

    @ViewBuilder
    private func comparisonContextSection(
        left: ResearchRunDetail,
        right: ResearchRunDetail
    ) -> some View {
        Section {
            comparisonSnapshotRow(title: comparesDifferentFilters ? "First feed" : "Earlier", detail: left)
            comparisonSnapshotRow(title: comparesDifferentFilters ? "Second feed" : "Later", detail: right)
            if comparesDifferentFilters {
                Label(
                    "Hot, New and Top show different posts, so a difference here can come from the feed rather than from the community changing.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(comparesDifferentFilters ? "Compared feeds" : "Compared snapshots")
        }
    }

    private func comparisonSnapshotRow(
        title: String,
        detail: ResearchRunDetail
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(captureName(detail.run))
                    .fontWeight(.semibold)
            }
            Text(detail.run.capturedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(detail.run.coverage.postsAnalyzed) posts · \(detail.run.coverage.commentsAnalyzed) comments read")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func subredditProgressSection(_ difference: ResearchRevisionDiff) -> some View {
        Section {
            if let changeReport {
                ResearchComparisonReportView(
                    report: changeReport,
                    claims: changeClaims,
                    citationsByClaim: changeCitations,
                    sourceLabel: comparisonSourceLabel,
                    openSource: openComparisonSource
                )
                Button {
                    generateWhatChangedReport(difference)
                } label: {
                    if isGeneratingReport {
                        VStack(alignment: .leading, spacing: 7) {
                            ProgressView(value: generationProgress)
                            Text(generationStatus)
                        }
                    } else {
                        Label(
                            comparesDifferentFilters
                                ? "Regenerate feed comparison"
                                : "Regenerate plain-language update",
                            systemImage: "arrow.clockwise"
                        )
                    }
                }
                .disabled(isGeneratingReport || !difference.hasSourceChanges)
            } else if difference.hasSourceChanges {
                Text(
                    comparesDifferentFilters
                        ? "Create a short, everyday-language explanation of how the topics surfaced by these saved feeds differ."
                        : "Create a short, everyday-language explanation of how the saved subreddit discussion moved from the earlier snapshot to the later one."
                )
                    .foregroundStyle(.secondary)
                Button {
                    generateWhatChangedReport(difference)
                } label: {
                    if isGeneratingReport {
                        VStack(alignment: .leading, spacing: 7) {
                            ProgressView(value: generationProgress)
                            Text(generationStatus)
                        }
                    } else {
                        Label(
                            comparesDifferentFilters
                                ? "Explain the feed differences"
                                : "Explain the progress in plain language",
                            systemImage: "text.quote"
                        )
                    }
                }
                .disabled(isGeneratingReport)
            } else if difference.hasChanges {
                Text(ResearchChangeNarrative.coverageOnlyText(changes: difference.coverageChanges))
                    .foregroundStyle(.secondary)
            } else {
                Text(ResearchChangeNarrative.noChangeText)
                    .foregroundStyle(.secondary)
            }

            if isGeneratingReport {
                Button {
                    minimizeResearchLibrary()
                } label: {
                    Label("Minimize and continue browsing", systemImage: "chevron.down")
                }
            }
        } header: {
            Text(subredditProgressTitle)
        } footer: {
            let explanation = comparesDifferentFilters
                ? "This compares two differently sorted saved samples. A difference may come from Reddit’s feed selection rather than a change in the community."
                : "This describes the saved sample, not every person or discussion in the subreddit."
            Text(explanation + (isGeneratingReport ? " You can minimize while it works." : ""))
        }
    }

    @ViewBuilder
    private func exactChangesSection(_ difference: ResearchRevisionDiff) -> some View {
        Section("Exact differences") {
            if !difference.hasChanges {
                Label("No saved source or coverage changes detected.", systemImage: "equal.circle")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent(laterOnlySourcesTitle, value: "\(difference.added.count)")
                LabeledContent(earlierOnlySourcesTitle, value: "\(difference.removed.count)")
                LabeledContent("Edited", value: "\(difference.edited.count)")
                LabeledContent("Score changes", value: "\(difference.scoreChanges.count)")
                LabeledContent("Unchanged sources", value: "\(difference.unchangedSourceCount)")
            }
        }
    }

    private var earlierOnlySourcesTitle: String {
        guard comparesDifferentFilters, let left else { return "Only in earlier snapshot" }
        return "Only in \(captureName(left.run))"
    }

    private var laterOnlySourcesTitle: String {
        guard comparesDifferentFilters, let right else { return "Only in later snapshot" }
        return "Only in \(captureName(right.run))"
    }

    private var subredditProgressTitle: String {
        guard let subreddit = right?.sources
            .map(\.subreddit)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return comparesDifferentFilters
                ? "How the saved feeds differed"
                : "How the subreddit progressed"
        }
        return comparesDifferentFilters
            ? "How r/\(subreddit) differed across feeds"
            : "How r/\(subreddit) progressed"
    }

    private var comparesDifferentFilters: Bool {
        guard let left, let right else { return false }
        return ResearchCaptureLabel.key(
            sortMode: left.run.sortMode,
            timeRange: left.run.timeRange
        ) != ResearchCaptureLabel.key(
            sortMode: right.run.sortMode,
            timeRange: right.run.timeRange
        )
    }

    private func captureName(_ run: ResearchRunRecord) -> String {
        ResearchCaptureLabel.displayName(sortMode: run.sortMode, timeRange: run.timeRange)
    }

    private func snapshotName(_ detail: ResearchRunDetail) -> String {
        comparesDifferentFilters
            ? captureName(detail.run)
            : "Saved \(detail.run.capturedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func comparisonReportTitle(
        difference: ResearchRevisionDiff,
        left: ResearchRunDetail,
        right: ResearchRunDetail
    ) -> String {
        let usesDifferentFilters = ResearchCaptureLabel.key(
            sortMode: left.run.sortMode,
            timeRange: left.run.timeRange
        ) != ResearchCaptureLabel.key(
            sortMode: right.run.sortMode,
            timeRange: right.run.timeRange
        )
        guard usesDifferentFilters else { return difference.reportTitle }
        let leftDate = left.run.capturedAt.formatted(date: .abbreviated, time: .shortened)
        let rightDate = right.run.capturedAt.formatted(date: .abbreviated, time: .shortened)
        return "Feed Differences: \(captureName(left.run)) (\(leftDate)) → \(captureName(right.run)) (\(rightDate))"
    }

    private func loadComparison() {
        do {
            let loadedLeft = try store.detail(runID: leftRunID)
            let loadedRight = try store.detail(runID: rightRunID)
            let loadedDifference = ResearchRevisionDiffer.compare(
                oldRunID: loadedLeft.run.id,
                oldRevision: loadedLeft.run.revision,
                oldSources: loadedLeft.sources.map(ResearchSourceInput.init(record:)),
                oldCoverage: loadedLeft.run.coverage,
                newRunID: loadedRight.run.id,
                newRevision: loadedRight.run.revision,
                newSources: loadedRight.sources.map(ResearchSourceInput.init(record:)),
                newCoverage: loadedRight.run.coverage
            )
            left = loadedLeft
            right = loadedRight
            difference = loadedDifference
            try loadSavedChangeReport(
                from: loadedRight,
                title: comparisonReportTitle(
                    difference: loadedDifference,
                    left: loadedLeft,
                    right: loadedRight
                )
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSavedChangeReport(from detail: ResearchRunDetail, title: String) throws {
        guard let report = detail.artifacts.last(where: {
            $0.kind == .changeReport && $0.title == title
        }) else {
            changeReport = nil
            changeClaims = []
            changeCitations = [:]
            return
        }
        changeReport = report
        changeClaims = try store.claims(artifactID: report.id)
        changeCitations = try changeClaims.reduce(into: [:]) { result, claim in
            result[claim.id] = try store.citations(claimID: claim.id).filter(\.validated)
        }
    }

    private func generateWhatChangedReport(_ difference: ResearchRevisionDiff) {
        guard let left, let right, difference.hasSourceChanges else { return }
        let comparisonSources = difference.promptSources()
        guard !comparisonSources.isEmpty else { return }
        let subreddit = right.sources
            .map(\.subreddit)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .map { "r/\($0)" } ?? "the saved subreddit"
        guard comparisonJobs.begin(
            key: generationKey,
            leftRunID: leftRunID,
            rightRunID: rightRunID,
            title: "Comparing \(subreddit)",
            status: "Preparing a balanced comparison…",
            progress: 0.05
        ) else { return }
        errorMessage = nil
        let isCrossFilter = comparesDifferentFilters
        let comparisonTask = isCrossFilter
            ? "Compare, in plain everyday language, what the two differently sorted saved subreddit feeds surfaced."
            : "Explain, in plain everyday language, how the saved subreddit discussion progressed from revision \(difference.oldRevision) to revision \(difference.newRevision)."
        let focusGuidance = isCrossFilter
            ? "Focus on which topics, concerns, attitudes, or conflicts are more visible in one feed than the other. Do not describe a difference as subreddit progress or a change over time merely because one feed contains different posts. Explicitly distinguish likely feed-selection differences from evidence of a genuine time-based shift."
            : "Focus on which topics or concerns appeared, faded, or changed; whether the saved discussion became more supportive, critical, uncertain, or divided; and what new consensus or conflict emerged. Only describe those shifts when the saved evidence supports them."
        let comparisonCaution = isCrossFilter
            ? "The snapshots use different Reddit sorting methods. Treat the deterministic source differences as differences between saved samples, not proof that the community changed."
            : "If the material only establishes that something is new or absent in one snapshot, state that carefully without guessing why."

        let instruction = """
        \(comparisonTask)

        Subreddit: \(subreddit)
        Earlier snapshot: \(captureName(left.run)) · \(left.run.capturedAt.formatted(date: .abbreviated, time: .shortened))
        Later snapshot: \(captureName(right.run)) · \(right.run.capturedAt.formatted(date: .abbreviated, time: .shortened))

        Write for a reader who does not want a technical data-diff report. Return 3 to 6 short claims in a natural reading order so that, when read together, they form a clear comparison. \(focusGuidance)

        In claim text, do not mention source IDs, manifests, digests, database terms, or raw added/removed counts. Say “the saved discussion,” “the saved feed,” or “this saved sample” rather than claiming to represent every member of the subreddit. Comparative claims should cite evidence from both snapshots when available. \(comparisonCaution)

        The deterministic manifest below is authoritative. Its totals describe the complete comparison, while its source IDs are bounded examples. Discuss only differences supported by the supplied evidence. Treat score changes only as engagement changes, never as proof that a claim is true. Every factual claim must cite the revision-prefixed saved sources. If the evidence cannot establish why something changed, say so under missing data.

        \(difference.compactPromptManifest())

        Previous saved report excerpts (context only, not evidence):
        \(reportExcerpts(left.artifacts))

        New saved report excerpts (context only, not evidence):
        \(reportExcerpts(right.artifacts))
        """

        let guidingOverview = comparisonGuidance(left: left, right: right)
        let selectedProvider = SummaryService.shared.settings.selectedSummaryProvider

#if os(iOS)
        let backgroundHandle = GeminiBackgroundTaskManager.shared.beginLongRunningTask(
            identifier: .summarization,
            title: "Comparing \(subreddit) feeds"
        )
        BatchSummaryLiveActivityController.shared.start(subreddit: subreddit, totalPosts: 4)
#endif

        let task = Task {
            var succeeded = false
            defer {
#if os(iOS)
                backgroundHandle.finish(success: succeeded)
                if succeeded {
                    BatchSummaryLiveActivityController.shared.end(
                        with: "Feed comparison ready",
                        processedPosts: 4,
                        totalPosts: 4
                    )
                }
#endif
            }
            do {
#if os(iOS)
                await backgroundHandle.waitForTaskStartIfNeeded()
#endif
                try Task.checkCancellation()
                if selectedProvider == .summarizeDaemon {
                    comparisonJobs.update(
                        key: generationKey,
                        status: "Checking the configured connection…",
                        progress: 0.12
                    )
#if os(iOS)
                    backgroundHandle.reportProgress(fractionCompleted: 0.12)
                    BatchSummaryLiveActivityController.shared.update(
                        status: "Checking the configured connection…",
                        processedPosts: 0,
                        totalPosts: 4,
                        progress: 0.12
                    )
#endif
                    do {
                        try await SummaryService.shared.testSummarizeDaemonConnection()
                    } catch {
                        throw ResearchComparisonGenerationError.summarizeBridgeUnavailable
                    }
                }

                comparisonJobs.update(
                    key: generationKey,
                    status: "Selecting the most representative evidence…",
                    progress: 0.25
                )
#if os(iOS)
                backgroundHandle.reportProgress(fractionCompleted: 0.25)
                BatchSummaryLiveActivityController.shared.update(
                    status: "Selecting representative evidence…",
                    processedPosts: 1,
                    totalPosts: 4,
                    progress: 0.25
                )
#endif

                comparisonJobs.update(
                    key: generationKey,
                    status: "Writing the plain-language comparison…",
                    progress: 0.42
                )
#if os(iOS)
                backgroundHandle.reportProgress(fractionCompleted: 0.42)
                BatchSummaryLiveActivityController.shared.update(
                    status: "Writing the feed comparison…",
                    processedPosts: 2,
                    totalPosts: 4,
                    progress: 0.42
                )
#endif
                let comparisonCoverage = left.run.coverage.combined(with: right.run.coverage)
                let result = try await GroundedResearchService.shared.generateReport(
                    instruction: instruction,
                    sources: comparisonSources,
                    coverage: comparisonCoverage,
                    guidingOverview: guidingOverview,
                    balanceAcrossPosts: true,
                    maximumSourceCharacters: 18_000,
                    promptVersion: 3
                )
                try Task.checkCancellation()
                comparisonJobs.update(
                    key: generationKey,
                    status: "Checking links and saving…",
                    progress: 0.88
                )
#if os(iOS)
                backgroundHandle.reportProgress(fractionCompleted: 0.88)
                BatchSummaryLiveActivityController.shared.update(
                    status: "Checking links and saving…",
                    processedPosts: 3,
                    totalPosts: 4,
                    progress: 0.88
                )
#endif
                let artifactBody = ResearchChangeNarrative.artifactBody(
                    claimTexts: result.response.claims.map(\.text),
                    evidenceMarkdown: result.response.markdown,
                    heading: isCrossFilter
                        ? "How the saved feeds differed"
                        : "How the subreddit progressed"
                )
                _ = try store.addArtifact(
                    runID: right.run.id,
                    kind: .changeReport,
                    title: comparisonReportTitle(
                        difference: difference,
                        left: left,
                        right: right
                    ),
                    body: artifactBody,
                    generationReceipt: result.receipt,
                    coverage: comparisonCoverage,
                    conflicts: result.response.conflicts,
                    missingData: result.response.missingData,
                    claims: result.response.claims,
                    validationSources: comparisonSources
                )
                succeeded = true
                comparisonJobs.complete(key: generationKey, status: "Feed comparison ready")
            } catch is CancellationError {
                let message = "The comparison was stopped before it finished."
                comparisonJobs.fail(key: generationKey, message: message)
                errorMessage = message
#if os(iOS)
                BatchSummaryLiveActivityController.shared.cancel(
                    reason: "Feed comparison stopped",
                    processedPosts: 0,
                    totalPosts: 4
                )
#endif
            } catch {
                let message = error.localizedDescription
                comparisonJobs.fail(key: generationKey, message: message)
                errorMessage = message
#if os(iOS)
                BatchSummaryLiveActivityController.shared.cancel(
                    reason: "Feed comparison needs attention",
                    processedPosts: 0,
                    totalPosts: 4
                )
#endif
            }
        }
        comparisonJobs.attach(task, to: generationKey)
#if os(iOS)
        backgroundHandle.registerCancellationHandler { task.cancel() }
#endif
    }

    private func reportExcerpts(_ artifacts: [ResearchArtifactRecord]) -> String {
        let excerpts = artifacts
            .filter { $0.kind != .changeReport }
            .prefix(4)
            .map { artifact in
                let compact = artifact.body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                return "- \(artifact.title): \(String(compact.prefix(450)))"
            }
        return excerpts.isEmpty ? "None saved." : excerpts.joined(separator: "\n")
    }

    private func comparisonGuidance(
        left: ResearchRunDetail,
        right: ResearchRunDetail
    ) -> String? {
        let snapshots = [left, right].compactMap { detail -> String? in
            guard let summary = detail.revisionArtifacts.overallSummary else { return nil }
            let compact = summary.body
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !compact.isEmpty else { return nil }
            return "\(captureName(detail.run)): \(String(compact.prefix(3_000)))"
        }
        return snapshots.isEmpty ? nil : snapshots.joined(separator: "\n\n")
    }

    @ViewBuilder
    private func sourceChangeRow(
        _ delta: ResearchSourceDelta,
        snapshotLabel: String,
        runID: UUID,
        systemImage: String,
        tint: Color
    ) -> some View {
        Button {
            openSource(runID: runID, sourceID: delta.sourceID)
        } label: {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(delta.displayTitle)
                        .foregroundStyle(.primary)
                    Text("\(snapshotLabel) · \(sourceKindDescription(delta.kind, author: delta.newSource?.author ?? delta.oldSource?.author))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sourceButton(title: String, runID: UUID, sourceID: String) -> some View {
        Button(title) { openSource(runID: runID, sourceID: sourceID) }
            .buttonStyle(RedappChipButtonStyle())
    }

    private func openComparisonSource(_ encodedID: String) {
        if let reference = ResearchComparisonSourceReference.parse(encodedID) {
            openSource(runID: reference.runID, sourceID: reference.sourceID)
        } else {
            openSource(runID: rightRunID, sourceID: encodedID)
        }
    }

    private func comparisonSourceLabel(_ encodedID: String) -> String {
        guard let reference = ResearchComparisonSourceReference.parse(encodedID) else {
            if let source = try? store.source(runID: rightRunID, sourceID: encodedID) {
                return ResearchSourceLabel.text(for: source)
            }
            return "Saved source"
        }
        let sourceText = (try? store.source(runID: reference.runID, sourceID: reference.sourceID))
            .map { ResearchSourceLabel.text(for: $0) } ?? "Saved source"
        if let left, reference.runID == left.run.id {
            return "\(snapshotName(left)) · \(sourceText)"
        }
        if let right, reference.runID == right.run.id {
            return "\(snapshotName(right)) · \(sourceText)"
        }
        return sourceText
    }

    private func sourceKindDescription(_ kind: ResearchSourceKind, author: String?) -> String {
        let noun = kind == .post ? "post" : "comment"
        guard let author, !author.isEmpty else { return noun }
        return "\(noun) by u/\(author)"
    }

    private func openSource(runID: UUID, sourceID: String) {
        do {
            selectedSource = try store.source(runID: runID, sourceID: sourceID)
            if selectedSource == nil { errorMessage = "The saved comparison source is unavailable." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scoreLabel(_ score: Int?) -> String {
        score.map(String.init) ?? "—"
    }

    private func comparisonRow(_ title: String, left: Int, right: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(left)")
                .frame(minWidth: 44)
            Image(systemName: left == right ? "equal" : (right > left ? "arrow.right" : "arrow.left"))
                .foregroundStyle(left == right ? Color.secondary : Color.accentColor)
            Text("\(right)")
                .frame(minWidth: 44)
        }
    }
}

@MainActor
private struct ResearchComparisonReportView: View {
    let report: ResearchArtifactRecord
    let claims: [ResearchClaimRecord]
    let citationsByClaim: [UUID: [ResearchCitationRecord]]
    let sourceLabel: (String) -> String
    let openSource: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if plainLanguageNarrative.isEmpty {
                Text("There wasn’t enough saved information to produce a clear comparison.")
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(plainLanguageNarrative)
                    .font(.body)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            DisclosureGroup("Sources and limitations") {
                evidenceContent
            }
        }
        .padding(.vertical, 4)
    }

    private var plainLanguageNarrative: String {
        ResearchChangeNarrative.plainText(from: claims.map(\.text))
    }

    @ViewBuilder
    private var evidenceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if claims.isEmpty {
                Text(report.body)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                ForEach(claims) { claim in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(claim.text)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ResearchConfidenceBadge(confidence: claim.confidence)
                                ForEach(citationsByClaim[claim.id] ?? []) { citation in
                                    Button(sourceLabel(citation.sourceID)) {
                                        openSource(citation.sourceID)
                                    }
                                    .buttonStyle(RedappChipButtonStyle())
                                }
                            }
                        }
                        if let missing = claim.missingDataNote, !missing.isEmpty {
                            Label(missing, systemImage: "questionmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                }
                DisclosureGroup("What does confidence mean?") {
                    Text("Low does not mean false. It means the saved support may be limited, conflicting, drawn from too few independent posts, or affected by incomplete coverage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption.weight(.semibold))
            }
            ForEach(report.conflicts, id: \.self) {
                Label($0, systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(report.missingData, id: \.self) {
                Label($0, systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Strong support" / "Some support" / "Thin support". Tapping it explains
/// what the rating means for this point.
struct ResearchConfidenceBadge: View {
    let confidence: ResearchEvidenceConfidence
    @State private var showsExplanation = false

    var body: some View {
        Button {
            showsExplanation = true
        } label: {
            Label(confidence.displayName, systemImage: "checkmark.shield")
                .font(.caption2.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(color.opacity(0.15))
                .foregroundStyle(color)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(confidence.explanation)
        .popover(isPresented: $showsExplanation) {
            Text(confidence.explanation)
                .font(.subheadline)
                .foregroundStyle(RedappDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280, alignment: .leading)
                .padding(16)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var color: Color {
        switch confidence {
        case .high: return RedappDesign.positive
        case .medium: return RedappDesign.inkSecondary
        case .low: return .orange
        case .unverified: return RedappDesign.negative
        }
    }
}

/// Readable chip text for a saved source, used instead of internal IDs such as
/// "t1_k3x9ab": "u/name · “first few words…”" or "Post · “title…”".
enum ResearchSourceLabel {
    static func text(for source: ResearchSourceRecord, quote: String? = nil) -> String {
        let trimmedQuote = quote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let excerptSource: String
        if !trimmedQuote.isEmpty {
            excerptSource = trimmedQuote
        } else if source.kind == .post, let title = source.title, !title.isEmpty {
            excerptSource = title
        } else {
            excerptSource = MarkdownTextView.extractPlainText(from: source.rawMarkdown)
        }
        let lead: String
        if source.kind == .post {
            lead = "Post"
        } else if let author = source.author, !author.isEmpty {
            lead = "u/\(author)"
        } else {
            lead = "Comment"
        }
        let excerpt = shortened(excerptSource)
        return excerpt.isEmpty ? lead : "\(lead) · “\(excerpt)”"
    }

    static func shortened(_ text: String, words: Int = 6) -> String {
        let parts = text.split(whereSeparator: \.isWhitespace)
        let head = parts.prefix(words).joined(separator: " ")
        return parts.count > words ? head + "…" : head
    }
}

extension ResearchSourceInput {
    init(record: ResearchSourceRecord) {
        self.init(
            sourceID: record.sourceID,
            kind: record.kind,
            postSourceID: record.postSourceID,
            parentSourceID: record.parentSourceID,
            subreddit: record.subreddit,
            title: record.title,
            permalink: record.permalink,
            author: record.author,
            score: record.score,
            createdAt: record.sourceCreatedAt,
            depth: record.depth,
            rawMarkdown: record.rawMarkdown,
            mediaURLs: record.mediaURLs,
            sourceOrder: record.sourceOrder
        )
    }
}


/// Says what actually made a snapshot partial (which posts failed and why),
/// instead of a generic warning.
struct ResearchPartialReason: View {
    let coverage: ResearchCoverageInput

    private var summary: String {
        let failures = coverage.failureMessages
        guard !failures.isEmpty else {
            return "Some posts or comments couldn’t be loaded when this was saved."
        }
        let count = failures.count
        let lead = count == 1 ? "1 post couldn't be loaded" : "\(count) posts couldn't be loaded"
        let first = failures[0]
        return count == 1 ? "\(lead): \(first)" : "\(lead), e.g. \(first)"
    }

    var body: some View {
        Label {
            Text(summary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .font(.caption)
        .foregroundStyle(RedappDesign.inkSecondary)
        .accessibilityElement(children: .combine)
    }
}
