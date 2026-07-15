#if os(macOS)
import AppKit
import SwiftUI

struct MacSidebarCommandActions {
    let focusSubreddit: () -> Void
    let toggleFavorite: () -> Void
    let summarize: () -> Void
    let cancelSummary: () -> Void
    let canToggleFavorite: Bool
    let canSummarize: Bool
    let canCancelSummary: Bool
}

private struct MacSidebarCommandActionsKey: FocusedValueKey {
    typealias Value = MacSidebarCommandActions
}

extension FocusedValues {
    var macSidebarCommandActions: MacSidebarCommandActions? {
        get { self[MacSidebarCommandActionsKey.self] }
        set { self[MacSidebarCommandActionsKey.self] = newValue }
    }
}

struct MacSidebarCommands: Commands {
    @FocusedValue(\.macSidebarCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Feed") {
            Button("Open Subreddit Field") {
                actions?.focusSubreddit()
            }
            .keyboardShortcut("l", modifiers: [.command])
            .disabled(actions == nil)

            Button("Toggle Favorite") {
                actions?.toggleFavorite()
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(actions?.canToggleFavorite != true)

            Divider()

            Button("Summarize Loaded Posts") {
                actions?.summarize()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(actions?.canSummarize != true)

            Button("Cancel Summary") {
                actions?.cancelSummary()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(actions?.canCancelSummary != true)
        }
    }
}

struct MacSidebarControls: View {
    @Binding var subreddit: String
    @Binding var postLimit: String
    let favoriteSubreddits: [String]
    let isCurrentSubredditFavorite: Bool
    let selectedFeedMode: RedditFeedMode
    let selectedPostType: PostType
    let selectedTopPostTimeRange: TopPostTimeRange
    let loadedPostCount: Int
    let isLoading: Bool
    let isBatchProcessing: Bool
    let isExportingComments: Bool
    let batchProgress: Double
    let batchCurrentPost: Int
    let batchTotalPosts: Int
    let batchCurrentPostTitle: String
    let batchError: String?
    let exportProgress: Double
    let exportStatus: String
    let summaryProviderName: String
    let summaryProviderIsWebAI: Bool
    let webProviderName: String
    let isOpenAIConfigured: Bool
    let throughputText: String?
    let focusedField: FocusState<SidebarControls.Field?>.Binding
    let shareItems: [Any]
    @Binding var isPresentingShare: Bool

    let onLoadSubreddit: () -> Void
    let onReloadActiveFeed: () -> Void
    let onSelectFavorite: (String) -> Void
    let onRemoveFavorite: (String) -> Void
    let onToggleFavorite: () -> Void
    let onSelectHomeFeed: () -> Void
    let onSelectPostType: (PostType) -> Void
    let onSelectTopTimeRange: (TopPostTimeRange) -> Void
    let onSummarizePreferred: () -> Void
    let onSummarizeSettings: () -> Void
    let onSummarizeWeb: () -> Void
    let onCancelSummary: () -> Void
    let onExportComments: () -> Void

    private var normalizedSubreddit: String {
        subreddit.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canUseLoadedPosts: Bool {
        !isLoading && loadedPostCount > 0
    }

    private var postLimitError: String? {
        let trimmed = postLimit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter a positive post count." }
        guard let value = Int(trimmed), value > 0 else { return "Post count must be a positive whole number." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            subredditRow
            filtersRow

            if let postLimitError {
                Label(postLimitError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Post count error: \(postLimitError)")
            }

            actionsRow
            activityStatus
            providerStatus
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .controlSize(.regular)
        .focusedSceneValue(
            \.macSidebarCommandActions,
            MacSidebarCommandActions(
                focusSubreddit: { focusedField.wrappedValue = .subreddit },
                toggleFavorite: onToggleFavorite,
                summarize: onSummarizePreferred,
                cancelSummary: onCancelSummary,
                canToggleFavorite: !normalizedSubreddit.isEmpty,
                canSummarize: canUseLoadedPosts && !isExportingComments && !isBatchProcessing,
                canCancelSummary: isBatchProcessing
            )
        )
    }

    private var subredditRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                subredditEntry
                favoritesControlGroup
            }

            VStack(alignment: .leading, spacing: 8) {
                subredditEntry
                HStack {
                    Spacer()
                    favoritesControlGroup
                }
            }
        }
    }

    private var subredditEntry: some View {
        HStack(spacing: 6) {
            Text("r/")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Subreddit", text: $subreddit)
                .textFieldStyle(.roundedBorder)
                .focused(focusedField, equals: .subreddit)
                .onSubmit(onLoadSubreddit)
                .accessibilityLabel("Subreddit")
                .accessibilityHint("Press Return to load this subreddit")
        }
        .frame(maxWidth: .infinity)
    }

    private var favoritesControlGroup: some View {
        HStack(spacing: 6) {
            Menu {
                if favoriteSubreddits.isEmpty {
                    Text("No favorites yet")
                } else {
                    ForEach(favoriteSubreddits, id: \.self) { favorite in
                        Button("r/\(favorite)") {
                            onSelectFavorite(favorite)
                        }
                    }

                    Divider()

                    Menu("Remove Favorite", systemImage: "trash") {
                        ForEach(favoriteSubreddits, id: \.self) { favorite in
                            Button("r/\(favorite)", systemImage: "trash", role: .destructive) {
                                onRemoveFavorite(favorite)
                            }
                        }
                    }
                }
            } label: {
                Text("Favorites")
            }
            .buttonStyle(.bordered)
            .help("Open a favorite subreddit")

            Button(action: onToggleFavorite) {
                Image(systemName: isCurrentSubredditFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.bordered)
            .disabled(normalizedSubreddit.isEmpty)
            .help(isCurrentSubredditFavorite ? "Remove this subreddit from Favorites" : "Add this subreddit to Favorites")
            .accessibilityLabel(isCurrentSubredditFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .fixedSize()
    }

    private var filtersRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                postCountControl
                Spacer(minLength: 4)
                sortControl
                if selectedPostType == .top && selectedFeedMode != .home {
                    periodControl
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                postCountControl
                HStack(spacing: 8) {
                    sortControl
                    if selectedPostType == .top && selectedFeedMode != .home {
                        periodControl
                    }
                }
            }
        }
    }

    private var postCountControl: some View {
        HStack(spacing: 6) {
            Text("Posts")
                .foregroundStyle(.secondary)

            TextField("Count", text: $postLimit)
                .textFieldStyle(.roundedBorder)
                .focused(focusedField, equals: .postLimit)
                .frame(width: 58)
                .onSubmit {
                    guard postLimitError == nil else { return }
                    onReloadActiveFeed()
                }
                .accessibilityLabel("Number of posts")
                .accessibilityValue(postLimit)
                .accessibilityHint("Press Return to reload the active feed")
        }
        .fixedSize()
    }

    private var sortControl: some View {
        HStack(spacing: 6) {
            Text("Sort")
                .foregroundStyle(.secondary)

            Menu {
                Button("Home", systemImage: "house", action: onSelectHomeFeed)
                Divider()
                ForEach(PostType.allCases) { type in
                    Button(type.displayName) {
                        onSelectPostType(type)
                    }
                }
            } label: {
                Text(selectedFeedMode == .home ? "Home" : selectedPostType.displayName)
                    .frame(minWidth: 46)
            }
            .accessibilityLabel("Sort posts")
        }
        .fixedSize()
    }

    private var periodControl: some View {
        HStack(spacing: 6) {
            Text("Period")
                .foregroundStyle(.secondary)

            Menu {
                ForEach(TopPostTimeRange.allCases) { range in
                    Button(range.displayName) {
                        onSelectTopTimeRange(range)
                    }
                }
            } label: {
                Text(selectedTopPostTimeRange.displayName)
                    .frame(minWidth: 48)
            }
            .accessibilityLabel("Top posts period")
        }
        .fixedSize()
    }

    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button(action: onExportComments) {
                if isExportingComments {
                    Label("Preparing Comments", systemImage: "square.and.arrow.up")
                } else {
                    Label("Export Comments", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.bordered)
            .disabled(!canUseLoadedPosts || isBatchProcessing || isExportingComments)
            .help("Export and share comments from all loaded posts")
            .accessibilityHint("Exports up to 500 comments per loaded post")
            .background {
                MacSidebarSharePickerAnchor(items: shareItems, isPresented: $isPresentingShare)
            }

            Spacer(minLength: 8)

            if isBatchProcessing {
                Button(action: onCancelSummary) {
                    Label("Cancel Summary", systemImage: "stop.fill")
                }
                .buttonStyle(.glass)
                .tint(.red)
                .help("Cancel the active batch summary")
            } else if summaryProviderIsWebAI {
                Button(action: onSummarizePreferred) {
                    Label("Summarize \(loadedPostCount)", systemImage: "doc.on.doc.fill")
                }
                .buttonStyle(.glassProminent)
                .disabled(!canUseLoadedPosts || isExportingComments)
                .help("Summarize the loaded posts with \(summaryProviderName)")
            } else {
                Menu {
                    Button("Settings model — \(summaryProviderName)", systemImage: "slider.horizontal.3") {
                        onSummarizeSettings()
                    }

                    Button("Web model — \(webProviderName)", systemImage: "globe") {
                        onSummarizeWeb()
                    }
                } label: {
                    Label("Summarize \(loadedPostCount)", systemImage: "doc.on.doc.fill")
                } primaryAction: {
                    onSummarizePreferred()
                }
                .buttonStyle(.glassProminent)
                .disabled(!canUseLoadedPosts || isExportingComments)
                .help("Summarize the loaded posts with \(summaryProviderName); open the menu for another model")
            }
        }
    }

    @ViewBuilder
    private var activityStatus: some View {
        if isExportingComments {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView(value: exportProgress)
                    Text("\(Int(exportProgress * 100))%")
                        .monospacedDigit()
                }

                Text(exportStatus)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }

        if isBatchProcessing {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView(value: batchProgress)
                    Text("\(Int(batchProgress * 100))%")
                        .monospacedDigit()
                }

                Text("Processing post \(batchCurrentPost) of \(batchTotalPosts)")
                Text(batchCurrentPostTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let throughputText {
                    Text(throughputText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Summary progress: post \(batchCurrentPost) of \(batchTotalPosts), \(Int(batchProgress * 100)) percent")
        }

        if let batchError, !batchError.isEmpty {
            Label(batchError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerStatus: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                summaryStatus
                speechStatus
            }

            VStack(alignment: .leading, spacing: 4) {
                summaryStatus
                speechStatus
            }
        }
        .font(.caption)
    }

    private var summaryStatus: some View {
        Label("Summary: \(summaryProviderName)", systemImage: "brain")
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help("Current summary provider")
    }

    private var speechStatus: some View {
        Group {
            if isOpenAIConfigured {
                Label("Speech: OpenAI configured", systemImage: "waveform")
                    .foregroundStyle(.secondary)
            } else {
                Label("Speech: OpenAI setup needed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .lineLimit(1)
        .help(isOpenAIConfigured ? "OpenAI speech API key is configured" : "OpenAI speech API key is missing")
    }
}

private struct MacSidebarSharePickerAnchor: NSViewRepresentable {
    let items: [Any]
    @Binding var isPresented: Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isPresented, !items.isEmpty else { return }

        DispatchQueue.main.async {
            guard let window = nsView.window, window.isVisible else { return }
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
            isPresented = false
        }
    }
}
#endif
