//
//  redappwLiveActivity.swift
//  redappw
//
//  Created by john val on 10/10/25.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct BatchSummaryAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String
        var processedPosts: Int
        var totalPosts: Int
        var progress: Double
    }

    var subreddit: String
}

struct BatchSummaryLiveActivityWidget: Widget {
    private func feedTitle(_ subreddit: String) -> String {
        subreddit.caseInsensitiveCompare("Home") == .orderedSame ? "Home" : "r/\(subreddit)"
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BatchSummaryAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text("Summarizing \(feedTitle(context.attributes.subreddit))")
                    .font(.headline)

                ProgressView(
                    value: min(max(context.state.progress, 0), 1)
                ) {
                    Text(context.state.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("\(context.state.processedPosts)/\(max(context.state.totalPosts, 1)) posts processed")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .activityBackgroundTint(Color(.systemBackground))
            .activitySystemActionForegroundColor(Color.accentColor)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(feedTitle(context.attributes.subreddit))
                            .font(.headline)
                        Text(context.state.status)
                            .font(.subheadline)
                        ProgressView(value: min(max(context.state.progress, 0), 1))
                        Text("\(context.state.processedPosts) of \(max(context.state.totalPosts, 1)) posts")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "text.bubble")
            } compactTrailing: {
                Text("\(min(context.state.processedPosts, 99))")
                    .font(.caption2)
            } minimal: {
                Image(systemName: "text.bubble")
            }
        }
    }
}

#Preview("Notification", as: .content, using: BatchSummaryAttributes(subreddit: "swift")) {
    BatchSummaryLiveActivityWidget()
} contentStates: {
    BatchSummaryAttributes.ContentState(
        status: "Processing posts 4-8",
        processedPosts: 8,
        totalPosts: 20,
        progress: 0.4
    )
    BatchSummaryAttributes.ContentState(
        status: "Generating summary",
        processedPosts: 20,
        totalPosts: 20,
        progress: 1.0
    )
}
