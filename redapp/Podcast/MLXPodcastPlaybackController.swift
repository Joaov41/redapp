#if os(iOS)
import AVFoundation
import Combine
import Foundation
import UIKit

final class PodcastApplicationActivityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(isActive: Bool) {
        active = isActive
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func setActive(_ isActive: Bool) {
        lock.lock()
        active = isActive
        let continuations = isActive ? waiters : []
        if isActive {
            waiters.removeAll(keepingCapacity: false)
        }
        lock.unlock()

        continuations.forEach { $0.resume() }
    }

    func waitUntilActive() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if active {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class PodcastMLXSynthesisActivity: @unchecked Sendable {
    private let condition = NSCondition()
    private var inFlightCount = 0

    func begin() {
        condition.lock()
        inFlightCount += 1
        condition.unlock()
    }

    func end() {
        condition.lock()
        inFlightCount = max(0, inFlightCount - 1)
        if inFlightCount == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    func waitUntilIdle() {
        condition.lock()
        while inFlightCount > 0 {
            condition.wait()
        }
        condition.unlock()
    }
}

struct MLXPodcastPlaybackChunk: Equatable, Sendable, Identifiable {
    let id: String
    let turnIndex: Int
    let speaker: PodcastSpeaker
    let text: String
    let isSpeakerChange: Bool
}

enum MLXPodcastPlaybackPlan {
    static func chunks(
        for episode: PodcastEpisode,
        firstChunkCharacters: Int = 140,
        maximumChunkCharacters: Int = 220
    ) -> [MLXPodcastPlaybackChunk] {
        var result: [MLXPodcastPlaybackChunk] = []
        var previousSpeaker: PodcastSpeaker?

        for (turnIndex, turn) in episode.turns.enumerated() {
            let text = PodcastSpokenTextCleaner.clean(turn.text)
            guard !text.isEmpty else { continue }
            let chunks = KokoroTTSService.shared.speechChunks(
                from: text,
                firstChunkCharacters: firstChunkCharacters,
                maximumChunkCharacters: maximumChunkCharacters
            )
            for (chunkIndex, chunk) in chunks.enumerated() {
                let changed = previousSpeaker != turn.speaker
                result.append(
                    MLXPodcastPlaybackChunk(
                        id: "turn-\(turnIndex)-chunk-\(chunkIndex)",
                        turnIndex: turnIndex,
                        speaker: turn.speaker,
                        text: chunk,
                        isSpeakerChange: changed && chunkIndex == 0
                    )
                )
                previousSpeaker = turn.speaker
            }
        }
        return result
    }

    static func voice(
        for speaker: PodcastSpeaker,
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice
    ) -> KokoroVoice {
        speaker == .hostA ? hostAVoice : hostBVoice
    }
}

enum MLXPodcastPlaybackState: Equatable {
    case idle
    case preparing
    case playing
    case paused
    case saving
    case finished
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .playing, .paused, .saving: return true
        case .idle, .finished, .failed: return false
        }
    }

    var isPlaying: Bool {
        self == .playing
    }
}

@MainActor
final class MLXPodcastPlaybackController: ObservableObject {
    @Published private(set) var state: MLXPodcastPlaybackState = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentTurnIndex: Int?
    @Published private(set) var currentSpeaker: PodcastSpeaker?
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var operationID: UUID?
    private var pauseRequested = false
    private var interruptionObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let applicationActivity = PodcastApplicationActivityGate(
        isActive: UIApplication.shared.applicationState == .active
    )
    private let synthesisActivity = PodcastMLXSynthesisActivity()

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch type {
                case .began:
                    self.pauseForInterruption()
                case .ended:
                    self.statusMessage = "Playback was interrupted. Tap resume to continue."
                @unknown default:
                    break
                }
            }
        }

        let applicationActivity = self.applicationActivity
        let synthesisActivity = self.synthesisActivity
        lifecycleObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                applicationActivity.setActive(false)
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                // iOS rejects Metal command buffers after this callback returns.
                // Let only the already-started bounded chunk finish first.
                synthesisActivity.waitUntilIdle()
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                applicationActivity.setActive(true)
            }
        ]

    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        applicationActivity.setActive(true)
    }

    func play(
        episode: PodcastEpisode,
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice,
        speed: Double
    ) {
        stop()
        guard KokoroTTSService.shared.isAvailable else {
            state = .failed(KokoroTTSServiceError.notAvailable.localizedDescription)
            errorMessage = KokoroTTSServiceError.notAvailable.localizedDescription
            return
        }

        let plan = MLXPodcastPlaybackPlan.chunks(for: episode)
        guard !plan.isEmpty else {
            state = .failed(KokoroTTSServiceError.emptyText.localizedDescription)
            errorMessage = KokoroTTSServiceError.emptyText.localizedDescription
            return
        }

        configureBackgroundAudioSession()
        errorMessage = nil
        pauseRequested = false
        progress = 0
        currentTurnIndex = nil
        currentSpeaker = nil
        statusMessage = "Preparing episode…"
        state = .preparing
        let id = UUID()
        operationID = id
        let token = KokoroTTSService.shared.newPlaybackToken()
        let clampedSpeed = min(max(speed, 0.5), 2.0)

        playbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runPlayback(
                    plan: plan,
                    hostAVoice: hostAVoice,
                    hostBVoice: hostBVoice,
                    speed: clampedSpeed,
                    playbackToken: token,
                    operationID: id
                )
                self.finish(operationID: id)
            } catch is CancellationError {
                self.finishCancellation(operationID: id)
            } catch {
                self.fail(error, operationID: id)
            }
        }
    }

    func pause() {
        guard state == .playing || state == .preparing else { return }
        pauseRequested = true
        player?.pause()
        state = .paused
        statusMessage = "Paused"
    }

    func resume() {
        guard state == .paused else { return }
        pauseRequested = false
        if let player, player.play() {
            self.player = player
            state = .playing
            statusMessage = "Playing"
        } else {
            state = .preparing
            statusMessage = "Preparing next chunk…"
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        operationID = nil
        pauseRequested = false
        player?.stop()
        player = nil
        KokoroTTSService.shared.cancelPlayback()
        state = .idle
        progress = 0
        currentTurnIndex = nil
        currentSpeaker = nil
        statusMessage = ""
        errorMessage = nil
    }

    func saveEpisode(
        _ episode: PodcastEpisode,
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice,
        speed: Double,
        runID: UUID,
        artifactID: UUID?,
        progressHandler: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async throws -> UUID {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("redapp-podcast-\(UUID().uuidString).wav")

        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let duration = try await renderEpisodeAudio(
            episode,
            hostAVoice: hostAVoice,
            hostBVoice: hostBVoice,
            speed: speed,
            outputURL: outputURL,
            progressLabel: "Saving to Research Library",
            progressHandler: progressHandler
        )
        let voiceMetadata = BatchPodcastSpeechVoiceMetadata(
            hostAVoice: hostAVoice.rawValue,
            hostBVoice: hostBVoice.rawValue
        )
        let sourceTextDigest = ResearchDigest.sha256Hex(episode.spokenText)
        return try await ResearchOfflinePackManager.shared.saveSpeechFile(
            outputURL,
            runID: runID,
            artifactID: artifactID,
            voiceMetadata: voiceMetadata,
            speed: min(max(speed, 0.5), 2.0),
            duration: duration,
            sourceTextDigest: sourceTextDigest
        )
    }

    func renderEpisodeForExport(
        _ episode: PodcastEpisode,
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice,
        speed: Double,
        progressHandler: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async throws -> URL {
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("redapp-podcast-export-\(UUID().uuidString)", isDirectory: true)
        let outputURL = exportDirectory
            .appendingPathComponent(Self.exportFileName(for: episode.title))
            .appendingPathExtension("wav")

        do {
            try FileManager.default.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: true
            )
            _ = try await renderEpisodeAudio(
                episode,
                hostAVoice: hostAVoice,
                hostBVoice: hostBVoice,
                speed: speed,
                outputURL: outputURL,
                progressLabel: "Preparing podcast export",
                progressHandler: progressHandler
            )
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: exportDirectory)
            throw error
        }
    }

    private func renderEpisodeAudio(
        _ episode: PodcastEpisode,
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice,
        speed: Double,
        outputURL: URL,
        progressLabel: String,
        progressHandler: (@MainActor @Sendable (Int, Int) -> Void)?
    ) async throws -> TimeInterval {
        stop()
        guard KokoroTTSService.shared.isAvailable else {
            throw BatchPodcastError.audioSaveFailed(KokoroTTSServiceError.notAvailable.localizedDescription)
        }

        let plan = MLXPodcastPlaybackPlan.chunks(for: episode)
        guard !plan.isEmpty else {
            throw BatchPodcastError.audioSaveFailed(KokoroTTSServiceError.emptyText.localizedDescription)
        }

        configureBackgroundAudioSession()
        errorMessage = nil
        progress = 0
        state = .saving
        statusMessage = "\(progressLabel) 0 of \(plan.count)…"
        let token = KokoroTTSService.shared.newPlaybackToken()
        var writer: PodcastWAVWriter?
        var duration: TimeInterval = 0

        defer {
            try? writer?.finish()
            unloadMLXIfAllowed()
            state = .idle
            statusMessage = ""
        }

        do {
            for (index, chunk) in plan.enumerated() {
                try Task.checkCancellation()
                guard KokoroTTSService.shared.isPlaybackTokenCurrent(token) else {
                    throw CancellationError()
                }
                statusMessage = "\(progressLabel) \(index + 1) of \(plan.count)…"
                let data = try await synthesize(
                    chunk: chunk,
                    hostAVoice: hostAVoice,
                    hostBVoice: hostBVoice,
                    speed: speed,
                    playbackToken: token
                )
                try Task.checkCancellation()
                if writer == nil {
                    writer = try PodcastWAVWriter(url: outputURL)
                }
                try writer?.append(wavData: data)
                let chunkPlayer = try AVAudioPlayer(data: data)
                duration += chunkPlayer.duration
                progress = Double(index + 1) / Double(plan.count)
                progressHandler?(index + 1, plan.count)
            }
            try writer?.finish()
            writer = nil
            return duration
        } catch is CancellationError {
            KokoroTTSService.shared.cancelPlayback()
            throw CancellationError()
        } catch {
            throw BatchPodcastError.audioSaveFailed(error.localizedDescription)
        }
    }

    private static func exportFileName(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_"))
        let sanitized = title.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = sanitized.isEmpty ? "Batch Podcast" : sanitized
        return String(fallback.prefix(80))
    }

    private func runPlayback(
        plan: [MLXPodcastPlaybackChunk],
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice,
        speed: Double,
        playbackToken: UUID,
        operationID: UUID
    ) async throws {
        var nextSynthesisTask: Task<Data, Error>?
        defer { nextSynthesisTask?.cancel() }

        var index = 0
        var currentData = try await synthesize(
            chunk: plan[0],
            hostAVoice: hostAVoice,
            hostBVoice: hostBVoice,
            speed: speed,
            playbackToken: playbackToken
        )

        while index < plan.count {
            try Task.checkCancellation()
            guard self.operationID == operationID,
                  KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
                throw CancellationError()
            }

            try await waitIfPaused()
            let chunk = plan[index]
            currentTurnIndex = chunk.turnIndex
            currentSpeaker = chunk.speaker
            let audioPlayer = try AVAudioPlayer(data: currentData)
            guard audioPlayer.prepareToPlay(), audioPlayer.play() else {
                throw NSError(
                    domain: "MLXPodcastPlayback",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The MLX podcast audio could not start playing."]
                )
            }
            player = audioPlayer
            state = .playing
            statusMessage = "Playing \(chunk.speaker.displayName)"

            let nextIndex = index + 1
            if nextIndex < plan.count {
                let nextChunk = plan[nextIndex]
                nextSynthesisTask = Task { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.synthesize(
                        chunk: nextChunk,
                        hostAVoice: hostAVoice,
                        hostBVoice: hostBVoice,
                        speed: speed,
                        playbackToken: playbackToken
                    )
                }
            } else {
                nextSynthesisTask = nil
            }

            try await waitForPlayerToFinish(
                audioPlayer,
                playbackToken: playbackToken
            )
            progress = Double(index + 1) / Double(plan.count)
            player = nil

            guard let task = nextSynthesisTask else { break }
            state = .preparing
            statusMessage = "Preparing the next voice…"
            currentData = try await task.value
            nextSynthesisTask = nil

            if plan[nextIndex].isSpeakerChange {
                try await Task.sleep(for: .milliseconds(120))
            }
            index = nextIndex
        }

        progress = 1
        state = .finished
        statusMessage = "Episode finished"
        player = nil
    }

    private func synthesize(
        chunk: MLXPodcastPlaybackChunk,
        hostAVoice: KokoroVoice,
        hostBVoice: KokoroVoice,
        speed: Double,
        playbackToken: UUID
    ) async throws -> Data {
        try Task.checkCancellation()
        guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
            throw CancellationError()
        }
        if !applicationActivity.isActive {
            statusMessage = "Audio will continue. Return to Redapp to prepare more audio."
        }
        await applicationActivity.waitUntilActive()
        try Task.checkCancellation()
        guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
            throw CancellationError()
        }
        let voice = MLXPodcastPlaybackPlan.voice(
            for: chunk.speaker,
            hostAVoice: hostAVoice,
            hostBVoice: hostBVoice
        )
        let synthesisActivity = self.synthesisActivity
        synthesisActivity.begin()
        let synthesisTask = Task.detached(priority: .userInitiated) {
            defer { synthesisActivity.end() }
            return try await KokoroTTSService.shared.synthesize(
                text: chunk.text,
                voice: voice.rawValue,
                speed: Float(min(max(speed, 0.5), 2.0)),
                allowCaching: false
            )
        }
        let data = try await withTaskCancellationHandler {
            try await synthesisTask.value
        } onCancel: {
            synthesisTask.cancel()
        }
        try Task.checkCancellation()
        guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
            throw CancellationError()
        }
        return data
    }

    private func waitForPlayerToFinish(
        _ audioPlayer: AVAudioPlayer,
        playbackToken: UUID
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
                audioPlayer.stop()
                throw CancellationError()
            }
            if pauseRequested {
                state = .paused
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            if audioPlayer.isPlaying {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            break
        }
    }

    private func waitIfPaused() async throws {
        while pauseRequested {
            try Task.checkCancellation()
            state = .paused
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func pauseForInterruption() {
        guard state == .playing || state == .preparing else { return }
        pauseRequested = true
        player?.pause()
        state = .paused
        statusMessage = "Playback interrupted. Tap resume to continue."
    }

    private func finish(operationID: UUID) {
        guard self.operationID == operationID else { return }
        playbackTask = nil
        self.operationID = nil
        player = nil
        unloadMLXIfAllowed()
    }

    private func finishCancellation(operationID: UUID) {
        guard self.operationID == operationID else { return }
        playbackTask = nil
        self.operationID = nil
        player?.stop()
        player = nil
        state = .idle
        statusMessage = ""
    }

    private func fail(_ error: Error, operationID: UUID) {
        guard self.operationID == operationID else { return }
        playbackTask = nil
        self.operationID = nil
        player?.stop()
        player = nil
        unloadMLXIfAllowed()
        let message = error.localizedDescription
        state = .failed(message)
        errorMessage = message
        statusMessage = "Playback failed"
    }

    private func unloadMLXIfAllowed() {
        guard !SummaryService.shared.settings.kokoroPrecacheEnabled else { return }
        KokoroTTSService.shared.unloadIfAllowed()
    }
}

private final class PodcastWAVWriter {
    private let fileHandle: FileHandle
    private var dataSizeOffset: UInt64?
    private var dataByteCount: UInt64 = 0
    private var formatChunk: Data?
    private var bytesPerSecond: UInt32?
    private var blockAlignment: UInt16?
    private var isFinished = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: url)
    }

    func append(wavData: Data) throws {
        guard !isFinished else { return }
        guard let chunks = Self.findChunks(in: wavData),
              let dataChunk = chunks.data,
              let formatChunk = chunks.format else {
            throw BatchPodcastError.audioSaveFailed("The synthesized chunk was not a PCM WAV file.")
        }

        if self.formatChunk == nil {
            self.formatChunk = formatChunk.payload
            guard formatChunk.payload.count >= 16 else {
                throw BatchPodcastError.audioSaveFailed("The synthesized WAV format was incomplete.")
            }
            bytesPerSecond = Self.readUInt32(formatChunk.payload, offset: 8)
            blockAlignment = Self.readUInt16(formatChunk.payload, offset: 12)
            try fileHandle.write(contentsOf: Data(wavData[0..<dataChunk.payloadStart]))
            dataSizeOffset = UInt64(dataChunk.payloadStart - 4)
        } else if self.formatChunk != formatChunk.payload {
            throw BatchPodcastError.audioSaveFailed("Audio chunks used incompatible formats.")
        }

        let payload = Data(wavData[dataChunk.payloadStart..<dataChunk.payloadEnd])
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: payload)
        dataByteCount += UInt64(payload.count)
    }

    func appendSilence(duration: TimeInterval) throws {
        guard !isFinished, duration > 0,
              let bytesPerSecond,
              let blockAlignment,
              blockAlignment > 0 else { return }
        let unalignedByteCount = max(0, Int(Double(bytesPerSecond) * duration))
        let alignment = Int(blockAlignment)
        let byteCount = unalignedByteCount - (unalignedByteCount % alignment)
        guard byteCount > 0 else { return }
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: Data(repeating: 0, count: byteCount))
        dataByteCount += UInt64(byteCount)
    }

    func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        guard let dataSizeOffset else {
            try fileHandle.close()
            return
        }

        try fileHandle.seek(toOffset: 4)
        try fileHandle.write(contentsOf: Self.littleEndian(UInt32(min(UInt64(UInt32.max), 36 + dataByteCount))))
        try fileHandle.seek(toOffset: dataSizeOffset)
        try fileHandle.write(contentsOf: Self.littleEndian(UInt32(min(UInt64(UInt32.max), dataByteCount))))
        try fileHandle.synchronize()
        try fileHandle.close()
    }

    deinit {
        try? fileHandle.close()
    }

    private struct WAVChunk {
        let payloadStart: Int
        let payloadEnd: Int
        let payload: Data
    }

    private static func findChunks(in data: Data) -> (data: WAVChunk?, format: WAVChunk?)? {
        guard data.count >= 12,
              String(bytes: data[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        var cursor = 12
        var dataChunk: WAVChunk?
        var formatChunk: WAVChunk?
        while cursor + 8 <= data.count {
            let id = String(bytes: data[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
            let size = Int(readUInt32(data, offset: cursor + 4))
            let payloadStart = cursor + 8
            let payloadEnd = min(data.count, payloadStart + size)
            guard payloadEnd >= payloadStart else { return nil }
            let chunk = WAVChunk(
                payloadStart: payloadStart,
                payloadEnd: payloadEnd,
                payload: Data(data[payloadStart..<payloadEnd])
            )
            if id == "fmt " { formatChunk = chunk }
            if id == "data" { dataChunk = chunk }
            cursor = payloadEnd + (size % 2)
        }
        guard let dataChunk, let formatChunk else { return nil }
        return (dataChunk, formatChunk)
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }
}
#endif
