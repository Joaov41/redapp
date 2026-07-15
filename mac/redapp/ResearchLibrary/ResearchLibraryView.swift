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

enum ResearchLibraryRoute: Hashable {
    case item(id: UUID)
    case run(id: UUID)
    case comparison(leftRunID: UUID, rightRunID: UUID)
    case crossFilterPicker(baseRunID: UUID)
    case communityPicker(baseRunID: UUID)
    case communitySetup(firstRunID: UUID, secondRunID: UUID)
    case communityComparison(id: UUID)
    case conversation(runID: UUID, conversationID: UUID?)
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
    @State private var presentedExport: ResearchExportDocument?
    @State private var communityComparisons: [ResearchCommunityComparisonRecord] = []
    @State private var errorMessage: String?

    init(
        navigationPath: Binding<NavigationPath>,
        initialComparison: ResearchComparisonGenerationState? = nil,
        onMinimize: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        _navigationPath = navigationPath
        self.initialComparison = initialComparison
        self.onMinimize = onMinimize
        self.onClose = onClose
    }

    private var availableTags: [String] {
        Array(Set(store.items.flatMap(\.tags))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
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
                                    .buttonStyle(.bordered)
                                    .tint(selectedTags.contains(tag) ? .accentColor : .secondary)
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
                                    ? "Save a completed batch to keep its reports, sources, metadata, and follow-up questions."
                                    : "Try a different search or tag filter."
                            )
                        )
                    } else {
                        ForEach(store.items) { item in
                            NavigationLink(value: ResearchLibraryRoute.item(id: item.id)) {
                                ResearchLibraryRow(item: item)
                            }
                            .contextMenu {
                                Button {
                                    perform { try store.setPinned(item.pinnedAt == nil, itemID: item.id) }
                                } label: {
                                    Label(item.pinnedAt == nil ? "Pin" : "Unpin", systemImage: "pin")
                                }
                                Button(role: .destructive) {
                                    perform { try store.deleteItem(id: item.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Saved batches")
                }
            }
#if os(macOS)
            .listStyle(.inset)
            .navigationTitle("Research Library")
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: "Search saved research"
            )
#else
            .listStyle(.insetGrouped)
            .navigationTitle("Research Library")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search reports, posts, comments, authors"
            )
#endif
            .navigationDestination(for: ResearchLibraryRoute.self) { route in
                switch route {
                case .item(let id):
                    ResearchItemDetailView(itemID: id)
                case .run(let id):
                    ResearchRunDetailView(runID: id)
                case .comparison(let leftRunID, let rightRunID):
                    ResearchComparisonView(leftRunID: leftRunID, rightRunID: rightRunID)
                case .crossFilterPicker(let baseRunID):
                    ResearchCrossFilterComparisonPickerView(baseRunID: baseRunID)
                case .communityPicker(let baseRunID):
                    ResearchCommunityComparisonPickerView(baseRunID: baseRunID)
                case .communitySetup(let firstRunID, let secondRunID):
                    ResearchCommunityComparisonSetupView(
                        firstRunID: firstRunID,
                        secondRunID: secondRunID
                    )
                case .communityComparison(let id):
                    ResearchCommunityComparisonView(comparisonID: id)
                case .conversation(let runID, let conversationID):
                    ResearchConversationView(runID: runID, conversationID: conversationID)
                case .sources(let runID):
                    ResearchSourcesListView(runID: runID)
                case .source(let runID, let sourceID):
                    ResearchSavedSourceRouteView(runID: runID, sourceID: sourceID)
                }
            }
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
        }
        .toolbar {
#if os(macOS)
            ToolbarItem(placement: .navigation) {
                Button(action: minimize) {
                    Label("Minimize", systemImage: "chevron.down")
                }
                .accessibilityHint("Keeps the Research Library available while you browse")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if comparisonJobs.hasActiveJobs {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Comparison in progress")
                }
                Button("Close", action: close)
            }
#else
            ToolbarItem(placement: .cancellationAction) {
                Button(action: minimize) {
                    Label("Minimize", systemImage: "chevron.down")
                }
                .accessibilityHint("Keeps the Research Library available while you browse")
            }
            ToolbarItem(placement: .confirmationAction) {
                if comparisonJobs.hasActiveJobs {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Comparison in progress")
                }
                Button("Close", action: close)
            }
#endif
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

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { errorMessage = error.localizedDescription }
    }
}

private struct ResearchSearchRequest: Equatable {
    let query: String
    let tags: Set<String>
}

@MainActor
private struct ResearchLibraryRow: View {
    let item: ResearchItemRecord

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
            Text("Updated \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

@MainActor
struct ResearchItemDetailView: View {
    let itemID: UUID
    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var item: ResearchItemRecord?
    @State private var runs: [ResearchRunRecord] = []
    @State private var crossFilterRuns: [ResearchRunRecord] = []
    @State private var showTagEditor = false
    @State private var tagText = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let item {
                Section("Collection") {
                    LabeledContent("Scope", value: item.subreddit == "home" ? "Home feed" : "r/\(item.subreddit)")
                    LabeledContent("Saved feed", value: ResearchCaptureLabel.displayName(scope: item.scope))
                    LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if !item.tags.isEmpty {
                        LabeledContent("Tags", value: item.tags.joined(separator: ", "))
                    }
                }

                if let latestRun = runs.first {
                    Section("Compare") {
                        if runs.count >= 2 {
                            NavigationLink(value: ResearchLibraryRoute.comparison(
                                leftRunID: runs[1].id,
                                rightRunID: runs[0].id
                            )) {
                                Label("Compare latest two revisions", systemImage: "rectangle.split.2x1")
                            }
                        }

                        if !crossFilterRuns.isEmpty {
                            NavigationLink(value: ResearchLibraryRoute.crossFilterPicker(baseRunID: latestRun.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("Compare New, Hot, or Top", systemImage: "slider.horizontal.3")
                                    Text("Choose another saved r/\(item.subreddit) feed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        NavigationLink(value: ResearchLibraryRoute.communityPicker(baseRunID: latestRun.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Compare with another subreddit", systemImage: "person.2.wave.2")
                                Text("Choose a saved community and a subject")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("History") {
                    ForEach(runs) { run in
                        NavigationLink(value: ResearchLibraryRoute.run(id: run.id)) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("Revision \(run.revision)")
                                        .font(.headline)
                                    Spacer()
                                    ResearchRunStateBadge(state: run.state)
                                }
                                Text(run.capturedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(run.coverage.postsAnalyzed) posts · \(run.coverage.commentsAnalyzed) comments analyzed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if run.state == .partial {
                                    Text(run.state.explanation)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(item?.title ?? "Saved Research")
        .toolbar {
            if let item {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        perform { try store.setPinned(item.pinnedAt == nil, itemID: item.id) }
                        reload()
                    } label: {
                        Image(systemName: item.pinnedAt == nil ? "pin" : "pin.slash")
                    }
                    .accessibilityLabel(item.pinnedAt == nil ? "Pin" : "Unpin")

                    Button {
                        tagText = item.tags.joined(separator: ", ")
                        showTagEditor = true
                    } label: {
                        Image(systemName: "tag")
                    }
                    .accessibilityLabel("Edit tags")
                }
            }
        }
        .sheet(isPresented: $showTagEditor) {
            NavigationStack {
                Form {
                    TextField("research, important, later", text: $tagText)
#if os(iOS)
                        .textInputAutocapitalization(.never)
#else
                        .textFieldStyle(.roundedBorder)
#endif
                    Text("Separate tags with commas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("Tags")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showTagEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let tagParts = tagText.split(separator: ",")
                            let tags: [String] = tagParts.map { String($0) }
                            perform { try store.setTags(tags, itemID: itemID) }
                            showTagEditor = false
                            reload()
                        }
                    }
                }
            }
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
            item = try store.item(id: itemID)
            runs = try store.runs(itemID: itemID)
            if let latestRun = runs.first {
                crossFilterRuns = try store.comparisonRuns(
                    for: latestRun.id,
                    differentFiltersOnly: true
                )
            } else {
                crossFilterRuns = []
            }
            try store.markOpened(itemID: itemID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
private struct ResearchCrossFilterComparisonPickerView: View {
    let baseRunID: UUID
    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var baseRun: ResearchRunRecord?
    @State private var candidates: [ResearchRunRecord] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let baseRun {
                Section("Starting snapshot") {
                    snapshotRow(baseRun)
                }

                Section {
                    if candidates.isEmpty {
                        ContentUnavailableView(
                            "No Other Feed Types Saved",
                            systemImage: "rectangle.stack.badge.plus",
                            description: Text("Save a New, Hot, or Top batch from the same subreddit first.")
                        )
                    } else {
                        ForEach(candidates) { candidate in
                            let orderedIDs = orderedRunIDs(baseRun, candidate)
                            NavigationLink(value: ResearchLibraryRoute.comparison(
                                leftRunID: orderedIDs.earlier,
                                rightRunID: orderedIDs.later
                            )) {
                                snapshotRow(candidate)
                            }
                        }
                    }
                } header: {
                    Text("Choose another saved feed")
                } footer: {
                    Text("Different feed types can surface different posts. The comparison will label this clearly.")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Compare Feed Types")
        .task { load() }
        .alert("Comparison unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func snapshotRow(_ run: ResearchRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(ResearchCaptureLabel.displayName(sortMode: run.sortMode, timeRange: run.timeRange))
                .font(.headline)
            Text(run.capturedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(run.coverage.postsAnalyzed) posts · \(run.coverage.commentsAnalyzed) comments analyzed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func orderedRunIDs(
        _ first: ResearchRunRecord,
        _ second: ResearchRunRecord
    ) -> (earlier: UUID, later: UUID) {
        if first.capturedAt <= second.capturedAt {
            return (first.id, second.id)
        }
        return (second.id, first.id)
    }

    private func load() {
        do {
            guard let loadedBase = try store.run(id: baseRunID) else {
                throw ResearchStoreError.runNotFound
            }
            baseRun = loadedBase
            candidates = try store.comparisonRuns(
                for: baseRunID,
                differentFiltersOnly: true
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct ResearchRunDetailView: View {
    let runID: UUID
    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var detail: ResearchRunDetail?
    @State private var claimsByArtifact: [UUID: [ResearchClaimRecord]] = [:]
    @State private var citationsByClaim: [UUID: [ResearchCitationRecord]] = [:]
    @State private var selectedSource: ResearchSourceRecord?
    @State private var exportDocument: ResearchExportDocument?
    @State private var errorMessage: String?
    @State private var isGeneratingCompleteOverview = false
    @State private var isGeneratingGroundedReport = false
    @State private var isUpdatingOfflinePack = false

    var body: some View {
        List {
            if let detail {
                overallSummarySection(detail)
                sourceLinkedReportSection(detail)
                coverageSection(detail.run.coverage)
                postSummariesSection(detail)
                remainingArtifactsSection(detail)
                followUpQuestionsSection(detail)

                Section("Sources") {
                    NavigationLink(value: ResearchLibraryRoute.sources(runID: runID)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(
                                "\(detail.sources.count) saved source\(detail.sources.count == 1 ? "" : "s")",
                                systemImage: "tray.full"
                            )
                            .font(.headline)
                            Text("Open the complete posts and comments list")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Offline") {
                    if detail.offlineAssets.isEmpty {
                        Text("Not downloaded")
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent(
                            "Downloaded files",
                            value: "\(detail.offlineAssets.filter { $0.state == .ready }.count)"
                        )
                        LabeledContent(
                            "Storage",
                            value: ByteCountFormatter.string(
                                fromByteCount: detail.offlineAssets.reduce(0) { $0 + $1.byteCount },
                                countStyle: .file
                            )
                        )
                        if detail.offlineAssets.contains(where: { $0.state != .ready }) {
                            Label("Some media could not be downloaded.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            ForEach(detail.offlineAssets.filter { $0.state == .failed }) { asset in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(asset.remoteURL ?? "Unavailable media")
                                        .font(.caption)
                                        .lineLimit(2)
                                    if let failureMessage = asset.failureMessage {
                                        Text(failureMessage)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(detail.map { "Revision \($0.run.revision)" } ?? "Research Run")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Markdown") { prepareExport(format: .markdown) }
                    Button("JSON archive") { prepareExport(format: .json) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Re-export")

                Menu {
                    if detail?.revisionArtifacts.completeOverview == nil,
                       detail?.revisionArtifacts.postSummaries.isEmpty == false {
                        Button {
                            generateCompleteOverview()
                        } label: {
                            Label(
                                "Create full overview from all saved posts",
                                systemImage: "doc.text.magnifyingglass"
                            )
                        }
                        .disabled(isGeneratingCompleteOverview)
                    }
                    Button {
                        generateGroundedReport()
                    } label: {
                        Label(
                            detail?.revisionArtifacts.sourceLinkedReport == nil
                                ? "Create key points with source links"
                                : "Update key points from complete overview",
                            systemImage: "checkmark.seal"
                        )
                    }
                    .disabled(isGeneratingGroundedReport || detail?.sources.isEmpty != false)
                } label: {
                    if isGeneratingCompleteOverview || isGeneratingGroundedReport {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .disabled(
                    isGeneratingCompleteOverview
                        || isGeneratingGroundedReport
                )
                .accessibilityLabel("More report options")

                Menu {
                    Button {
                        makeOffline()
                    } label: {
                        Label(detail?.offlineAssets.isEmpty == false ? "Refresh offline pack" : "Make available offline", systemImage: "arrow.down.circle")
                    }
                    if detail?.offlineAssets.isEmpty == false {
                        Button(role: .destructive) {
                            deleteOfflinePack()
                        } label: {
                            Label("Remove offline download", systemImage: "trash")
                        }
                    }
                } label: {
                    if isUpdatingOfflinePack {
                        ProgressView()
                    } else {
                        Image(systemName: detail?.offlineAssets.isEmpty == false ? "checkmark.icloud" : "icloud.and.arrow.down")
                    }
                }
                .disabled(isUpdatingOfflinePack)
                .accessibilityLabel("Offline options")
            }
        }
        .sheet(item: $selectedSource) { source in
            NavigationStack {
                ResearchSourceDetailView(source: source)
            }
        }
        .sheet(item: $exportDocument) { document in
            #if os(iOS)
            ShareSheet(activityItems: [document.url])
            #else
            Text(document.url.path)
            #endif
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

    @ViewBuilder
    private func overallSummarySection(_ detail: ResearchRunDetail) -> some View {
        Section {
            Label(
                "\(detail.revisionArtifacts.postSummaries.count) saved post summaries",
                systemImage: "doc.on.doc"
            )
            .font(.subheadline.weight(.semibold))
            if let summary = detail.revisionArtifacts.completeOverview {
                artifactView(
                    summary,
                    in: detail,
                    presentation: .expanded,
                    showsSourceLinkNotice: false
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A full overview was not created when this revision was saved.")
                        .foregroundStyle(.secondary)
                    if !detail.revisionArtifacts.postSummaries.isEmpty {
                        Button {
                            generateCompleteOverview()
                        } label: {
                            if isGeneratingCompleteOverview {
                                Label("Creating full overview…", systemImage: "hourglass")
                            } else {
                                Label(
                                    "Create overview from all \(detail.revisionArtifacts.postSummaries.count) posts",
                                    systemImage: "doc.text.magnifyingglass"
                                )
                            }
                        }
                        .disabled(isGeneratingCompleteOverview)
                    }
                }
            }
        } header: {
            Text("Complete overview")
        } footer: {
            if detail.revisionArtifacts.completeOverview != nil {
                Text("This overview was created from all saved post summaries. Source-linked key points are shown separately below.")
            }
        }
    }

    @ViewBuilder
    private func sourceLinkedReportSection(_ detail: ResearchRunDetail) -> some View {
        if let report = detail.revisionArtifacts.sourceLinkedReport {
            let representedPosts = representedPostCount(for: report, in: detail)
            let savedPosts = max(
                detail.revisionArtifacts.postSummaries.count,
                Set(detail.sources.map(\.postSourceID)).count
            )
            Section {
                Label(
                    "\(representedPosts) of \(savedPosts) saved posts provide direct examples",
                    systemImage: "link"
                )
                .font(.subheadline.weight(.semibold))
                artifactView(report, in: detail, presentation: .expanded)
            } header: {
                Text("Key points with source links")
            } footer: {
                Text("The themes come from the complete overview of all saved post summaries. This count shows how many original posts provide direct supporting or conflicting links.")
            }
        }
    }

    @ViewBuilder
    private func postSummariesSection(_ detail: ResearchRunDetail) -> some View {
        if !detail.revisionArtifacts.postSummaries.isEmpty {
            Section("Individual post summaries (\(detail.revisionArtifacts.postSummaries.count))") {
                ForEach(detail.revisionArtifacts.postSummaries) { artifact in
                    artifactView(
                        artifact,
                        in: detail,
                        presentation: .disclosure,
                        showsSourceLinkNotice: false
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func remainingArtifactsSection(_ detail: ResearchRunDetail) -> some View {
        if !detail.revisionArtifacts.remainingArtifacts.isEmpty {
            Section("Other reports and answers") {
                ForEach(detail.revisionArtifacts.remainingArtifacts) { artifact in
                    artifactView(artifact, in: detail, presentation: .disclosure)
                }
            }
        }
    }

    private func followUpQuestionsSection(_ detail: ResearchRunDetail) -> some View {
        Section("Follow-up questions") {
            NavigationLink(value: ResearchLibraryRoute.conversation(runID: runID, conversationID: nil)) {
                Label("Ask about this saved batch", systemImage: "plus.bubble")
            }
            ForEach(detail.conversations) { conversation in
                NavigationLink(value: ResearchLibraryRoute.conversation(
                    runID: runID,
                    conversationID: conversation.id
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conversation.title)
                        Text("Updated \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func artifactView(
        _ artifact: ResearchArtifactRecord,
        in detail: ResearchRunDetail,
        presentation: ResearchArtifactPresentation,
        showsSourceLinkNotice: Bool = true
    ) -> some View {
        ResearchArtifactView(
            runID: runID,
            artifact: artifact,
            claims: claimsByArtifact[artifact.id] ?? [],
            citationsByClaim: citationsByClaim,
            speechAsset: detail.offlineAssets.first {
                $0.kind == .speech && $0.artifactID == artifact.id && $0.state == .ready
            },
            sourceForID: { sourceID in
                if let reference = ResearchComparisonSourceReference.parse(sourceID),
                   let source = try? store.source(
                       runID: reference.runID,
                       sourceID: reference.sourceID
                   ) {
                    return source
                }
                return detail.sources.first { $0.sourceID == sourceID }
            },
            openSource: { selectedSource = $0 },
            onOfflineChange: reload,
            presentation: presentation,
            showsSourceLinkNotice: showsSourceLinkNotice
        )
    }

    private func representedPostCount(
        for artifact: ResearchArtifactRecord,
        in detail: ResearchRunDetail
    ) -> Int {
        let sourcesByID = Dictionary(uniqueKeysWithValues: detail.sources.map { ($0.sourceID, $0) })
        let postIDs = (claimsByArtifact[artifact.id] ?? []).flatMap { claim in
            let supportingPostIDs = (citationsByClaim[claim.id] ?? [])
                .filter(\.validated)
                .compactMap { sourcesByID[$0.sourceID]?.postSourceID }
            let conflictingPostIDs = claim.conflictingSourceIDs.compactMap {
                sourcesByID[$0]?.postSourceID
            }
            return supportingPostIDs + conflictingPostIDs
        }
        return Set(postIDs).count
    }

    @ViewBuilder
    private func coverageSection(_ coverage: ResearchCoverageInput) -> some View {
        Section("Coverage") {
            LabeledContent("Posts analyzed", value: "\(coverage.postsAnalyzed) of \(coverage.postsRequested)")
            if let missingPostsNotice = coverage.missingPostsNotice {
                Label(missingPostsNotice, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            LabeledContent("Comments analyzed", value: "\(coverage.commentsAnalyzed)")
            LabeledContent("Comments fetched", value: "\(coverage.commentsFetched)")
            LabeledContent("Comments reported", value: "\(coverage.commentsReported)")
            if coverage.commentsOmitted > 0 {
                LabeledContent("Comments omitted", value: "\(coverage.commentsOmitted)")
                    .foregroundStyle(.orange)
            }
            ForEach(coverage.failureMessages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func reload() {
        do {
            let loaded = try store.detail(runID: runID)
            detail = loaded
            var loadedClaims: [UUID: [ResearchClaimRecord]] = [:]
            var loadedCitations: [UUID: [ResearchCitationRecord]] = [:]
            for artifact in loaded.artifacts {
                let claims = try store.claims(artifactID: artifact.id)
                loadedClaims[artifact.id] = claims
                for claim in claims {
                    loadedCitations[claim.id] = try store.citations(claimID: claim.id)
                }
            }
            claimsByArtifact = loadedClaims
            citationsByClaim = loadedCitations
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareExport(format: ResearchExportFormat) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("redapp-research-exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("research-\(runID.uuidString).\(format.fileExtension)")
            switch format {
            case .json:
                try store.exportJSON(runID: runID).write(to: url, options: .atomic)
            case .markdown:
                try store.exportMarkdown(runID: runID).write(to: url, atomically: true, encoding: .utf8)
            }
            exportDocument = ResearchExportDocument(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateCompleteOverview() {
        guard let detail else { return }
        isGeneratingCompleteOverview = true
        errorMessage = nil
        Task {
            defer { isGeneratingCompleteOverview = false }
            do {
                _ = try await ensureCompleteOverview(for: detail)
                reload()
            } catch is CancellationError {
                // Closing the revision while generation is running is not an error.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func ensureCompleteOverview(
        for initialDetail: ResearchRunDetail
    ) async throws -> ResearchArtifactRecord {
        let latestDetail = try store.detail(runID: runID)
        if let existing = latestDetail.revisionArtifacts.completeOverview {
            return existing
        }

        let postSummaries = latestDetail.revisionArtifacts.postSummaries
        guard !postSummaries.isEmpty else { throw GroundedResearchError.noPostSummaries }
        let prompt = completeOverviewPrompt(from: postSummaries, detail: latestDetail)
        let startedAt = Date()
        let service = SummaryService.shared
        let generated: String
        if service.settings.selectedSummaryProvider == .webAI {
            generated = try await AppState.shared.performWebAIRequestAsync(
                title: "Complete Revision Overview",
                prompt: prompt
            )
        } else {
            generated = try await service.summarize(text: prompt)
        }

        let body = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw GroundedResearchError.invalidResponse }

        // A second action may have finished while the model was working.
        if let existing = try store.detail(runID: runID).revisionArtifacts.completeOverview {
            return existing
        }
        return try store.addArtifact(
            runID: runID,
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
            coverage: initialDetail.run.coverage,
            legacyUncited: true
        )
    }

    private func completeOverviewPrompt(
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

        Use clear Markdown headings and short paragraphs. End with a short coverage sentence stating that all \(postSummaries.count) saved post summaries were included in the request. Do not output a table or a post-by-post list.

        Saved batch coverage: \(detail.run.coverage.postsAnalyzed) posts analyzed and \(detail.run.coverage.commentsAnalyzed) comments analyzed.

        \(entries)
        """
    }

    private func generateGroundedReport() {
        guard let detail else { return }
        isGeneratingGroundedReport = true
        errorMessage = nil
        let inputs = detail.sources.map(ResearchSourceInput.init(record:))
        Task {
            defer {
                isGeneratingCompleteOverview = false
                isGeneratingGroundedReport = false
            }
            do {
                let overview: ResearchArtifactRecord
                if let savedOverview = detail.revisionArtifacts.completeOverview {
                    overview = savedOverview
                } else {
                    isGeneratingCompleteOverview = true
                    overview = try await ensureCompleteOverview(for: detail)
                    isGeneratingCompleteOverview = false
                    reload()
                }
                let result = try await GroundedResearchService.shared.generateReport(
                    instruction: "Using the complete overview only to decide what matters, produce 8 to 12 representative key points. Cover the major recurring themes, meaningful disagreement, and important minority topics. Prefer support from different posts. When a recurring point is supported by multiple posts, cite at least two different posts. Every point and quotation must still be supported by the saved Reddit sources. Do not claim that these linked examples are exhaustive.",
                    sources: inputs,
                    coverage: detail.run.coverage,
                    guidingOverview: overview.body,
                    balanceAcrossPosts: true,
                    promptVersion: 3
                )
                try store.addArtifact(
                    runID: runID,
                    kind: .overallReport,
                    title: result.response.title,
                    body: result.response.markdown,
                    generationReceipt: result.receipt,
                    coverage: detail.run.coverage,
                    conflicts: result.response.conflicts,
                    missingData: result.response.missingData,
                    claims: result.response.claims
                )
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func makeOffline() {
        isUpdatingOfflinePack = true
        Task {
            do {
                _ = try await ResearchOfflinePackManager.shared.makeOffline(runID: runID)
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
            isUpdatingOfflinePack = false
        }
    }

    private func deleteOfflinePack() {
        isUpdatingOfflinePack = true
        Task {
            do {
                try await ResearchOfflinePackManager.shared.deletePack(runID: runID)
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
            isUpdatingOfflinePack = false
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
        .onDisappear {
            stopSpeechOperation()
        }
    }

    @ViewBuilder
    private var artifactContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if artifact.legacyUncited && showsSourceLinkNotice {
                Label(
                    "This summary was created before source links were saved. Its points cannot open the original posts or comments.",
                    systemImage: "info.circle"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if claims.isEmpty {
                MarkdownTextView(content: artifact.body, fontScale: 0.8)
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
                                        Button(ResearchComparisonSourceReference.displayName(for: citation.sourceID)) {
                                            openSource(source)
                                        }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
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
                                            Button(ResearchComparisonSourceReference.displayName(for: sourceID)) {
                                                openSource(source)
                                            }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                                .tint(.orange)
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
                DisclosureGroup("What does confidence mean?") {
                    Text("Confidence shows how much support the app found for a point. Low does not mean the point is wrong. It means there were few supporting posts or comments, some sources disagreed, or not enough comments were available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
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
                            toggleSpeechPlayback()
                        } label: {
                            Image(systemName: speechActivity.isPlayback ? "stop.circle.fill" : "play.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(speechActivity.isBusy && !speechActivity.isPlayback)
                        .accessibilityLabel(speechActivity.isPlayback ? "Stop report speech" : "Play report with MLX speech")

                        Button {
                            saveSpeechOffline()
                        } label: {
                            Image(systemName: speechSaved || speechAsset != nil ? "checkmark.circle.fill" : "arrow.down.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(speechActivity.isBusy || speechSaved || speechAsset != nil)
                        .accessibilityLabel(
                            speechSaved || speechAsset != nil ? "Speech saved offline" : "Save speech offline"
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

    private func toggleSpeechPlayback() {
        if speechActivity.isPlayback {
            stopSpeechOperation()
        } else {
            startSpeechPlayback()
        }
    }

    private func startSpeechPlayback() {
        stopSpeechOperation()
        let operationID = UUID()
        speechOperationID = operationID
        let settings = SummaryService.shared.settings
        let plainText = MarkdownTextView.extractPlainText(from: artifact.body)
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
                    for (index, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
                            throw CancellationError()
                        }
                        speechActivity = .preparing(current: index + 1, total: chunks.count)
                        let data = try await KokoroTTSService.shared.synthesize(
                            text: chunk,
                            voice: settings.kokoroVoice,
                            speed: Float(settings.kokoroSpeed)
                        )
                        try await playSpeechData(
                            data,
                            current: index + 1,
                            total: chunks.count,
                            playbackToken: playbackToken
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
        let plainText = MarkdownTextView.extractPlainText(from: artifact.body)
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
    @State private var areScoreChangesExpanded = false
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
                revisionOverallSummarySection(left)
                revisionOverallSummarySection(right)
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
                                    tint: .blue
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
                    } footer: {
                        if !areAddedSourcesExpanded {
                            Text("Collapsed to keep large comparisons easy to scan.")
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
                                    tint: .blue
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
                    } footer: {
                        if !areEarlierOnlySourcesExpanded {
                            Text("Collapsed to keep large comparisons easy to scan.")
                        }
                    }
                }

                if !difference.edited.isEmpty {
                    Section("Edited sources") {
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
                                            Text(delta.sourceID)
                                                .font(.caption.monospaced())
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
                        Text("Scores show engagement, not whether a claim is true. Expand to inspect individual changes.")
                    }
                }

                if !difference.coverageChanges.isEmpty {
                    Section("Coverage changes") {
                        ForEach(difference.coverageChanges) { delta in
                            comparisonRow(delta.title, left: delta.oldValue, right: delta.newValue)
                        }
                    }
                }

                Section("Coverage") {
                    comparisonRow("Posts analyzed", left: left.run.coverage.postsAnalyzed, right: right.run.coverage.postsAnalyzed)
                    comparisonRow("Comments analyzed", left: left.run.coverage.commentsAnalyzed, right: right.run.coverage.commentsAnalyzed)
                    comparisonRow("Comments omitted", left: left.run.coverage.commentsOmitted, right: right.run.coverage.commentsOmitted)
                    comparisonRow("Reports and answers", left: left.artifacts.count, right: right.artifacts.count)
                    comparisonRow("Saved sources", left: left.sources.count, right: right.sources.count)
                }
                revisionRemainingOutputsSection(left)
                revisionRemainingOutputsSection(right)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(comparesDifferentFilters ? "Compare Feeds" : "Compare Revisions")
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

    @ViewBuilder
    private func revisionOverallSummarySection(_ detail: ResearchRunDetail) -> some View {
        Section("\(snapshotName(detail)) — Overall summary") {
            if let summary = detail.revisionArtifacts.overallSummary {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownTextView(content: summary.body, fontScale: 0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    HStack(alignment: .top) {
                        Text("Saved \(summary.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ResearchMLXSpeechControls(
                            text: summary.body,
                            runID: summary.runID,
                            artifactID: summary.id,
                            label: "overall summary"
                        )
                    }
                }
                .padding(.vertical, 3)
            } else {
                Text("No overall summary was saved for this revision.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func revisionRemainingOutputsSection(_ detail: ResearchRunDetail) -> some View {
        let overallID = detail.revisionArtifacts.overallSummary?.id
        let remaining = detail.artifacts.filter { $0.id != overallID }
        if !remaining.isEmpty {
            Section("\(snapshotName(detail)) — Individual summaries and reports") {
                ForEach(remaining) { artifact in
                    DisclosureGroup {
                        MarkdownTextView(content: artifact.body, fontScale: 0.8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(artifact.title)
                                    .font(.headline)
                                Text(artifact.kind.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ResearchMLXSpeechControls(
                                text: artifact.body,
                                runID: artifact.runID,
                                artifactID: artifact.id,
                                label: artifact.kind.displayName.lowercased()
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func comparisonContextSection(
        left: ResearchRunDetail,
        right: ResearchRunDetail
    ) -> some View {
        Section {
            comparisonSnapshotRow(title: "Earlier snapshot", detail: left)
            comparisonSnapshotRow(title: "Later snapshot", detail: right)
            if comparesDifferentFilters {
                Label(
                    "These snapshots use different Reddit feed types. Differences show what each feed surfaced and do not automatically mean the subreddit changed over time.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Compared snapshots")
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
            Text("\(detail.run.coverage.postsAnalyzed) posts · \(detail.run.coverage.commentsAnalyzed) comments analyzed")
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
        Section("Exact changes") {
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
        comparesDifferentFilters ? captureName(detail.run) : "Revision \(detail.run.revision)"
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
                    Text("\(snapshotLabel) · \(delta.sourceID)")
                        .font(.caption.monospaced())
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
            .buttonStyle(.bordered)
            .controlSize(.small)
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
            return encodedID
        }
        if let left, reference.runID == left.run.id {
            return "\(snapshotName(left)) · \(reference.sourceID)"
        }
        if let right, reference.runID == right.run.id {
            return "\(snapshotName(right)) · \(reference.sourceID)"
        }
        return reference.displayName
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
            HStack {
                Text("Plain-language comparison")
                    .font(.headline)
                Spacer()
                ResearchMLXSpeechControls(
                    text: speechText,
                    runID: report.runID,
                    artifactID: report.id,
                    label: "comparison"
                )
            }
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

    private var speechText: String {
        plainLanguageNarrative.isEmpty ? report.body : plainLanguageNarrative
    }

    @ViewBuilder
    private var evidenceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if claims.isEmpty {
                MarkdownTextView(content: report.body, fontScale: 0.8)
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
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
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

private struct ResearchRunStateBadge: View {
    let state: ResearchRunState

    var body: some View {
        Text(state.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(state == .ready ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
            .clipShape(Capsule())
            .accessibilityHint(state.explanation)
    }
}

struct ResearchConfidenceBadge: View {
    let confidence: ResearchEvidenceConfidence

    var body: some View {
        Label(confidence.displayName, systemImage: "checkmark.shield")
            .font(.caption2.weight(.semibold))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch confidence {
        case .high: return .green
        case .medium: return .blue
        case .low: return .orange
        case .unverified: return .red
        }
    }
}

private enum ResearchExportFormat {
    case markdown
    case json

    var fileExtension: String { self == .json ? "json" : "md" }
}

private struct ResearchExportDocument: Identifiable {
    let id = UUID()
    let url: URL
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
