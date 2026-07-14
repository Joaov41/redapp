import Combine
import Foundation
import SwiftData

enum ResearchStoreError: LocalizedError {
    case unavailable(String)
    case itemNotFound
    case runNotFound
    case invalidSource(String)
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return "Research Library is unavailable: \(message)"
        case .itemNotFound: return "The saved research item could not be found."
        case .runNotFound: return "The saved research run could not be found."
        case .invalidSource(let sourceID): return "The source \(sourceID) is invalid."
        case .exportFailed: return "The saved research could not be exported."
        }
    }
}

struct ResearchBatchSaveRequest: Sendable {
    var title: String
    var scope: String
    var subreddit: String
    var feedMode: String
    var sortMode: String
    var timeRange: String
    var sources: [ResearchSourceInput]
    var coverage: ResearchCoverageInput
    var perPostSummaries: [(title: String, summary: String, permalink: String)]
    var overallSummary: String?
    var generationReceipt: ResearchGenerationReceiptInput?
}

struct ResearchRunDetail {
    let item: ResearchItemRecord
    let run: ResearchRunRecord
    let sources: [ResearchSourceRecord]
    let artifacts: [ResearchArtifactRecord]
    let conversations: [ResearchConversationRecord]
    let offlineAssets: [ResearchOfflineAssetRecord]
}

struct ResearchExportEnvelope: Codable {
    struct Item: Codable {
        let id: UUID
        let title: String
        let scope: String
        let subreddit: String
        let createdAt: Date
        let updatedAt: Date
        let pinnedAt: Date?
        let tags: [String]
    }

    struct Run: Codable {
        let id: UUID
        let revision: Int
        let state: String
        let capturedAt: Date
        let completedAt: Date?
        let feedMode: String
        let sortMode: String
        let timeRange: String
        let sourceDigest: String
        let coverage: ResearchCoverageInput
        let appBuild: String
    }

    struct Source: Codable {
        let sourceID: String
        let kind: String
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
        let contentDigest: String
    }

    struct Artifact: Codable {
        let id: UUID
        let kind: String
        let title: String
        let body: String
        let format: String
        let createdAt: Date
        let generationReceipt: ResearchGenerationReceiptInput?
        let conflicts: [String]
        let missingData: [String]
        let legacyUncited: Bool
        let claims: [Claim]
    }

    struct Claim: Codable {
        let id: UUID
        let order: Int
        let text: String
        let claimType: String
        let confidence: String
        let conflictingSourceIDs: [String]
        let missingDataNote: String?
        let citations: [Citation]
    }

    struct Citation: Codable {
        let sourceID: String
        let supportingQuote: String?
        let validated: Bool
        let validationMessage: String?
    }

    struct Conversation: Codable {
        let id: UUID
        let title: String
        let sourceDigest: String
        let createdAt: Date
        let updatedAt: Date
        let turns: [Turn]
    }

    struct Turn: Codable {
        let id: UUID
        let sequence: Int
        let role: String
        let text: String
        let artifactID: UUID?
        let generationReceipt: ResearchGenerationReceiptInput?
        let createdAt: Date
    }

    let schemaVersion: Int
    let exportedAt: Date
    let item: Item
    let run: Run
    let sources: [Source]
    let artifacts: [Artifact]
    let conversations: [Conversation]
}

@MainActor
final class ResearchLibraryStore: ObservableObject {
    static let shared = ResearchLibraryStore()

    @Published private(set) var items: [ResearchItemRecord] = []
    @Published private(set) var isReady = false
    @Published private(set) var storageURL: URL?
    @Published var lastError: String?

    let modelContainer: ModelContainer
    private let context: ModelContext
    private var activeSearchText = ""
    private var activeTags = Set<String>()

    init(inMemory: Bool = false) {
        var resolvedStorageURL: URL?
        do {
            let schema = Schema(versionedSchema: ResearchSchemaV1.self)
            let configuration: ModelConfiguration

            if inMemory {
                configuration = ModelConfiguration(
                    "ResearchLibraryTests",
                    schema: schema,
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )
            } else {
                let directory = try Self.researchDirectory()
                let storeURL = directory.appendingPathComponent("ResearchLibrary.store")
                configuration = ModelConfiguration(
                    "ResearchLibrary",
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )
                resolvedStorageURL = directory
            }

            modelContainer = try ModelContainer(
                for: schema,
                migrationPlan: ResearchMigrationPlan.self,
                configurations: [configuration]
            )
            context = ModelContext(modelContainer)
            context.autosaveEnabled = true
            storageURL = resolvedStorageURL
            isReady = true
            reload()
        } catch {
            let schema = Schema(versionedSchema: ResearchSchemaV1.self)
            let fallback = ModelConfiguration(
                "ResearchLibraryFallback",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [fallback])
                context = ModelContext(modelContainer)
                lastError = ResearchStoreError.unavailable(error.localizedDescription).localizedDescription
            } catch {
                fatalError("Unable to create Research Library model container: \(error)")
            }
        }
    }

    nonisolated static func researchDirectory() throws -> URL {
        let fm = FileManager.default
        let applicationSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("ResearchLibrary-v1", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func reload(searchText: String = "", tags: Set<String> = []) {
        activeSearchText = searchText
        activeTags = tags
        do {
            let descriptor = FetchDescriptor<ResearchItemRecord>()
            let allItems = try context.fetch(descriptor)
            let normalizedQuery = Self.normalized(searchText)
            items = allItems
                .filter { item in
                    let matchesQuery = normalizedQuery.isEmpty
                        || item.normalizedSearchText.contains(normalizedQuery)
                        || Self.normalized(item.title).contains(normalizedQuery)
                    let itemTags = Set(item.tags.map { Self.normalized($0) })
                    let normalizedTags = Set(tags.map { Self.normalized($0) })
                    let matchesTags = normalizedTags.isEmpty || normalizedTags.isSubset(of: itemTags)
                    return matchesQuery && matchesTags
                }
                .sorted { lhs, rhs in
                    switch (lhs.pinnedAt, rhs.pinnedAt) {
                    case let (left?, right?): return left > right
                    case (.some, .none): return true
                    case (.none, .some): return false
                    case (.none, .none): return lhs.updatedAt > rhs.updatedAt
                    }
                }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            items = []
        }
    }

    @discardableResult
    func saveBatch(_ request: ResearchBatchSaveRequest) throws -> ResearchRunRecord {
        let now = Date()
        let searchIndex = Self.searchIndex(
            title: request.title,
            subreddit: request.subreddit,
            sources: request.sources,
            summaries: request.perPostSummaries.map { $0.summary },
            overallSummary: request.overallSummary
        )
        let item: ResearchItemRecord
        if let existing = try self.item(scope: request.scope, subreddit: request.subreddit) {
            item = existing
            item.title = request.title
            item.updatedAt = now
            item.normalizedSearchText = Self.normalized(item.normalizedSearchText + " " + searchIndex)
        } else {
            item = ResearchItemRecord(
                title: request.title,
                scope: request.scope,
                subreddit: request.subreddit,
                createdAt: now,
                updatedAt: now,
                normalizedSearchText: searchIndex
            )
            context.insert(item)
        }

        let sourceDigest = ResearchDigest.sha256Hex(
            request.sources
                .sorted { $0.sourceOrder < $1.sourceOrder }
                .map(\.contentDigest)
                .joined(separator: "|")
        )
        let hasIncompleteCoverage = !request.coverage.failureMessages.isEmpty
            || request.coverage.postsAnalyzed < request.coverage.postsRequested
            || request.coverage.commentsOmitted > 0
            || request.coverage.commentsFetched < request.coverage.commentsReported
        let state: ResearchRunState = hasIncompleteCoverage ? .partial : .ready
        let run = ResearchRunRecord(
            itemID: item.id,
            revision: (try runs(itemID: item.id).map(\.revision).max() ?? 0) + 1,
            state: state,
            capturedAt: now,
            completedAt: now,
            feedMode: request.feedMode,
            subreddit: request.subreddit,
            sortMode: request.sortMode,
            timeRange: request.timeRange,
            sourceDigest: sourceDigest,
            coverage: request.coverage,
            appBuild: request.generationReceipt?.appBuild ?? Self.appBuild
        )
        context.insert(run)

        var seenSourceIDs = Set<String>()
        for source in request.sources.sorted(by: { $0.sourceOrder < $1.sourceOrder }) {
            guard !source.sourceID.isEmpty, seenSourceIDs.insert(source.sourceID).inserted else { continue }
            context.insert(ResearchSourceRecord(runID: run.id, input: source))
        }

        for summary in request.perPostSummaries {
            let artifact = ResearchArtifactRecord(
                runID: run.id,
                kind: .postSummary,
                title: summary.title,
                body: summary.summary,
                generationReceipt: request.generationReceipt,
                coverage: request.coverage,
                legacyUncited: true
            )
            context.insert(artifact)
        }

        if let overallSummary = request.overallSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overallSummary.isEmpty {
            let artifact = ResearchArtifactRecord(
                runID: run.id,
                kind: .overallReport,
                title: "Overall Summary",
                body: overallSummary,
                generationReceipt: request.generationReceipt,
                coverage: request.coverage,
                legacyUncited: true
            )
            context.insert(artifact)
        }

        try context.save()
        reloadCurrentQuery()
        return run
    }

    @discardableResult
    func addArtifact(
        runID: UUID,
        kind: ResearchArtifactKind,
        title: String,
        body: String,
        format: String = "markdown",
        generationReceipt: ResearchGenerationReceiptInput? = nil,
        coverage: ResearchCoverageInput = .empty,
        conflicts: [String] = [],
        missingData: [String] = [],
        claims: [ResearchClaimInput] = [],
        legacyUncited: Bool = false
    ) throws -> ResearchArtifactRecord {
        guard try run(id: runID) != nil else { throw ResearchStoreError.runNotFound }
        let artifact = ResearchArtifactRecord(
            runID: runID,
            kind: kind,
            title: title,
            body: body,
            format: format,
            generationReceipt: generationReceipt,
            coverage: coverage,
            conflicts: conflicts,
            missingData: missingData,
            legacyUncited: legacyUncited
        )
        context.insert(artifact)
        let sourceRecords = try sources(runID: runID).map {
            ResearchSourceInput(
                sourceID: $0.sourceID,
                kind: $0.kind,
                postSourceID: $0.postSourceID,
                parentSourceID: $0.parentSourceID,
                subreddit: $0.subreddit,
                title: $0.title,
                permalink: $0.permalink,
                author: $0.author,
                score: $0.score,
                createdAt: $0.sourceCreatedAt,
                depth: $0.depth,
                rawMarkdown: $0.rawMarkdown,
                mediaURLs: $0.mediaURLs,
                sourceOrder: $0.sourceOrder
            )
        }
        try insertClaims(claims, for: artifact, sourceRecords: sourceRecords)
        try appendSearchText(
            ([title, body] + conflicts + missingData + claims.map(\.text)).joined(separator: " "),
            runID: runID
        )
        try context.save()
        touchItem(for: runID)
        reloadCurrentQuery()
        return artifact
    }

    func setPinned(_ pinned: Bool, itemID: UUID) throws {
        guard let item = try item(id: itemID) else { throw ResearchStoreError.itemNotFound }
        item.pinnedAt = pinned ? Date() : nil
        item.updatedAt = Date()
        try context.save()
        reloadCurrentQuery()
    }

    func setTags(_ tags: [String], itemID: UUID) throws {
        guard let item = try item(id: itemID) else { throw ResearchStoreError.itemNotFound }
        let normalizedTags = Array(
            Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        ).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        item.tags = normalizedTags
        item.updatedAt = Date()
        item.normalizedSearchText += " " + normalizedTags.map(Self.normalized).joined(separator: " ")
        try context.save()
        reloadCurrentQuery()
    }

    func markOpened(itemID: UUID) throws {
        guard let item = try item(id: itemID) else { throw ResearchStoreError.itemNotFound }
        item.lastOpenedAt = Date()
        try context.save()
        reloadCurrentQuery()
    }

    func deleteItem(id: UUID) throws {
        let runRecords = try runs(itemID: id)
        for run in runRecords {
            try deleteRun(id: run.id)
        }
        if let item = try item(id: id) {
            context.delete(item)
        }
        try context.save()
        reloadCurrentQuery()
    }

    func detail(runID: UUID) throws -> ResearchRunDetail {
        guard let run = try run(id: runID),
              let item = try item(id: run.itemID) else {
            throw ResearchStoreError.runNotFound
        }
        return ResearchRunDetail(
            item: item,
            run: run,
            sources: try sources(runID: runID),
            artifacts: try artifacts(runID: runID),
            conversations: try conversations(runID: runID),
            offlineAssets: try offlineAssets(runID: runID)
        )
    }

    func item(id: UUID) throws -> ResearchItemRecord? {
        var descriptor = FetchDescriptor<ResearchItemRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func item(scope: String, subreddit: String) throws -> ResearchItemRecord? {
        let normalizedScope = Self.normalized(scope)
        let normalizedSubreddit = Self.normalized(subreddit)
        return try context.fetch(FetchDescriptor<ResearchItemRecord>()).first {
            Self.normalized($0.scope) == normalizedScope
                && Self.normalized($0.subreddit) == normalizedSubreddit
        }
    }

    func latestRun(itemID: UUID) throws -> ResearchRunRecord? {
        try runs(itemID: itemID).sorted { $0.revision > $1.revision }.first
    }

    func runs(itemID: UUID) throws -> [ResearchRunRecord] {
        let descriptor = FetchDescriptor<ResearchRunRecord>(
            predicate: #Predicate { $0.itemID == itemID },
            sortBy: [SortDescriptor(\.revision, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func run(id: UUID) throws -> ResearchRunRecord? {
        var descriptor = FetchDescriptor<ResearchRunRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func sources(runID: UUID) throws -> [ResearchSourceRecord] {
        let descriptor = FetchDescriptor<ResearchSourceRecord>(
            predicate: #Predicate { $0.runID == runID },
            sortBy: [SortDescriptor(\.sourceOrder)]
        )
        return try context.fetch(descriptor)
    }

    func source(runID: UUID, sourceID: String) throws -> ResearchSourceRecord? {
        var descriptor = FetchDescriptor<ResearchSourceRecord>(
            predicate: #Predicate { $0.runID == runID && $0.sourceID == sourceID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func artifacts(runID: UUID) throws -> [ResearchArtifactRecord] {
        let descriptor = FetchDescriptor<ResearchArtifactRecord>(
            predicate: #Predicate { $0.runID == runID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor)
    }

    func claims(artifactID: UUID) throws -> [ResearchClaimRecord] {
        let descriptor = FetchDescriptor<ResearchClaimRecord>(
            predicate: #Predicate { $0.artifactID == artifactID },
            sortBy: [SortDescriptor(\.claimOrder)]
        )
        return try context.fetch(descriptor)
    }

    func citations(claimID: UUID) throws -> [ResearchCitationRecord] {
        let descriptor = FetchDescriptor<ResearchCitationRecord>(
            predicate: #Predicate { $0.claimID == claimID }
        )
        return try context.fetch(descriptor)
    }

    func conversations(runID: UUID) throws -> [ResearchConversationRecord] {
        let descriptor = FetchDescriptor<ResearchConversationRecord>(
            predicate: #Predicate { $0.runID == runID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func conversation(id: UUID) throws -> ResearchConversationRecord? {
        var descriptor = FetchDescriptor<ResearchConversationRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func turns(conversationID: UUID) throws -> [ResearchConversationTurnRecord] {
        let descriptor = FetchDescriptor<ResearchConversationTurnRecord>(
            predicate: #Predicate { $0.conversationID == conversationID },
            sortBy: [SortDescriptor(\.sequence)]
        )
        return try context.fetch(descriptor)
    }

    @discardableResult
    func createConversation(runID: UUID, title: String) throws -> ResearchConversationRecord {
        guard let run = try run(id: runID) else { throw ResearchStoreError.runNotFound }
        let conversation = ResearchConversationRecord(
            runID: runID,
            sourceDigest: run.sourceDigest,
            title: title
        )
        context.insert(conversation)
        try appendSearchText(title, runID: runID)
        try context.save()
        return conversation
    }

    @discardableResult
    func appendTurn(
        conversationID: UUID,
        role: ResearchConversationRole,
        text: String,
        artifactID: UUID? = nil,
        generationReceipt: ResearchGenerationReceiptInput? = nil
    ) throws -> ResearchConversationTurnRecord {
        guard let conversation = try conversation(id: conversationID) else {
            throw ResearchStoreError.runNotFound
        }
        let sequence = (try turns(conversationID: conversationID).last?.sequence ?? -1) + 1
        let turn = ResearchConversationTurnRecord(
            conversationID: conversationID,
            sequence: sequence,
            role: role,
            text: text,
            artifactID: artifactID,
            generationReceipt: generationReceipt
        )
        context.insert(turn)
        conversation.updatedAt = Date()
        try appendSearchText(text, runID: conversation.runID)
        try context.save()
        return turn
    }

    func offlineAssets(runID: UUID) throws -> [ResearchOfflineAssetRecord] {
        let descriptor = FetchDescriptor<ResearchOfflineAssetRecord>(
            predicate: #Predicate { $0.runID == runID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor)
    }

    func insertOfflineAsset(_ asset: ResearchOfflineAssetRecord) throws {
        context.insert(asset)
        try context.save()
        reloadCurrentQuery()
    }

    func deleteOfflineAssets(runID: UUID) throws -> [String] {
        let assets = try offlineAssets(runID: runID)
        let relativePaths = assets.map(\.relativePath)
        for asset in assets { context.delete(asset) }
        try context.save()
        reloadCurrentQuery()
        return relativePaths
    }

    func draft(kind: ResearchDraftKind, destinationKey: String) throws -> ResearchDraftRecord? {
        let rawKind = kind.rawValue
        var descriptor = FetchDescriptor<ResearchDraftRecord>(
            predicate: #Predicate {
                $0.kindRawValue == rawKind && $0.destinationKey == destinationKey
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @discardableResult
    func saveDraft(
        kind: ResearchDraftKind,
        destinationKey: String,
        subreddit: String = "",
        parentSourceID: String? = nil,
        permalink: String? = nil,
        title: String = "",
        body: String,
        linkURL: String = "",
        flairID: String? = nil,
        flairText: String? = nil,
        attachmentPaths: [String] = []
    ) throws -> ResearchDraftRecord {
        if let existing = try draft(kind: kind, destinationKey: destinationKey) {
            existing.subreddit = subreddit
            existing.parentSourceID = parentSourceID
            existing.permalink = permalink
            existing.title = title
            existing.body = body
            existing.linkURL = linkURL
            existing.flairID = flairID
            existing.flairText = flairText
            existing.attachmentPaths = attachmentPaths
            existing.updatedAt = Date()
            try context.save()
            return existing
        }

        let draft = ResearchDraftRecord(
            kind: kind,
            destinationKey: destinationKey,
            subreddit: subreddit,
            parentSourceID: parentSourceID,
            permalink: permalink,
            title: title,
            body: body,
            linkURL: linkURL,
            flairID: flairID,
            flairText: flairText,
            attachmentPaths: attachmentPaths
        )
        context.insert(draft)
        try context.save()
        return draft
    }

    func deleteDraft(kind: ResearchDraftKind, destinationKey: String) throws {
        if let draft = try draft(kind: kind, destinationKey: destinationKey) {
            context.delete(draft)
            try context.save()
        }
    }

    func exportEnvelope(runID: UUID) throws -> ResearchExportEnvelope {
        let detail = try detail(runID: runID)
        let claimRecords = try detail.artifacts.reduce(into: [UUID: [ResearchClaimRecord]]()) { result, artifact in
            result[artifact.id] = try claims(artifactID: artifact.id)
        }
        let citationRecords = try claimRecords.values.flatMap { $0 }.reduce(into: [UUID: [ResearchCitationRecord]]()) { result, claim in
            result[claim.id] = try citations(claimID: claim.id)
        }
        let conversationExports = try detail.conversations.map { conversation in
            ResearchExportEnvelope.Conversation(
                id: conversation.id,
                title: conversation.title,
                sourceDigest: conversation.sourceDigest,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt,
                turns: try turns(conversationID: conversation.id).map { turn in
                    ResearchExportEnvelope.Turn(
                        id: turn.id,
                        sequence: turn.sequence,
                        role: turn.roleRawValue,
                        text: turn.text,
                        artifactID: turn.artifactID,
                        generationReceipt: turn.generationReceipt,
                        createdAt: turn.createdAt
                    )
                }
            )
        }

        return ResearchExportEnvelope(
            schemaVersion: 1,
            exportedAt: Date(),
            item: .init(
                id: detail.item.id,
                title: detail.item.title,
                scope: detail.item.scope,
                subreddit: detail.item.subreddit,
                createdAt: detail.item.createdAt,
                updatedAt: detail.item.updatedAt,
                pinnedAt: detail.item.pinnedAt,
                tags: detail.item.tags
            ),
            run: .init(
                id: detail.run.id,
                revision: detail.run.revision,
                state: detail.run.stateRawValue,
                capturedAt: detail.run.capturedAt,
                completedAt: detail.run.completedAt,
                feedMode: detail.run.feedMode,
                sortMode: detail.run.sortMode,
                timeRange: detail.run.timeRange,
                sourceDigest: detail.run.sourceDigest,
                coverage: detail.run.coverage,
                appBuild: detail.run.appBuild
            ),
            sources: detail.sources.map {
                .init(
                    sourceID: $0.sourceID,
                    kind: $0.kindRawValue,
                    postSourceID: $0.postSourceID,
                    parentSourceID: $0.parentSourceID,
                    subreddit: $0.subreddit,
                    title: $0.title,
                    permalink: $0.permalink,
                    author: $0.author,
                    score: $0.score,
                    createdAt: $0.sourceCreatedAt,
                    depth: $0.depth,
                    rawMarkdown: $0.rawMarkdown,
                    mediaURLs: $0.mediaURLs,
                    contentDigest: $0.contentDigest
                )
            },
            artifacts: detail.artifacts.map { artifact in
                .init(
                    id: artifact.id,
                    kind: artifact.kindRawValue,
                    title: artifact.title,
                    body: artifact.body,
                    format: artifact.format,
                    createdAt: artifact.createdAt,
                    generationReceipt: artifact.generationReceipt,
                    conflicts: artifact.conflicts,
                    missingData: artifact.missingData,
                    legacyUncited: artifact.legacyUncited,
                    claims: (claimRecords[artifact.id] ?? []).map { claim in
                        .init(
                            id: claim.id,
                            order: claim.claimOrder,
                            text: claim.text,
                            claimType: claim.claimType,
                            confidence: claim.confidenceRawValue,
                            conflictingSourceIDs: claim.conflictingSourceIDs,
                            missingDataNote: claim.missingDataNote,
                            citations: (citationRecords[claim.id] ?? []).map {
                                .init(
                                    sourceID: $0.sourceID,
                                    supportingQuote: $0.supportingQuote,
                                    validated: $0.validated,
                                    validationMessage: $0.validationMessage
                                )
                            }
                        )
                    }
                )
            },
            conversations: conversationExports
        )
    }

    func exportJSON(runID: UUID) throws -> Data {
        let envelope = try exportEnvelope(runID: runID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    func exportMarkdown(runID: UUID) throws -> String {
        let detail = try detail(runID: runID)
        var markdown = "# \(detail.item.title)\n\n"
        markdown += "- Scope: \(detail.item.scope)\n"
        markdown += "- Captured: \(detail.run.capturedAt.formatted(date: .abbreviated, time: .shortened))\n"
        markdown += "- Revision: \(detail.run.revision)\n"
        markdown += "- Source digest: `\(detail.run.sourceDigest)`\n"
        markdown += "- Posts analyzed: \(detail.run.coverage.postsAnalyzed) of \(detail.run.coverage.postsRequested)\n"
        markdown += "- Comments analyzed: \(detail.run.coverage.commentsAnalyzed) of \(detail.run.coverage.commentsFetched) fetched\n\n"

        for artifact in detail.artifacts {
            markdown += "## \(artifact.title)\n\n\(artifact.body)\n\n"
            if artifact.legacyUncited {
                markdown += "> Legacy output — claim-level citations were unavailable when this artifact was created.\n\n"
            }
            let claimRecords = try claims(artifactID: artifact.id)
            for claim in claimRecords {
                let citationRecords = try citations(claimID: claim.id).filter(\.validated)
                guard !citationRecords.isEmpty else { continue }
                let refs = citationRecords.map { "[\($0.sourceID)]" }.joined(separator: " ")
                markdown += "- \(claim.text) \(refs)\n"
            }
            markdown += "\n"
        }

        if !detail.conversations.isEmpty {
            markdown += "## Conversations\n\n"
            for conversation in detail.conversations {
                markdown += "### \(conversation.title)\n\n"
                markdown += "- Source digest: `\(conversation.sourceDigest)`\n\n"
                for turn in try turns(conversationID: conversation.id) {
                    markdown += "**\(turn.role.rawValue.capitalized):** \(turn.text)\n\n"
                }
            }
        }

        markdown += "## Sources\n\n"
        for source in detail.sources {
            let display = source.title ?? source.author ?? source.sourceID
            let url = source.permalink.hasPrefix("http")
                ? source.permalink
                : "https://www.reddit.com\(source.permalink)"
            markdown += "- [\(source.sourceID)] [\(display)](\(url))\n"
        }
        return markdown
    }

    private func insertClaims(
        _ claims: [ResearchClaimInput],
        for artifact: ResearchArtifactRecord,
        sourceRecords: [ResearchSourceInput]
    ) throws {
        let sourceMap = Dictionary(uniqueKeysWithValues: sourceRecords.map { ($0.sourceID, $0) })
        for input in claims.sorted(by: { $0.order < $1.order }) {
            let claim = ResearchClaimRecord(artifactID: artifact.id, input: input)
            context.insert(claim)
            for citation in input.citations {
                guard let source = sourceMap[citation.sourceID] else {
                    context.insert(
                        ResearchCitationRecord(
                            id: citation.id,
                            claimID: claim.id,
                            sourceID: citation.sourceID,
                            supportingQuote: citation.supportingQuote,
                            sourceDigest: "",
                            validated: false,
                            validationMessage: "Source was not included in this run."
                        )
                    )
                    continue
                }
                let quoteMatches = citation.supportingQuote.map {
                    Self.normalized([source.title ?? "", source.rawMarkdown].joined(separator: "\n"))
                        .contains(Self.normalized($0))
                } ?? true
                context.insert(
                    ResearchCitationRecord(
                        id: citation.id,
                        claimID: claim.id,
                        sourceID: citation.sourceID,
                        supportingQuote: citation.supportingQuote,
                        sourceDigest: source.contentDigest,
                        validated: quoteMatches,
                        validationMessage: quoteMatches ? nil : "Supporting excerpt did not match the saved source."
                    )
                )
            }
        }
    }

    private func touchItem(for runID: UUID) {
        guard let run = try? run(id: runID),
              let item = try? item(id: run.itemID) else { return }
        item.updatedAt = Date()
        try? context.save()
    }

    private func appendSearchText(_ text: String, runID: UUID) throws {
        guard let run = try run(id: runID),
              let item = try item(id: run.itemID) else { throw ResearchStoreError.runNotFound }
        item.normalizedSearchText = Self.normalized(item.normalizedSearchText + " " + text)
        item.updatedAt = Date()
    }

    private func reloadCurrentQuery() {
        reload(searchText: activeSearchText, tags: activeTags)
    }

    private func deleteRun(id: UUID) throws {
        if let directory = try? Self.researchDirectory()
            .appendingPathComponent("Assets/\(id.uuidString)", isDirectory: true),
           FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        for artifact in try artifacts(runID: id) {
            for claim in try claims(artifactID: artifact.id) {
                for citation in try citations(claimID: claim.id) { context.delete(citation) }
                context.delete(claim)
            }
            context.delete(artifact)
        }
        for conversation in try conversations(runID: id) {
            for turn in try turns(conversationID: conversation.id) { context.delete(turn) }
            context.delete(conversation)
        }
        for source in try sources(runID: id) { context.delete(source) }
        for asset in try offlineAssets(runID: id) { context.delete(asset) }
        if let run = try run(id: id) { context.delete(run) }
    }

    private static func searchIndex(
        title: String,
        subreddit: String,
        sources: [ResearchSourceInput],
        summaries: [String],
        overallSummary: String?
    ) -> String {
        let content = [title, subreddit, overallSummary ?? ""]
            + summaries
            + sources.flatMap { [$0.title ?? "", $0.author ?? "", $0.rawMarkdown] }
        return normalized(content.joined(separator: " "))
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    nonisolated static var appBuild: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }
}
