import Foundation

enum BatchPodcastContextBuilder {
    static let commentBoundary = "---END OF POST---"
    static let maximumCommentChunkCharacters = 30_000

    private struct CommentSegment {
        let text: String
        let title: String
        let sourceIDs: [String]
    }

    static func build(_ input: BatchPodcastBuildInput) throws -> BatchPodcastContext {
        let contextName = input.contextName.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaries = input.postSummaries.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let rawComments = input.rawComments.trimmingCharacters(in: .whitespacesAndNewlines)
        let chunks = commentChunks(
            from: rawComments,
            sources: input.capturedSources
        )

        let hasOverallSummary = !(input.overallSummary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard !chunks.isEmpty || !summaries.isEmpty || hasOverallSummary else {
            throw BatchPodcastError.noBatchEvidence
        }
        if chunks.isEmpty && !input.allowSummariesOnly {
            throw BatchPodcastError.summariesOnlyRequiresExplicitOptIn
        }

        return BatchPodcastContext(
            contextName: contextName.isEmpty ? "Reddit batch" : contextName,
            sourceDigest: sourceDigest(
                sources: input.capturedSources,
                summaries: summaries,
                overallSummary: input.overallSummary
            ),
            capturedSources: input.capturedSources.sorted { $0.sourceOrder < $1.sourceOrder },
            postSummaries: summaries,
            overallSummary: input.overallSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
            coverage: input.coverage,
            commentChunks: chunks,
            isSummariesOnly: chunks.isEmpty
        )
    }

    /// The Research Library uses this same source-only digest when it creates a run.
    /// Keeping the calculation here deterministic lets a generated episode be linked
    /// to the exact in-memory batch revision without another Reddit request.
    static func sourceDigest(
        sources: [ResearchSourceInput],
        summaries: [BatchPodcastPostSummaryInput] = [],
        overallSummary: String? = nil
    ) -> String {
        if !sources.isEmpty {
            return ResearchDigest.sha256Hex(
                sources
                    .sorted { $0.sourceOrder < $1.sourceOrder }
                    .map(\.contentDigest)
                    .joined(separator: "|")
            )
        }

        let trimmedOverallSummary = (overallSummary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summaries.isEmpty || !trimmedOverallSummary.isEmpty else {
            return ResearchDigest.sha256Hex("")
        }

        let fallback = summaries
            .map { [$0.title, $0.summary, $0.permalink].joined(separator: "\u{1f}") }
            .joined(separator: "\u{1e}")
            + "\u{1d}"
            + trimmedOverallSummary
        return ResearchDigest.sha256Hex("summaries-only\u{1c}\(fallback)")
    }

    static func commentChunks(
        from rawComments: String,
        sources: [ResearchSourceInput],
        maximumCharacters: Int = maximumCommentChunkCharacters
    ) -> [BatchPodcastCommentChunk] {
        let sections = rawComments
            .components(separatedBy: commentBoundary)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let segments = sections.map { section in
            let title = postTitle(from: section)
            let sourceIDs = sourceIDs(forPostTitle: title, sources: sources)
            return CommentSegment(
                text: section + "\n" + commentBoundary,
                title: title,
                sourceIDs: sourceIDs
            )
        }

        guard maximumCharacters > 0 else {
            return segments.enumerated().map { index, segment in
                BatchPodcastCommentChunk(
                    id: String(format: "comment-chunk-%04d", index + 1),
                    text: segment.text,
                    postTitles: segment.title.isEmpty ? [] : [segment.title],
                    sourceIDs: segment.sourceIDs
                )
            }
        }

        var chunks: [(text: String, titles: Set<String>, sourceIDs: Set<String>)] = []
        var currentText = ""
        var currentTitles = Set<String>()
        var currentSourceIDs = Set<String>()

        func flush() {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            chunks.append((text, currentTitles, currentSourceIDs))
            currentText = ""
            currentTitles.removeAll()
            currentSourceIDs.removeAll()
        }

        for segment in segments {
            var remaining = segment.text
            while remaining.count > maximumCharacters {
                flush()
                let splitIndex = remaining.index(remaining.startIndex, offsetBy: maximumCharacters)
                chunks.append((
                    String(remaining[..<splitIndex]),
                    segment.title.isEmpty ? [] : [segment.title],
                    Set(segment.sourceIDs)
                ))
                remaining = String(remaining[splitIndex...])
            }

            let separatorCount = currentText.isEmpty ? 0 : 2
            if currentText.count + separatorCount + remaining.count > maximumCharacters {
                flush()
            }
            if !remaining.isEmpty {
                if !currentText.isEmpty { currentText += "\n\n" }
                currentText += remaining
                if !segment.title.isEmpty { currentTitles.insert(segment.title) }
                currentSourceIDs.formUnion(segment.sourceIDs)
            }
        }
        flush()

        return chunks.enumerated().map { index, chunk in
            BatchPodcastCommentChunk(
                id: String(format: "comment-chunk-%04d", index + 1),
                text: chunk.text,
                postTitles: chunk.titles.sorted(),
                sourceIDs: chunk.sourceIDs.sorted()
            )
        }
    }

    /// Rebuilds the same bounded podcast input from source records that the
    /// batch already captured. This is intentionally local-only: it never
    /// reaches back to Reddit when an older live batch no longer has its
    /// combined raw-comments string in memory.
    static func reconstructedRawComments(from sources: [ResearchSourceInput]) -> String {
        let sortedSources = sources.sorted { $0.sourceOrder < $1.sourceOrder }
        let posts = sortedSources.filter { $0.kind == .post }
        let comments = sortedSources.filter { $0.kind == .comment }

        var sections: [String] = []
        var includedCommentIDs = Set<String>()

        for post in posts {
            let title = post.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let postComments = comments.filter { $0.postSourceID == post.sourceID }
            includedCommentIDs.formUnion(postComments.map(\.sourceID))

            var lines = ["POST: \((title?.isEmpty == false ? title : nil) ?? "Saved post")"]
            let postBody = post.rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !postBody.isEmpty {
                lines.append("POST CONTENT:\n\(postBody)")
            }
            lines.append("COMMENTS:")
            for comment in postComments {
                let body = comment.rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                if let author = comment.author?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !author.isEmpty {
                    lines.append("\(author): \(body)")
                } else {
                    lines.append(body)
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }

        let orphanedComments = comments.filter { !includedCommentIDs.contains($0.sourceID) }
        if !orphanedComments.isEmpty {
            var lines = ["POST: Saved post", "COMMENTS:"]
            for comment in orphanedComments {
                let body = comment.rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { lines.append(body) }
            }
            sections.append(lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\(commentBoundary)\n")
    }

    private static func postTitle(from section: String) -> String {
        section
            .components(separatedBy: .newlines)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("POST:") })?
            .replacingOccurrences(of: "POST:", with: "", options: [.caseInsensitive, .anchored])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    private static func sourceIDs(
        forPostTitle title: String,
        sources: [ResearchSourceInput]
    ) -> [String] {
        let normalizedTitle = normalize(title)
        guard !normalizedTitle.isEmpty else { return [] }

        let postIDs = sources.filter { source in
            source.kind == .post && normalize(source.title ?? "") == normalizedTitle
        }.map(\.sourceID)
        let relatedComments = sources.filter { source in
            source.kind == .comment && postIDs.contains(source.postSourceID)
        }.map(\.sourceID)
        let matched = postIDs + relatedComments
        let nonEmptyMatched = matched.filter { !$0.isEmpty }
        if !nonEmptyMatched.isEmpty { return Array(Set(nonEmptyMatched)).sorted() }

        // A raw-comments export can contain a title variant. Retain grounding by
        // exposing all captured IDs rather than silently dropping the chunk.
        return sources.map(\.sourceID).filter { !$0.isEmpty }.sorted()
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
