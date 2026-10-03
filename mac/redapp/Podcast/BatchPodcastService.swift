import Foundation

protocol BatchPodcastTextGenerator {
    func generate(prompt: String, title: String) async throws -> String
}

struct SummaryServiceBatchPodcastGenerator: BatchPodcastTextGenerator {
    func generate(prompt: String, title: String) async throws -> String {
        if SummaryService.shared.settings.selectedSummaryProvider == .webAI {
            return try await AppState.shared.performWebAIRequestAsync(
                title: title,
                prompt: prompt,
                responseFormat: .strictJSON
            )
        }
        return try await SummaryService.shared.summarize(text: prompt)
    }
}

private struct PodcastEvidenceReference: Codable, Equatable, Sendable {
    let id: String
    let sourceIDs: [String]
    let claims: [String]
    let tensions: [String]
    let unknowns: [String]
}

private struct PodcastPromptEvidence: Codable, Equatable, Sendable {
    let evidenceRef: String
    let claims: [String]
    let tensions: [String]
    let unknowns: [String]
}

private struct PodcastEvidenceDraftClaim: Codable, Equatable, Sendable {
    let text: String
}

private struct PodcastEvidenceDraftReport: Codable, Equatable, Sendable {
    let claims: [PodcastEvidenceDraftClaim]
    let tensions: [String]
    let unknowns: [String]
}

private struct PodcastEvidenceMergeDraft: Codable, Equatable, Sendable {
    let evidenceRefs: [String]
    let claims: [PodcastEvidenceDraftClaim]
    let tensions: [String]
    let unknowns: [String]
}

private struct PodcastOutlineDraftBeat: Codable, Equatable, Sendable {
    let title: String
    let talkingPoints: [String]
    let evidenceRefs: [String]
}

private struct PodcastOutlineDraft: Codable, Equatable, Sendable {
    let title: String
    let summary: String
    let beats: [PodcastOutlineDraftBeat]
}

enum BatchPodcastJSONDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let withoutFences = trimmed
            .replacingOccurrences(of: #"```(?:json|JSON)?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var candidates = [withoutFences]
        candidates.append(contentsOf: balancedFragments(in: withoutFences))
        var seen = Set<String>()

        for candidate in candidates where seen.insert(candidate).inserted {
            for normalized in [candidate, normalizeModelJSON(candidate)] where !normalized.isEmpty {
                guard let data = normalized.data(using: .utf8) else { continue }
                if let object = try? JSONSerialization.jsonObject(with: data),
                   let value: T = decodeNested(type, object: object, decoder: decoder, depth: 0) {
                    return value
                }
                if let value = try? decoder.decode(type, from: data) {
                    return value
                }
            }
        }
        return nil
    }

    private static func decodeNested<T: Decodable>(
        _ type: T.Type,
        object: Any,
        decoder: JSONDecoder,
        depth: Int
    ) -> T? {
        guard depth <= 3 else { return nil }

        if let dictionary = object as? [String: Any] {
            let preferredKeys = ["episode", "podcast", "script", "result", "data"]
            for key in preferredKeys {
                if let nested = dictionary[key],
                   let value: T = decodeNested(type, object: nested, decoder: decoder, depth: depth + 1) {
                    return value
                }
            }
        }

        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object),
           let value = try? decoder.decode(type, from: data) {
            return value
        }

        guard let dictionary = object as? [String: Any] else { return nil }
        for nested in dictionary.values {
            if let value: T = decodeNested(type, object: nested, decoder: decoder, depth: depth + 1) {
                return value
            }
        }
        return nil
    }

    private static func balancedFragments(in text: String) -> [String] {
        let characters = Array(text)
        var fragments: [String] = []

        for start in characters.indices where characters[start] == "{" || characters[start] == "[" {
            var stack: [Character] = []
            var isInsideString = false
            var isEscaped = false

            for index in start..<characters.endIndex {
                let character = characters[index]
                if isInsideString {
                    if isEscaped {
                        isEscaped = false
                    } else if character == "\\" {
                        isEscaped = true
                    } else if character == "\"" {
                        isInsideString = false
                    }
                    continue
                }

                if character == "\"" {
                    isInsideString = true
                } else if character == "{" || character == "[" {
                    stack.append(character)
                } else if character == "}" || character == "]" {
                    guard let opening = stack.last,
                          (opening == "{" && character == "}") || (opening == "[" && character == "]") else {
                        break
                    }
                    stack.removeLast()
                    if stack.isEmpty {
                        fragments.append(String(characters[start...index]))
                        break
                    }
                }
            }
        }
        return fragments
    }

    private static func normalizeModelJSON(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var isInsideString = false
        var isEscaped = false

        for index in characters.indices {
            let character = characters[index]
            if isInsideString {
                if isEscaped {
                    output.append(character)
                    isEscaped = false
                } else if character == "\\" {
                    output.append(character)
                    isEscaped = true
                } else if character == "\"" {
                    output.append(character)
                    isInsideString = false
                } else if character == "\n" {
                    output.append(contentsOf: "\\n")
                } else if character == "\r" {
                    output.append(contentsOf: "\\r")
                } else if character == "\t" {
                    output.append(contentsOf: "\\t")
                } else {
                    output.append(character)
                }
                continue
            }

            if character == "\"" {
                output.append(character)
                isInsideString = true
            } else if character == "," {
                var lookahead = characters.index(after: index)
                while lookahead < characters.endIndex && characters[lookahead].isWhitespace {
                    lookahead = characters.index(after: lookahead)
                }
                if lookahead < characters.endIndex,
                   characters[lookahead] == "}" || characters[lookahead] == "]" {
                    continue
                }
                output.append(character)
            } else {
                output.append(character)
            }
        }
        return output
    }
}

final class BatchPodcastService {
    private let generator: any BatchPodcastTextGenerator
    private let maximumEvidenceReportsPerMerge = 6

    init(generator: any BatchPodcastTextGenerator = SummaryServiceBatchPodcastGenerator()) {
        self.generator = generator
    }

    func generateEpisode(
        from context: BatchPodcastContext,
        progress: (@MainActor @Sendable (BatchPodcastProgress) -> Void)? = nil
    ) async throws -> PodcastEpisode {
        try Task.checkCancellation()
        let evidence = try await reduceEvidence(from: context, progress: progress)
        try Task.checkCancellation()

        await progress?(.consolidatingEvidence)
        let consolidated = try await consolidateEvidence(evidence)
        let evidenceReferences = makeEvidenceReferences(from: consolidated)

        await progress?(.outlining)
        let outline = try await makeOutline(from: evidenceReferences, context: context)

        await progress?(.writingScript)
        let scriptPrompt = finalScriptPrompt(
            outline: outline,
            evidence: evidenceReferences,
            context: context
        )
        var rawScript = try await generator.generate(prompt: scriptPrompt, title: "Batch Podcast Script")

        do {
            await progress?(.validating)
            let episode = try validatedEpisode(
                from: rawScript,
                context: context,
                evidenceReferences: evidenceReferences
            )
            await progress?(.complete)
            return episode
        } catch {
            try Task.checkCancellation()
            await progress?(.repairingJSON)
            let repairPrompt = repairPrompt(
                rawScript: rawScript,
                outline: outline,
                context: context,
                evidenceReferences: evidenceReferences,
                validationError: error
            )
            rawScript = try await generator.generate(
                prompt: repairPrompt,
                title: repairRequestTitle(for: error)
            )

            do {
                await progress?(.validating)
                let episode = try validatedEpisode(
                    from: rawScript,
                    context: context,
                    evidenceReferences: evidenceReferences
                )
                await progress?(.complete)
                return episode
            } catch let validationError as BatchPodcastError {
                throw validationError
            } catch {
                throw BatchPodcastError.invalidScript(error.localizedDescription)
            }
        }
    }

    private func reduceEvidence(
        from context: BatchPodcastContext,
        progress: (@MainActor @Sendable (BatchPodcastProgress) -> Void)?
    ) async throws -> [PodcastEvidenceReport] {
        if context.commentChunks.isEmpty {
            var reports = context.postSummaries.enumerated().map { index, summary in
                let ids = sourceIDs(for: summary, in: context.capturedSources)
                return PodcastEvidenceReport(
                    chunkID: "summary-\(index + 1)",
                    sourceIDs: ids,
                    claims: [
                        PodcastEvidenceClaim(
                            text: String(summary.summary.prefix(2_000)),
                            sourceIDs: ids
                        )
                    ],
                    tensions: [],
                    unknowns: ["Raw comments were not saved for this batch; this is a summaries-only episode."]
                )
            }
            if reports.isEmpty,
               let overallSummary = context.overallSummary,
               !overallSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reports.append(
                    PodcastEvidenceReport(
                        chunkID: "overall-summary",
                        sourceIDs: [],
                        claims: [
                            PodcastEvidenceClaim(
                                text: String(overallSummary.prefix(2_000)),
                                sourceIDs: []
                            )
                        ],
                        tensions: [],
                        unknowns: ["Raw comments were not saved for this batch; this is a summaries-only episode."]
                    )
                )
            }
            return reports
        }

        var reports: [PodcastEvidenceReport] = []
        reports.reserveCapacity(context.commentChunks.count)
        for (index, chunk) in context.commentChunks.enumerated() {
            try Task.checkCancellation()
            await progress?(.analyzingComments(current: index + 1, total: context.commentChunks.count))
            let prompt = evidencePrompt(chunk: chunk, context: context)
            let raw = try await generator.generate(
                prompt: prompt,
                title: "Saved Comments \(index + 1) of \(context.commentChunks.count)"
            )
            reports.append(parseEvidence(raw: raw, chunk: chunk, knownSourceIDs: context.knownSourceIDs))
        }
        return reports
    }

    private func consolidateEvidence(
        _ reports: [PodcastEvidenceReport]
    ) async throws -> [PodcastEvidenceReport] {
        guard reports.count > maximumEvidenceReportsPerMerge else { return reports }
        var current = reports

        while current.count > maximumEvidenceReportsPerMerge {
            var next: [PodcastEvidenceReport] = []
            for start in stride(from: 0, to: current.count, by: maximumEvidenceReportsPerMerge) {
                try Task.checkCancellation()
                let group = Array(current[start..<min(start + maximumEvidenceReportsPerMerge, current.count)])
                let references = makeEvidenceReferences(from: group)
                let prompt = mergePrompt(for: references)
                let raw = try await generator.generate(
                    prompt: prompt,
                    title: "Consolidate Podcast Evidence"
                )
                let decoded = decode([PodcastEvidenceMergeDraft].self, from: raw)
                if let decoded, !decoded.isEmpty {
                    let merged = decoded.compactMap {
                        mergeEvidence($0, references: references, fallback: group)
                    }
                    if !merged.isEmpty {
                        next.append(contentsOf: merged)
                    } else {
                        next.append(fallbackMergedReport(group))
                    }
                } else {
                    next.append(fallbackMergedReport(group))
                }
            }
            current = next
        }
        return current
    }

    private func makeOutline(
        from evidence: [PodcastEvidenceReference],
        context: BatchPodcastContext
    ) async throws -> PodcastOutline {
        let prompt = """
        Build a compact outline for a grounded two-host podcast about \(context.contextName).

        Saved evidence reports, already reduced from every captured comment chunk. Each report has an app-owned evidence reference:
        \(json(promptEvidence(from: evidence)))

        Existing per-post summaries:
        \(context.postSummaries.map { "- \($0.title): \(String($0.summary.prefix(500)))" }.joined(separator: "\n"))

        Overall summary, if present:
        \(context.overallSummary ?? "No overall summary was saved.")

        Allowed evidence references (copy exactly; do not invent):
        \(evidence.map(\.id).joined(separator: ", ").isEmpty ? "(none)" : evidence.map(\.id).joined(separator: ", "))

        Return only JSON matching this shape:
        {"title":"...","summary":"...","beats":[{"title":"...","talkingPoints":["..."],"evidenceRefs":["evidence-1"]}]}
        Preserve disagreement and uncertainty. Do not invent counts or claim consensus. Keep evidence references internal to JSON.
        """
        let raw = try await generator.generate(prompt: prompt, title: "Outline Batch Podcast")
        if let draft = decode(PodcastOutlineDraft.self, from: raw) {
            let allowed = Set(evidence.map(\.id))
            return PodcastOutline(
                title: draft.title,
                summary: draft.summary,
                beats: draft.beats.map {
                    PodcastOutlineBeat(
                        title: $0.title,
                        talkingPoints: $0.talkingPoints,
                        evidenceRefs: $0.evidenceRefs.filter { allowed.contains($0) }
                    )
                }
            )
        }

        let beats = evidence.prefix(8).map { report in
            PodcastOutlineBeat(
                title: report.id,
                talkingPoints: report.claims.filter { !$0.isEmpty },
                evidenceRefs: [report.id]
            )
        }
        return PodcastOutline(
            title: "\(context.contextName) Conversation",
            summary: context.overallSummary ?? "A grounded conversation about the saved batch.",
            beats: beats
        )
    }

    private func validatedEpisode(
        from raw: String,
        context: BatchPodcastContext,
        evidenceReferences: [PodcastEvidenceReference]
    ) throws -> PodcastEpisode {
        guard let draft = decode(PodcastDraftEpisode.self, from: raw) else {
            throw BatchPodcastError.invalidScript("expected Codable JSON")
        }

        let referencesByID = Dictionary(uniqueKeysWithValues: evidenceReferences.map { ($0.id, $0) })
        let unknownEvidenceRefs = Set(draft.turns.flatMap(\.evidenceRefs)).subtracting(referencesByID.keys)
        guard unknownEvidenceRefs.isEmpty else {
            throw BatchPodcastError.invalidEvidenceReferences(unknownEvidenceRefs.sorted())
        }

        let turns = draft.turns.map { turn in
            let cleanedText = context.knownSourceIDs
                .sorted { $0.count > $1.count }
                .reduce(PodcastSpokenTextCleaner.clean(turn.text)) { text, sourceID in
                    text.replacingOccurrences(of: sourceID, with: "")
                }
            let sourceIDs = Array(
                Set(turn.evidenceRefs.flatMap { referencesByID[$0]?.sourceIDs ?? [] })
            ).sorted()
            return PodcastTurn(
                id: turn.id,
                speaker: turn.speaker,
                text: PodcastSpokenTextCleaner.clean(cleanedText),
                sourceIDs: sourceIDs
            )
        }
        let alternatingTurns = PodcastSpeakerAlternator.normalize(turns)
        var episode = PodcastEpisode(
            id: draft.id,
            schemaVersion: PodcastEpisode.currentSchemaVersion,
            title: PodcastSpokenTextCleaner.clean(draft.title),
            summary: PodcastSpokenTextCleaner.clean(draft.summary),
            sourceDigest: context.sourceDigest,
            createdAt: draft.createdAt,
            estimatedDuration: draft.estimatedDuration,
            turns: alternatingTurns
        )
        episode = PodcastEpisodeWordLimiter.limit(episode)
        let duration = Double(episode.spokenWordCount) / 150.0 * 60.0
        episode = episode.withEstimatedDuration(duration)

        try PodcastEpisodeValidator.validate(
            episode,
            knownSourceIDs: context.knownSourceIDs,
            expectedSourceDigest: context.sourceDigest
        )
        return episode
    }

    private func evidencePrompt(
        chunk: BatchPodcastCommentChunk,
        context: BatchPodcastContext
    ) -> String {
        let sourceList = chunk.sourceIDs.map { sourceID in
            let source = context.capturedSources.first { $0.sourceID == sourceID }
            let label = source?.title ?? source?.author ?? "saved Reddit source"
            return "- \(label)"
        }.joined(separator: "\n")

        return """
        Analyze only this saved Reddit comment chunk for a future grounded podcast. This is already-captured evidence; do not fetch or infer anything outside it.

        Chunk ID: \(chunk.id)
        Related captured evidence:
        \(sourceList.isEmpty ? "(none recorded)" : sourceList)

        Saved comments:
        \(chunk.text)

        Return only JSON matching:
        {"claims":[{"text":"compact factual evidence"}],"tensions":["disagreement or uncertainty"],"unknowns":["missing information"]}
        Do not return Reddit source IDs. The app will attach the captured sources for this chunk after decoding.
        Preserve concrete viewpoints, examples, workarounds, and disagreement. Do not use counts or consensus language. Keep it under 400 words.
        """
    }

    private func mergePrompt(for references: [PodcastEvidenceReference]) -> String {
        """
        Merge these saved-comment evidence reports into fewer compact evidence reports for a podcast outline.

        \(json(promptEvidence(from: references)))

        Return only a JSON array shaped like [{"evidenceRefs":["evidence-1"],"claims":[{"text":"compact evidence"}],"tensions":[],"unknowns":[]}].
        Use only the evidence references shown above. Preserve meaningful disagreement and uncertainty. Remove repetition. Do not add facts, counts, consensus claims, or Reddit source IDs.
        """
    }

    private func finalScriptPrompt(
        outline: PodcastOutline,
        evidence: [PodcastEvidenceReference],
        context: BatchPodcastContext
    ) -> String {
        let allowedEvidenceRefs = evidence.map(\.id).joined(separator: ", ")
        let summaryOnlyNote = context.isSummariesOnly
            ? "This is an explicitly selected summaries-only fallback. Say that the conversation is based on saved summaries rather than raw comments, without making up what commenters said."
            : "The saved comment evidence is the source of truth for specific claims."

        return """
        Write a natural, conversational two-host podcast script about the saved Reddit batch \(context.contextName).

        Grounding rule: \(summaryOnlyNote)
        Use only the evidence and outline below. Phrase claims according to what the evidence actually supports, and qualify uncertainty or differing viewpoints naturally. Exact quantities or broad agreement claims may be used only when the evidence explicitly supports them. Do not use Markdown, headings, URLs, source IDs, speaker labels, or production directions in spoken text.

        Aim for 10–18 alternating turns and about \(PodcastEpisodeValidator.targetWords) spoken words, but a shorter grounded episode with fewer turns is acceptable. Do not exceed 18 turns or 1,060 spoken words. Do not pad or repeat material merely to reach a minimum. Count whitespace-delimited words in turn text only, not the title or summary. Let hostA and hostB sound like people reacting to one another. Include the major themes, useful examples, and meaningful tension or uncertainty. The final turn should close naturally.

        Outline:
        \(json(outline))

        Reduced evidence:
        \(json(promptEvidence(from: evidence)))

        Allowed evidence references (copy exactly; do not invent or substitute):
        \(allowedEvidenceRefs.isEmpty ? "(none)" : allowedEvidenceRefs)

        Return only valid JSON matching exactly:
        {"id":"UUID","schemaVersion":1,"title":"short spoken title","summary":"one-paragraph spoken summary","sourceDigest":"\(context.sourceDigest)","createdAt":"ISO-8601 date","estimatedDuration":0,"turns":[{"id":"UUID","speaker":"hostA","text":"spoken words only","evidenceRefs":["evidence-1"]}]}
        Keep evidence references in the JSON arrays for grounding, but never place them in spoken text. Every turn should cite one or more allowed evidence references when any are available.
        """
    }

    private func repairPrompt(
        rawScript: String,
        outline: PodcastOutline,
        context: BatchPodcastContext,
        evidenceReferences: [PodcastEvidenceReference],
        validationError: Error
    ) -> String {
        let allowedEvidenceRefs = evidenceReferences.map(\.id).joined(separator: ", ")
        return """
        Rewrite the following attempted BatchPodcast Codable JSON so it passes validation. Return only valid JSON for schema version 1. The previous validation failure was: \(validationError.localizedDescription).

        Aim for 10–18 alternating turns and 900–1,000 spoken words, but there is no minimum turn or word count. Do not exceed 18 turns or 1,060 spoken words, and do not expand, pad, or repeat material solely to satisfy length. If it is too long, remove repetition while preserving the important evidence. Keep sourceDigest exactly \(context.sourceDigest), use only hostA/hostB speakers, and use only allowed evidence references.

        Phrase claims according to what the supplied evidence supports. Exact quantities or broad agreement claims may be used when explicitly supported by that evidence. Spoken text must contain no Markdown, URLs, evidence references, source IDs, speaker labels, or production directions.

        Return exactly one JSON object with this shape and no prose or Markdown fences:
        {"id":"UUID","schemaVersion":1,"title":"short spoken title","summary":"one-paragraph spoken summary","sourceDigest":"\(context.sourceDigest)","createdAt":"ISO-8601 date","estimatedDuration":0,"turns":[{"id":"UUID","speaker":"hostA","text":"spoken words only","evidenceRefs":["evidence-1"]}]}

        Outline:
        \(json(outline))

        Reduced evidence:
        \(json(promptEvidence(from: evidenceReferences)))

        Attempted JSON:
        \(String(rawScript.prefix(24_000)))

        Allowed evidence references:
        \(allowedEvidenceRefs.isEmpty ? "(none)" : allowedEvidenceRefs)
        """
    }

    private func repairRequestTitle(for error: Error) -> String {
        guard let podcastError = error as? BatchPodcastError else {
            return "Repair Batch Podcast JSON"
        }
        switch podcastError {
        case .invalidWordCount:
            return "Condense Batch Podcast Script"
        case .invalidTurnCount:
            return "Restructure Batch Podcast Script"
        default:
            return "Repair Batch Podcast JSON"
        }
    }

    private func parseEvidence(
        raw: String,
        chunk: BatchPodcastCommentChunk,
        knownSourceIDs: Set<String>
    ) -> PodcastEvidenceReport {
        let capturedSourceIDs = chunk.sourceIDs.filter { knownSourceIDs.contains($0) }
        if let decoded = decode(PodcastEvidenceDraftReport.self, from: raw) {
            let claims = decoded.claims.map {
                PodcastEvidenceClaim(
                    text: String($0.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000)),
                    sourceIDs: capturedSourceIDs
                )
            }.filter { !$0.text.isEmpty }
            return PodcastEvidenceReport(
                chunkID: chunk.id,
                sourceIDs: capturedSourceIDs,
                claims: claims,
                tensions: decoded.tensions.map { String($0.prefix(500)) },
                unknowns: decoded.unknowns.map { String($0.prefix(500)) }
            )
        }

        let fallbackText = PodcastSpokenTextCleaner.clean(String(raw.prefix(4_000)))
        return PodcastEvidenceReport(
            chunkID: chunk.id,
            sourceIDs: capturedSourceIDs,
            claims: [
                PodcastEvidenceClaim(
                    text: fallbackText.isEmpty ? "No structured evidence was returned for this saved chunk." : fallbackText,
                    sourceIDs: capturedSourceIDs
                )
            ],
            tensions: [],
            unknowns: ["The evidence response was not valid JSON; the saved chunk was still included in the reduction."]
        )
    }

    private func makeEvidenceReferences(
        from reports: [PodcastEvidenceReport]
    ) -> [PodcastEvidenceReference] {
        reports.enumerated().map { index, report in
            PodcastEvidenceReference(
                id: "evidence-\(index + 1)",
                sourceIDs: report.sourceIDs,
                claims: report.claims.map(\.text).filter { !$0.isEmpty },
                tensions: report.tensions,
                unknowns: report.unknowns
            )
        }
    }

    private func promptEvidence(
        from references: [PodcastEvidenceReference]
    ) -> [PodcastPromptEvidence] {
        references.map {
            PodcastPromptEvidence(
                evidenceRef: $0.id,
                claims: $0.claims,
                tensions: $0.tensions,
                unknowns: $0.unknowns
            )
        }
    }

    private func mergeEvidence(
        _ draft: PodcastEvidenceMergeDraft,
        references: [PodcastEvidenceReference],
        fallback: [PodcastEvidenceReport]
    ) -> PodcastEvidenceReport? {
        let referencesByID = Dictionary(uniqueKeysWithValues: references.map { ($0.id, $0) })
        let validRefs = draft.evidenceRefs.filter { referencesByID[$0] != nil }
        let sourceIDs = Array(
            Set(validRefs.flatMap { referencesByID[$0]?.sourceIDs ?? [] })
        ).sorted()
        guard !validRefs.isEmpty || fallback.allSatisfy({ $0.sourceIDs.isEmpty }) else {
            return nil
        }

        let claims = draft.claims.map { claim in
            PodcastEvidenceClaim(
                text: String(claim.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000)),
                sourceIDs: sourceIDs
            )
        }.filter { !$0.text.isEmpty }
        return PodcastEvidenceReport(
            chunkID: validRefs.isEmpty ? fallback.map(\.chunkID).joined(separator: "+") : validRefs.joined(separator: "+"),
            sourceIDs: sourceIDs,
            claims: claims,
            tensions: draft.tensions.map { String($0.prefix(500)) },
            unknowns: draft.unknowns.map { String($0.prefix(500)) }
        )
    }

    private func sanitizeEvidence(
        _ report: PodcastEvidenceReport,
        knownSourceIDs: Set<String>,
        fallbackChunk: BatchPodcastCommentChunk? = nil
    ) -> PodcastEvidenceReport {
        let fallbackIDs = fallbackChunk?.sourceIDs ?? []
        let reportIDs = report.sourceIDs.filter { knownSourceIDs.contains($0) }
        let sourceIDs = reportIDs.isEmpty ? fallbackIDs.filter { knownSourceIDs.contains($0) } : reportIDs
        let claims = report.claims.map { claim in
            PodcastEvidenceClaim(
                text: String(claim.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000)),
                sourceIDs: claim.sourceIDs.filter { knownSourceIDs.contains($0) }
            )
        }.filter { !$0.text.isEmpty }
        return PodcastEvidenceReport(
            chunkID: fallbackChunk?.id ?? report.chunkID,
            sourceIDs: sourceIDs,
            claims: claims,
            tensions: report.tensions.map { String($0.prefix(500)) },
            unknowns: report.unknowns.map { String($0.prefix(500)) }
        )
    }

    private func fallbackMergedReport(_ reports: [PodcastEvidenceReport]) -> PodcastEvidenceReport {
        PodcastEvidenceReport(
            chunkID: reports.map(\.chunkID).joined(separator: "+"),
            sourceIDs: Array(Set(reports.flatMap(\.sourceIDs))).sorted(),
            claims: reports.flatMap(\.claims),
            tensions: reports.flatMap(\.tensions),
            unknowns: reports.flatMap(\.unknowns)
        )
    }

    private func sourceIDs(
        for summary: BatchPodcastPostSummaryInput,
        in sources: [ResearchSourceInput]
    ) -> [String] {
        let normalizedTitle = normalize(summary.title)
        let postIDs = sources.filter {
            $0.kind == .post
                && normalize($0.title ?? "") == normalizedTitle
        }.map(\.sourceID)
        let ids = sources.filter { $0.kind == .comment && postIDs.contains($0.postSourceID) }.map(\.sourceID)
        return Array(Set(postIDs + ids)).sorted()
    }

    private func json<T: Encodable>(_ value: T) -> String {
        ResearchJSON.encode(value)
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func decode<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        BatchPodcastJSONDecoder.decode(type, from: raw)
    }
}
