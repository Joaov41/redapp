import SwiftUI
import AVFoundation

// MARK: - Workspace

/// The Research Library as a section of the app shell. The sidebar lists
/// saved research; the workspace shows the selected report, or the library
/// overview (comparisons, tags, search) when nothing is selected.
@MainActor
struct ResearchLibraryWorkspace: View {
    @Binding var selectedItemID: UUID?
    @Binding var navigationPath: NavigationPath
    let initialComparison: ResearchComparisonGenerationState?
    var onShowSidebar: (() -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if let selectedItemID {
                    ResearchItemBriefingLoader(
                        itemID: selectedItemID,
                        onShowLibrary: { self.selectedItemID = nil },
                        onShowSidebar: onShowSidebar
                    )
                    .id(selectedItemID)
                } else {
                    ResearchLibraryView(
                        navigationPath: $navigationPath,
                        initialComparison: initialComparison,
                        isEmbedded: true
                    )
                    .navigationTitle("Research Library")
                    .toolbar {
                        // On iPhone the split view already shows a back button to the sidebar.
                        if let onShowSidebar, horizontalSizeClass != .compact {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(action: onShowSidebar) {
                                    Image(systemName: "sidebar.leading")
                                }
                                .accessibilityLabel("Show sidebar")
                            }
                        }
                    }
                }
            }
            .modifier(ResearchLibraryDestinations())
        }
        .environment(\.researchLibraryNavigate, { route in
            navigationPath.append(route)
        })
        .onChange(of: selectedItemID) { _, _ in
            navigationPath = NavigationPath()
        }
    }
}

/// Resolves a saved feed to its latest snapshot and shows the report.
@MainActor
struct ResearchItemBriefingLoader: View {
    let itemID: UUID
    var onShowLibrary: (() -> Void)? = nil
    var onShowSidebar: (() -> Void)? = nil

    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var latestRunID: UUID?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let latestRunID {
                ResearchBriefingView(
                    runID: latestRunID,
                    onShowLibrary: onShowLibrary,
                    onShowSidebar: onShowSidebar
                )
            } else if didLoad {
                ContentUnavailableView(
                    "Nothing Saved Yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("This saved feed has no snapshots yet.")
                )
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RedappDesign.canvas)
        .task(id: itemID) {
            latestRunID = (try? store.runs(itemID: itemID))?.first?.id
            didLoad = true
            try? store.markOpened(itemID: itemID)
        }
    }
}

// MARK: - Report

private enum BriefingTab: String, CaseIterable, Hashable {
    case overview = "Overview"
    case topics = "Topics"
    case sources = "Sources"
    case ask = "Ask"
}

/// The one screen for a saved report: overview, numbered key points backed by
/// quotes, disagreements, topics, sources and questions. Snapshots, comparisons,
/// export and offline download are reached from here as well.
@MainActor
struct ResearchBriefingView: View {
    let runID: UUID
    var onShowLibrary: (() -> Void)? = nil
    var onShowSidebar: (() -> Void)? = nil

    @ObservedObject private var store = ResearchLibraryStore.shared
    @ObservedObject private var builder = ResearchReportBuilder.shared
    @Environment(\.researchLibraryNavigate) private var navigate
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var speaker = RedappSpeechPlayer()

    @State private var selectedRunID: UUID?
    @State private var detail: ResearchRunDetail?
    @State private var snapshots: [ResearchRunRecord] = []
    @State private var claimsByArtifact: [UUID: [ResearchClaimRecord]] = [:]
    @State private var citationsByClaim: [UUID: [ResearchCitationRecord]] = [:]
    @State private var tab: BriefingTab = .overview
    @State private var selectedClaimID: UUID?
    @State private var isEvidencePresented = false
    @State private var question = ""
    @State private var exportDocument: BriefingExport?
    @State private var isUpdatingOffline = false
    @State private var expandedTopicIDs = Set<UUID>()
    @State private var showsFullOverview = false
    @State private var selectedSource: ResearchSourceRecord?
    @State private var showsCompare = false
    @State private var pendingRoute: ResearchLibraryRoute?
    @State private var showsTagEditor = false
    @State private var itemPendingDeletion: ResearchItemRecord?
    @State private var tagText = ""
    @State private var errorMessage: String?

    private var currentRunID: UUID { selectedRunID ?? runID }
    private var buildPhase: ResearchReportBuilder.Phase? { builder.phase(for: currentRunID) }
    private var isBuilding: Bool { buildPhase?.isRunning == true }
    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var horizontalPadding: CGFloat { isCompact ? 20 : 40 }

    private var report: ResearchArtifactRecord? { detail?.revisionArtifacts.sourceLinkedReport }
    private var overview: ResearchArtifactRecord? {
        detail?.revisionArtifacts.completeOverview ?? detail?.revisionArtifacts.overallSummary
    }
    private var themes: [ResearchClaimRecord] {
        guard let report else { return [] }
        return (claimsByArtifact[report.id] ?? []).sorted { $0.claimOrder < $1.claimOrder }
    }
    private var selectedClaim: ResearchClaimRecord? {
        themes.first { $0.id == selectedClaimID }
    }
    private var communityName: String {
        guard let detail else { return "" }
        return detail.item.subreddit == "home" ? "your Home feed" : "r/\(detail.item.subreddit)"
    }
    private var isSavedOffline: Bool {
        detail?.offlineAssets.contains { $0.kind != .speech && $0.state == .ready } == true
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if let detail {
                    VStack(alignment: .leading, spacing: 0) {
                        header(detail)
                        RedappUnderlineTabs(tabs: BriefingTab.allCases, selection: $tab) { $0.rawValue }
                            .padding(.top, 22)
                        tabContent(detail)
                            .padding(.top, 26)
                    }
                    .frame(maxWidth: RedappDesign.reportWidth, alignment: .leading)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 28)
                    .padding(.bottom, 120)
                    .frame(maxWidth: .infinity)
                } else {
                    ProgressView().padding(.top, 120)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if detail != nil {
                    RedappAskBar(
                        placeholder: "Ask about this report…",
                        text: $question,
                        onSubmit: askQuestion
                    )
                    .frame(maxWidth: RedappDesign.reportWidth)
                    .padding(.horizontal, isCompact ? 16 : 32)
                    .padding(.bottom, 14)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [RedappDesign.canvas.opacity(0), RedappDesign.canvas],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                }
            }
        }
        .background(RedappDesign.canvas)
        .safeAreaBar(edge: .top, spacing: 0) {
            topBar
        }
        .toolbar(.hidden, for: .navigationBar)
        .inspector(isPresented: $isEvidencePresented) {
            if let claim = selectedClaim, let detail {
                ResearchEvidencePanel(
                    claim: claim,
                    citations: citationsByClaim[claim.id] ?? [],
                    detail: detail,
                    onOpenSource: { selectedSource = $0 },
                    onClose: { isEvidencePresented = false }
                )
                .inspectorColumnWidth(min: 320, ideal: RedappDesign.panelWidth, max: 460)
            } else {
                ContentUnavailableView("Select a Key Point", systemImage: "quote.bubble")
                    .inspectorColumnWidth(min: 320, ideal: RedappDesign.panelWidth, max: 460)
            }
        }
        .sheet(item: $exportDocument) { document in
            ShareSheet(activityItems: [document.url])
        }
        .sheet(item: $selectedSource) { source in
            NavigationStack { ResearchSourceDetailView(source: source) }
        }
        .sheet(isPresented: $showsCompare, onDismiss: {
            if let pendingRoute {
                self.pendingRoute = nil
                navigate(pendingRoute)
            }
        }) {
            ResearchCompareSheet(runID: currentRunID) { route in
                pendingRoute = route
                showsCompare = false
            }
        }
        .sheet(isPresented: $showsTagEditor) {
            tagEditor
        }
        .researchItemDeletionConfirmation(item: $itemPendingDeletion, beforeDelete: { _ in
            speaker.stop()
            if let onShowLibrary { onShowLibrary() } else { dismiss() }
        })
        .alert("Research Library", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: currentRunID) {
            reload()
            if let detail { builder.buildAutomaticallyIfNeeded(detail) }
        }
        .onChange(of: buildPhase) { _, _ in reload() }
        .onDisappear { speaker.stop() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            if let onShowSidebar {
                Button(action: onShowSidebar) {
                    Image(systemName: "sidebar.leading")
                }
                .buttonStyle(RedappIconButtonStyle())
                .accessibilityLabel("Show sidebar")
            }

            Button {
                if let onShowLibrary { onShowLibrary() } else { dismiss() }
            } label: {
                Label("Library", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(RedappDesign.inkSecondary)
            .accessibilityLabel("Back to Research Library")

            if !isCompact, detail != nil {
                Text("/").foregroundStyle(RedappDesign.inkTertiary)
                Text(communityName.replacingOccurrences(of: "your ", with: ""))
                    .font(.subheadline)
                    .foregroundStyle(RedappDesign.inkSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                showsCompare = true
            } label: {
                Label("Compare", systemImage: "arrow.left.arrow.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(RedappSecondaryButtonStyle(isCapsule: false, isBordered: !isCompact, isCompact: isCompact))
            .disabled(detail == nil)

            moreMenu
        }
        .padding(.horizontal, isCompact ? 12 : 24)
        .frame(height: 56)
        .background(RedappDesign.canvas)
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button {
                    toggleOffline()
                } label: {
                    Label(
                        isSavedOffline ? "Remove offline download" : "Download for offline",
                        systemImage: isSavedOffline ? "trash" : "arrow.down.circle"
                    )
                }
                .disabled(isUpdatingOffline)
            }
            Section("Export") {
                Button { prepareExport(.markdown) } label: { Label("Markdown", systemImage: "doc.richtext") }
                Button { prepareExport(.json) } label: { Label("JSON archive", systemImage: "curlybraces") }
            }
            if let item = detail?.item {
                Section {
                    Button {
                        perform { try store.setPinned(item.pinnedAt == nil, itemID: item.id) }
                        reload()
                    } label: {
                        Label(item.pinnedAt == nil ? "Pin to top" : "Unpin", systemImage: item.pinnedAt == nil ? "pin" : "pin.slash")
                    }
                    Button {
                        tagText = item.tags.joined(separator: ", ")
                        showsTagEditor = true
                    } label: {
                        Label("Edit tags…", systemImage: "tag")
                    }
                }
            }
            if let detail, !detail.sources.isEmpty, report != nil {
                Section {
                    Button {
                        builder.build(runID: currentRunID, rebuildKeyPoints: true)
                    } label: {
                        Label("Rebuild key points", systemImage: "arrow.clockwise")
                    }
                    .disabled(isBuilding)
                }
            }
            if let item = detail?.item {
                Section {
                    Button(role: .destructive) {
                        itemPendingDeletion = item
                    } label: {
                        Label("Delete this feed…", systemImage: "trash")
                    }
                }
            }
        } label: {
            Group {
                if isUpdatingOffline {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .foregroundStyle(RedappDesign.ink)
        .accessibilityLabel("More options")
    }

    private var tagEditor: some View {
        NavigationStack {
            Form {
                TextField("research, important, later", text: $tagText)
                    .textInputAutocapitalization(.never)
                Text("Separate tags with commas. Tags let you filter the library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .scrollContentBackground(.hidden)
            .background(RedappDesign.canvas)
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsTagEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let itemID = detail?.item.id {
                            let tags = tagText.split(separator: ",").map(String.init)
                            perform { try store.setTags(tags, itemID: itemID) }
                        }
                        showsTagEditor = false
                        reload()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: Header

    private func header(_ detail: ResearchRunDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RedappEyebrow("Community briefing")
            if isCompact {
                titleText
                listenButton(detail)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    titleText
                    Spacer(minLength: 0)
                    listenButton(detail)
                        .padding(.top, 4)
                }
            }
            snapshotLine(detail)
            if detail.run.state == .partial {
                ResearchPartialReason(coverage: detail.run.coverage)
            }
        }
    }

    private var titleText: some View {
        Text("What \(communityName) is talking about")
            .font(isCompact ? .title.bold() : RedappType.display)
            .foregroundStyle(RedappDesign.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func listenButton(_ detail: ResearchRunDetail) -> some View {
        Button {
            if speaker.isSpeaking {
                speaker.stop()
            } else {
                speaker.speak(briefingSpeechText(detail))
            }
        } label: {
            Label(
                speaker.isSpeaking ? "Stop" : "Listen",
                systemImage: speaker.isSpeaking ? "stop.fill" : "play.fill"
            )
        }
        .buttonStyle(RedappSecondaryButtonStyle(isCompact: isCompact))
        .disabled(overview == nil && themes.isEmpty)
    }

    /// "50 posts · Hot · Saved 28 Sep" with a menu to switch between the times
    /// this feed was saved.
    private func snapshotLine(_ detail: ResearchRunDetail) -> some View {
        let feed = ResearchCaptureLabel.displayName(sortMode: detail.run.sortMode, timeRange: detail.run.timeRange)
        let date = detail.run.capturedAt.formatted(date: .abbreviated, time: .omitted)
        return HStack(spacing: 6) {
            Text("\(detail.run.coverage.postsAnalyzed) posts · \(feed) ·")
                .foregroundStyle(RedappDesign.inkSecondary)
            if snapshots.count > 1 {
                Menu {
                    Section("Saved \(snapshots.count) times") {
                        ForEach(snapshots) { run in
                            Button {
                                selectedRunID = run.id == runID ? nil : run.id
                            } label: {
                                if run.id == currentRunID {
                                    Label(snapshotMenuTitle(run), systemImage: "checkmark")
                                } else {
                                    Text(snapshotMenuTitle(run))
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Saved \(date)")
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(RedappDesign.accent)
                }
                .accessibilityLabel("Saved \(date). \(snapshots.count) snapshots. Choose another snapshot")
            } else {
                Text("Saved \(date)")
                    .foregroundStyle(RedappDesign.inkSecondary)
            }
        }
        .font(.subheadline)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private func snapshotMenuTitle(_ run: ResearchRunRecord) -> String {
        var title = run.capturedAt.formatted(date: .abbreviated, time: .shortened)
        if run.id == snapshots.first?.id { title += " · latest" }
        if run.state == .partial { title += " · some content missing" }
        return title
    }

    // MARK: Tabs

    @ViewBuilder
    private func tabContent(_ detail: ResearchRunDetail) -> some View {
        switch tab {
        case .overview: overviewTab(detail)
        case .topics: topicsTab(detail)
        case .sources: sourcesTab(detail)
        case .ask: askTab(detail)
        }
    }

    @ViewBuilder
    private func overviewTab(_ detail: ResearchRunDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            buildStatus(detail)

            if let overview {
                Text(leadParagraph(from: overview.body))
                    .font(.title3)
                    .foregroundStyle(RedappDesign.ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if !isBuilding && detail.revisionArtifacts.postSummaries.isEmpty {
                RedappInlineMessage(
                    title: "No overview",
                    message: "This snapshot was saved without post summaries, so there is nothing to build an overview from. The key points below come straight from the saved posts and comments.",
                    kind: .info
                )
            }

            if !themes.isEmpty {
                Text("Key points")
                    .font(RedappType.section)
                    .foregroundStyle(RedappDesign.ink)
                    .padding(.top, 36)
                    .padding(.bottom, 8)
                Rectangle().fill(RedappDesign.hairline).frame(height: 1)
                ForEach(Array(themes.enumerated()), id: \.element.id) { index, claim in
                    themeRow(index: index, claim: claim, detail: detail)
                    Rectangle().fill(RedappDesign.hairline).frame(height: 1)
                }
            } else if report != nil && !isBuilding {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Key points")
                        .font(RedappType.section)
                    Text("No key points could be linked to quotes in this snapshot.")
                        .foregroundStyle(RedappDesign.inkSecondary)
                    Button {
                        builder.build(runID: currentRunID, rebuildKeyPoints: true)
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(RedappChipButtonStyle())
                }
                .padding(.top, 36)
            }

            if let report, !report.conflicts.isEmpty {
                Text("Where opinions differ")
                    .font(RedappType.section)
                    .foregroundStyle(RedappDesign.ink)
                    .padding(.top, 32)
                    .padding(.bottom, 8)
                ForEach(report.conflicts, id: \.self) { conflict in
                    Text(conflict)
                        .font(.body)
                        .foregroundStyle(RedappDesign.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
            }

            if let report, !report.missingData.isEmpty {
                Text("What the saved posts can’t tell you")
                    .font(.headline)
                    .foregroundStyle(RedappDesign.ink)
                    .padding(.top, 24)
                    .padding(.bottom, 6)
                ForEach(report.missingData, id: \.self) { gap in
                    Label(gap, systemImage: "questionmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(RedappDesign.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                }
            }

            if let overview {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showsFullOverview.toggle() }
                } label: {
                    Label(showsFullOverview ? "Hide full overview" : "Read the full overview",
                          systemImage: showsFullOverview ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(RedappChipButtonStyle(isFilled: false))
                .padding(.top, 28)

                if showsFullOverview {
                    MarkdownTextView(
                        content: readableReplyText(overview.body),
                        fontScale: 0.8,
                        sourceLinks: sourceLinks(detail)
                    )
                    .padding(.top, 12)
                }
            }

            aboutThisData(detail)
                .padding(.top, 32)
        }
    }

    /// Progress, failure or (for Web AI) a manual start, for the parts of the
    /// report that are built after saving.
    @ViewBuilder
    private func buildStatus(_ detail: ResearchRunDetail) -> some View {
        switch buildPhase {
        case .some(let phase) where phase.isRunning:
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Building your report")
                        .font(.subheadline.weight(.semibold))
                    Text(phase.statusText)
                        .font(.subheadline)
                        .foregroundStyle(RedappDesign.inkSecondary)
                    Text("You can keep browsing; it continues in the background.")
                        .font(.footnote)
                        .foregroundStyle(RedappDesign.inkTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .redappCard()
            .padding(.bottom, 24)
        case .some(.failed(let message)):
            VStack(alignment: .leading, spacing: 10) {
                RedappInlineMessage(title: "The report couldn’t be finished", message: message, kind: .warning)
                Button {
                    builder.build(runID: currentRunID, rebuildKeyPoints: false)
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(RedappChipButtonStyle())
            }
            .padding(.bottom, 24)
        default:
            if builder.needsBuild(detail) && !builder.canBuildAutomatically {
                VStack(alignment: .leading, spacing: 10) {
                    RedappInlineMessage(
                        title: "Finish this report",
                        message: "The overview and key points are created with your AI provider. Web AI needs you to paste replies, so it starts only when you ask.",
                        kind: .info
                    )
                    Button {
                        builder.build(runID: currentRunID, rebuildKeyPoints: false)
                    } label: {
                        Label("Build report", systemImage: "sparkles")
                    }
                    .buttonStyle(RedappChipButtonStyle())
                }
                .padding(.bottom, 24)
            }
        }
    }

    /// Collection details that most readers don't need, kept out of the way.
    private func aboutThisData(_ detail: ResearchRunDetail) -> some View {
        let coverage = detail.run.coverage
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("Saved \(detail.run.capturedAt.formatted(date: .long, time: .shortened)) from \(communityName), \(ResearchCaptureLabel.displayName(sortMode: detail.run.sortMode, timeRange: detail.run.timeRange)) feed.")
                Text("\(coverage.postsAnalyzed) of \(coverage.postsRequested) requested posts were summarized.")
                Text(commentLine(coverage))
                if coverage.commentsOmitted > 0 {
                    Text("\(coverage.commentsOmitted) loaded comments were beyond the reading limit and weren’t used.")
                }
                ForEach(coverage.failureMessages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text(methodNote)
                    .foregroundStyle(RedappDesign.inkTertiary)
            }
            .font(.footnote)
            .foregroundStyle(RedappDesign.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            Label("About this data", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RedappDesign.ink)
        }
        .tint(RedappDesign.inkSecondary)
    }

    /// Key points built from version 4 of the prompt onward also passed the
    /// quote-support check; older ones only had their quotes matched.
    private var methodNote: String {
        let quoteCheck = (report?.generationReceipt?.promptVersion ?? 0) >= 4
            ? "Key points only use quotes found in the saved posts and comments, and each quote was checked to make sure it supports its point."
            : "Key points only use quotes found in the saved posts and comments. These key points were made before quotes were also checked for support; rebuild them from the … menu to add that check."
        return quoteCheck + " The overview is written from the post summaries and has no quotes of its own."
    }

    private func commentLine(_ coverage: ResearchCoverageInput) -> String {
        if coverage.commentsReported > coverage.commentsFetched {
            return "\(coverage.commentsAnalyzed) comments were read. Reddit listed \(coverage.commentsReported) and \(coverage.commentsFetched) could be loaded."
        }
        return "\(coverage.commentsAnalyzed) comments were read."
    }

    private func themeRow(index: Int, claim: ResearchClaimRecord, detail: ResearchRunDetail) -> some View {
        let citations = (citationsByClaim[claim.id] ?? []).filter(\.validated)
        let sourcesByID = Dictionary(detail.sources.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        let commentCount = citations.filter { sourcesByID[$0.sourceID]?.kind == .comment }.count
        let postCount = Set(citations.compactMap { sourcesByID[$0.sourceID]?.postSourceID }).count
        let isSelected = isEvidencePresented && selectedClaimID == claim.id

        return HStack(alignment: .firstTextBaseline, spacing: isCompact ? 14 : 24) {
            Text(String(format: "%02d", index + 1))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(RedappDesign.accent)
                .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Text(claim.text)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(RedappDesign.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(themeSupportLine(comments: commentCount, posts: postCount, conflicts: claim.conflictingSourceIDs.count))
                    .font(.body)
                    .foregroundStyle(RedappDesign.inkSecondary)
                HStack(spacing: 10) {
                    Button {
                        selectedClaimID = claim.id
                        isEvidencePresented = true
                    } label: {
                        Label(commentCount > 0 ? "See the quotes" : "See the sources", systemImage: "arrow.up.right")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                    .buttonStyle(RedappChipButtonStyle(isFilled: isSelected))
                    .disabled(citations.isEmpty)
                    ResearchConfidenceBadge(confidence: claim.confidence)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 20)
    }

    private func themeSupportLine(comments: Int, posts: Int, conflicts: Int) -> String {
        var parts: [String] = []
        if comments > 0 { parts.append("\(comments) supporting comment\(comments == 1 ? "" : "s")") }
        if posts > 0 { parts.append("from \(posts) post\(posts == 1 ? "" : "s")") }
        var line = parts.joined(separator: " ")
        if conflicts > 0 {
            line += line.isEmpty ? "" : ". "
            line += "\(conflicts) source\(conflicts == 1 ? "" : "s") disagree\(conflicts == 1 ? "s" : "")."
        } else if !line.isEmpty {
            line += "."
        }
        return line.isEmpty ? "Linked to the saved sources." : line
    }

    @ViewBuilder
    private func topicsTab(_ detail: ResearchRunDetail) -> some View {
        let summaries = detail.revisionArtifacts.postSummaries
        if summaries.isEmpty {
            ContentUnavailableView("No Topics", systemImage: "list.bullet.rectangle", description: Text("This snapshot has no per-post summaries."))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("One summary for each saved post.")
                    .font(.subheadline)
                    .foregroundStyle(RedappDesign.inkSecondary)
                    .padding(.bottom, 4)
                ForEach(Array(summaries.enumerated()), id: \.element.id) { index, artifact in
                    let isExpanded = expandedTopicIDs.contains(artifact.id)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(artifact.title)
                            .font(.headline)
                            .foregroundStyle(RedappDesign.ink)
                        if isExpanded {
                            MarkdownTextView(content: readableReplyText(artifact.body), fontScale: 0.75, sourceLinks: sourceLinks(detail))
                        } else {
                            Text(MarkdownTextView.extractPlainText(
                                from: ResearchPostSummaryPresentation.displayMarkdown(from: artifact.body)
                            ))
                                .font(.body)
                                .foregroundStyle(RedappDesign.inkSecondary)
                                .lineLimit(3)
                        }
                        Button(isExpanded ? "Show less" : "Read summary") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isExpanded { expandedTopicIDs.remove(artifact.id) } else { expandedTopicIDs.insert(artifact.id) }
                            }
                        }
                        .buttonStyle(RedappChipButtonStyle(isFilled: false))
                    }
                    .padding(.vertical, 18)
                    if index < summaries.count - 1 {
                        Rectangle().fill(RedappDesign.hairline).frame(height: 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sourcesTab(_ detail: ResearchRunDetail) -> some View {
        let posts = detail.sources.filter { $0.kind == .post }
        let commentsByPost = Dictionary(grouping: detail.sources.filter { $0.kind == .comment }, by: \.postSourceID)
        VStack(alignment: .leading, spacing: 0) {
            Text("\(posts.count) posts · \(detail.sources.count - posts.count) comments saved")
                .font(.subheadline)
                .foregroundStyle(RedappDesign.inkSecondary)
                .padding(.bottom, 12)
            ForEach(posts) { post in
                Button {
                    selectedSource = post
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        RedappCommunityBadge(name: post.subreddit, size: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(post.title ?? "Untitled post")
                                .font(.headline)
                                .foregroundStyle(RedappDesign.ink)
                                .multilineTextAlignment(.leading)
                            Text(sourceMeta(post, extra: "\(commentsByPost[post.sourceID]?.count ?? 0) comments saved"))
                                .font(.subheadline)
                                .foregroundStyle(RedappDesign.inkSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(RedappDesign.inkTertiary)
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(RedappDesign.hairline).frame(height: 1)
            }
            Button {
                navigate(.sources(runID: currentRunID))
            } label: {
                Label("Browse every saved post and comment", systemImage: "arrow.up.right")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .buttonStyle(RedappChipButtonStyle(isFilled: false))
            .padding(.top, 16)
        }
    }

    @ViewBuilder
    private func askTab(_ detail: ResearchRunDetail) -> some View {
        let savedReports = otherSavedReports(detail)
        VStack(alignment: .leading, spacing: 0) {
            Text("Answers use only the saved posts and comments. Each point links to the quotes behind it, and the answer says what the posts can’t tell you.")
                .font(.body)
                .foregroundStyle(RedappDesign.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            if detail.conversations.isEmpty {
                Text("No questions yet. Use the field below to ask one.")
                    .font(.subheadline)
                    .foregroundStyle(RedappDesign.inkTertiary)
            } else {
                ForEach(detail.conversations) { conversation in
                    listRow(
                        title: conversation.title,
                        subtitle: "Updated \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                    ) {
                        navigate(.conversation(runID: currentRunID, conversationID: conversation.id))
                    }
                }
            }

            if !savedReports.isEmpty {
                Text("Other saved answers and reports")
                    .font(.headline)
                    .foregroundStyle(RedappDesign.ink)
                    .padding(.top, 32)
                    .padding(.bottom, 4)
                ForEach(savedReports) { artifact in
                    listRow(
                        title: artifact.title,
                        subtitle: "\(artifact.kind.displayName) · \(artifact.createdAt.formatted(date: .abbreviated, time: .shortened))"
                    ) {
                        navigate(.artifact(runID: currentRunID, artifactID: artifact.id))
                    }
                }
            }
        }
    }

    private func listRow(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(RedappDesign.ink)
                            .multilineTextAlignment(.leading)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(RedappDesign.inkSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(RedappDesign.inkTertiary)
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(RedappDesign.hairline).frame(height: 1)
        }
    }

    /// Answers and reports other than the overview, the key points, post
    /// summaries and conversation replies. Community comparisons have their own
    /// place in the Compare sheet.
    private func otherSavedReports(_ detail: ResearchRunDetail) -> [ResearchArtifactRecord] {
        let overviewID = overview?.id
        return detail.revisionArtifacts.remainingArtifacts
            .filter { artifact in
                artifact.id != overviewID
                    && artifact.kind != .conversationAnswer
                    && artifact.kind != .communityComparison
                    && !artifact.title.hasPrefix("Community Q&A [")
                    && !artifact.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Helpers

    private func leadParagraph(from markdown: String) -> String {
        let paragraphs = markdown
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { paragraph in
                guard !paragraph.isEmpty, !paragraph.hasPrefix("#"), !paragraph.hasPrefix("|") else { return false }
                let firstLine = paragraph.components(separatedBy: .newlines).first ?? ""
                return !firstLine.hasPrefix("- ") && !firstLine.hasPrefix("* ") && firstLine.range(of: #"^\d+\."#, options: .regularExpression) == nil
            }
        let lead = paragraphs.first ?? MarkdownTextView.extractPlainText(from: markdown)
        return MarkdownTextView.extractPlainText(from: lead)
            .replacingOccurrences(of: #"\s*\[(?:SOURCE:\s*)?t[1-6]_[^\]]*\]"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    private func sourceLinks(_ detail: ResearchRunDetail) -> [String: URL] {
        var links: [String: URL] = [:]
        for source in detail.sources {
            if let url = URL(string: normalizeRedditPermalink(source.permalink)) {
                links[source.sourceID] = url
            }
        }
        return links
    }

    private func sourceMeta(_ source: ResearchSourceRecord, extra: String? = nil) -> String {
        var parts: [String] = []
        if let author = source.author, !author.isEmpty { parts.append("u/\(author)") }
        if let created = source.sourceCreatedAt { parts.append("\(RedappTime.shortAge(from: created)) ago") }
        if let extra { parts.append(extra) }
        return parts.joined(separator: " · ")
    }

    private func briefingSpeechText(_ detail: ResearchRunDetail) -> String {
        var sections: [String] = ["What \(communityName) is talking about."]
        if let overview { sections.append(leadParagraph(from: overview.body)) }
        if !themes.isEmpty {
            sections.append("Key points.")
            sections.append(contentsOf: themes.enumerated().map { "\($0.offset + 1). \($0.element.text)" })
        }
        if let report, !report.conflicts.isEmpty {
            sections.append("Where opinions differ.")
            sections.append(contentsOf: report.conflicts)
        }
        return sections.joined(separator: "\n\n")
    }

    private func askQuestion() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        question = ""
        navigate(.ask(runID: currentRunID, question: trimmed))
    }

    private func reload() {
        do {
            let loaded = try store.detail(runID: currentRunID)
            detail = loaded
            snapshots = try store.runs(itemID: loaded.item.id)
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

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { errorMessage = error.localizedDescription }
    }

    private enum ExportFormat { case markdown, json }

    private func prepareExport(_ format: ExportFormat) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("redapp-research-exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            switch format {
            case .markdown:
                let url = directory.appendingPathComponent("research-\(currentRunID.uuidString).md")
                try store.exportMarkdown(runID: currentRunID).write(to: url, atomically: true, encoding: .utf8)
                exportDocument = BriefingExport(url: url)
            case .json:
                let url = directory.appendingPathComponent("research-\(currentRunID.uuidString).json")
                try store.exportJSON(runID: currentRunID).write(to: url, options: .atomic)
                exportDocument = BriefingExport(url: url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleOffline() {
        let runID = currentRunID
        let remove = isSavedOffline
        isUpdatingOffline = true
        Task {
            do {
                if remove {
                    try await ResearchOfflinePackManager.shared.deletePack(runID: runID)
                } else {
                    let result = try await ResearchOfflinePackManager.shared.makeOffline(runID: runID)
                    if !result.isComplete {
                        errorMessage = "The report was downloaded, but \(result.failedAssets) image\(result.failedAssets == 1 ? "" : "s") couldn’t be saved for offline use."
                    }
                }
                reload()
            } catch {
                errorMessage = error.localizedDescription
            }
            isUpdatingOffline = false
        }
    }
}

private struct BriefingExport: Identifiable {
    let url: URL
    var id: String { url.path }
}

// MARK: - Compare

/// One place to start any comparison: an earlier snapshot of this feed, another
/// feed of the same subreddit, or another subreddit. Saved community
/// comparisons for this report are listed first.
@MainActor
private struct ResearchCompareSheet: View {
    let runID: UUID
    let onSelect: (ResearchLibraryRoute) -> Void

    @ObservedObject private var store = ResearchLibraryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var baseRun: ResearchRunRecord?
    @State private var earlierSnapshots: [ResearchRunRecord] = []
    @State private var otherFeeds: [ResearchRunRecord] = []
    @State private var otherCommunities: [ResearchRunRecord] = []
    @State private var savedComparisons: [ResearchCommunityComparisonRecord] = []
    @State private var errorMessage: String?

    private var hasOnlineModel: Bool {
        ResearchCommunityComparisonService.isCloudComparisonProvider(
            SummaryService.shared.settings.selectedSummaryProvider
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if let baseRun {
                    if !savedComparisons.isEmpty {
                        Section("Your comparisons") {
                            ForEach(savedComparisons) { comparison in
                                Button {
                                    onSelect(.communityComparison(id: comparison.id))
                                } label: {
                                    row(
                                        title: comparison.subject,
                                        subtitle: comparisonSubtitle(comparison)
                                    )
                                }
                            }
                        }
                    }

                    Section {
                        if earlierSnapshots.isEmpty {
                            emptyRow("Save this feed again another day to see how the discussion changes.")
                        }
                        ForEach(earlierSnapshots) { candidate in
                            Button {
                                onSelect(orderedComparison(baseRun, candidate))
                            } label: {
                                row(
                                    title: "Saved \(candidate.capturedAt.formatted(date: .abbreviated, time: .shortened))",
                                    subtitle: "\(candidate.coverage.postsAnalyzed) posts"
                                )
                            }
                        }
                    } header: {
                        Text("How it changed over time")
                    }

                    Section {
                        if otherFeeds.isEmpty {
                            emptyRow("Save the Hot, New or Top feed of \(communityName(baseRun)) to compare what each one shows.")
                        }
                        ForEach(otherFeeds) { candidate in
                            Button {
                                onSelect(orderedComparison(baseRun, candidate))
                            } label: {
                                row(
                                    title: ResearchCaptureLabel.displayName(sortMode: candidate.sortMode, timeRange: candidate.timeRange),
                                    subtitle: "Saved \(candidate.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(candidate.coverage.postsAnalyzed) posts"
                                )
                            }
                        }
                    } header: {
                        Text("Another feed of \(communityName(baseRun))")
                    } footer: {
                        if !otherFeeds.isEmpty {
                            Text("Hot, New and Top show different posts, so differences can come from the feed rather than the community.")
                        }
                    }

                    Section {
                        if !hasOnlineModel {
                            emptyRow("Comparing subreddits needs an online model. Choose Gemini, Codex / Summarize, Apple Cloud, Apple PCC or Web AI in Settings.")
                        } else if otherCommunities.isEmpty {
                            emptyRow("Save another subreddit to compare it with this one.")
                        } else {
                            ForEach(otherCommunities) { candidate in
                                let compatibility = ResearchCommunityCompatibility.evaluate(base: baseRun, candidate: candidate)
                                Button {
                                    onSelect(.communitySetup(firstRunID: baseRun.id, secondRunID: candidate.id))
                                } label: {
                                    row(
                                        title: candidate.subreddit == "home" ? "Home feed" : "r/\(candidate.subreddit)",
                                        subtitle: "\(ResearchCaptureLabel.displayName(sortMode: candidate.sortMode, timeRange: candidate.timeRange)) · saved \(candidate.capturedAt.formatted(date: .abbreviated, time: .omitted))",
                                        trailing: compatibility.label,
                                        trailingColor: compatibility.score >= 82 ? RedappDesign.positive : .orange
                                    )
                                }
                            }
                        }
                    } header: {
                        Text("Another subreddit")
                    } footer: {
                        if hasOnlineModel && !otherCommunities.isEmpty {
                            Text("You’ll choose a subject next. Closer matches appear first.")
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .scrollContentBackground(.hidden)
            .background(RedappDesign.canvas)
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { load() }
            .alert("Compare", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func row(
        title: String,
        subtitle: String,
        trailing: String? = nil,
        trailingColor: Color = RedappDesign.inkSecondary
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(RedappDesign.ink)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(RedappDesign.inkSecondary)
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(trailingColor)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RedappDesign.inkTertiary)
        }
        .contentShape(Rectangle())
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(RedappDesign.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func communityName(_ run: ResearchRunRecord) -> String {
        run.subreddit == "home" ? "your Home feed" : "r/\(run.subreddit)"
    }

    private func comparisonSubtitle(_ comparison: ResearchCommunityComparisonRecord) -> String {
        let names = [comparison.leftRunID, comparison.rightRunID]
            .compactMap { try? store.run(id: $0) }
            .map { $0.subreddit == "home" ? "Home feed" : "r/\($0.subreddit)" }
            .joined(separator: " and ")
        switch comparison.state {
        case .preparing, .running: return "\(names) · in progress"
        case .ready: return names
        case .failed: return "\(names) · needs attention"
        }
    }

    private func orderedComparison(_ first: ResearchRunRecord, _ second: ResearchRunRecord) -> ResearchLibraryRoute {
        first.capturedAt <= second.capturedAt
            ? .comparison(leftRunID: first.id, rightRunID: second.id)
            : .comparison(leftRunID: second.id, rightRunID: first.id)
    }

    private func load() {
        do {
            guard let run = try store.run(id: runID) else { throw ResearchStoreError.runNotFound }
            baseRun = run
            earlierSnapshots = try store.runs(itemID: run.itemID).filter { $0.id != run.id }
            otherFeeds = try store.comparisonRuns(for: run.id, differentFiltersOnly: true)
            otherCommunities = try store.communityComparisonRuns(for: run.id)
            savedComparisons = try store.communityComparisons(runID: run.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// "View sources ↗": title first, arrow after.
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
                .font(.footnote.weight(.semibold))
        }
    }
}

// MARK: - Source evidence panel

private enum EvidenceTab: String, CaseIterable, Hashable {
    case comments = "Comments"
    case posts = "Posts"
}

/// Right-hand panel listing the quotes behind one key point.
@MainActor
private struct ResearchEvidencePanel: View {
    let claim: ResearchClaimRecord
    let citations: [ResearchCitationRecord]
    let detail: ResearchRunDetail
    let onOpenSource: (ResearchSourceRecord) -> Void
    let onClose: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var tab: EvidenceTab = .comments

    private var sourcesByID: [String: ResearchSourceRecord] {
        Dictionary(detail.sources.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var commentEvidence: [(citation: ResearchCitationRecord, source: ResearchSourceRecord)] {
        citations.filter(\.validated).compactMap { citation in
            guard let source = sourcesByID[citation.sourceID], source.kind == .comment else { return nil }
            return (citation, source)
        }
    }

    private var postEvidence: [ResearchSourceRecord] {
        var seen = Set<String>()
        return citations.filter(\.validated).compactMap { citation -> ResearchSourceRecord? in
            guard let source = sourcesByID[citation.sourceID] else { return nil }
            let postID = source.kind == .post ? source.sourceID : source.postSourceID
            guard seen.insert(postID).inserted else { return nil }
            return sourcesByID[postID] ?? (source.kind == .post ? source : nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RedappPanelHeader(title: "Quotes behind this point", subtitle: claim.text, onClose: onClose)
                .padding(.horizontal, 22)
                .padding(.top, 20)
            RedappUnderlineTabs(tabs: EvidenceTab.allCases, selection: $tab) { $0.rawValue }
                .padding(.horizontal, 22)
                .padding(.top, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .comments:
                        if commentEvidence.isEmpty {
                            emptyState("No comment quotes are linked to this point.")
                        }
                        ForEach(commentEvidence, id: \.citation.id) { item in
                            evidenceCard(source: item.source, quote: item.citation.supportingQuote)
                            Rectangle().fill(RedappDesign.hairline).frame(height: 1)
                        }
                    case .posts:
                        if postEvidence.isEmpty {
                            emptyState("No posts are linked to this point.")
                        }
                        ForEach(postEvidence) { post in
                            evidenceCard(source: post, quote: nil)
                            Rectangle().fill(RedappDesign.hairline).frame(height: 1)
                        }
                    }

                    if !claim.conflictingSourceIDs.isEmpty {
                        Label("\(claim.conflictingSourceIDs.count) saved source\(claim.conflictingSourceIDs.count == 1 ? "" : "s") disagree with this point.",
                              systemImage: "arrow.left.arrow.right")
                            .font(.footnote)
                            .foregroundStyle(RedappDesign.inkSecondary)
                            .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RedappDesign.panel)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(RedappDesign.inkSecondary)
            .padding(.vertical, 24)
    }

    private func evidenceCard(source: ResearchSourceRecord, quote: String?) -> some View {
        let postTitle = source.kind == .post ? source.title : sourcesByID[source.postSourceID]?.title
        let excerpt = quote?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? String(MarkdownTextView.extractPlainText(from: source.rawMarkdown).prefix(260))

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                RedappCommunityBadge(name: source.subreddit, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("r/\(source.subreddit)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RedappDesign.ink)
                    Text([source.author.map { "u/\($0)" }, source.sourceCreatedAt.map { "\(RedappTime.shortAge(from: $0)) ago" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(RedappDesign.inkSecondary)
                    if let postTitle, source.kind == .comment {
                        Text("From: \(postTitle)")
                            .font(.footnote)
                            .foregroundStyle(RedappDesign.inkSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Menu {
                    Button { onOpenSource(source) } label: { Label("Show Saved Source", systemImage: "doc.text") }
                    Button {
                        #if os(iOS)
                        UIPasteboard.general.string = excerpt
                        #endif
                    } label: { Label("Copy Quote", systemImage: "doc.on.doc") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RedappDesign.inkSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More options")
            }

            if source.kind == .post {
                Text(source.title ?? "Untitled post")
                    .font(.headline)
                    .foregroundStyle(RedappDesign.ink)
            }
            if !excerpt.isEmpty {
                RedappQuote(text: excerpt)
            }

            if let url = URL(string: normalizeRedditPermalink(source.permalink)) {
                Button {
                    openURL(url)
                } label: {
                    Label("Open thread", systemImage: "arrow.up.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(RedappChipButtonStyle(isFilled: false))
            }
        }
        .padding(.vertical, 20)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Speech

/// "Listen" for briefings and panels: MLX voice when selected in Settings,
/// otherwise the on-device system voice.
@MainActor
final class RedappSpeechPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var task: Task<Void, Never>?
    private var player: AVAudioPlayer?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()
        let plainText = MarkdownTextView.extractPlainText(from: text)
        guard !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSpeaking = true
        configureAudioSession()

        let settings = SummaryService.shared.settings
        if settings.localTTSEngine == .kokoro && KokoroTTSService.shared.isAvailable {
            let chunks = KokoroTTSService.shared.speechChunks(from: plainText)
            let token = KokoroTTSService.shared.newPlaybackToken()
            task = Task { [weak self] in
                do {
                    try await playResearchSpeechChunks(
                        chunks,
                        voice: settings.kokoroVoice,
                        speed: Float(settings.kokoroSpeed),
                        playbackToken: token,
                        onPreparing: { _, _ in }
                    ) { data, _, _, playbackToken in
                        try await self?.play(data: data, token: playbackToken)
                    }
                } catch {
                    // Stopping or failing speech simply ends playback.
                }
                self?.isSpeaking = false
            }
        } else {
            let utterance = AVSpeechUtterance(string: plainText)
            if let voiceID = UserDefaults.standard.string(forKey: "LocalTTS.SelectedVoiceID"),
               let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
                utterance.voice = voice
            }
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        KokoroTTSService.shared.cancelPlayback()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    private func play(data: Data, token: UUID) async throws {
        let audioPlayer = try AVAudioPlayer(data: data)
        guard audioPlayer.prepareToPlay(), audioPlayer.play() else { throw CancellationError() }
        player = audioPlayer
        while audioPlayer.isPlaying {
            try Task.checkCancellation()
            guard KokoroTTSService.shared.isPlaybackTokenCurrent(token) else {
                audioPlayer.stop()
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func configureAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
