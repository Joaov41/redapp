import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

struct ResearchOfflinePackResult: Sendable {
    let downloadedAssets: Int
    let failedAssets: Int
    let byteCount: Int64

    var isComplete: Bool { failedAssets == 0 }
}

enum ResearchOfflineError: LocalizedError {
    case invalidResponse(URL)
    case assetTooLarge(URL, maximumBytes: Int64)
    case packSizeLimitReached(maximumBytes: Int64)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let url): return "Could not download \(url.absoluteString)."
        case .assetTooLarge(let url, let maximumBytes):
            return "\(url.lastPathComponent.isEmpty ? "A media file" : url.lastPathComponent) exceeds the \(ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)) offline limit."
        case .packSizeLimitReached(let maximumBytes):
            return "The offline pack reached its \(ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)) media limit."
        case .unavailable: return "The offline research pack is unavailable."
        }
    }
}

private struct ResearchOfflineAssetInput: Sendable {
    let runID: UUID
    let artifactID: UUID?
    let kind: ResearchOfflineAssetKind
    let remoteURL: String?
    let relativePath: String
    let mimeType: String
    let checksum: String
    let byteCount: Int64
    let state: ResearchOfflineAssetState
    let sourceTextDigest: String?
    let ttsEngine: String?
    let ttsVoice: String?
    let ttsSpeed: Double?
    let duration: Double?
    let failureMessage: String?
}

private struct ResearchOfflineMediaDownload: Sendable {
    let response: HTTPURLResponse
    let byteCount: Int64
    let checksum: String
}

actor ResearchOfflinePackManager {
    static let shared = ResearchOfflinePackManager()

    private let fileManager = FileManager.default
    private let maximumMediaAssetBytes: Int64 = 25 * 1_024 * 1_024
    private let maximumPackBytes: Int64 = 250 * 1_024 * 1_024

    func makeOffline(runID: UUID) async throws -> ResearchOfflinePackResult {
        let snapshot = try await MainActor.run {
            let store = ResearchLibraryStore.shared
            return (
                detail: try store.detail(runID: runID),
                json: try store.exportJSON(runID: runID),
                markdown: try store.exportMarkdown(runID: runID)
            )
        }

        let root = try assetsRoot()
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let final = root.appendingPathComponent(runID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var pendingRecords: [ResearchOfflineAssetInput] = []
            var failures = 0
            var totalBytes: Int64 = 0

            let existingSpeech = snapshot.detail.offlineAssets.filter {
                $0.kind == .speech && $0.state == .ready
            }
            if !existingSpeech.isEmpty {
                let speechDirectory = staging.appendingPathComponent("speech", isDirectory: true)
                try fileManager.createDirectory(at: speechDirectory, withIntermediateDirectories: true)
                let researchDirectory = try ResearchLibraryStore.researchDirectory()
                for asset in existingSpeech {
                    let sourceURL = researchDirectory.appendingPathComponent(asset.relativePath)
                    guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                    let destination = speechDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                    try fileManager.copyItem(at: sourceURL, to: destination)
                    totalBytes += asset.byteCount
                    pendingRecords.append(
                        ResearchOfflineAssetInput(
                            runID: asset.runID,
                            artifactID: asset.artifactID,
                            kind: asset.kind,
                            remoteURL: asset.remoteURL,
                            relativePath: relativePath(
                                runID: runID,
                                filename: "speech/\(sourceURL.lastPathComponent)"
                            ),
                            mimeType: asset.mimeType,
                            checksum: asset.checksum,
                            byteCount: asset.byteCount,
                            state: .ready,
                            sourceTextDigest: asset.sourceTextDigest,
                            ttsEngine: asset.ttsEngine,
                            ttsVoice: asset.ttsVoice,
                            ttsSpeed: asset.ttsSpeed,
                            duration: asset.duration,
                            failureMessage: nil
                        )
                    )
                }
            }

            let archiveURL = staging.appendingPathComponent("research.json")
            try snapshot.json.write(to: archiveURL, options: .atomic)
            totalBytes += Int64(snapshot.json.count)
            pendingRecords.append(
                record(
                    runID: runID,
                    kind: .report,
                    relativePath: relativePath(runID: runID, filename: "research.json"),
                    mimeType: "application/json",
                    data: snapshot.json
                )
            )

            let markdownData = Data(snapshot.markdown.utf8)
            let markdownURL = staging.appendingPathComponent("research.md")
            try markdownData.write(to: markdownURL, options: .atomic)
            totalBytes += Int64(markdownData.count)
            pendingRecords.append(
                record(
                    runID: runID,
                    kind: .report,
                    relativePath: relativePath(runID: runID, filename: "research.md"),
                    mimeType: "text/markdown",
                    data: markdownData
                )
            )

            let mediaURLs = Array(
                Set(snapshot.detail.sources.flatMap(\.mediaURLs))
            ).compactMap(URL.init(string:))

            let mediaDirectory = staging.appendingPathComponent("media", isDirectory: true)
            try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            for (index, remoteURL) in mediaURLs.enumerated() {
                let temporaryURL = mediaDirectory.appendingPathComponent(".download-\(UUID().uuidString)")
                do {
                    let remainingPackBytes = maximumPackBytes - totalBytes
                    guard remainingPackBytes > 0 else {
                        throw ResearchOfflineError.packSizeLimitReached(maximumBytes: maximumPackBytes)
                    }
                    let downloadLimit = min(maximumMediaAssetBytes, remainingPackBytes)
                    let download = try await downloadMedia(
                        from: remoteURL,
                        to: temporaryURL,
                        maximumBytes: downloadLimit
                    )
                    let mimeType = download.response.mimeType ?? "application/octet-stream"
                    let fileExtension = Self.fileExtension(mimeType: mimeType, remoteURL: remoteURL)
                    let digestPrefix = String(ResearchDigest.sha256Hex(remoteURL.absoluteString).prefix(12))
                    let filename = "\(String(format: "%04d", index))-\(digestPrefix).\(fileExtension)"
                    let destination = mediaDirectory.appendingPathComponent(filename)
                    try fileManager.moveItem(at: temporaryURL, to: destination)
                    totalBytes += download.byteCount
                    pendingRecords.append(
                        ResearchOfflineAssetInput(
                            runID: runID,
                            artifactID: nil,
                            kind: .thumbnail,
                            remoteURL: remoteURL.absoluteString,
                            relativePath: relativePath(runID: runID, filename: "media/\(filename)"),
                            mimeType: mimeType,
                            checksum: download.checksum,
                            byteCount: download.byteCount,
                            state: .ready,
                            sourceTextDigest: nil,
                            ttsEngine: nil,
                            ttsVoice: nil,
                            ttsSpeed: nil,
                            duration: nil,
                            failureMessage: nil
                        )
                    )
                } catch {
                    try? fileManager.removeItem(at: temporaryURL)
                    failures += 1
                    pendingRecords.append(
                        ResearchOfflineAssetInput(
                            runID: runID,
                            artifactID: nil,
                            kind: .thumbnail,
                            remoteURL: remoteURL.absoluteString,
                            relativePath: relativePath(
                                runID: runID,
                                filename: "media/unavailable-\(String(format: "%04d", index))"
                            ),
                            mimeType: "application/octet-stream",
                            checksum: "",
                            byteCount: 0,
                            state: .failed,
                            sourceTextDigest: nil,
                            ttsEngine: nil,
                            ttsVoice: nil,
                            ttsSpeed: nil,
                            duration: nil,
                            failureMessage: error.localizedDescription
                        )
                    )
                }
            }

            if fileManager.fileExists(atPath: final.path) {
                try fileManager.removeItem(at: final)
            }
            try fileManager.moveItem(at: staging, to: final)

            let recordsToPersist = pendingRecords
            try await MainActor.run {
                let store = ResearchLibraryStore.shared
                _ = try store.deleteOfflineAssets(runID: runID)
                for input in recordsToPersist {
                    let record = ResearchOfflineAssetRecord(
                        runID: input.runID,
                        artifactID: input.artifactID,
                        kind: input.kind,
                        remoteURL: input.remoteURL,
                        relativePath: input.relativePath,
                        mimeType: input.mimeType,
                        checksum: input.checksum,
                        byteCount: input.byteCount,
                        state: input.state,
                        sourceTextDigest: input.sourceTextDigest,
                        ttsEngine: input.ttsEngine,
                        ttsVoice: input.ttsVoice,
                        ttsSpeed: input.ttsSpeed,
                        duration: input.duration,
                        failureMessage: input.failureMessage
                    )
                    try store.insertOfflineAsset(record)
                }
            }

            return ResearchOfflinePackResult(
                downloadedAssets: pendingRecords.filter { $0.state == .ready }.count,
                failedAssets: failures,
                byteCount: totalBytes
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func downloadMedia(
        from remoteURL: URL,
        to destinationURL: URL,
        maximumBytes: Int64
    ) async throws -> ResearchOfflineMediaDownload {
        guard let scheme = remoteURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw ResearchOfflineError.invalidResponse(remoteURL)
        }

        let (bytes, response) = try await URLSession.shared.bytes(from: remoteURL)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw ResearchOfflineError.invalidResponse(remoteURL)
        }
        if response.expectedContentLength > maximumBytes {
            throw ResearchOfflineError.assetTooLarge(remoteURL, maximumBytes: maximumBytes)
        }

        guard fileManager.createFile(atPath: destinationURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destinationURL) else {
            throw ResearchOfflineError.unavailable
        }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        var byteCount: Int64 = 0
#if canImport(CryptoKit)
        var hasher = SHA256()
#endif
        do {
            for try await byte in bytes {
                guard byteCount < maximumBytes else {
                    throw ResearchOfflineError.assetTooLarge(remoteURL, maximumBytes: maximumBytes)
                }
                buffer.append(byte)
                byteCount += 1
                if buffer.count >= 64 * 1_024 {
                    try handle.write(contentsOf: buffer)
#if canImport(CryptoKit)
                    hasher.update(data: buffer)
#endif
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
#if canImport(CryptoKit)
                hasher.update(data: buffer)
#endif
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
        guard byteCount > 0 else {
            try? fileManager.removeItem(at: destinationURL)
            throw ResearchOfflineError.invalidResponse(remoteURL)
        }
#if canImport(CryptoKit)
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
#else
        let checksum = ResearchDigest.sha256Hex(
            try Data(contentsOf: destinationURL, options: .mappedIfSafe)
        )
#endif
        return ResearchOfflineMediaDownload(
            response: http,
            byteCount: byteCount,
            checksum: checksum
        )
    }

    func saveSpeech(
        _ data: Data,
        runID: UUID,
        artifactID: UUID?,
        voice: String,
        speed: Double,
        duration: Double? = nil
    ) async throws -> UUID {
        let root = try assetsRoot()
        let runDirectory = root.appendingPathComponent(runID.uuidString, isDirectory: true)
        let speechDirectory = runDirectory.appendingPathComponent("speech", isDirectory: true)
        try fileManager.createDirectory(at: speechDirectory, withIntermediateDirectories: true)
        let filename = "speech-\(UUID().uuidString).wav"
        let url = speechDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        let savedRelativePath = relativePath(runID: runID, filename: "speech/\(filename)")
        return try await MainActor.run {
            let record = ResearchOfflineAssetRecord(
                runID: runID,
                artifactID: artifactID,
                kind: .speech,
                relativePath: savedRelativePath,
                mimeType: "audio/wav",
                checksum: ResearchDigest.sha256Hex(data),
                byteCount: Int64(data.count),
                state: .ready,
                sourceTextDigest: nil,
                ttsEngine: "MLX",
                ttsVoice: voice,
                ttsSpeed: speed,
                duration: duration
            )
            try ResearchLibraryStore.shared.insertOfflineAsset(record)
            return record.id
        }
    }

    func deletePack(runID: UUID) async throws {
        let directory = try assetsRoot().appendingPathComponent(runID.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try await MainActor.run {
            _ = try ResearchLibraryStore.shared.deleteOfflineAssets(runID: runID)
        }
    }

    func localURL(relativePath: String) throws -> URL {
        let base = try ResearchLibraryStore.researchDirectory()
        let url = base.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: url.path) else { throw ResearchOfflineError.unavailable }
        return url
    }

    private func assetsRoot() throws -> URL {
        let directory = try ResearchLibraryStore.researchDirectory()
            .appendingPathComponent("Assets", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func relativePath(runID: UUID, filename: String) -> String {
        "Assets/\(runID.uuidString)/\(filename)"
    }

    private func record(
        runID: UUID,
        kind: ResearchOfflineAssetKind,
        remoteURL: String? = nil,
        relativePath: String,
        mimeType: String,
        data: Data
    ) -> ResearchOfflineAssetInput {
        ResearchOfflineAssetInput(
            runID: runID,
            artifactID: nil,
            kind: kind,
            remoteURL: remoteURL,
            relativePath: relativePath,
            mimeType: mimeType,
            checksum: ResearchDigest.sha256Hex(data),
            byteCount: Int64(data.count),
            state: .ready,
            sourceTextDigest: nil,
            ttsEngine: nil,
            ttsVoice: nil,
            ttsSpeed: nil,
            duration: nil,
            failureMessage: nil
        )
    }

    private static func fileExtension(mimeType: String, remoteURL: URL) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default:
            let ext = remoteURL.pathExtension.lowercased()
            return ext.isEmpty || ext.count > 5 ? "bin" : ext
        }
    }
}
