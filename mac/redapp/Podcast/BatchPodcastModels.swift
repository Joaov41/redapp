import Foundation

enum PodcastSpeaker: String, Codable, CaseIterable, Identifiable, Sendable {
    case hostA
    case hostB

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hostA: return "Host A"
        case .hostB: return "Host B"
        }
    }
}

struct PodcastTurn: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let speaker: PodcastSpeaker
    let text: String
    let sourceIDs: [String]

    init(
        id: UUID = UUID(),
        speaker: PodcastSpeaker,
        text: String,
        sourceIDs: [String] = []
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.sourceIDs = sourceIDs
    }
}

enum PodcastSpeakerAlternator {
    /// Speaker labels are presentation metadata, so the app owns the final
    /// voice assignment instead of trusting a model to alternate perfectly.
    /// This leaves turn text, IDs, and grounding untouched.
    static func normalize(_ turns: [PodcastTurn]) -> [PodcastTurn] {
        guard let firstSpeaker = turns.first?.speaker else { return turns }
        var nextSpeaker = firstSpeaker
        return turns.map { turn in
            let normalized = PodcastTurn(
                id: turn.id,
                speaker: nextSpeaker,
                text: turn.text,
                sourceIDs: turn.sourceIDs
            )
            nextSpeaker = nextSpeaker == .hostA ? .hostB : .hostA
            return normalized
        }
    }
}

struct PodcastEpisode: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    let title: String
    let summary: String
    let sourceDigest: String
    let createdAt: Date
    let estimatedDuration: TimeInterval
    let turns: [PodcastTurn]

    init(
        id: UUID = UUID(),
        schemaVersion: Int = PodcastEpisode.currentSchemaVersion,
        title: String,
        summary: String,
        sourceDigest: String,
        createdAt: Date = Date(),
        estimatedDuration: TimeInterval = 0,
        turns: [PodcastTurn]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.title = title
        self.summary = summary
        self.sourceDigest = sourceDigest
        self.createdAt = createdAt
        self.estimatedDuration = estimatedDuration
        self.turns = turns
    }

    var spokenText: String {
        turns.map(\.text).joined(separator: " ")
    }

    var spokenWordCount: Int {
        turns.reduce(0) { result, turn in
            result + turn.text.split(whereSeparator: \.isWhitespace).count
        }
    }

    func withEstimatedDuration(_ duration: TimeInterval) -> PodcastEpisode {
        PodcastEpisode(
            id: id,
            schemaVersion: schemaVersion,
            title: title,
            summary: summary,
            sourceDigest: sourceDigest,
            createdAt: createdAt,
            estimatedDuration: duration,
            turns: turns
        )
    }
}

struct BatchPodcastPostSummaryInput: Equatable, Sendable {
    let title: String
    let summary: String
    let permalink: String

    init(title: String, summary: String, permalink: String) {
        self.title = title
        self.summary = summary
        self.permalink = permalink
    }
}

struct BatchPodcastContext: Equatable, Sendable {
    let contextName: String
    let sourceDigest: String
    let capturedSources: [ResearchSourceInput]
    let postSummaries: [BatchPodcastPostSummaryInput]
    let overallSummary: String?
    let coverage: ResearchCoverageInput
    let commentChunks: [BatchPodcastCommentChunk]
    let isSummariesOnly: Bool

    var knownSourceIDs: Set<String> {
        Set(capturedSources.map(\.sourceID).filter { !$0.isEmpty })
    }
}

struct BatchPodcastCommentChunk: Equatable, Sendable, Identifiable {
    let id: String
    let text: String
    let postTitles: [String]
    let sourceIDs: [String]
}

struct BatchPodcastBuildInput: Sendable {
    let contextName: String
    let rawComments: String
    let capturedSources: [ResearchSourceInput]
    let postSummaries: [BatchPodcastPostSummaryInput]
    let overallSummary: String?
    let coverage: ResearchCoverageInput
    let allowSummariesOnly: Bool

    init(
        contextName: String,
        rawComments: String,
        capturedSources: [ResearchSourceInput],
        postSummaries: [BatchPodcastPostSummaryInput],
        overallSummary: String?,
        coverage: ResearchCoverageInput,
        allowSummariesOnly: Bool = false
    ) {
        self.contextName = contextName
        self.rawComments = rawComments
        self.capturedSources = capturedSources
        self.postSummaries = postSummaries
        self.overallSummary = overallSummary
        self.coverage = coverage
        self.allowSummariesOnly = allowSummariesOnly
    }
}

struct PodcastEvidenceClaim: Codable, Equatable, Sendable {
    let text: String
    let sourceIDs: [String]
}

struct PodcastEvidenceReport: Codable, Equatable, Sendable {
    let chunkID: String
    let sourceIDs: [String]
    let claims: [PodcastEvidenceClaim]
    let tensions: [String]
    let unknowns: [String]
}

struct PodcastOutlineBeat: Codable, Equatable, Sendable {
    let title: String
    let talkingPoints: [String]
    let evidenceRefs: [String]
}

struct PodcastOutline: Codable, Equatable, Sendable {
    let title: String
    let summary: String
    let beats: [PodcastOutlineBeat]
}

/// The model-facing script format uses short app-owned evidence labels. The app
/// resolves those labels to captured Reddit source IDs after decoding, so a
/// model can never invent a real source ID in the saved episode.
struct PodcastDraftTurn: Codable, Equatable, Sendable {
    let id: UUID
    let speaker: PodcastSpeaker
    let text: String
    let evidenceRefs: [String]

    init(
        id: UUID = UUID(),
        speaker: PodcastSpeaker,
        text: String,
        evidenceRefs: [String] = []
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.evidenceRefs = evidenceRefs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case speaker
        case text
        case evidenceRefs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedID = try? container.decode(UUID.self, forKey: .id) {
            id = decodedID
        } else if let rawID = try? container.decode(String.self, forKey: .id),
                  let decodedID = UUID(uuidString: rawID) {
            id = decodedID
        } else {
            id = UUID()
        }

        if let decodedSpeaker = try? container.decode(PodcastSpeaker.self, forKey: .speaker) {
            speaker = decodedSpeaker
        } else {
            let rawSpeaker = (try? container.decode(String.self, forKey: .speaker)) ?? ""
            switch rawSpeaker.lowercased().filter({ $0.isLetter || $0.isNumber }) {
            case "hosta", "a", "host1", "1": speaker = .hostA
            case "hostb", "b", "host2", "2": speaker = .hostB
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .speaker,
                    in: container,
                    debugDescription: "Unknown podcast speaker."
                )
            }
        }

        text = (try? container.decode(String.self, forKey: .text)) ?? ""
        if let references = try? container.decode([String].self, forKey: .evidenceRefs) {
            evidenceRefs = references
        } else if let reference = try? container.decode(String.self, forKey: .evidenceRefs) {
            evidenceRefs = [reference]
        } else {
            evidenceRefs = []
        }
    }
}

struct PodcastDraftEpisode: Codable, Equatable, Sendable {
    let id: UUID
    let schemaVersion: Int
    let title: String
    let summary: String
    let sourceDigest: String
    let createdAt: Date
    let estimatedDuration: TimeInterval
    let turns: [PodcastDraftTurn]

    private enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion
        case title
        case summary
        case sourceDigest
        case createdAt
        case estimatedDuration
        case turns
    }

    init(
        id: UUID = UUID(),
        schemaVersion: Int = PodcastEpisode.currentSchemaVersion,
        title: String,
        summary: String,
        sourceDigest: String,
        createdAt: Date = Date(),
        estimatedDuration: TimeInterval = 0,
        turns: [PodcastDraftTurn]
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.title = title
        self.summary = summary
        self.sourceDigest = sourceDigest
        self.createdAt = createdAt
        self.estimatedDuration = estimatedDuration
        self.turns = turns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.title) || container.contains(.summary) || container.contains(.turns) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "The object is not a podcast episode payload."
                )
            )
        }
        if let decodedID = try? container.decode(UUID.self, forKey: .id) {
            id = decodedID
        } else if let rawID = try? container.decode(String.self, forKey: .id),
                  let decodedID = UUID(uuidString: rawID) {
            id = decodedID
        } else {
            id = UUID()
        }

        if let version = try? container.decode(Int.self, forKey: .schemaVersion) {
            schemaVersion = version
        } else if let rawVersion = try? container.decode(String.self, forKey: .schemaVersion),
                  let version = Int(rawVersion) {
            schemaVersion = version
        } else {
            schemaVersion = PodcastEpisode.currentSchemaVersion
        }

        title = (try? container.decode(String.self, forKey: .title)) ?? "Batch Podcast"
        summary = (try? container.decode(String.self, forKey: .summary)) ?? "A conversation grounded in the saved batch."
        sourceDigest = (try? container.decode(String.self, forKey: .sourceDigest)) ?? ""

        if let decodedDate = try? container.decode(Date.self, forKey: .createdAt) {
            createdAt = decodedDate
        } else if let rawDate = try? container.decode(String.self, forKey: .createdAt) {
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            createdAt = fractionalFormatter.date(from: rawDate)
                ?? ISO8601DateFormatter().date(from: rawDate)
                ?? Date()
        } else {
            createdAt = Date()
        }

        if let duration = try? container.decode(Double.self, forKey: .estimatedDuration) {
            estimatedDuration = duration
        } else if let rawDuration = try? container.decode(String.self, forKey: .estimatedDuration),
                  let duration = Double(rawDuration) {
            estimatedDuration = duration
        } else {
            estimatedDuration = 0
        }
        turns = (try? container.decode([PodcastDraftTurn].self, forKey: .turns)) ?? []
    }
}

struct BatchPodcastSpeechVoiceMetadata: Codable, Equatable, Sendable {
    let hostAVoice: String
    let hostBVoice: String
}

enum BatchPodcastProgress: Equatable, Sendable {
    case analyzingComments(current: Int, total: Int)
    case consolidatingEvidence
    case outlining
    case writingScript
    case repairingJSON
    case validating
    case complete

    var message: String {
        switch self {
        case let .analyzingComments(current, total):
            return "Analyzing saved comments \(current) of \(total)…"
        case .consolidatingEvidence: return "Merging evidence into an outline…"
        case .outlining: return "Planning the conversation…"
        case .writingScript: return "Writing the podcast script…"
        case .repairingJSON: return "Repairing the structured script…"
        case .validating: return "Checking grounding and spoken length…"
        case .complete: return "Podcast ready"
        }
    }
}

enum BatchPodcastError: LocalizedError, Equatable, Sendable {
    case noBatchEvidence
    case summariesOnlyRequiresExplicitOptIn
    case invalidScript(String)
    case invalidEvidenceReferences([String])
    case invalidSourceIDs([String])
    case missingSourceGrounding(UUID)
    case invalidTurnCount(Int)
    case invalidWordCount(Int)
    case containsUnspokenMarkup(UUID)
    case digestMismatch
    case researchRunUnavailable
    case audioSaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBatchEvidence:
            return "This batch has no saved post summaries or comments. Run a batch summary first."
        case .summariesOnlyRequiresExplicitOptIn:
            return "This batch has no saved raw comments. Turn on the summaries-only fallback to continue."
        case let .invalidScript(message):
            return "The podcast script was not valid: \(message)"
        case .invalidEvidenceReferences:
            return "The podcast could not be linked to the saved batch evidence. Please try generating it again."
        case let .invalidSourceIDs(sourceIDs):
            return "The script cited sources that are not in this batch: \(sourceIDs.joined(separator: ", "))."
        case .missingSourceGrounding:
            return "A podcast turn did not retain a source reference."
        case let .invalidTurnCount(count):
            return count == 0
                ? "The script did not contain any spoken turns."
                : "The script contained \(count) turns; the maximum is 18."
        case let .invalidWordCount(count):
            return "The script contained \(count) spoken words; the maximum is 1,060."
        case .containsUnspokenMarkup:
            return "The script contained Markdown, a URL, or a production direction."
        case .digestMismatch:
            return "The podcast belongs to a different batch revision and must be regenerated."
        case .researchRunUnavailable:
            return "Save this batch to the Research Library before saving the podcast."
        case let .audioSaveFailed(message):
            return "The podcast audio could not be saved: \(message)"
        }
    }
}

enum PodcastSpokenTextCleaner {
    static func clean(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(
                of: #"\[SOURCE:\s*[^\]]+\]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\[([^\]]+)\]\((?:https?://|www\.)[^\)]*\)"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"https?://\S+|www\.\S+"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?im)^\s*(?:intro|outro|sfx|music|sound effect|direction)\s*:\s*.*$"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\[(?:music|sfx|sound effect|pause|intro|outro|laughs?|stage direction)[^\]]*\]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\((?:music|sfx|sound effect|pause|intro|outro|laughs?|stage direction)[^\)]*\)"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?im)^\s*(?:#{1,6}\s*|[-*+]\s+|\d+[.)]\s+)"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\[[^\]]+\]"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: #"(?im)^\s*(?:host\s*a|host\s*b|hostA|hostB)\s*:\s*"#, with: "", options: .regularExpression)

        cleaned = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    static func trimToWordCount(_ text: String, maximumWords: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > maximumWords else { return text }
        guard maximumWords > 0 else { return "" }

        var trimmed = words.prefix(maximumWords).map(String.init).joined(separator: " ")
        if let last = trimmed.last, !".!?".contains(last) {
            trimmed.append(".")
        }
        return trimmed
    }
}

enum PodcastEpisodeWordLimiter {
    static func limit(
        _ episode: PodcastEpisode,
        maximumWords: Int = PodcastEpisodeValidator.maximumWords
    ) -> PodcastEpisode {
        let totalWords = episode.spokenWordCount
        guard totalWords > maximumWords, maximumWords > 0 else { return episode }

        var turns = episode.turns
        var remainingOverflow = totalWords - maximumWords
        for index in turns.indices.reversed() where remainingOverflow > 0 {
            let currentWords = turns[index].text.split(whereSeparator: \.isWhitespace).count
            guard currentWords > 1 else { continue }
            let targetWords = max(1, currentWords - remainingOverflow)
            let trimmedText = PodcastSpokenTextCleaner.trimToWordCount(
                turns[index].text,
                maximumWords: targetWords
            )
            let removedWords = currentWords - trimmedText.split(whereSeparator: \.isWhitespace).count
            turns[index] = PodcastTurn(
                id: turns[index].id,
                speaker: turns[index].speaker,
                text: trimmedText,
                sourceIDs: turns[index].sourceIDs
            )
            remainingOverflow -= removedWords
        }

        return PodcastEpisode(
            id: episode.id,
            schemaVersion: episode.schemaVersion,
            title: episode.title,
            summary: episode.summary,
            sourceDigest: episode.sourceDigest,
            createdAt: episode.createdAt,
            estimatedDuration: episode.estimatedDuration,
            turns: turns
        )
    }
}

enum PodcastEpisodeValidator {
    static let maximumTurns = 18
    static let targetWords = 900
    static let maximumWords = 1_060

    static func validate(
        _ episode: PodcastEpisode,
        knownSourceIDs: Set<String>,
        expectedSourceDigest: String
    ) throws {
        guard episode.schemaVersion == PodcastEpisode.currentSchemaVersion else {
            throw BatchPodcastError.invalidScript("unsupported schema version")
        }
        guard episode.sourceDigest == expectedSourceDigest else {
            throw BatchPodcastError.digestMismatch
        }
        guard !episode.turns.isEmpty, episode.turns.count <= maximumTurns else {
            throw BatchPodcastError.invalidTurnCount(episode.turns.count)
        }
        let spokenWords = episode.spokenWordCount
        guard spokenWords <= maximumWords else {
            throw BatchPodcastError.invalidWordCount(spokenWords)
        }
        guard episode.turns.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw BatchPodcastError.invalidScript("every turn needs spoken text")
        }
        for index in 1..<episode.turns.count where episode.turns[index].speaker == episode.turns[index - 1].speaker {
            throw BatchPodcastError.invalidScript("hosts must alternate")
        }

        let unknownSourceIDs = Set(episode.turns.flatMap(\.sourceIDs)).subtracting(knownSourceIDs)
        guard unknownSourceIDs.isEmpty else {
            throw BatchPodcastError.invalidSourceIDs(unknownSourceIDs.sorted())
        }

        if !knownSourceIDs.isEmpty {
            for turn in episode.turns where turn.sourceIDs.isEmpty {
                throw BatchPodcastError.missingSourceGrounding(turn.id)
            }
        }

        let markupPattern = try! NSRegularExpression(
            pattern: #"(?i)https?://|www\.|\[SOURCE:|\]\([^\)]*\)|```|\*\*|^\s*#{1,6}\s|^\s*[-*+]\s"#,
            options: [.anchorsMatchLines]
        )
        let directionPattern = try! NSRegularExpression(
            pattern: #"(?i)\[(?:music|sfx|sound effect|pause|intro|outro|laughs?|stage direction)[^\]]*\]|\((?:music|sfx|sound effect|pause|intro|outro|laughs?|stage direction)[^\)]*\)"#
        )

        for turn in episode.turns {
            let range = NSRange(turn.text.startIndex..<turn.text.endIndex, in: turn.text)
            if markupPattern.firstMatch(in: turn.text, range: range) != nil
                || directionPattern.firstMatch(in: turn.text, range: range) != nil {
                throw BatchPodcastError.containsUnspokenMarkup(turn.id)
            }
        }
    }
}
