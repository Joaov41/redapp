import Foundation
import SwiftData
#if canImport(CryptoKit)
import CryptoKit
#endif

enum ResearchArtifactKind: String, Codable, CaseIterable, Sendable {
    case postSummary
    case commentSummary
    case batchSummary
    case overallReport
    case categorizedReport
    case tableReport
    case infographic
    case whiteboard
    case questionAnswer
    case conversationAnswer
    case changeReport
    case communityComparison

    var displayName: String {
        switch self {
        case .postSummary: return "Post Summary"
        case .commentSummary: return "Comment Summary"
        case .batchSummary: return "Batch Summary"
        case .overallReport: return "Overall Report"
        case .categorizedReport: return "Categorized Report"
        case .tableReport: return "Table Report"
        case .infographic: return "Infographic"
        case .whiteboard: return "Whiteboard"
        case .questionAnswer: return "Q&A"
        case .conversationAnswer: return "Conversation Answer"
        case .changeReport: return "What Changed"
        case .communityComparison: return "Community Comparison"
        }
    }
}

enum ResearchSourceKind: String, Codable, Sendable {
    case post
    case comment
}

enum ResearchRunState: String, Codable, Sendable {
    case capturing
    case ready
    case partial
    case failed

    var displayName: String {
        switch self {
        case .capturing: return "Saving"
        case .ready: return "Complete"
        case .partial: return "Incomplete"
        case .failed: return "Failed"
        }
    }

    var explanation: String {
        switch self {
        case .capturing:
            return "This saved revision is still being prepared."
        case .ready:
            return "All requested material that was fetched was included."
        case .partial:
            return "Some requested posts or comments could not be fetched, were omitted by the analysis limit, or failed during processing."
        case .failed:
            return "The revision could not be completed."
        }
    }
}

enum ResearchEvidenceConfidence: String, Codable, CaseIterable, Sendable {
    case unverified
    case low
    case medium
    case high

    var displayName: String { rawValue.capitalized }
}

enum ResearchOfflineAssetState: String, Codable, Sendable {
    case queued
    case downloading
    case ready
    case partial
    case failed
}

enum ResearchOfflineAssetKind: String, Codable, Sendable {
    case thumbnail
    case image
    case speech
    case report
    case attachment
}

enum ResearchDraftKind: String, Codable, Sendable {
    case post
    case reply
}

enum ResearchConversationRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

struct ResearchSourceInput: Codable, Hashable, Identifiable, Sendable {
    let sourceID: String
    let kind: ResearchSourceKind
    let postSourceID: String
    let parentSourceID: String?
    let subreddit: String
    let title: String?
    let permalink: String
    let author: String?
    let score: Int?
    let createdAt: Date?
    let depth: Int?
    let rawMarkdown: String
    let mediaURLs: [String]
    let sourceOrder: Int

    var id: String { sourceID }

    var contentDigest: String {
        ResearchDigest.sha256Hex(
            [sourceID, title ?? "", rawMarkdown, permalink]
                .joined(separator: "\u{1f}")
        )
    }
}

struct ResearchCoverageInput: Codable, Hashable, Sendable {
    var postsRequested: Int
    var postsFetched: Int
    var postsAnalyzed: Int
    var commentsReported: Int
    var commentsFetched: Int
    var commentsAnalyzed: Int
    var commentsOmitted: Int
    var failureMessages: [String]
    var truncationMessages: [String]

    static let empty = ResearchCoverageInput(
        postsRequested: 0,
        postsFetched: 0,
        postsAnalyzed: 0,
        commentsReported: 0,
        commentsFetched: 0,
        commentsAnalyzed: 0,
        commentsOmitted: 0,
        failureMessages: [],
        truncationMessages: []
    )

    func combined(with other: ResearchCoverageInput) -> ResearchCoverageInput {
        ResearchCoverageInput(
            postsRequested: postsRequested + other.postsRequested,
            postsFetched: postsFetched + other.postsFetched,
            postsAnalyzed: postsAnalyzed + other.postsAnalyzed,
            commentsReported: commentsReported + other.commentsReported,
            commentsFetched: commentsFetched + other.commentsFetched,
            commentsAnalyzed: commentsAnalyzed + other.commentsAnalyzed,
            commentsOmitted: commentsOmitted + other.commentsOmitted,
            failureMessages: Array(Set(failureMessages + other.failureMessages)).sorted(),
            truncationMessages: Array(Set(truncationMessages + other.truncationMessages)).sorted()
        )
    }
}

struct ResearchGenerationReceiptInput: Codable, Hashable, Sendable {
    var requestedProvider: String
    var actualProvider: String
    var modelID: String
    var webProvider: String?
    var route: String
    var wasRerouted: Bool
    var promptVersion: Int
    var responseSchemaVersion: Int
    var startedAt: Date
    var completedAt: Date
    var appBuild: String
}

struct ResearchCitationInput: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let sourceID: String
    let supportingQuote: String?

    init(id: UUID = UUID(), sourceID: String, supportingQuote: String? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.supportingQuote = supportingQuote
    }
}

struct ResearchClaimInput: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let order: Int
    let text: String
    let claimType: String
    let citations: [ResearchCitationInput]
    let conflictingSourceIDs: [String]
    let missingDataNote: String?
    let confidence: ResearchEvidenceConfidence

    init(
        id: UUID = UUID(),
        order: Int,
        text: String,
        claimType: String = "finding",
        citations: [ResearchCitationInput],
        conflictingSourceIDs: [String] = [],
        missingDataNote: String? = nil,
        confidence: ResearchEvidenceConfidence
    ) {
        self.id = id
        self.order = order
        self.text = text
        self.claimType = claimType
        self.citations = citations
        self.conflictingSourceIDs = conflictingSourceIDs
        self.missingDataNote = missingDataNote
        self.confidence = confidence
    }
}

@Model
final class ResearchItemRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var scope: String
    var subreddit: String
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?
    var pinnedAt: Date?
    var tagsJSON: String
    var normalizedSearchText: String

    init(
        id: UUID = UUID(),
        title: String,
        scope: String,
        subreddit: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        pinnedAt: Date? = nil,
        tags: [String] = [],
        normalizedSearchText: String = ""
    ) {
        self.id = id
        self.title = title
        self.scope = scope
        self.subreddit = subreddit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
        self.pinnedAt = pinnedAt
        self.tagsJSON = ResearchJSON.encode(tags)
        self.normalizedSearchText = normalizedSearchText
    }

    var tags: [String] {
        get { ResearchJSON.decode([String].self, from: tagsJSON) ?? [] }
        set { tagsJSON = ResearchJSON.encode(newValue) }
    }
}

@Model
final class ResearchRunRecord {
    @Attribute(.unique) var id: UUID
    var itemID: UUID
    var revision: Int
    var stateRawValue: String
    var capturedAt: Date
    var completedAt: Date?
    var feedMode: String
    var subreddit: String
    var sortMode: String
    var timeRange: String
    var sourceDigest: String
    var coverageJSON: String
    var appBuild: String
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        itemID: UUID,
        revision: Int,
        state: ResearchRunState,
        capturedAt: Date = Date(),
        completedAt: Date? = nil,
        feedMode: String,
        subreddit: String,
        sortMode: String,
        timeRange: String,
        sourceDigest: String,
        coverage: ResearchCoverageInput,
        appBuild: String,
        failureMessage: String? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.revision = revision
        self.stateRawValue = state.rawValue
        self.capturedAt = capturedAt
        self.completedAt = completedAt
        self.feedMode = feedMode
        self.subreddit = subreddit
        self.sortMode = sortMode
        self.timeRange = timeRange
        self.sourceDigest = sourceDigest
        self.coverageJSON = ResearchJSON.encode(coverage)
        self.appBuild = appBuild
        self.failureMessage = failureMessage
    }

    var state: ResearchRunState {
        get { ResearchRunState(rawValue: stateRawValue) ?? .partial }
        set { stateRawValue = newValue.rawValue }
    }

    var coverage: ResearchCoverageInput {
        get { ResearchJSON.decode(ResearchCoverageInput.self, from: coverageJSON) ?? .empty }
        set { coverageJSON = ResearchJSON.encode(newValue) }
    }
}

enum ResearchCaptureLabel {
    static func displayName(sortMode: String, timeRange: String) -> String {
        let normalizedSort = sortMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sortName: String
        switch normalizedSort {
        case "new": sortName = "New"
        case "hot": sortName = "Hot"
        case "top": sortName = "Top"
        default: sortName = normalizedSort.isEmpty ? "Saved feed" : normalizedSort.capitalized
        }

        guard normalizedSort == "top" else { return sortName }
        let normalizedTime = timeRange.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let timeName: String
        switch normalizedTime {
        case "hour": timeName = "Past hour"
        case "day": timeName = "Today"
        case "week": timeName = "This week"
        case "month": timeName = "This month"
        case "year": timeName = "This year"
        case "all": timeName = "All time"
        default: timeName = normalizedTime.isEmpty ? "All time" : normalizedTime.capitalized
        }
        return "\(sortName) · \(timeName)"
    }

    static func displayName(scope: String) -> String {
        let components = scope.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 4 else { return "Saved feed" }
        return displayName(sortMode: components[components.count - 2], timeRange: components.last ?? "all")
    }

    static func key(sortMode: String, timeRange: String) -> String {
        let sort = sortMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let time = timeRange.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(sort)|\(sort == "top" ? time : "all")"
    }
}

@Model
final class ResearchSourceRecord {
    @Attribute(.unique) var id: UUID
    var runID: UUID
    var sourceID: String
    var kindRawValue: String
    var postSourceID: String
    var parentSourceID: String?
    var subreddit: String
    var title: String?
    var permalink: String
    var author: String?
    var score: Int?
    var sourceCreatedAt: Date?
    var depth: Int?
    var rawMarkdown: String
    var mediaURLsJSON: String
    var sourceOrder: Int
    var contentDigest: String

    init(id: UUID = UUID(), runID: UUID, input: ResearchSourceInput) {
        self.id = id
        self.runID = runID
        self.sourceID = input.sourceID
        self.kindRawValue = input.kind.rawValue
        self.postSourceID = input.postSourceID
        self.parentSourceID = input.parentSourceID
        self.subreddit = input.subreddit
        self.title = input.title
        self.permalink = input.permalink
        self.author = input.author
        self.score = input.score
        self.sourceCreatedAt = input.createdAt
        self.depth = input.depth
        self.rawMarkdown = input.rawMarkdown
        self.mediaURLsJSON = ResearchJSON.encode(input.mediaURLs)
        self.sourceOrder = input.sourceOrder
        self.contentDigest = input.contentDigest
    }

    var kind: ResearchSourceKind {
        ResearchSourceKind(rawValue: kindRawValue) ?? .comment
    }

    var mediaURLs: [String] {
        ResearchJSON.decode([String].self, from: mediaURLsJSON) ?? []
    }
}

@Model
final class ResearchArtifactRecord {
    @Attribute(.unique) var id: UUID
    var runID: UUID
    var supersedesArtifactID: UUID?
    var kindRawValue: String
    var title: String
    var body: String
    var format: String
    var createdAt: Date
    var generationReceiptJSON: String?
    var coverageJSON: String
    var conflictsJSON: String
    var missingDataJSON: String
    var legacyUncited: Bool

    init(
        id: UUID = UUID(),
        runID: UUID,
        supersedesArtifactID: UUID? = nil,
        kind: ResearchArtifactKind,
        title: String,
        body: String,
        format: String = "markdown",
        createdAt: Date = Date(),
        generationReceipt: ResearchGenerationReceiptInput? = nil,
        coverage: ResearchCoverageInput = .empty,
        conflicts: [String] = [],
        missingData: [String] = [],
        legacyUncited: Bool = false
    ) {
        self.id = id
        self.runID = runID
        self.supersedesArtifactID = supersedesArtifactID
        self.kindRawValue = kind.rawValue
        self.title = title
        self.body = body
        self.format = format
        self.createdAt = createdAt
        self.generationReceiptJSON = generationReceipt.map { ResearchJSON.encode($0) }
        self.coverageJSON = ResearchJSON.encode(coverage)
        self.conflictsJSON = ResearchJSON.encode(conflicts)
        self.missingDataJSON = ResearchJSON.encode(missingData)
        self.legacyUncited = legacyUncited
    }

    var kind: ResearchArtifactKind {
        ResearchArtifactKind(rawValue: kindRawValue) ?? .batchSummary
    }

    var generationReceipt: ResearchGenerationReceiptInput? {
        guard let generationReceiptJSON else { return nil }
        return ResearchJSON.decode(ResearchGenerationReceiptInput.self, from: generationReceiptJSON)
    }

    var coverage: ResearchCoverageInput {
        ResearchJSON.decode(ResearchCoverageInput.self, from: coverageJSON) ?? .empty
    }

    var conflicts: [String] {
        ResearchJSON.decode([String].self, from: conflictsJSON) ?? []
    }

    var missingData: [String] {
        ResearchJSON.decode([String].self, from: missingDataJSON) ?? []
    }
}

@Model
final class ResearchClaimRecord {
    @Attribute(.unique) var id: UUID
    var artifactID: UUID
    var claimOrder: Int
    var text: String
    var claimType: String
    var confidenceRawValue: String
    var conflictingSourceIDsJSON: String
    var missingDataNote: String?

    init(artifactID: UUID, input: ResearchClaimInput) {
        self.id = input.id
        self.artifactID = artifactID
        self.claimOrder = input.order
        self.text = input.text
        self.claimType = input.claimType
        self.confidenceRawValue = input.confidence.rawValue
        self.conflictingSourceIDsJSON = ResearchJSON.encode(input.conflictingSourceIDs)
        self.missingDataNote = input.missingDataNote
    }

    var confidence: ResearchEvidenceConfidence {
        ResearchEvidenceConfidence(rawValue: confidenceRawValue) ?? .unverified
    }

    var conflictingSourceIDs: [String] {
        ResearchJSON.decode([String].self, from: conflictingSourceIDsJSON) ?? []
    }
}

@Model
final class ResearchCitationRecord {
    @Attribute(.unique) var id: UUID
    var claimID: UUID
    var sourceID: String
    var supportingQuote: String?
    var sourceDigest: String
    var validated: Bool
    var validationMessage: String?

    init(
        id: UUID = UUID(),
        claimID: UUID,
        sourceID: String,
        supportingQuote: String?,
        sourceDigest: String,
        validated: Bool,
        validationMessage: String? = nil
    ) {
        self.id = id
        self.claimID = claimID
        self.sourceID = sourceID
        self.supportingQuote = supportingQuote
        self.sourceDigest = sourceDigest
        self.validated = validated
        self.validationMessage = validationMessage
    }
}

@Model
final class ResearchConversationRecord {
    @Attribute(.unique) var id: UUID
    var runID: UUID
    var sourceDigest: String
    var title: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        runID: UUID,
        sourceDigest: String,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.sourceDigest = sourceDigest
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class ResearchConversationTurnRecord {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID
    var sequence: Int
    var roleRawValue: String
    var text: String
    var artifactID: UUID?
    var generationReceiptJSON: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        sequence: Int,
        role: ResearchConversationRole,
        text: String,
        artifactID: UUID? = nil,
        generationReceipt: ResearchGenerationReceiptInput? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.sequence = sequence
        self.roleRawValue = role.rawValue
        self.text = text
        self.artifactID = artifactID
        self.generationReceiptJSON = generationReceipt.map { ResearchJSON.encode($0) }
        self.createdAt = createdAt
    }

    var role: ResearchConversationRole {
        ResearchConversationRole(rawValue: roleRawValue) ?? .assistant
    }

    var generationReceipt: ResearchGenerationReceiptInput? {
        guard let generationReceiptJSON else { return nil }
        return ResearchJSON.decode(ResearchGenerationReceiptInput.self, from: generationReceiptJSON)
    }
}

@Model
final class ResearchOfflineAssetRecord {
    @Attribute(.unique) var id: UUID
    var runID: UUID
    var artifactID: UUID?
    var kindRawValue: String
    var remoteURL: String?
    var relativePath: String
    var mimeType: String
    var checksum: String
    var byteCount: Int64
    var stateRawValue: String
    var sourceTextDigest: String?
    var ttsEngine: String?
    var ttsVoice: String?
    var ttsSpeed: Double?
    var duration: Double?
    var createdAt: Date
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        runID: UUID,
        artifactID: UUID? = nil,
        kind: ResearchOfflineAssetKind,
        remoteURL: String? = nil,
        relativePath: String,
        mimeType: String,
        checksum: String,
        byteCount: Int64,
        state: ResearchOfflineAssetState,
        sourceTextDigest: String? = nil,
        ttsEngine: String? = nil,
        ttsVoice: String? = nil,
        ttsSpeed: Double? = nil,
        duration: Double? = nil,
        createdAt: Date = Date(),
        failureMessage: String? = nil
    ) {
        self.id = id
        self.runID = runID
        self.artifactID = artifactID
        self.kindRawValue = kind.rawValue
        self.remoteURL = remoteURL
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.checksum = checksum
        self.byteCount = byteCount
        self.stateRawValue = state.rawValue
        self.sourceTextDigest = sourceTextDigest
        self.ttsEngine = ttsEngine
        self.ttsVoice = ttsVoice
        self.ttsSpeed = ttsSpeed
        self.duration = duration
        self.createdAt = createdAt
        self.failureMessage = failureMessage
    }

    var kind: ResearchOfflineAssetKind {
        ResearchOfflineAssetKind(rawValue: kindRawValue) ?? .attachment
    }

    var state: ResearchOfflineAssetState {
        get { ResearchOfflineAssetState(rawValue: stateRawValue) ?? .failed }
        set { stateRawValue = newValue.rawValue }
    }
}

@Model
final class ResearchDraftRecord {
    @Attribute(.unique) var id: UUID
    var kindRawValue: String
    var destinationKey: String
    var subreddit: String
    var parentSourceID: String?
    var permalink: String?
    var title: String
    var body: String
    var linkURL: String
    var flairID: String?
    var flairText: String?
    var attachmentPathsJSON: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: ResearchDraftKind,
        destinationKey: String,
        subreddit: String = "",
        parentSourceID: String? = nil,
        permalink: String? = nil,
        title: String = "",
        body: String = "",
        linkURL: String = "",
        flairID: String? = nil,
        flairText: String? = nil,
        attachmentPaths: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kindRawValue = kind.rawValue
        self.destinationKey = destinationKey
        self.subreddit = subreddit
        self.parentSourceID = parentSourceID
        self.permalink = permalink
        self.title = title
        self.body = body
        self.linkURL = linkURL
        self.flairID = flairID
        self.flairText = flairText
        self.attachmentPathsJSON = ResearchJSON.encode(attachmentPaths)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var kind: ResearchDraftKind {
        ResearchDraftKind(rawValue: kindRawValue) ?? .post
    }

    var attachmentPaths: [String] {
        get { ResearchJSON.decode([String].self, from: attachmentPathsJSON) ?? [] }
        set { attachmentPathsJSON = ResearchJSON.encode(newValue) }
    }
}

enum ResearchCommunityComparisonState: String, Codable, Sendable {
    case preparing
    case running
    case ready
    case failed
}

@Model
final class ResearchCommunityComparisonRecord {
    @Attribute(.unique) var id: UUID
    var leftRunID: UUID
    var rightRunID: UUID
    var subject: String
    var stateRawValue: String
    var artifactID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var compatibilityJSON: String
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        leftRunID: UUID,
        rightRunID: UUID,
        subject: String,
        state: ResearchCommunityComparisonState = .preparing,
        artifactID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        compatibilityJSON: String = "",
        failureMessage: String? = nil
    ) {
        self.id = id
        self.leftRunID = leftRunID
        self.rightRunID = rightRunID
        self.subject = subject
        self.stateRawValue = state.rawValue
        self.artifactID = artifactID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.compatibilityJSON = compatibilityJSON
        self.failureMessage = failureMessage
    }

    var state: ResearchCommunityComparisonState {
        get { ResearchCommunityComparisonState(rawValue: stateRawValue) ?? .failed }
        set { stateRawValue = newValue.rawValue }
    }
}

enum ResearchSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            ResearchItemRecord.self,
            ResearchRunRecord.self,
            ResearchSourceRecord.self,
            ResearchArtifactRecord.self,
            ResearchClaimRecord.self,
            ResearchCitationRecord.self,
            ResearchConversationRecord.self,
            ResearchConversationTurnRecord.self,
            ResearchOfflineAssetRecord.self,
            ResearchDraftRecord.self
        ]
    }
}

enum ResearchSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            ResearchItemRecord.self,
            ResearchRunRecord.self,
            ResearchSourceRecord.self,
            ResearchArtifactRecord.self,
            ResearchClaimRecord.self,
            ResearchCitationRecord.self,
            ResearchConversationRecord.self,
            ResearchConversationTurnRecord.self,
            ResearchOfflineAssetRecord.self,
            ResearchDraftRecord.self,
            ResearchCommunityComparisonRecord.self
        ]
    }
}

enum ResearchMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ResearchSchemaV1.self, ResearchSchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ResearchSchemaV1.self, toVersion: ResearchSchemaV2.self)]
    }
}

enum ResearchJSON {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

enum ResearchDigest {
    static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return String(data.hashValue, radix: 16)
        #endif
    }
}
