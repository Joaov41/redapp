import AVFoundation
import SwiftUI

@MainActor
struct ResearchLibraryView: View {
    @ObservedObject private var store = ResearchLibraryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedTags = Set<String>()
    @State private var presentedExport: ResearchExportDocument?
    @State private var errorMessage: String?

    private var availableTags: [String] {
        Array(Set(store.items.flatMap(\.tags))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
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
                            NavigationLink {
                                ResearchItemDetailView(itemID: item.id)
                            } label: {
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
            .listStyle(.insetGrouped)
            .navigationTitle("Research Library")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search reports, posts, comments, authors"
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: ResearchSearchRequest(query: searchText, tags: selectedTags)) {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                store.reload(searchText: searchText, tags: selectedTags)
            }
            .refreshable {
                store.reload(searchText: searchText, tags: selectedTags)
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
            Text(item.subreddit == "home" ? "Home feed" : "r/\(item.subreddit)")
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
    @State private var showTagEditor = false
    @State private var tagText = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let item {
                Section("Collection") {
                    LabeledContent("Scope", value: item.subreddit == "home" ? "Home feed" : "r/\(item.subreddit)")
                    LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if !item.tags.isEmpty {
                        LabeledContent("Tags", value: item.tags.joined(separator: ", "))
                    }
                }

                if runs.count >= 2 {
                    Section("Compare") {
                        NavigationLink {
                            ResearchComparisonView(leftRunID: runs[1].id, rightRunID: runs[0].id)
                        } label: {
                            Label("Compare latest two revisions", systemImage: "rectangle.split.2x1")
                        }
                    }
                }

                Section("History") {
                    ForEach(runs) { run in
                        NavigationLink {
                            ResearchRunDetailView(runID: run.id)
                        } label: {
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
                        .textInputAutocapitalization(.never)
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
                            let tags = tagText.split(separator: ",").map(String.init)
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
struct ResearchRunDetailView: View {
    let runID: UUID
    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var detail: ResearchRunDetail?
    @State private var claimsByArtifact: [UUID: [ResearchClaimRecord]] = [:]
    @State private var citationsByClaim: [UUID: [ResearchCitationRecord]] = [:]
    @State private var selectedSource: ResearchSourceRecord?
    @State private var exportDocument: ResearchExportDocument?
    @State private var errorMessage: String?
    @State private var isGeneratingGroundedReport = false
    @State private var isUpdatingOfflinePack = false

    var body: some View {
        List {
            if let detail {
                overallSummarySection(detail)
                coverageSection(detail.run.coverage)
                postSummariesSection(detail)
                remainingArtifactsSection(detail)
                followUpQuestionsSection(detail)

                Section("Sources") {
                    NavigationLink {
                        ResearchSourcesListView(sources: detail.sources)
                    } label: {
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
                    Button {
                        generateGroundedReport()
                    } label: {
                        Label("Create a report with source links", systemImage: "checkmark.seal")
                    }
                } label: {
                    if isGeneratingGroundedReport {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .disabled(isGeneratingGroundedReport || detail?.sources.isEmpty != false)
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
            if let summary = detail.revisionArtifacts.overallSummary {
                artifactView(summary, in: detail, presentation: .expanded)
            } else {
                Text("No overall summary was saved for this revision.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Overall summary")
        } footer: {
            if detail.revisionArtifacts.overallSummary != nil {
                Text("This is the summary you already created. Use the … menu to create a separate report with links to the original posts and comments.")
            }
        }
    }

    @ViewBuilder
    private func postSummariesSection(_ detail: ResearchRunDetail) -> some View {
        if !detail.revisionArtifacts.postSummaries.isEmpty {
            Section("Individual post summaries") {
                ForEach(detail.revisionArtifacts.postSummaries) { artifact in
                    artifactView(artifact, in: detail, presentation: .disclosure)
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
            NavigationLink {
                ResearchConversationView(runID: runID)
            } label: {
                Label("Ask about this saved batch", systemImage: "plus.bubble")
            }
            ForEach(detail.conversations) { conversation in
                NavigationLink {
                    ResearchConversationView(runID: runID, conversationID: conversation.id)
                } label: {
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
        presentation: ResearchArtifactPresentation
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
            presentation: presentation
        )
    }

    @ViewBuilder
    private func coverageSection(_ coverage: ResearchCoverageInput) -> some View {
        Section("Coverage") {
            LabeledContent("Posts analyzed", value: "\(coverage.postsAnalyzed) of \(coverage.postsRequested)")
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

    private func generateGroundedReport() {
        guard let detail else { return }
        isGeneratingGroundedReport = true
        errorMessage = nil
        let inputs = detail.sources.map(ResearchSourceInput.init(record:))
        Task {
            do {
                let result = try await GroundedResearchService.shared.generateReport(
                    instruction: "Produce a concise evidence-grounded report of the most important findings in this saved batch.",
                    sources: inputs,
                    coverage: detail.run.coverage
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
            isGeneratingGroundedReport = false
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
    let sources: [ResearchSourceRecord]

    var body: some View {
        List(sources) { source in
            NavigationLink {
                ResearchSourceDetailView(source: source)
            } label: {
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
    }
}

private enum ResearchArtifactPresentation {
    case disclosure
    case expanded
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
    @State private var isSavingSpeech = false
    @State private var speechSaved = false
    @State private var speechError: String?
    @State private var offlineSpeechPlayer: AVAudioPlayer?

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
        .alert("Couldn’t Save Speech", isPresented: Binding(
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
            if artifact.legacyUncited {
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
                Label($0, systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                if let speechAsset {
                    Button {
                        playOfflineSpeech(speechAsset)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Play saved MLX speech")
                }
                Button {
                    saveSpeechOffline()
                } label: {
                    if isSavingSpeech {
                        ProgressView()
                    } else {
                        Image(systemName: speechSaved ? "checkmark.circle.fill" : "waveform.badge.plus")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isSavingSpeech || speechSaved || speechAsset != nil)
                .accessibilityLabel(
                    speechSaved || speechAsset != nil ? "Speech saved offline" : "Save MLX speech offline"
                )
            }
        }
    }

    private func saveSpeechOffline() {
        let settings = SummaryService.shared.settings
        isSavingSpeech = true
        Task {
            do {
                let data = try await KokoroTTSService.shared.synthesize(
                    text: MarkdownTextView.extractPlainText(from: artifact.body),
                    voice: settings.kokoroVoice,
                    speed: Float(settings.kokoroSpeed)
                )
                _ = try await ResearchOfflinePackManager.shared.saveSpeech(
                    data,
                    runID: runID,
                    artifactID: artifact.id,
                    voice: settings.kokoroVoice,
                    speed: settings.kokoroSpeed
                )
                speechSaved = true
                onOfflineChange()
            } catch {
                speechError = error.localizedDescription
            }
            isSavingSpeech = false
        }
    }

    private func playOfflineSpeech(_ asset: ResearchOfflineAssetRecord) {
        Task {
            do {
                let url = try await ResearchOfflinePackManager.shared.localURL(
                    relativePath: asset.relativePath
                )

                #if os(iOS)
                let audioSession = AVAudioSession.sharedInstance()
                do {
                    try audioSession.setCategory(
                        .playback,
                        mode: .spokenAudio,
                        options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP]
                    )
                } catch {
                    // Some iPad audio routes reject the Bluetooth option combination.
                    try audioSession.setCategory(
                        .playback,
                        mode: .spokenAudio,
                        options: [.duckOthers]
                    )
                }
                try audioSession.setActive(true)
                #endif

                // Match the established MLX playback path used elsewhere in the app.
                // AVAudioPlayer's URL initializer can reject this generated Float32 WAV
                // with OSStatus -50 even though its in-memory initializer accepts it.
                let audioData = try Data(contentsOf: url)
                let player = try AVAudioPlayer(data: audioData)
                guard player.prepareToPlay() else {
                    throw NSError(
                        domain: "ResearchLibraryPlayback",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The saved speech file could not be prepared for playback."]
                    )
                }
                offlineSpeechPlayer = player
                guard player.play() else {
                    throw NSError(
                        domain: "ResearchLibraryPlayback",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The saved speech file could not start playing."]
                    )
                }
            } catch {
                speechError = error.localizedDescription
            }
        }
    }
}

@MainActor
struct ResearchSourceDetailView: View {
    let source: ResearchSourceRecord
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
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

@MainActor
struct ResearchComparisonView: View {
    let leftRunID: UUID
    let rightRunID: UUID
    @ObservedObject private var store = ResearchLibraryStore.shared
    @State private var left: ResearchRunDetail?
    @State private var right: ResearchRunDetail?
    @State private var difference: ResearchRevisionDiff?
    @State private var changeReport: ResearchArtifactRecord?
    @State private var changeClaims: [ResearchClaimRecord] = []
    @State private var changeCitations: [UUID: [ResearchCitationRecord]] = [:]
    @State private var selectedSource: ResearchSourceRecord?
    @State private var isGeneratingReport = false
    @State private var generationTask: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let left, let right, let difference {
                subredditProgressSection(difference)
                revisionOverallSummarySection(left)
                revisionOverallSummarySection(right)
                exactChangesSection(difference)

                if !difference.added.isEmpty {
                    Section("Added sources") {
                        ForEach(difference.added) { delta in
                            sourceChangeRow(
                                delta,
                                revision: difference.newRevision,
                                runID: difference.newRunID,
                                systemImage: "plus.circle.fill",
                                tint: .green
                            )
                        }
                    }
                }

                if !difference.removed.isEmpty {
                    Section("Removed sources") {
                        ForEach(difference.removed) { delta in
                            sourceChangeRow(
                                delta,
                                revision: difference.oldRevision,
                                runID: difference.oldRunID,
                                systemImage: "minus.circle.fill",
                                tint: .red
                            )
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
                                        title: "Revision \(difference.oldRevision)",
                                        runID: difference.oldRunID,
                                        sourceID: delta.sourceID
                                    )
                                    sourceButton(
                                        title: "Revision \(difference.newRevision)",
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
                    } header: {
                        Text("Score changes")
                    } footer: {
                        Text("Score changes measure engagement, not whether a claim is true.")
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
        .navigationTitle("Compare Revisions")
        .task {
            loadComparison()
        }
        .onDisappear {
            generationTask?.cancel()
        }
        .sheet(item: $selectedSource) { source in
            NavigationStack { ResearchSourceDetailView(source: source) }
        }
        .alert("Comparison unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private func revisionOverallSummarySection(_ detail: ResearchRunDetail) -> some View {
        Section("Revision \(detail.run.revision) — Overall summary") {
            if let summary = detail.revisionArtifacts.overallSummary {
                VStack(alignment: .leading, spacing: 8) {
                    Text(summary.body)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Text("Saved \(summary.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            Section("Revision \(detail.run.revision) — Individual summaries and reports") {
                ForEach(remaining) { artifact in
                    DisclosureGroup {
                        Text(artifact.body)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(artifact.title)
                                .font(.headline)
                            Text(artifact.kind.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func subredditProgressSection(_ difference: ResearchRevisionDiff) -> some View {
        Section {
            if let changeReport {
                ResearchComparisonReportView(
                    report: changeReport,
                    claims: changeClaims,
                    citationsByClaim: changeCitations,
                    openSource: openComparisonSource
                )
                Button {
                    generateWhatChangedReport(difference)
                } label: {
                    if isGeneratingReport {
                        HStack {
                            ProgressView()
                            Text("Rewriting the plain-language update…")
                        }
                    } else {
                        Label("Regenerate plain-language update", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isGeneratingReport || !difference.hasSourceChanges)
            } else if difference.hasSourceChanges {
                Text("Create a short, everyday-language explanation of how the saved subreddit discussion moved from the earlier snapshot to the later one.")
                    .foregroundStyle(.secondary)
                Button {
                    generateWhatChangedReport(difference)
                } label: {
                    if isGeneratingReport {
                        HStack {
                            ProgressView()
                            Text("Writing the plain-language update…")
                        }
                    } else {
                        Label("Explain the progress in plain language", systemImage: "text.quote")
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
        } header: {
            Text(subredditProgressTitle)
        } footer: {
            Text("This describes the saved sample, not every person or discussion in the subreddit.")
        }
    }

    @ViewBuilder
    private func exactChangesSection(_ difference: ResearchRevisionDiff) -> some View {
        Section("Exact changes") {
            if !difference.hasChanges {
                Label("No saved source or coverage changes detected.", systemImage: "equal.circle")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Added", value: "\(difference.added.count)")
                LabeledContent("Removed", value: "\(difference.removed.count)")
                LabeledContent("Edited", value: "\(difference.edited.count)")
                LabeledContent("Score changes", value: "\(difference.scoreChanges.count)")
                LabeledContent("Unchanged sources", value: "\(difference.unchangedSourceCount)")
            }
        }
    }

    private var subredditProgressTitle: String {
        guard let subreddit = right?.sources
            .map(\.subreddit)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return "How the subreddit progressed"
        }
        return "How r/\(subreddit) progressed"
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
            try loadSavedChangeReport(from: loadedRight, title: loadedDifference.reportTitle)
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
        isGeneratingReport = true
        errorMessage = nil
        let subreddit = right.sources
            .map(\.subreddit)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .map { "r/\($0)" } ?? "the saved subreddit"

        let instruction = """
        Explain, in plain everyday language, how the saved subreddit discussion progressed from revision \(difference.oldRevision) to revision \(difference.newRevision).

        Subreddit: \(subreddit)
        Earlier snapshot: \(left.run.capturedAt.formatted(date: .abbreviated, time: .shortened))
        Later snapshot: \(right.run.capturedAt.formatted(date: .abbreviated, time: .shortened))

        Write for a reader who does not want a technical data-diff report. Return 3 to 6 short claims in a natural reading order so that, when read together, they form a clear update. Focus on which topics or concerns appeared, faded, or changed; whether the saved discussion became more supportive, critical, uncertain, or divided; and what new consensus or conflict emerged. Only describe those shifts when the saved evidence supports them.

        In claim text, do not mention source IDs, manifests, digests, database terms, or raw added/removed counts. Say “the saved discussion” or “this saved sample” rather than claiming to represent every member of the subreddit. Comparative claims should cite evidence from both revisions when available. If the material only establishes that something is new or absent in one snapshot, state that carefully without guessing why.

        The deterministic manifest below is authoritative. Discuss only changes present in it. Treat score changes only as engagement changes, never as proof that a claim is true. Every factual claim must cite the revision-prefixed saved sources. If the evidence cannot establish why something changed, say so under missing data.

        \(difference.promptManifest)

        Previous saved report excerpts (context only, not evidence):
        \(reportExcerpts(left.artifacts))

        New saved report excerpts (context only, not evidence):
        \(reportExcerpts(right.artifacts))
        """

        generationTask = Task {
            defer {
                isGeneratingReport = false
                generationTask = nil
            }
            do {
                let result = try await GroundedResearchService.shared.generateReport(
                    instruction: instruction,
                    sources: comparisonSources,
                    coverage: right.run.coverage,
                    promptVersion: 2
                )
                try Task.checkCancellation()
                let artifactBody = ResearchChangeNarrative.artifactBody(
                    claimTexts: result.response.claims.map(\.text),
                    evidenceMarkdown: result.response.markdown
                )
                _ = try store.addArtifact(
                    runID: right.run.id,
                    kind: .changeReport,
                    title: difference.reportTitle,
                    body: artifactBody,
                    generationReceipt: result.receipt,
                    coverage: right.run.coverage,
                    conflicts: result.response.conflicts,
                    missingData: result.response.missingData,
                    claims: result.response.claims,
                    validationSources: comparisonSources
                )
                loadComparison()
            } catch is CancellationError {
                // Leaving the comparison screen is a normal cancellation path.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reportExcerpts(_ artifacts: [ResearchArtifactRecord]) -> String {
        let excerpts = artifacts
            .filter { $0.kind != .changeReport }
            .prefix(8)
            .map { artifact in
                let compact = artifact.body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                return "- \(artifact.title): \(String(compact.prefix(900)))"
            }
        return excerpts.isEmpty ? "None saved." : excerpts.joined(separator: "\n")
    }

    @ViewBuilder
    private func sourceChangeRow(
        _ delta: ResearchSourceDelta,
        revision: Int,
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
                    Text("R\(revision) · \(delta.sourceID)")
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
    let openSource: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if plainLanguageNarrative.isEmpty {
                Text("There wasn’t enough saved information to explain how the discussion changed.")
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
                                    Button(ResearchComparisonSourceReference.displayName(for: citation.sourceID)) {
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
        Text(state.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(state == .ready ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
            .clipShape(Capsule())
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
