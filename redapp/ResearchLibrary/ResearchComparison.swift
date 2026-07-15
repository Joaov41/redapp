import Foundation

enum ResearchChangeNarrative {
    static let noChangeText = "No meaningful change was detected between these two saved snapshots."

    static func plainText(from claimTexts: [String], maximumSentences: Int = 6) -> String {
        let sentences = claimTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maximumSentences)
            .map(endingWithSentencePunctuation)
        return sentences.joined(separator: " ")
    }

    static func artifactBody(
        claimTexts: [String],
        evidenceMarkdown: String,
        heading: String = "How the subreddit progressed"
    ) -> String {
        let narrative = plainText(from: claimTexts)
        let evidence = evidenceMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []
        if !narrative.isEmpty {
            sections.append("### \(heading)\n\n\(narrative)")
        }
        if !evidence.isEmpty {
            sections.append("### Supporting evidence\n\n\(evidence)")
        }
        return sections.joined(separator: "\n\n")
    }

    static func coverageOnlyText(changes: [ResearchCoverageDelta]) -> String {
        guard !changes.isEmpty else { return noChangeText }
        let details = changes.map { change in
            let direction = change.newValue > change.oldValue ? "increased" : "decreased"
            return "\(change.title.lowercased()) \(direction) from \(change.oldValue) to \(change.newValue)"
        }.joined(separator: "; ")
        return "The saved posts and comments are unchanged. Only collection coverage changed: \(details). Any apparent shift should therefore be treated as a capture difference, not a change in the community discussion."
    }

    private static func endingWithSentencePunctuation(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }
}

struct ResearchComparisonSourceReference: Hashable, Sendable {
    let runID: UUID
    let revision: Int
    let sourceID: String

    var encodedID: String {
        "comparison:\(revision):\(runID.uuidString):\(sourceID)"
    }

    var displayName: String {
        "R\(revision) · \(sourceID)"
    }

    static func parse(_ value: String) -> ResearchComparisonSourceReference? {
        let components = value.split(
            separator: ":",
            maxSplits: 3,
            omittingEmptySubsequences: false
        )
        guard components.count == 4,
              components[0] == "comparison",
              let revision = Int(components[1]),
              let runID = UUID(uuidString: String(components[2])) else {
            return nil
        }
        return ResearchComparisonSourceReference(
            runID: runID,
            revision: revision,
            sourceID: String(components[3])
        )
    }

    static func displayName(for value: String) -> String {
        parse(value)?.displayName ?? value
    }
}

struct ResearchSourceDelta: Identifiable, Hashable, Sendable {
    let sourceID: String
    let oldSource: ResearchSourceInput?
    let newSource: ResearchSourceInput?

    var id: String { sourceID }
    var kind: ResearchSourceKind { newSource?.kind ?? oldSource?.kind ?? .comment }
    var displayTitle: String {
        newSource?.title
            ?? oldSource?.title
            ?? newSource?.author.map { "u/\($0)" }
            ?? oldSource?.author.map { "u/\($0)" }
            ?? sourceID
    }
}

struct ResearchScoreDelta: Identifiable, Hashable, Sendable {
    let sourceID: String
    let kind: ResearchSourceKind
    let displayTitle: String
    let oldScore: Int?
    let newScore: Int?
    let oldSource: ResearchSourceInput
    let newSource: ResearchSourceInput

    var id: String { sourceID }
}

struct ResearchCoverageDelta: Identifiable, Hashable, Sendable {
    let title: String
    let oldValue: Int
    let newValue: Int

    var id: String { title }
    var change: Int { newValue - oldValue }
}

struct ResearchRevisionDiff: Hashable, Sendable {
    let oldRunID: UUID
    let newRunID: UUID
    let oldRevision: Int
    let newRevision: Int
    let added: [ResearchSourceDelta]
    let removed: [ResearchSourceDelta]
    let edited: [ResearchSourceDelta]
    let scoreChanges: [ResearchScoreDelta]
    let coverageChanges: [ResearchCoverageDelta]
    let unchangedSourceCount: Int

    var hasSourceChanges: Bool {
        !added.isEmpty || !removed.isEmpty || !edited.isEmpty || !scoreChanges.isEmpty
    }

    var hasChanges: Bool {
        hasSourceChanges || !coverageChanges.isEmpty
    }

    var reportTitle: String {
        "What Changed: Revision \(oldRevision) → \(newRevision)"
    }

    var deterministicSummary: String {
        [
            "Added sources: \(added.count)",
            "Removed sources: \(removed.count)",
            "Edited sources: \(edited.count)",
            "Score changes: \(scoreChanges.count)",
            "Coverage changes: \(coverageChanges.count)",
            "Unchanged sources: \(unchangedSourceCount)"
        ].joined(separator: "\n")
    }

    var promptManifest: String {
        var sections = [
            "Deterministic comparison: revision \(oldRevision) to revision \(newRevision).",
            deterministicSummary
        ]
        if !added.isEmpty {
            sections.append("ADDED:\n" + added.map { "- \($0.sourceID) (\($0.kind.rawValue))" }.joined(separator: "\n"))
        }
        if !removed.isEmpty {
            sections.append("REMOVED:\n" + removed.map { "- \($0.sourceID) (\($0.kind.rawValue))" }.joined(separator: "\n"))
        }
        if !edited.isEmpty {
            sections.append("EDITED:\n" + edited.map { "- \($0.sourceID) (\($0.kind.rawValue))" }.joined(separator: "\n"))
        }
        if !scoreChanges.isEmpty {
            sections.append(
                "SCORE CHANGES:\n" + scoreChanges.map {
                    "- \($0.sourceID): \($0.oldScore.map(String.init) ?? "missing") → \($0.newScore.map(String.init) ?? "missing")"
                }.joined(separator: "\n")
            )
        }
        if !coverageChanges.isEmpty {
            sections.append(
                "COVERAGE CHANGES:\n" + coverageChanges.map {
                    "- \($0.title): \($0.oldValue) → \($0.newValue)"
                }.joined(separator: "\n")
            )
        }
        return sections.joined(separator: "\n\n")
    }

    func promptSources() -> [ResearchSourceInput] {
        var result: [ResearchSourceInput] = []
        var seen = Set<String>()

        func append(_ source: ResearchSourceInput, runID: UUID, revision: Int) {
            let reference = ResearchComparisonSourceReference(
                runID: runID,
                revision: revision,
                sourceID: source.sourceID
            )
            guard seen.insert(reference.encodedID).inserted else { return }
            let postReference = ResearchComparisonSourceReference(
                runID: runID,
                revision: revision,
                sourceID: source.postSourceID
            )
            let parentReference = source.parentSourceID.map {
                ResearchComparisonSourceReference(
                    runID: runID,
                    revision: revision,
                    sourceID: $0
                ).encodedID
            }
            result.append(
                ResearchSourceInput(
                    sourceID: reference.encodedID,
                    kind: source.kind,
                    postSourceID: postReference.encodedID,
                    parentSourceID: parentReference,
                    subreddit: source.subreddit,
                    title: source.title.map { "[Revision \(revision)] \($0)" },
                    permalink: source.permalink,
                    author: source.author,
                    score: source.score,
                    createdAt: source.createdAt,
                    depth: source.depth,
                    rawMarkdown: source.rawMarkdown,
                    mediaURLs: source.mediaURLs,
                    sourceOrder: result.count
                )
            )
        }

        for delta in added {
            if let source = delta.newSource { append(source, runID: newRunID, revision: newRevision) }
        }
        for delta in removed {
            if let source = delta.oldSource { append(source, runID: oldRunID, revision: oldRevision) }
        }
        for delta in edited {
            if let source = delta.oldSource { append(source, runID: oldRunID, revision: oldRevision) }
            if let source = delta.newSource { append(source, runID: newRunID, revision: newRevision) }
        }
        for delta in scoreChanges {
            append(delta.oldSource, runID: oldRunID, revision: oldRevision)
            append(delta.newSource, runID: newRunID, revision: newRevision)
        }
        return result
    }
}

enum ResearchRevisionDiffer {
    static func compare(
        oldRunID: UUID,
        oldRevision: Int,
        oldSources: [ResearchSourceInput],
        oldCoverage: ResearchCoverageInput,
        newRunID: UUID,
        newRevision: Int,
        newSources: [ResearchSourceInput],
        newCoverage: ResearchCoverageInput
    ) -> ResearchRevisionDiff {
        let oldMap = Dictionary(uniqueKeysWithValues: oldSources.map { ($0.sourceID, $0) })
        let newMap = Dictionary(uniqueKeysWithValues: newSources.map { ($0.sourceID, $0) })
        let oldIDs = Set(oldMap.keys)
        let newIDs = Set(newMap.keys)

        let added = sorted(newIDs.subtracting(oldIDs), map: newMap).map {
            ResearchSourceDelta(sourceID: $0.sourceID, oldSource: nil, newSource: $0)
        }
        let removed = sorted(oldIDs.subtracting(newIDs), map: oldMap).map {
            ResearchSourceDelta(sourceID: $0.sourceID, oldSource: $0, newSource: nil)
        }
        let sharedIDs = oldIDs.intersection(newIDs)
        let edited = sharedIDs.compactMap { sourceID -> ResearchSourceDelta? in
            guard let old = oldMap[sourceID], let new = newMap[sourceID],
                  old.contentDigest != new.contentDigest else { return nil }
            return ResearchSourceDelta(sourceID: sourceID, oldSource: old, newSource: new)
        }.sorted { sourceOrder($0) < sourceOrder($1) }
        let scoreChanges = sharedIDs.compactMap { sourceID -> ResearchScoreDelta? in
            guard let old = oldMap[sourceID], let new = newMap[sourceID], old.score != new.score else { return nil }
            return ResearchScoreDelta(
                sourceID: sourceID,
                kind: new.kind,
                displayTitle: new.title ?? new.author.map { "u/\($0)" } ?? sourceID,
                oldScore: old.score,
                newScore: new.score,
                oldSource: old,
                newSource: new
            )
        }.sorted { $0.sourceID.localizedStandardCompare($1.sourceID) == .orderedAscending }

        let changedSharedIDs = Set(edited.map(\.sourceID)).union(scoreChanges.map(\.sourceID))
        return ResearchRevisionDiff(
            oldRunID: oldRunID,
            newRunID: newRunID,
            oldRevision: oldRevision,
            newRevision: newRevision,
            added: added,
            removed: removed,
            edited: edited,
            scoreChanges: scoreChanges,
            coverageChanges: coverageDeltas(old: oldCoverage, new: newCoverage),
            unchangedSourceCount: sharedIDs.subtracting(changedSharedIDs).count
        )
    }

    private static func sorted(
        _ ids: Set<String>,
        map: [String: ResearchSourceInput]
    ) -> [ResearchSourceInput] {
        ids.compactMap { map[$0] }.sorted {
            if $0.sourceOrder == $1.sourceOrder {
                return $0.sourceID.localizedStandardCompare($1.sourceID) == .orderedAscending
            }
            return $0.sourceOrder < $1.sourceOrder
        }
    }

    private static func sourceOrder(_ delta: ResearchSourceDelta) -> Int {
        delta.newSource?.sourceOrder ?? delta.oldSource?.sourceOrder ?? .max
    }

    private static func coverageDeltas(
        old: ResearchCoverageInput,
        new: ResearchCoverageInput
    ) -> [ResearchCoverageDelta] {
        [
            ResearchCoverageDelta(title: "Posts requested", oldValue: old.postsRequested, newValue: new.postsRequested),
            ResearchCoverageDelta(title: "Posts fetched", oldValue: old.postsFetched, newValue: new.postsFetched),
            ResearchCoverageDelta(title: "Posts analyzed", oldValue: old.postsAnalyzed, newValue: new.postsAnalyzed),
            ResearchCoverageDelta(title: "Comments reported", oldValue: old.commentsReported, newValue: new.commentsReported),
            ResearchCoverageDelta(title: "Comments fetched", oldValue: old.commentsFetched, newValue: new.commentsFetched),
            ResearchCoverageDelta(title: "Comments analyzed", oldValue: old.commentsAnalyzed, newValue: new.commentsAnalyzed),
            ResearchCoverageDelta(title: "Comments omitted", oldValue: old.commentsOmitted, newValue: new.commentsOmitted)
        ].filter { $0.oldValue != $0.newValue }
    }
}
