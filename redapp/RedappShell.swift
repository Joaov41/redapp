import SwiftUI
import Combine

// MARK: - Sections

/// Top-level areas of the app, shown as the sidebar's navigation rows.
enum RedappSection: String, Hashable {
    case browse
    case library
    case saved

    var title: String {
        switch self {
        case .browse: return "Browse"
        case .library: return "Research Library"
        case .saved: return "Saved"
        }
    }

    var symbol: String {
        switch self {
        case .browse: return "house"
        case .library: return "books.vertical"
        case .saved: return "bookmark"
        }
    }
}

// MARK: - Communities

/// Favorite subreddits, shared by the sidebar and the feed header.
/// Persists to the same UserDefaults key the app has always used.
@MainActor
final class RedappCommunitiesModel: ObservableObject {
    static let shared = RedappCommunitiesModel()
    private static let key = "FavoriteSubreddits"

    @Published private(set) var favorites: [String]

    private init() {
        favorites = Self.load()
    }

    private static func load() -> [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func reload() {
        favorites = Self.load()
    }

    func isFavorite(_ name: String) -> Bool {
        favorites.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func toggle(_ name: String) {
        let cleaned = Self.normalized(name)
        guard !cleaned.isEmpty else { return }
        if let index = favorites.firstIndex(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            favorites.remove(at: index)
        } else {
            favorites.append(cleaned)
        }
        UserDefaults.standard.set(favorites, forKey: Self.key)
    }

    func remove(_ name: String) {
        favorites.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        UserDefaults.standard.set(favorites, forKey: Self.key)
    }

    static func normalized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("/r/") { return String(trimmed.dropFirst(3)) }
        if lowercased.hasPrefix("r/") { return String(trimmed.dropFirst(2)) }
        return trimmed
    }
}

// MARK: - Saved posts

/// Posts bookmarked on this device (the Saved section).
@MainActor
final class SavedPostsStore: ObservableObject {
    static let shared = SavedPostsStore()
    private static let key = "SavedPosts.v1"

    @Published private(set) var posts: [SubredditPostData] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([SubredditPostData].self, from: data) {
            posts = decoded
        }
    }

    func isSaved(_ post: SubredditPostData) -> Bool {
        posts.contains { $0.id == post.id }
    }

    func toggle(_ post: SubredditPostData) {
        if let index = posts.firstIndex(where: { $0.id == post.id }) {
            posts.remove(at: index)
        } else {
            posts.insert(post, at: 0)
        }
        persist()
    }

    func remove(_ post: SubredditPostData) {
        posts.removeAll { $0.id == post.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(posts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Sidebar

/// Charcoal navigation sidebar from the mockup: brand, search, sections,
/// a contextual list (communities or saved research), settings and account.
struct RedappSidebar: View {
    @Binding var section: RedappSection
    @Binding var selectedResearchItemID: UUID?
    let activeFeedTitle: String
    let isHomeFeed: Bool
    let onSelectHome: () -> Void
    let onSelectCommunity: (String) -> Void
    let onOpenSettings: () -> Void

    @ObservedObject private var communities = RedappCommunitiesModel.shared
    @ObservedObject private var researchStore = ResearchLibraryStore.shared
    @ObservedObject private var authManager = RedditAuthManager.shared
    @ObservedObject private var savedPosts = SavedPostsStore.shared
    @State private var searchText = ""
    @State private var researchItemPendingDeletion: ResearchItemRecord?
    @FocusState private var searchFocused: Bool

    private var activeCommunity: String? {
        guard !isHomeFeed else { return nil }
        return activeFeedTitle.hasPrefix("r/") ? String(activeFeedTitle.dropFirst(2)) : activeFeedTitle
    }

    /// Favorites plus the community currently on screen, so it is always reachable.
    private var communityRows: [String] {
        var rows = communities.favorites
        if let activeCommunity,
           !rows.contains(where: { $0.caseInsensitiveCompare(activeCommunity) == .orderedSame }) {
            rows.insert(activeCommunity, at: 0)
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandRow
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

            searchField
                .padding(.horizontal, 14)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([RedappSection.browse, .library, .saved], id: \.self) { item in
                        RedappSidebarRow(
                            title: item.title,
                            symbol: item.symbol,
                            isSelected: section == item && (item != .library || selectedResearchItemID == nil),
                            trailing: item == .saved && !savedPosts.posts.isEmpty
                                ? "\(savedPosts.posts.count)" : nil
                        ) {
                            if item == .library { selectedResearchItemID = nil }
                            section = item
                        }
                    }

                    if section == .library {
                        savedResearchList
                    } else {
                        communitiesList
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)

            Rectangle()
                .fill(RedappDesign.hairline)
                .frame(height: 1)
                .padding(.horizontal, 16)

            VStack(spacing: 2) {
                RedappSidebarRow(title: "Settings", symbol: "gearshape", isSelected: false, action: onOpenSettings)
                accountRow
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RedappDesign.sidebar.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(RedappDesign.hairline)
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .task {
            researchStore.reload(searchText: "", tags: [])
            communities.reload()
        }
        .researchItemDeletionConfirmation(item: $researchItemPendingDeletion, beforeDelete: { deletedID in
            if selectedResearchItemID == deletedID { selectedResearchItemID = nil }
        })
    }

    private var brandRow: some View {
        HStack(spacing: 10) {
            RedappBrandMark(size: 30)
            Text("redapp")
                .font(.title2.weight(.bold))
                .foregroundStyle(RedappDesign.sidebarText)
            Spacer()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(RedappDesign.sidebarSecondaryText)
            TextField("Go to subreddit", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundStyle(RedappDesign.sidebarText)
                .focused($searchFocused)
                .submitLabel(.go)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .onSubmit(submitSearch)
            if searchFocused || !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(RedappDesign.sidebarSecondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            } else if UIDevice.current.userInterfaceIdiom == .pad {
                // Keyboard shortcut hint only where a hardware keyboard is likely.
                Text("⌘K")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(RedappDesign.sidebarSecondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RedappDesign.sidebarField))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(RedappDesign.hairlineStrong, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
        .background {
            // ⌘K focuses the field from a hardware keyboard.
            Button("Go to subreddit") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
    }

    private func submitSearch() {
        let name = RedappCommunitiesModel.normalized(searchText)
        guard !name.isEmpty else { return }
        section = .browse
        onSelectCommunity(name)
        searchText = ""
        searchFocused = false
    }

    @ViewBuilder
    private var communitiesList: some View {
        RedappSidebarSectionHeader(title: "Communities")

        RedappSidebarRow(
            title: "Home",
            badge: AnyView(RedappCommunityBadge(name: "Home", size: 22, isHome: true)),
            isSelected: section == .browse && isHomeFeed
        ) {
            section = .browse
            onSelectHome()
        }

        ForEach(communityRows, id: \.self) { name in
            RedappSidebarRow(
                title: "r/\(name)",
                badge: AnyView(RedappCommunityBadge(name: name, size: 22)),
                isSelected: section == .browse && activeCommunity?.caseInsensitiveCompare(name) == .orderedSame
            ) {
                section = .browse
                onSelectCommunity(name)
            }
            .contextMenu {
                if communities.isFavorite(name) {
                    Button(role: .destructive) {
                        communities.remove(name)
                    } label: {
                        Label("Remove from Communities", systemImage: "star.slash")
                    }
                } else {
                    Button {
                        communities.toggle(name)
                    } label: {
                        Label("Keep in Communities", systemImage: "star")
                    }
                }
            }
        }

        if communityRows.isEmpty {
            Text("Star a subreddit to keep it here.")
                .font(.footnote)
                .foregroundStyle(RedappDesign.sidebarSecondaryText)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var savedResearchList: some View {
        RedappSidebarSectionHeader(title: "Saved research")

        if researchStore.items.isEmpty {
            Text("Save a finished community analysis to keep it here.")
                .font(.footnote)
                .foregroundStyle(RedappDesign.sidebarSecondaryText)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        } else {
            ForEach(researchStore.items) { item in
                RedappSidebarRow(
                    title: item.title,
                    isSelected: selectedResearchItemID == item.id
                ) {
                    guard !ResearchRowSwipe.isActive else { return }
                    selectedResearchItemID = item.id
                    section = .library
                }
                .researchSwipeToDelete(background: RedappDesign.sidebar) {
                    researchItemPendingDeletion = item
                }
                .contextMenu {
                    Button(role: .destructive) {
                        researchItemPendingDeletion = item
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var accountRow: some View {
        if authManager.isAuthenticated {
            Menu {
                Button(action: onOpenSettings) {
                    Label("Account Settings", systemImage: "person.crop.circle")
                }
                Button(role: .destructive) {
                    authManager.logout()
                } label: {
                    Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                accountLabel(name: authManager.username ?? "Reddit account", detail: nil)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: onOpenSettings) {
                accountLabel(name: "Connect Reddit", detail: "Not logged in", symbol: "person.fill")
            }
            .buttonStyle(.plain)
        }
    }

    private func accountLabel(name: String, detail: String?, symbol: String? = nil) -> some View {
        HStack(spacing: 12) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .medium))
                } else {
                    Text(String(name.prefix(2)).uppercased())
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(RedappDesign.sidebarText)
            .frame(width: 38, height: 38)
            .background(Circle().fill(RedappDesign.sidebarText.opacity(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(RedappDesign.sidebarText)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(RedappDesign.sidebarSecondaryText)
                }
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RedappDesign.sidebarSecondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct RedappSidebarSectionHeader: View {
    let title: String

    var body: some View {
        RedappEyebrow(title, color: RedappDesign.sidebarSecondaryText)
            .padding(.horizontal, 12)
            .padding(.top, 26)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

struct RedappSidebarRow: View {
    let title: String
    var symbol: String? = nil
    var badge: AnyView? = nil
    let isSelected: Bool
    var trailing: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let badge {
                    badge
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .regular))
                        .frame(width: 24)
                        .foregroundStyle(RedappDesign.sidebarText)
                }
                Text(title)
                    .font(.body)
                    .foregroundStyle(RedappDesign.sidebarText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(RedappDesign.sidebarSecondaryText)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(RedappDesign.sidebarSelection)
                        .overlay(alignment: .leading) {
                            UnevenRoundedRectangle(
                                topLeadingRadius: 10,
                                bottomLeadingRadius: 10,
                                style: .continuous
                            )
                            .fill(RedappDesign.accent)
                            .frame(width: 4)
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}


// MARK: - Subreddit icons

/// Caches each subreddit's icon URL (in memory and on disk) so badges show the
/// real community icon without refetching. A missing icon is remembered too.
@MainActor
final class SubredditIconStore: ObservableObject {
    static let shared = SubredditIconStore()

    @Published private(set) var urls: [String: URL] = [:]
    private var known: [String: String]
    private var inFlight: Set<String> = []
    private let defaultsKey = "SubredditIconURLs.v1"

    private init() {
        known = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        for (key, value) in known {
            if let url = URL(string: value), !value.isEmpty { urls[key] = url }
        }
    }

    func url(for subreddit: String) -> URL? {
        urls[Self.key(subreddit)]
    }

    func load(_ subreddit: String) {
        let key = Self.key(subreddit)
        guard key.count >= 2, key != "home", known[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task {
            defer { inFlight.remove(key) }
            do {
                let url = try await RedditAPI.shared.fetchSubredditIconURL(subreddit)
                known[key] = url?.absoluteString ?? ""
                if let url { urls[key] = url }
                UserDefaults.standard.set(known, forKey: defaultsKey)
            } catch {
                // Network or rate-limit errors: try again next time the badge appears.
            }
        }
    }

    private static func key(_ subreddit: String) -> String {
        subreddit.replacingOccurrences(of: "r/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
