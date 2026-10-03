import Foundation
import XCTest
@testable import redapp

final class BatchPodcastTests: XCTestCase {
    func testContextRetainsCoverageAndGroundsSavedCommentChunks() throws {
        var coverage = ResearchCoverageInput.empty
        coverage.postsRequested = 2
        coverage.postsFetched = 2
        coverage.postsAnalyzed = 2
        coverage.commentsReported = 4
        coverage.commentsFetched = 4
        coverage.commentsAnalyzed = 4

        let context = try BatchPodcastContextBuilder.build(
            BatchPodcastBuildInput(
                contextName: "Swift discussion",
                rawComments: """
                POST: Test post
                COMMENTS:
                A saved comment.
                ---END OF POST---
                """,
                capturedSources: [
                    podcastSource(id: "t3_post", kind: .post, title: "Test post", order: 0),
                    podcastSource(id: "t1_comment", kind: .comment, title: nil, order: 1)
                ],
                postSummaries: [
                    BatchPodcastPostSummaryInput(
                        title: "Test post",
                        summary: "A saved summary.",
                        permalink: "/r/swift/comments/post/test/"
                    )
                ],
                overallSummary: "The saved batch covers a focused discussion.",
                coverage: coverage
            )
        )

        XCTAssertEqual(context.coverage, coverage)
        XCTAssertFalse(context.isSummariesOnly)
        XCTAssertEqual(context.commentChunks.count, 1)
        XCTAssertEqual(context.commentChunks[0].sourceIDs, ["t1_comment", "t3_post"])
        XCTAssertEqual(
            context.sourceDigest,
            BatchPodcastContextBuilder.sourceDigest(sources: context.capturedSources)
        )
    }

    func testCommentPackerRetainsEverySavedPostBoundary() {
        let raw = (1...3).map { index in
            "POST: Post \(index)\nCOMMENTS:\nSaved comment \(index)."
        }.joined(separator: "\n---END OF POST---\n")

        let chunks = BatchPodcastContextBuilder.commentChunks(
            from: raw,
            sources: [],
            maximumCharacters: 80
        )

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(
            chunks.flatMap(\.postTitles),
            ["Post 1", "Post 2", "Post 3"]
        )
        for index in 1...3 {
            XCTAssertTrue(chunks.contains { $0.text.contains("Saved comment \(index)") })
        }
    }

    func testNoRawCommentsRequiresExplicitSummariesOnlyFallback() throws {
        let input = BatchPodcastBuildInput(
            contextName: "Saved summaries",
            rawComments: "",
            capturedSources: [],
            postSummaries: [
                BatchPodcastPostSummaryInput(title: "Post", summary: "Saved summary.", permalink: "")
            ],
            overallSummary: nil,
            coverage: .empty
        )

        XCTAssertThrowsError(try BatchPodcastContextBuilder.build(input)) { error in
            XCTAssertEqual(error as? BatchPodcastError, .summariesOnlyRequiresExplicitOptIn)
        }

        let fallback = try BatchPodcastContextBuilder.build(
            BatchPodcastBuildInput(
                contextName: input.contextName,
                rawComments: input.rawComments,
                capturedSources: input.capturedSources,
                postSummaries: input.postSummaries,
                overallSummary: input.overallSummary,
                coverage: input.coverage,
                allowSummariesOnly: true
            )
        )
        XCTAssertTrue(fallback.isSummariesOnly)
        XCTAssertEqual(
            fallback.sourceDigest,
            BatchPodcastContextBuilder.sourceDigest(
                sources: [],
                summaries: input.postSummaries
            )
        )
    }

    func testEverySavedCommentChunkParticipatesInEvidenceReductionWithoutRedditFetch() async throws {
        let context = podcastContext(chunkCount: 3)
        let generator = PodcastTestGenerator(sourceDigest: context.sourceDigest)
        let service = BatchPodcastService(generator: generator)

        _ = try await service.generateEpisode(from: context)

        let prompts = generator.prompts
        let savedCommentPrompts = prompts.filter { $0.hasPrefix("Saved Comments") }
        XCTAssertEqual(savedCommentPrompts.count, context.commentChunks.count)
        for chunk in context.commentChunks {
            XCTAssertTrue(prompts.contains { $0.contains("Chunk ID: \(chunk.id)") })
        }
        XCTAssertTrue(
            prompts.contains {
                $0.hasPrefix("Batch Podcast Script")
                    && $0.contains("Allowed evidence references (copy exactly; do not invent or substitute):")
                    && $0.contains("evidence-1")
                    && !$0.contains("t1_comment")
                    && !$0.contains("t3_post")
            }
        )
        XCTAssertFalse(prompts.contains { $0.contains("RedditAPI") || $0.contains("URLSession") })
    }

    func testPodcastServiceHasNoRedditTransportDependency() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("redapp/Podcast/BatchPodcastService.swift")
        let implementation = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(implementation.contains("RedditAPI"))
        XCTAssertFalse(implementation.contains("URLSession"))
    }

    func testPodcastJSONRepairRunsOnceAndReturnsCodableEpisode() async throws {
        let context = podcastContext(chunkCount: 1)
        let generator = PodcastTestGenerator(sourceDigest: context.sourceDigest, firstScriptIsInvalid: true)
        let service = BatchPodcastService(generator: generator)

        let episode = try await service.generateEpisode(from: context)

        XCTAssertEqual(episode.schemaVersion, PodcastEpisode.currentSchemaVersion)
        XCTAssertEqual(episode.sourceDigest, context.sourceDigest)
        XCTAssertEqual(generator.repairCallCount, 1)
        XCTAssertTrue(generator.prompts.last?.contains("expected Codable JSON") == true)
        XCTAssertNotNil(ResearchJSON.decode(PodcastEpisode.self, from: ResearchJSON.encode(episode)))
    }

    func testShortGroundedScriptDoesNotTriggerLengthRepair() async throws {
        let context = podcastContext(chunkCount: 1)
        let generator = PodcastTestGenerator(
            sourceDigest: context.sourceDigest,
            firstScriptIsShort: true
        )
        let service = BatchPodcastService(generator: generator)

        let episode = try await service.generateEpisode(from: context)

        XCTAssertEqual(episode.spokenWordCount, 200)
        XCTAssertLessThanOrEqual(episode.spokenWordCount, PodcastEpisodeValidator.maximumWords)
        XCTAssertEqual(generator.repairCallCount, 0)
    }

    func testEightTurnGroundedScriptDoesNotTriggerTurnCountRepair() async throws {
        let context = podcastContext(chunkCount: 1)
        let generator = PodcastTestGenerator(
            sourceDigest: context.sourceDigest,
            firstScriptHasTooFewTurns: true
        )
        let service = BatchPodcastService(generator: generator)

        let episode = try await service.generateEpisode(from: context)

        XCTAssertEqual(episode.turns.count, 8)
        XCTAssertLessThanOrEqual(episode.turns.count, PodcastEpisodeValidator.maximumTurns)
        XCTAssertEqual(generator.repairCallCount, 0)
    }

    func testPodcastJSONDecoderAcceptsWrappedJSONAndAppOwnedMetadataDefaults() throws {
        let raw = """
        Here is the requested object. The earlier {example} was only explanatory prose.
        ```json
        {
          "episode": {
            "title": "Saved discussion",
            "summary": "A grounded conversation.",
            "turns": [
              {
                "speaker": "Host A",
                "text": "A line with an accidental
        line break inside the JSON string.",
                "evidenceRefs": "evidence-1",
              },
            ],
          }
        }
        ```
        """

        let draft = try XCTUnwrap(BatchPodcastJSONDecoder.decode(PodcastDraftEpisode.self, from: raw))

        XCTAssertEqual(draft.schemaVersion, PodcastEpisode.currentSchemaVersion)
        XCTAssertEqual(draft.title, "Saved discussion")
        XCTAssertEqual(draft.sourceDigest, "")
        XCTAssertEqual(draft.estimatedDuration, 0)
        XCTAssertEqual(draft.turns.count, 1)
        XCTAssertEqual(draft.turns[0].speaker, .hostA)
        XCTAssertEqual(draft.turns[0].evidenceRefs, ["evidence-1"])
        XCTAssertTrue(draft.turns[0].text.contains("accidental\nline break"))
    }

    func testPodcastJSONDecoderIgnoresBracesInsideSpokenText() throws {
        let draft = PodcastDraftEpisode(
            title: "Braces",
            summary: "Summary",
            sourceDigest: "digest",
            turns: [
                PodcastDraftTurn(
                    speaker: .hostB,
                    text: "A spoken {example} should not terminate extraction.",
                    evidenceRefs: ["evidence-1"]
                )
            ]
        )
        let wrapped = "Result follows:\n\(ResearchJSON.encode(draft))\nEnd of result."

        let decoded = try XCTUnwrap(BatchPodcastJSONDecoder.decode(PodcastDraftEpisode.self, from: wrapped))

        XCTAssertEqual(decoded.title, draft.title)
        XCTAssertEqual(decoded.turns.first?.text, draft.turns.first?.text)
    }

    func testValidatorRejectsUnknownSourceIDsEmptyTurnsAndExcessiveLength() throws {
        let valid = podcastEpisode(sourceDigest: "digest", sourceIDs: ["known"])

        XCTAssertThrowsError(
            try PodcastEpisodeValidator.validate(
                podcastEpisode(sourceDigest: "digest", sourceIDs: ["unknown"]),
                knownSourceIDs: ["known"],
                expectedSourceDigest: "digest"
            )
        ) { error in
            XCTAssertEqual(error as? BatchPodcastError, .invalidSourceIDs(["unknown"]))
        }

        let eightTurnEpisode = PodcastEpisode(
            title: "Short",
            summary: "Short",
            sourceDigest: "digest",
            turns: Array(valid.turns.prefix(8))
        )
        XCTAssertNoThrow(
            try PodcastEpisodeValidator.validate(
                eightTurnEpisode,
                knownSourceIDs: ["known"],
                expectedSourceDigest: "digest"
            )
        )

        XCTAssertThrowsError(
            try PodcastEpisodeValidator.validate(
                PodcastEpisode(title: "Empty", summary: "Empty", sourceDigest: "digest", turns: []),
                knownSourceIDs: ["known"],
                expectedSourceDigest: "digest"
            )
        ) { error in
            XCTAssertEqual(error as? BatchPodcastError, .invalidTurnCount(0))
        }

        let longText = Array(repeating: "word", count: 107).joined(separator: " ")
        let longTurns = (0..<10).map { index in
            PodcastTurn(
                speaker: index.isMultiple(of: 2) ? .hostA : .hostB,
                text: longText,
                sourceIDs: ["known"]
            )
        }
        XCTAssertThrowsError(
            try PodcastEpisodeValidator.validate(
                PodcastEpisode(
                    title: "Long",
                    summary: "Long",
                    sourceDigest: "digest",
                    turns: longTurns
                ),
                knownSourceIDs: ["known"],
                expectedSourceDigest: "digest"
            )
        ) { error in
            XCTAssertEqual(error as? BatchPodcastError, .invalidWordCount(1_070))
        }
    }

    func testPodcastSpeakerAssignmentRepairsRepeatedModelSpeakerLabels() {
        let turns = (0..<4).map { index in
            PodcastTurn(
                speaker: index == 0 ? .hostB : .hostA,
                text: "Turn \(index)",
                sourceIDs: ["known"]
            )
        }

        let normalized = PodcastSpeakerAlternator.normalize(turns)

        XCTAssertEqual(normalized.map(\.speaker), [.hostB, .hostA, .hostB, .hostA])
        XCTAssertEqual(normalized.map(\.text), turns.map(\.text))
        XCTAssertEqual(normalized.map(\.sourceIDs), turns.map(\.sourceIDs))
    }

    func testValidatorAllowsGroundedCountsAndConsensusLanguage() throws {
        let valid = podcastEpisode(sourceDigest: "digest", sourceIDs: ["known"])
        let turns = valid.turns.enumerated().map { index, turn in
            PodcastTurn(
                id: turn.id,
                speaker: turn.speaker,
                text: index == 0 ? "Everyone agrees. \(turn.text)" : turn.text,
                sourceIDs: turn.sourceIDs
            )
        }
        let episode = PodcastEpisode(
            id: valid.id,
            title: valid.title,
            summary: valid.summary,
            sourceDigest: valid.sourceDigest,
            createdAt: valid.createdAt,
            estimatedDuration: valid.estimatedDuration,
            turns: turns
        )

        XCTAssertNoThrow(
            try PodcastEpisodeValidator.validate(
                episode,
                knownSourceIDs: ["known"],
                expectedSourceDigest: "digest"
            )
        )
    }

    func testPodcastEpisodeWordLimiterTrimsSmallOverflowWithoutChangingGrounding() {
        let text = String(repeating: "spoken ", count: 100).trimmingCharacters(in: .whitespaces)
        let episode = PodcastEpisode(
            title: "Episode",
            summary: "Summary",
            sourceDigest: "digest",
            turns: (0..<11).map { index in
                PodcastTurn(
                    speaker: index.isMultiple(of: 2) ? .hostA : .hostB,
                    text: text,
                    sourceIDs: ["known"]
                )
            }
        )

        let limited = PodcastEpisodeWordLimiter.limit(episode, maximumWords: 1_050)

        XCTAssertEqual(limited.spokenWordCount, 1_050)
        XCTAssertEqual(limited.turns.flatMap(\.sourceIDs).count, episode.turns.flatMap(\.sourceIDs).count)
    }

    func testSpokenTextCleanupRemovesDirectionsLinksAndInternalTokens() {
        let cleaned = PodcastSpokenTextCleaner.clean(
            "Host A: **Read** [the docs](https://example.com). [SOURCE:t1_comment]\n(Music)\n- Then reflect."
        )

        XCTAssertEqual(cleaned, "Read the docs. Then reflect.")
        XCTAssertFalse(cleaned.contains("http"))
        XCTAssertFalse(cleaned.contains("SOURCE:"))
    }

    func testDigestInvalidationRejectsAnEpisodeFromAnOlderBatch() throws {
        let episode = podcastEpisode(sourceDigest: "old-digest", sourceIDs: ["known"])

        XCTAssertThrowsError(
            try PodcastEpisodeValidator.validate(
                episode,
                knownSourceIDs: ["known"],
                expectedSourceDigest: "new-digest"
            )
        ) { error in
            XCTAssertEqual(error as? BatchPodcastError, .digestMismatch)
        }
    }

    #if os(iOS)
    @MainActor
    func testPodcastPlaybackAlternatesVoicesAndUsesBoundedMLXChunks() throws {
        let episode = PodcastEpisode(
            title: "Episode",
            summary: "Summary",
            sourceDigest: "digest",
            turns: [
                PodcastTurn(speaker: .hostA, text: String(repeating: "alpha ", count: 90), sourceIDs: ["known"]),
                PodcastTurn(speaker: .hostB, text: String(repeating: "beta ", count: 90), sourceIDs: ["known"])
            ]
        )
        let chunks = MLXPodcastPlaybackPlan.chunks(for: episode)

        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertLessThanOrEqual(chunks.first?.text.count ?? .max, 140)
        XCTAssertTrue(chunks.dropFirst().allSatisfy { $0.text.count <= 220 })
        XCTAssertEqual(chunks.first?.speaker, .hostA)
        XCTAssertTrue(chunks.contains { $0.speaker == .hostB && $0.isSpeakerChange })
        XCTAssertEqual(
            MLXPodcastPlaybackPlan.voice(for: .hostA, hostAVoice: .alba, hostBVoice: .marius),
            .alba
        )
        XCTAssertEqual(
            MLXPodcastPlaybackPlan.voice(for: .hostB, hostAVoice: .alba, hostBVoice: .marius),
            .marius
        )
    }

    @MainActor
    func testPodcastPlaybackStopReturnsToIdleAndCancelsTheCurrentToken() {
        let controller = MLXPodcastPlaybackController()
        controller.stop()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.progress, 0)
    }

    func testPodcastPlaybackStreamsOneChunkAheadAndGatesBackgroundMetalWork() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("redapp/Podcast/MLXPodcastPlaybackController.swift")
        let implementation = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(implementation.contains("var nextSynthesisTask: Task<Data, Error>?"))
        XCTAssertTrue(implementation.contains("defer { nextSynthesisTask?.cancel() }"))
        XCTAssertTrue(implementation.contains("let nextIndex = index + 1"))
        XCTAssertTrue(implementation.contains("nextSynthesisTask = Task"))
        XCTAssertTrue(implementation.contains("currentData = try await task.value"))
        XCTAssertTrue(implementation.contains("applicationActivity.waitUntilActive()"))
        XCTAssertTrue(implementation.contains("UIApplication.willResignActiveNotification"))
        XCTAssertTrue(implementation.contains("UIApplication.didEnterBackgroundNotification"))
        XCTAssertTrue(implementation.contains("synthesisActivity.waitUntilIdle()"))
        XCTAssertFalse(implementation.contains("useConservativeMemory"))
    }

    func testPodcastApplicationActivityGateDefersWorkUntilForeground() async {
        let gate = PodcastApplicationActivityGate(isActive: false)
        let premature = expectation(description: "Background work stayed deferred")
        premature.isInverted = true
        let resumed = expectation(description: "Foreground work resumed")

        let task = Task {
            await gate.waitUntilActive()
            premature.fulfill()
            resumed.fulfill()
        }

        await fulfillment(of: [premature], timeout: 0.05, enforceOrder: false)
        XCTAssertFalse(gate.isActive)

        gate.setActive(true)
        await fulfillment(of: [resumed], timeout: 1, enforceOrder: false)
        await task.value
        XCTAssertTrue(gate.isActive)
    }

    func testPodcastDoesNotAlterExistingPocketTTSSynthesisBehavior() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("redapp/KokoroTTSService.swift")
        let implementation = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(implementation.contains("MLXSynthesisGate"))
        XCTAssertFalse(implementation.contains("recoveryGapSeconds"))
        XCTAssertFalse(implementation.contains("synthesisGate.acquire"))
        XCTAssertFalse(implementation.contains("Memory.cacheLimit"))
        XCTAssertTrue(implementation.contains("GPU.set(cacheLimit: 512 * 1024 * 1024)"))
        XCTAssertTrue(implementation.contains("Memory.clearCache()"))
    }

    func testPodcastGenerationAndPlaybackSessionSurvivePodcastViewMinimization() throws {
        let viewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("redapp/Podcast/BatchPodcastView.swift")
        let sessionURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("redapp/Podcast/BatchPodcastSession.swift")
        let viewImplementation = try String(contentsOf: viewURL, encoding: .utf8)
        let sessionImplementation = try String(contentsOf: sessionURL, encoding: .utf8)

        XCTAssertTrue(viewImplementation.contains("onMinimize"))
        XCTAssertTrue(viewImplementation.contains("Keeps podcast generation and playback running"))
        XCTAssertFalse(viewImplementation.contains("generationTask?.cancel()"))
        XCTAssertFalse(viewImplementation.contains("@StateObject private var playbackController"))
        XCTAssertTrue(viewImplementation.contains("@ObservedObject private var playbackController"))
        XCTAssertTrue(viewImplementation.contains("session.playbackController"))
        XCTAssertTrue(sessionImplementation.contains("final class BatchPodcastSession"))
        XCTAssertTrue(sessionImplementation.contains("func generate"))
        XCTAssertTrue(sessionImplementation.contains("generationTask?.cancel()"))
        XCTAssertTrue(sessionImplementation.contains("let playbackController: MLXPodcastPlaybackController"))
        XCTAssertTrue(sessionImplementation.contains("playbackController.stop()"))

        let disappearBlock = try XCTUnwrap(
            viewImplementation.range(of: ".onDisappear {")
        )
        let disappearSuffix = viewImplementation[disappearBlock.lowerBound...]
        let disappearBody = String(disappearSuffix.prefix(160))
        XCTAssertFalse(disappearBody.contains("playbackController.stop()"))
    }

    func testPodcastInvalidationDoesNotObserveLargeBatchEvidenceValues() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("redapp/ContentView.swift")
        let implementation = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(implementation.contains("batchSourceRevision"))
        XCTAssertFalse(implementation.contains(".onChange(of: viewModel.batchRawComments)"))
        XCTAssertFalse(implementation.contains(".onChange(of: viewModel.batchCapturedSources)"))
        XCTAssertFalse(implementation.contains(".onChange(of: viewModel.batchSummaries.map"))
        XCTAssertFalse(implementation.contains(".onChange(of: viewModel.batchExtractedPosts.map"))
        XCTAssertFalse(implementation.contains("batchOperationID"))
    }
    #endif

    @MainActor
    func testPodcastScriptPersistsAsARevisionLinkedArtifactWithoutOverwriting() throws {
        let store = ResearchLibraryStore(inMemory: true)
        var coverage = ResearchCoverageInput.empty
        coverage.postsRequested = 1
        coverage.postsFetched = 1
        coverage.postsAnalyzed = 1

        let sources = [podcastSource(id: "t3_post", kind: .post, title: "Test post", order: 0)]
        let run = try store.saveBatch(
            ResearchBatchSaveRequest(
                title: "Saved batch",
                scope: "subreddit|swift|top|day",
                subreddit: "swift",
                feedMode: "subreddit",
                sortMode: "top",
                timeRange: "day",
                sources: sources,
                coverage: coverage,
                perPostSummaries: [(title: "Test post", summary: "Saved summary.", permalink: "/post")],
                overallSummary: "Saved overview.",
                generationReceipt: nil
            )
        )
        let episode = podcastEpisode(sourceDigest: run.sourceDigest, sourceIDs: ["t3_post"])
        let body = ResearchJSON.encode(episode)

        let first = try store.addArtifact(
            runID: run.id,
            kind: .podcastScript,
            title: episode.title,
            body: body,
            format: "podcast-json",
            coverage: coverage
        )
        let second = try store.addArtifact(
            runID: run.id,
            kind: .podcastScript,
            title: episode.title + " regenerated",
            body: body,
            format: "podcast-json",
            coverage: coverage
        )

        let detail = try store.detail(runID: run.id)
        let podcastArtifacts = detail.artifacts.filter { $0.kind == .podcastScript }
        XCTAssertEqual(detail.run.sourceDigest, episode.sourceDigest)
        XCTAssertEqual(podcastArtifacts.map(\.id), [first.id, second.id])
        XCTAssertEqual(ResearchJSON.decode(PodcastEpisode.self, from: podcastArtifacts[0].body), episode)
    }

    func testAudioPersistencePathRecordsStreamingSaveMetadataAndTemporaryCleanup() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("redapp/ResearchLibrary/ResearchOffline.swift")
        let implementation = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(implementation.contains("func saveSpeechFile"))
        XCTAssertTrue(implementation.contains(".staging-"))
        XCTAssertTrue(implementation.contains("sourceTextDigest: sourceTextDigest"))
        XCTAssertTrue(implementation.contains("kind: .speech"))
        XCTAssertTrue(implementation.contains("ttsEngine: \"MLX Pocket TTS\""))
    }

    #if os(iOS)
    func testSavePodcastExportsWAVSeparatelyFromResearchLibraryPersistence() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewImplementation = try String(
            contentsOf: root.appendingPathComponent("redapp/Podcast/BatchPodcastView.swift"),
            encoding: .utf8
        )
        let playbackImplementation = try String(
            contentsOf: root.appendingPathComponent("redapp/Podcast/MLXPodcastPlaybackController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(viewImplementation.contains("Label(\"Save Podcast\", systemImage:"))
        XCTAssertTrue(viewImplementation.contains("Save to Research Library"))
        XCTAssertTrue(viewImplementation.contains("UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)"))
        XCTAssertTrue(viewImplementation.contains("Podcast WAV exported to Files."))
        XCTAssertTrue(viewImplementation.contains("removeExportTemporaryDirectory(for:"))
        XCTAssertTrue(playbackImplementation.contains("func renderEpisodeForExport("))
        XCTAssertTrue(playbackImplementation.contains("redapp-podcast-export-"))
        XCTAssertTrue(playbackImplementation.contains("appendingPathExtension(\"wav\")"))
        XCTAssertTrue(playbackImplementation.contains("try? FileManager.default.removeItem(at: exportDirectory)"))
    }
    #endif

    #if os(iOS)
    func testPlaybackCancellationInvalidatesTokenAndCleansEpisodeTemporaryFile() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("redapp/Podcast/MLXPodcastPlaybackController.swift")
        let implementation = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(implementation.contains("playbackTask?.cancel()"))
        XCTAssertTrue(implementation.contains("KokoroTTSService.shared.cancelPlayback()"))
        XCTAssertTrue(implementation.contains("try? FileManager.default.removeItem(at: outputURL)"))
        XCTAssertTrue(implementation.contains("defer {"))
    }
    #endif

    private func podcastContext(chunkCount: Int) -> BatchPodcastContext {
        let sources = [
            podcastSource(id: "t3_post", kind: .post, title: "Test post", order: 0),
            podcastSource(id: "t1_comment", kind: .comment, title: nil, order: 1)
        ]
        let chunks = (0..<chunkCount).map { index in
            BatchPodcastCommentChunk(
                id: "chunk-\(index + 1)",
                text: "Saved comment chunk \(index + 1) with a concrete viewpoint.",
                postTitles: ["Test post"],
                sourceIDs: ["t1_comment", "t3_post"]
            )
        }
        return BatchPodcastContext(
            contextName: "Test batch",
            sourceDigest: BatchPodcastContextBuilder.sourceDigest(sources: sources),
            capturedSources: sources,
            postSummaries: [
                BatchPodcastPostSummaryInput(title: "Test post", summary: "Saved summary.", permalink: "/post")
            ],
            overallSummary: "Saved overview.",
            coverage: .empty,
            commentChunks: chunks,
            isSummariesOnly: false
        )
    }

    private func podcastEpisode(sourceDigest: String, sourceIDs: [String]) -> PodcastEpisode {
        let line = Array(repeating: [
            "The", "saved", "discussion", "moves", "between", "careful", "examples", "and", "practical", "tradeoffs", "while", "people", "compare", "different", "ways", "to", "solve", "the", "same", "problem"
        ], count: 5).flatMap { $0 }.joined(separator: " ")
        return PodcastEpisode(
            title: "Test episode",
            summary: "A saved conversation.",
            sourceDigest: sourceDigest,
            turns: (0..<10).map { index in
                PodcastTurn(
                    speaker: index.isMultiple(of: 2) ? .hostA : .hostB,
                    text: line,
                    sourceIDs: sourceIDs
                )
            }
        )
    }

    private func podcastSource(
        id: String,
        kind: ResearchSourceKind,
        title: String?,
        order: Int
    ) -> ResearchSourceInput {
        ResearchSourceInput(
            sourceID: id,
            kind: kind,
            postSourceID: kind == .post ? id : "t3_post",
            parentSourceID: kind == .comment ? "t3_post" : nil,
            subreddit: "swift",
            title: title,
            permalink: "/r/swift/comments/post/test/",
            author: "tester",
            score: 12,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            depth: kind == .comment ? 0 : nil,
            rawMarkdown: "Saved source text.",
            mediaURLs: [],
            sourceOrder: order
        )
    }
}

private final class PodcastTestGenerator: BatchPodcastTextGenerator {
    let sourceDigest: String
    let firstScriptIsInvalid: Bool
    let firstScriptIsShort: Bool
    let firstScriptHasTooFewTurns: Bool
    var prompts: [String] = []
    var repairCallCount = 0
    private var scriptCallCount = 0

    init(
        sourceDigest: String,
        firstScriptIsInvalid: Bool = false,
        firstScriptIsShort: Bool = false,
        firstScriptHasTooFewTurns: Bool = false
    ) {
        self.sourceDigest = sourceDigest
        self.firstScriptIsInvalid = firstScriptIsInvalid
        self.firstScriptIsShort = firstScriptIsShort
        self.firstScriptHasTooFewTurns = firstScriptHasTooFewTurns
    }

    func generate(prompt: String, title: String) async throws -> String {
        prompts.append(title + "\n" + prompt)
        if title.hasPrefix("Saved Comments") {
            return "not structured evidence"
        }
        if title == "Batch Podcast Script" {
            scriptCallCount += 1
            if firstScriptIsInvalid && scriptCallCount == 1 {
                return "{broken json"
            }
            if firstScriptIsShort && scriptCallCount == 1 {
                return ResearchJSON.encode(makeDraftEpisode(repetitionCount: 1))
            }
            if firstScriptHasTooFewTurns && scriptCallCount == 1 {
                return ResearchJSON.encode(makeDraftEpisode(turnCount: 8))
            }
            return ResearchJSON.encode(makeDraftEpisode())
        }
        if title == "Repair Batch Podcast JSON" {
            repairCallCount += 1
            return ResearchJSON.encode(makeDraftEpisode())
        }
        return "not an outline"
    }

    private func makeDraftEpisode(repetitionCount: Int = 5, turnCount: Int = 10) -> PodcastDraftEpisode {
        let line = Array(repeating: [
            "The", "saved", "discussion", "moves", "between", "careful", "examples", "and", "practical", "tradeoffs", "while", "people", "compare", "different", "ways", "to", "solve", "the", "same", "problem"
        ], count: repetitionCount).flatMap { $0 }.joined(separator: " ")
        return PodcastDraftEpisode(
            id: UUID(),
            schemaVersion: PodcastEpisode.currentSchemaVersion,
            title: "Test episode",
            summary: "A saved conversation.",
            sourceDigest: sourceDigest,
            createdAt: Date(),
            estimatedDuration: 0,
            turns: (0..<turnCount).map { index in
                PodcastDraftTurn(
                    speaker: index.isMultiple(of: 2) ? .hostA : .hostB,
                    text: line,
                    evidenceRefs: ["evidence-1"]
                )
            }
        )
    }
}
