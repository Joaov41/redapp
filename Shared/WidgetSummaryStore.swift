import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

struct WidgetSummarySnapshot: Codable, Identifiable {
    struct PostHighlight: Codable, Identifiable {
        let id: UUID
        let title: String
        let summary: String
        let permalink: String

        init(id: UUID = UUID(), title: String, summary: String, permalink: String) {
            self.id = id
            self.title = title
            self.summary = summary
            self.permalink = permalink
        }
    }

    let id: UUID
    let subreddit: String
    let headline: String
    let detail: String
    let processedPosts: Int
    let totalPosts: Int
    let updatedAt: Date
    let status: String
    let progress: Double
    let highlights: [PostHighlight]

    init(
        id: UUID = UUID(),
        subreddit: String,
        headline: String,
        detail: String,
        processedPosts: Int,
        totalPosts: Int,
        updatedAt: Date = Date(),
        status: String,
        progress: Double,
        highlights: [PostHighlight]
    ) {
        self.id = id
        self.subreddit = subreddit
        self.headline = headline
        self.detail = detail
        self.processedPosts = processedPosts
        self.totalPosts = totalPosts
        self.updatedAt = updatedAt
        self.status = status
        self.progress = progress
        self.highlights = highlights
    }

    static var placeholder: WidgetSummarySnapshot {
        WidgetSummarySnapshot(
            subreddit: "SwiftUI",
            headline: "AI summary ready",
            detail: "Run a batch summary to surface fresh highlights.",
            processedPosts: 8,
            totalPosts: 8,
            status: "Waiting for next summary…",
            progress: 1.0,
            highlights: [
                PostHighlight(
                    title: "Sample post",
                    summary: "Per-post highlights will appear here once a batch finishes.",
                    permalink: ""
                )
            ]
        )
    }
}

final class WidgetSummaryStore {
    static let shared = WidgetSummaryStore()
    static let appGroupIdentifier = "group.com.jv.redapp"

    private let storageKey = "LatestWidgetSummary"
    private let defaults: UserDefaults?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var lastSavedData: Data?
#if canImport(WidgetKit)
    private var lastReloadDate: Date?
    private var pendingReloadWorkItem: DispatchWorkItem?
    private static let reloadThrottleInterval: TimeInterval = 3.0
#endif

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroupIdentifier)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    @discardableResult
    func save(snapshot: WidgetSummarySnapshot, forceReload: Bool = false) -> Bool {
        guard let defaults, let data = try? encoder.encode(snapshot) else {
            return false
        }

        if lastSavedData == data {
            return true
        }

        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
        lastSavedData = data

        #if canImport(WidgetKit)
        scheduleWidgetReload(force: forceReload)
        #endif

        return true
    }

    func load() -> WidgetSummarySnapshot? {
        guard let defaults, let data = defaults.data(forKey: storageKey) else {
            return nil
        }

        return try? decoder.decode(WidgetSummarySnapshot.self, from: data)
    }

    #if canImport(WidgetKit)
    private func scheduleWidgetReload(force: Bool) {
        let triggerReload = { [weak self] in
            guard let self else { return }
            self.lastReloadDate = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: "redappw")
        }

        let executeReload = {
            if Thread.isMainThread {
                triggerReload()
            } else {
                DispatchQueue.main.async {
                    triggerReload()
                }
            }
        }

        if force {
            pendingReloadWorkItem?.cancel()
            pendingReloadWorkItem = nil
            executeReload()
            return
        }

        let now = Date()
        if let lastReloadDate,
           now.timeIntervalSince(lastReloadDate) < Self.reloadThrottleInterval {
            let delay = Self.reloadThrottleInterval - now.timeIntervalSince(lastReloadDate)
            pendingReloadWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingReloadWorkItem = nil
                self.lastReloadDate = Date()
                WidgetCenter.shared.reloadTimelines(ofKind: "redappw")
            }
            pendingReloadWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            pendingReloadWorkItem?.cancel()
            pendingReloadWorkItem = nil
            executeReload()
        }
    }
    #endif
}
