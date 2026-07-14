//
//  redappTests.swift
//  redappTests
//
//  Created by john val on 12/27/24.
//

import Foundation
import XCTest
@testable import redapp

final class redappTests: XCTestCase {
    private func source(
        id: String = "t1_comment",
        postID: String = "t3_post",
        text: String = "Battery life improved after the update.",
        score: Int = 12,
        sourceOrder: Int = 0
    ) -> ResearchSourceInput {
        ResearchSourceInput(
            sourceID: id,
            kind: id.hasPrefix("t3_") ? .post : .comment,
            postSourceID: postID,
            parentSourceID: id.hasPrefix("t1_") ? postID : nil,
            subreddit: "swift",
            title: id.hasPrefix("t3_") ? "Test post" : nil,
            permalink: "/r/swift/comments/post/test/comment/",
            author: "tester",
            score: score,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            depth: id.hasPrefix("t1_") ? 0 : nil,
            rawMarkdown: text,
            mediaURLs: [],
            sourceOrder: sourceOrder
        )
    }

    func testComputesDeterministicRevisionChangesAndComparisonSources() throws {
        let oldRunID = UUID()
        let newRunID = UUID()
        var oldCoverage = ResearchCoverageInput.empty
        oldCoverage.postsAnalyzed = 1
        oldCoverage.commentsAnalyzed = 1
        var newCoverage = oldCoverage
        newCoverage.commentsAnalyzed = 2

        let diff = ResearchRevisionDiffer.compare(
            oldRunID: oldRunID,
            oldRevision: 1,
            oldSources: [
                source(id: "t3_shared", postID: "t3_shared", text: "Original post text", score: 10),
                source(id: "t1_removed", postID: "t3_shared", text: "Removed comment", sourceOrder: 1)
            ],
            oldCoverage: oldCoverage,
            newRunID: newRunID,
            newRevision: 2,
            newSources: [
                source(id: "t3_shared", postID: "t3_shared", text: "Edited post text", score: 15),
                source(id: "t1_added", postID: "t3_shared", text: "Added comment", sourceOrder: 1)
            ],
            newCoverage: newCoverage
        )

        XCTAssertEqual(diff.added.map(\.sourceID), ["t1_added"])
        XCTAssertEqual(diff.removed.map(\.sourceID), ["t1_removed"])
        XCTAssertEqual(diff.edited.map(\.sourceID), ["t3_shared"])
        XCTAssertEqual(diff.scoreChanges.map(\.sourceID), ["t3_shared"])
        XCTAssertEqual(diff.coverageChanges.map(\.title), ["Comments analyzed"])
        XCTAssertTrue(diff.promptManifest.contains("Comments analyzed: 1 → 2"))

        let promptSources = diff.promptSources()
        XCTAssertEqual(promptSources.count, 4)
        XCTAssertTrue(promptSources.allSatisfy {
            ResearchComparisonSourceReference.parse($0.sourceID) != nil
        })
        let parsed = try XCTUnwrap(
            ResearchComparisonSourceReference.parse(promptSources[0].sourceID)
        )
        XCTAssertTrue(parsed.revision == 1 || parsed.revision == 2)
        XCTAssertEqual(
            ResearchComparisonSourceReference.displayName(for: parsed.encodedID),
            "R\(parsed.revision) · \(parsed.sourceID)"
        )
    }

    func testBuildsReadableChangeNarrativeFromValidatedClaimText() {
        let narrative = ResearchChangeNarrative.plainText(from: [
            "  The saved discussion moved toward practical deployment questions  ",
            "",
            "Concern about battery use became more visible.",
            "Participants remained divided about reliability",
            "Fourth point",
            "Fifth point",
            "Sixth point",
            "This seventh point should be omitted"
        ])

        XCTAssertEqual(
            narrative,
            "The saved discussion moved toward practical deployment questions. Concern about battery use became more visible. Participants remained divided about reliability. Fourth point. Fifth point. Sixth point."
        )

        let body = ResearchChangeNarrative.artifactBody(
            claimTexts: ["A new concern appeared"],
            evidenceMarkdown: "- A new concern appeared [R2]"
        )
        XCTAssertTrue(body.hasPrefix("### How the subreddit progressed"))
        XCTAssertTrue(body.contains("A new concern appeared."))
        XCTAssertTrue(body.contains("### Supporting evidence"))

        let coverageText = ResearchChangeNarrative.coverageOnlyText(
            changes: [
                ResearchCoverageDelta(
                    title: "Comments analyzed",
                    oldValue: 20,
                    newValue: 35
                )
            ]
        )
        XCTAssertTrue(coverageText.contains("comments analyzed increased from 20 to 35"))
        XCTAssertTrue(coverageText.contains("capture difference"))
    }

    @MainActor
    func testSavesSearchesPinsTagsAndCreatesHistory() throws {
        let store = ResearchLibraryStore(inMemory: true)
        let request = ResearchBatchSaveRequest(
            title: "Swift Research",
            scope: "subreddit|swift|new|all",
            subreddit: "swift",
            feedMode: "subreddit",
            sortMode: "new",
            timeRange: "all",
            sources: [source()],
            coverage: ResearchCoverageInput(
                postsRequested: 1,
                postsFetched: 1,
                postsAnalyzed: 1,
                commentsReported: 1,
                commentsFetched: 1,
                commentsAnalyzed: 1,
                commentsOmitted: 0,
                failureMessages: [],
                truncationMessages: []
            ),
            perPostSummaries: [("Test post", "The update improved battery life.", "/r/swift/comments/post/test/")],
            overallSummary: "Users reported better battery life.",
            generationReceipt: nil
        )

        let first = try store.saveBatch(request)
        let second = try store.saveBatch(request)
        XCTAssertEqual(first.itemID, second.itemID)
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, 2)

        for run in [first, second] {
            let artifacts = try store.artifacts(runID: run.id)
            XCTAssertEqual(artifacts.filter { $0.kind == .postSummary }.count, 1)
            let overall = try XCTUnwrap(artifacts.last {
                $0.kind == .overallReport && $0.title == "Overall Summary"
            })
            XCTAssertEqual(overall.body, "Users reported better battery life.")
            XCTAssertEqual(ResearchRevisionArtifacts(artifacts: artifacts).overallSummary?.id, overall.id)
        }

        try store.setTags(["Important", "battery"], itemID: first.itemID)
        try store.setPinned(true, itemID: first.itemID)
        store.reload(searchText: "battery", tags: ["important"])
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNotNil(store.items.first?.pinnedAt)
        XCTAssertEqual(store.items.first?.tags.contains("battery"), true)
        try store.setPinned(false, itemID: first.itemID)
        XCTAssertEqual(store.items.count, 1, "Pinning should preserve the active search and tag filters")

        let searchableArtifact = try store.addArtifact(
            runID: second.id,
            kind: .questionAnswer,
            title: "Charging question",
            body: "MagSafe charging remained stable.",
            claims: [
                ResearchClaimInput(
                    order: 0,
                    text: "The supporting post is the test post.",
                    citations: [ResearchCitationInput(sourceID: "t1_comment", supportingQuote: "Battery life improved")],
                    confidence: .low
                )
            ]
        )
        store.reload(searchText: "MagSafe")
        XCTAssertEqual(store.items.count, 1)
        let savedClaim = try XCTUnwrap(store.claims(artifactID: searchableArtifact.id).first)
        XCTAssertEqual(try store.citations(claimID: savedClaim.id).first?.validated, true)

        let laterGroundedReport = try store.addArtifact(
            runID: second.id,
            kind: .overallReport,
            title: "Grounded findings",
            body: "A later evidence report."
        )
        let grouped = try store.detail(runID: second.id).revisionArtifacts
        XCTAssertEqual(grouped.overallSummary?.title, "Overall Summary")
        XCTAssertEqual(grouped.postSummaries.count, 1)
        XCTAssertTrue(grouped.remainingArtifacts.contains { $0.id == searchableArtifact.id })
        XCTAssertTrue(grouped.remainingArtifacts.contains { $0.id == laterGroundedReport.id })

        var tableOnlyRequest = request
        tableOnlyRequest.overallSummary = nil
        let tableOnlyRun = try store.saveBatch(tableOnlyRequest)
        let savedOverallTable = try store.addArtifact(
            runID: tableOnlyRun.id,
            kind: .tableReport,
            title: "Overall Summary Table",
            body: "A batch-wide table summary."
        )
        let tableOnlyGrouped = try store.detail(runID: tableOnlyRun.id).revisionArtifacts
        XCTAssertEqual(tableOnlyGrouped.overallSummary?.id, savedOverallTable.id)
        XCTAssertFalse(tableOnlyGrouped.remainingArtifacts.contains { $0.id == savedOverallTable.id })

        let json = try store.exportJSON(runID: second.id)
        let markdown = try store.exportMarkdown(runID: second.id)
        XCTAssertFalse(json.isEmpty)
        XCTAssertTrue(markdown.contains("Comments analyzed: 1"))
        XCTAssertTrue(markdown.contains("t1_comment"))
        XCTAssertTrue(markdown.contains("Users reported better battery life."))
    }

    func testValidatesQuotesAndComputesConfidenceFromIndependentPosts() throws {
        let sources = [
            source(id: "t1_one", postID: "t3_a", text: "Battery life improved after the update."),
            source(id: "t1_two", postID: "t3_b", text: "The update doubled my battery duration."),
            source(id: "t1_three", postID: "t3_b", text: "I also noticed longer battery life.")
        ]
        let payload = GroundedResearchPayload(
            title: "Battery findings",
            overview: "Saved-source analysis",
            claims: [
                .init(
                    text: "Multiple users reported improved battery life.",
                    claimType: "finding",
                    citations: [
                        .init(sourceID: "t1_one", quote: "Battery life improved"),
                        .init(sourceID: "t1_two", quote: "doubled my battery duration"),
                        .init(sourceID: "t1_three", quote: "longer battery life")
                    ],
                    conflictingSourceIDs: [],
                    missingData: nil
                ),
                .init(
                    text: "This unsupported claim must be omitted.",
                    claimType: "finding",
                    citations: [.init(sourceID: "t1_one", quote: "words not in source")],
                    conflictingSourceIDs: [],
                    missingData: nil
                )
            ],
            conflicts: [],
            missingData: []
        )
        var coverage = ResearchCoverageInput.empty
        coverage.postsRequested = 2
        coverage.postsFetched = 2
        coverage.postsAnalyzed = 2
        coverage.commentsFetched = 3
        coverage.commentsAnalyzed = 3

        let result = try ResearchEvidenceValidator.validate(payload, sources: sources, coverage: coverage)
        XCTAssertEqual(result.claims.count, 1)
        XCTAssertEqual(result.claims[0].confidence, .high)
        XCTAssertEqual(result.claims[0].citations.count, 3)
        XCTAssertTrue(result.missingData.contains { $0.contains("Unverified model claim omitted") })

        let unanswered = try ResearchEvidenceValidator.validate(
            GroundedResearchPayload(
                title: "Unanswered",
                overview: nil,
                claims: [],
                conflicts: [],
                missingData: ["The saved sources do not answer this question."]
            ),
            sources: sources,
            coverage: coverage
        )
        XCTAssertTrue(unanswered.claims.isEmpty)
        XCTAssertEqual(unanswered.missingData.first, "The saved sources do not answer this question.")
    }

    @MainActor
    func testPersistsDraftAndScopedConversation() throws {
        let store = ResearchLibraryStore(inMemory: true)
        let run = try store.saveBatch(
            ResearchBatchSaveRequest(
                title: "Draft test",
                scope: "subreddit|swift|new|all",
                subreddit: "swift",
                feedMode: "subreddit",
                sortMode: "new",
                timeRange: "all",
                sources: [source()],
                coverage: .empty,
                perPostSummaries: [],
                overallSummary: nil,
                generationReceipt: nil
            )
        )

        _ = try store.saveDraft(
            kind: .reply,
            destinationKey: "reply:t1_comment",
            parentSourceID: "t1_comment",
            body: "An unfinished reply"
        )
        XCTAssertEqual(try store.draft(kind: .reply, destinationKey: "reply:t1_comment")?.body, "An unfinished reply")

        let conversation = try store.createConversation(runID: run.id, title: "Battery")
        _ = try store.appendTurn(conversationID: conversation.id, role: .user, text: "What changed?")
        _ = try store.appendTurn(conversationID: conversation.id, role: .assistant, text: "Battery life improved.")
        let turns = try store.turns(conversationID: conversation.id)
        XCTAssertEqual(conversation.sourceDigest, run.sourceDigest)
        XCTAssertEqual(turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(turns.map(\.sequence), [0, 1])

        let jsonExport = try XCTUnwrap(String(data: store.exportJSON(runID: run.id), encoding: .utf8))
        let markdownExport = try store.exportMarkdown(runID: run.id)
        XCTAssertTrue(jsonExport.contains("What changed?"))
        XCTAssertTrue(markdownExport.contains("**User:** What changed?"))

        try store.deleteDraft(kind: .reply, destinationKey: "reply:t1_comment")
        XCTAssertNil(try store.draft(kind: .reply, destinationKey: "reply:t1_comment"))
    }
}
