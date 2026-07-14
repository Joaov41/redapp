import WidgetKit
import SwiftUI

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BatchSummaryEntry {
        BatchSummaryEntry(date: Date(), configuration: ConfigurationAppIntent(), snapshot: .placeholder)
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> BatchSummaryEntry {
        let snapshot = WidgetSummaryStore.shared.load() ?? .placeholder
        return BatchSummaryEntry(date: Date(), configuration: configuration, snapshot: snapshot)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<BatchSummaryEntry> {
        let snapshot = WidgetSummaryStore.shared.load() ?? .placeholder
        let entry = BatchSummaryEntry(date: Date(), configuration: configuration, snapshot: snapshot)
        let refresh = Calendar.current.date(byAdding: .minute, value: 10, to: Date()) ?? Date().addingTimeInterval(600)
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}

struct BatchSummaryEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent
    let snapshot: WidgetSummarySnapshot
}

struct BatchSummaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    private var snapshot: WidgetSummarySnapshot { entry.snapshot }

    private var feedTitle: String {
        snapshot.subreddit.caseInsensitiveCompare("Home") == .orderedSame ? "Home" : "r/\(snapshot.subreddit)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if showProgressSection {
                progressSection
            }
            highlightSection
            Spacer(minLength: 0)
        }
        .padding()
        .widgetURL(tappableURL)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(feedTitle)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(snapshot.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var showProgressSection: Bool {
        entry.configuration.displayMode == .progress || snapshot.progress < 0.999 || snapshot.highlights.isEmpty
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: snapshot.progress)
                .progressViewStyle(.linear)
            Text("\(snapshot.processedPosts)/\(max(snapshot.totalPosts, 1)) posts summarized")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryHighlight: WidgetSummarySnapshot.PostHighlight? {
        snapshot.highlights.first { $0.permalink.isEmpty }
    }

    private var postHighlights: [WidgetSummarySnapshot.PostHighlight] {
        snapshot.highlights.filter { !$0.permalink.isEmpty }
    }

    private var postHighlightLimit: Int {
        (family == .systemMedium || family == .systemLarge) ? 2 : 1
    }

    private var postHighlightsToShow: [WidgetSummarySnapshot.PostHighlight] {
        let highlights = postHighlights
        if entry.configuration.displayMode == .highlight {
            return Array(highlights.prefix(postHighlightLimit))
        } else {
            return highlights.isEmpty ? [] : [highlights[0]]
        }
    }

    private var highlightSection: some View {
        if let summary = summaryHighlight {
            return AnyView(summaryOnlyView(summary))
        }

        let posts = postHighlightsToShow
        return AnyView(
            Group {
                if posts.isEmpty {
                    Text(snapshot.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(family == .systemSmall ? 4 : 6)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(posts) { highlight in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(highlight.title)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                Text(highlight.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(family == .systemSmall ? 3 : 4)
                            }
                            if let lastID = posts.last?.id, highlight.id != lastID {
                                Divider()
                                    .opacity(0.25)
                            }
                        }
                    }
                }
            }
        )
    }

    private func summaryOnlyView(_ summary: WidgetSummarySnapshot.PostHighlight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.title)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(1)
            Text(summary.summary)
                .font(summaryTextFont)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .lineLimit(summaryLineLimit)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var summaryLineLimit: Int {
        switch family {
        case .systemSmall:
            return 6
        case .systemMedium:
            return 10
        case .systemLarge:
            return 14
        default:
            return 18
        }
    }

    private var summaryTextFont: Font {
        switch family {
        case .systemSmall:
            return .caption2
        case .systemMedium:
            return .system(size: 12, weight: .regular, design: .default)
        default:
            return .system(size: 13, weight: .regular, design: .default)
        }
    }

    private var tappableURL: URL? {
        guard let highlight = postHighlights.first else { return nil }
        return permalinkURL(from: highlight.permalink)
    }

    private func permalinkURL(from permalink: String) -> URL? {
        guard !permalink.isEmpty else { return nil }
        if permalink.hasPrefix("http") {
            return URL(string: permalink)
        }
        let normalized = permalink.hasPrefix("/") ? permalink : "/\(permalink)"
        return URL(string: "https://reddit.com\(normalized)")
    }
}

struct redappw: Widget {
    let kind: String = "redappw"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            BatchSummaryWidgetView(entry: entry)
        }
        .configurationDisplayName("Reddit Batch Summary")
        .description("See AI-generated Reddit highlights and progress at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

#Preview(as: .systemSmall) {
    redappw()
} timeline: {
    BatchSummaryEntry(
        date: .now,
        configuration: .highlightPreview,
        snapshot: WidgetSummarySnapshot(
            subreddit: "SwiftUI",
            headline: "Summary ready",
            detail: "Dark mode migration is complete.",
            processedPosts: 8,
            totalPosts: 8,
            status: "Summary ready",
            progress: 1.0,
            highlights: [
                .init(title: "AsyncImage rollout", summary: "Most posts celebrated finally moving to the new media stack after Reddit's API shift.", permalink: "/r/swift/comments/123"),
                .init(title: "NavigationStack tips", summary: "Power users shared scene storage tricks for smoothing deep-link restores.", permalink: "/r/swift/comments/456")
            ]
        )
    )
    BatchSummaryEntry(
        date: .now.addingTimeInterval(60),
        configuration: .progressPreview,
        snapshot: WidgetSummarySnapshot(
            subreddit: "SwiftUI",
            headline: "Summarizing r/SwiftUI",
            detail: "Processing posts 5-8 of 12",
            processedPosts: 4,
            totalPosts: 12,
            status: "Processing posts 5-8 of 12",
            progress: 0.45,
            highlights: []
        )
    )
}
