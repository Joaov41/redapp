#if os(macOS)
import Foundation

enum ScheduledSummaryRunError: LocalizedError {
    case invalidSubreddit
    case unsupportedProvider(String)
    case noPosts(String)
    case commentsUnavailable(post: String, reason: String)
    case emptySummary(post: String)

    var errorDescription: String? {
        switch self {
        case .invalidSubreddit:
            return "Enter a valid subreddit before running this schedule."
        case .unsupportedProvider(let provider):
            return "\(provider) requires an interactive window and cannot run unattended. Choose another summary provider."
        case .noPosts(let subreddit):
            return "Reddit did not return any posts for r/\(subreddit)."
        case .commentsUnavailable(let post, let reason):
            return "Comments for “\(post)” could not be fetched after three attempts. \(reason)"
        case .emptySummary(let post):
            return "The summary provider returned an empty result for “\(post)”."
        }
    }
}

@MainActor
final class ScheduledSummaryRunner {
    static let shared = ScheduledSummaryRunner()
    static let analyzedCommentLimit = 500

    private init() {}

    func run(
        schedule: ScheduledSummaryDefinition,
        progress: @MainActor @escaping (Double, String) -> Void
    ) async throws -> ScheduledSummaryRunResult {
        let subreddit = schedule.normalizedSubreddit
        guard !subreddit.isEmpty else { throw ScheduledSummaryRunError.invalidSubreddit }
        guard schedule.provider != .webAI else {
            throw ScheduledSummaryRunError.unsupportedProvider(schedule.provider.displayName)
        }

        let originalProvider = SummaryService.shared.settings.selectedSummaryProvider
        SummaryService.shared.setSummaryProvider(schedule.provider)
        defer { SummaryService.shared.setSummaryProvider(originalProvider) }

        let generationStartedAt = Date()
        progress(0.02, "Fetching \(schedule.postLimit) \(schedule.feedDescription.lowercased()) posts from r/\(subreddit)…")
        let fetched = try await RedditAPI.shared.fetchPosts(
            subreddit: subreddit,
            type: schedule.feedType,
            limit: schedule.postLimit,
            topTimeRange: schedule.topTimeRange
        )
        let posts = fetched.filter { $0.stickied != true }
        guard !posts.isEmpty else { throw ScheduledSummaryRunError.noPosts(subreddit) }

        var coverage = ResearchCoverageInput(
            postsRequested: schedule.postLimit,
            postsFetched: posts.count,
            postsAnalyzed: 0,
            commentsReported: 0,
            commentsFetched: 0,
            commentsAnalyzed: 0,
            commentsOmitted: 0,
            failureMessages: [],
            truncationMessages: []
        )
        if posts.count < schedule.postLimit {
            coverage.failureMessages.append(
                "Reddit returned \(posts.count) of the \(schedule.postLimit) requested posts. All returned posts and their available comments were analyzed."
            )
        }

        var sources: [ResearchSourceInput] = []
        var perPostInputs: [(post: SubredditPostData, response: PostAndComments, comments: [CommentData])] = []

        for (index, post) in posts.enumerated() {
            try Task.checkCancellation()
            let base = 0.05 + (Double(index) / Double(max(posts.count, 1))) * 0.42
            progress(base, "Fetching comments \(index + 1) of \(posts.count): \(post.title)")
            let response = try await fetchCommentsRequired(for: post, progress: progress)
            let flattened = flatten(response.comments)
            appendSources(post: post, response: response, comments: flattened, to: &sources)

            coverage.postsAnalyzed += 1
            coverage.commentsReported += max(0, post.num_comments)
            coverage.commentsFetched += flattened.count
            let analyzedCount = min(Self.analyzedCommentLimit, flattened.count)
            coverage.commentsAnalyzed += analyzedCount
            let omitted = max(0, flattened.count - analyzedCount)
            coverage.commentsOmitted += omitted
            if omitted > 0 {
                coverage.truncationMessages.append(
                    "\(post.title): analyzed \(analyzedCount) of \(flattened.count) comments returned by Reddit."
                )
            }
            perPostInputs.append((post, response, Array(flattened.prefix(Self.analyzedCommentLimit))))
        }

        var summaries: [(title: String, summary: String, permalink: String)] = []
        for (index, input) in perPostInputs.enumerated() {
            try Task.checkCancellation()
            let base = 0.48 + (Double(index) / Double(max(perPostInputs.count, 1))) * 0.35
            progress(base, "Summarizing post \(index + 1) of \(perPostInputs.count): \(input.post.title)")
            let prompt = postSummaryPrompt(
                subreddit: subreddit,
                post: input.post,
                response: input.response,
                comments: input.comments
            )
            let generated = try await SummaryService.shared.summarize(text: prompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !generated.isEmpty else {
                throw ScheduledSummaryRunError.emptySummary(post: input.post.title)
            }
            summaries.append((input.post.title, generated, input.post.permalink))
        }

        progress(0.86, "Writing the overall r/\(subreddit) summary…")
        let overallPrompt = overallSummaryPrompt(
            subreddit: subreddit,
            schedule: schedule,
            summaries: summaries
        )
        let overall = try await SummaryService.shared.summarize(text: overallPrompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overall.isEmpty else {
            throw ScheduledSummaryRunError.emptySummary(post: "Overall Summary")
        }

        progress(0.96, "Saving the scheduled summary to Research Library…")
        let generationCompletedAt = Date()
        let request = ResearchBatchSaveRequest(
            title: "r/\(subreddit) Research",
            scope: ["subreddit", subreddit.lowercased(), schedule.feedType.rawValue, schedule.feedType == .top ? schedule.topTimeRange.rawValue : "all"].joined(separator: "|"),
            subreddit: subreddit,
            feedMode: "subreddit",
            sortMode: schedule.feedType.rawValue,
            timeRange: schedule.feedType == .top ? schedule.topTimeRange.rawValue : "all",
            sources: sources,
            coverage: coverage,
            perPostSummaries: summaries,
            overallSummary: overall,
            generationReceipt: ResearchGenerationReceiptFactory.make(
                settings: SummaryService.shared.settings,
                startedAt: generationStartedAt,
                completedAt: generationCompletedAt,
                promptVersion: 1,
                responseSchemaVersion: 1
            )
        )
        let run = try ResearchLibraryStore.shared.saveBatch(request)
        progress(1, "Saved Revision \(run.revision) for r/\(subreddit)")
        return ScheduledSummaryRunResult(runID: run.id, coverage: coverage)
    }

    private func fetchCommentsRequired(
        for post: SubredditPostData,
        progress: @MainActor @escaping (Double, String) -> Void
    ) async throws -> PostAndComments {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try await RedditAPI.shared.fetchPostAndComments(
                    permalink: post.permalink,
                    useResponsiveSession: true
                )
            } catch {
                lastError = error
                guard attempt < 3 else { break }
                let delay = attempt == 1 ? 2 : 5
                progress(0.05, "Reddit did not deliver comments for “\(post.title)”. Retrying in \(delay) seconds…")
                try await Task.sleep(for: .seconds(delay))
            }
        }
        throw ScheduledSummaryRunError.commentsUnavailable(
            post: post.title,
            reason: lastError?.localizedDescription ?? "Unknown Reddit response."
        )
    }

    private func flatten(_ comments: [CommentData]) -> [CommentData] {
        var result: [CommentData] = []
        func visit(_ values: [CommentData]) {
            for comment in values {
                result.append(comment)
                visit(comment.replies)
            }
        }
        visit(comments)
        return result
    }

    private func appendSources(
        post: SubredditPostData,
        response: PostAndComments,
        comments: [CommentData],
        to sources: inout [ResearchSourceInput]
    ) {
        sources.append(
            ResearchSourceInput(
                sourceID: response.postID,
                kind: .post,
                postSourceID: response.postID,
                parentSourceID: nil,
                subreddit: response.subreddit.isEmpty ? (post.subreddit ?? "") : response.subreddit,
                title: response.postTitle.isEmpty ? post.title : response.postTitle,
                permalink: response.permalink,
                author: post.author,
                score: response.score ?? post.ups,
                createdAt: response.createdAt ?? post.created_utc.map(Date.init(timeIntervalSince1970:)),
                depth: nil,
                rawMarkdown: response.postContent.isEmpty ? post.selftext : response.postContent,
                mediaURLs: Array(Set(post.allImageURLs.map(\.absoluteString))).sorted(),
                sourceOrder: sources.count
            )
        )
        for comment in comments {
            let sourceID = comment.id.hasPrefix("t1_") ? comment.id : "t1_\(comment.id)"
            let commentID = comment.id.replacingOccurrences(of: "t1_", with: "")
            sources.append(
                ResearchSourceInput(
                    sourceID: sourceID,
                    kind: .comment,
                    postSourceID: comment.postSourceID ?? response.postID,
                    parentSourceID: comment.parentSourceID,
                    subreddit: response.subreddit.isEmpty ? (post.subreddit ?? "") : response.subreddit,
                    title: nil,
                    permalink: comment.permalink ?? "\(response.permalink)?context=3&comment=\(commentID)",
                    author: comment.author,
                    score: comment.score,
                    createdAt: comment.createdAt,
                    depth: comment.depth,
                    rawMarkdown: comment.rawText,
                    mediaURLs: comment.imageURLs.map(\.absoluteString),
                    sourceOrder: sources.count
                )
            )
        }
    }

    private func postSummaryPrompt(
        subreddit: String,
        post: SubredditPostData,
        response: PostAndComments,
        comments: [CommentData]
    ) -> String {
        let commentText = comments.isEmpty
            ? "No comments were returned for this post."
            : comments.map { comment in
                let sourceID = comment.id.hasPrefix("t1_") ? comment.id : "t1_\(comment.id)"
                return "[SOURCE:\(sourceID)] u/\(comment.author) (score \(comment.score)): \(comment.rawText)"
            }.joined(separator: "\n\n")
        let body = response.postContent.isEmpty ? post.selftext : response.postContent
        return """
        Summarize this r/\(subreddit) post and its comment discussion in clear everyday language.

        Requirements:
        - Explain the main subject and what the community said about it.
        - Include disagreement, uncertainty, or missing information when important.
        - Do not invent reactions that are not present in the comments.
        - Write one to three concise paragraphs in Markdown.

        Post: \(post.title)
        Post source: [SOURCE:\(response.postID)]
        Post text:
        \(body.isEmpty ? "No post body was provided." : body)

        Comments returned by Reddit:
        \(commentText)
        """
    }

    private func overallSummaryPrompt(
        subreddit: String,
        schedule: ScheduledSummaryDefinition,
        summaries: [(title: String, summary: String, permalink: String)]
    ) -> String {
        let inputs = summaries.enumerated().map { index, item in
            "\(index + 1). \(item.title)\n\(item.summary)\nLink: https://reddit.com\(item.permalink)"
        }.joined(separator: "\n\n---\n\n")
        return """
        Write a comprehensive overall summary of the \(schedule.feedDescription) feed from r/\(subreddit).

        This overview must represent the most important themes across all \(summaries.count) analyzed posts and their comments. Explain how the subreddit is progressing, the strongest recurring subjects, community sentiment, meaningful disagreements, and notable changes or patterns. Use clear everyday language and Markdown headings. Do not focus only on the first few posts.

        Individual post and comment summaries:
        \(inputs)
        """
    }
}
#endif
