import AVFoundation
import SwiftUI

private func synthesizeResearchSpeechChunk(
    text: String,
    voice: String,
    speed: Float,
    playbackToken: UUID
) async throws -> Data {
    try Task.checkCancellation()
    guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
        throw CancellationError()
    }

    let synthesisTask = Task.detached(priority: .userInitiated) {
        try await KokoroTTSService.shared.synthesize(
            text: text,
            voice: voice,
            speed: speed
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

@MainActor
func playResearchSpeechChunks(
    _ chunks: [String],
    voice: String,
    speed: Float,
    playbackToken: UUID,
    onPreparing: @escaping (_ current: Int, _ total: Int) -> Void,
    playData: @escaping (_ data: Data, _ current: Int, _ total: Int, _ token: UUID) async throws -> Void
) async throws {
    guard let firstChunk = chunks.first else { throw KokoroTTSServiceError.emptyText }
    var nextSynthesisTask: Task<Data, Error>?
    defer { nextSynthesisTask?.cancel() }

    onPreparing(1, chunks.count)
    var currentData = try await synthesizeResearchSpeechChunk(
        text: firstChunk,
        voice: voice,
        speed: speed,
        playbackToken: playbackToken
    )
    var index = 0

    while index < chunks.count {
        try Task.checkCancellation()
        guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
            throw CancellationError()
        }

        let nextIndex = index + 1
        if nextIndex < chunks.count {
            let nextChunk = chunks[nextIndex]
            nextSynthesisTask = Task {
                try await synthesizeResearchSpeechChunk(
                    text: nextChunk,
                    voice: voice,
                    speed: speed,
                    playbackToken: playbackToken
                )
            }
        } else {
            nextSynthesisTask = nil
        }

        try await playData(currentData, index + 1, chunks.count, playbackToken)
        guard let task = nextSynthesisTask else { break }
        onPreparing(nextIndex + 1, chunks.count)
        currentData = try await task.value
        nextSynthesisTask = nil
        index = nextIndex
    }
}

private struct ResearchSpeechPlaybackKey: Hashable {
    let value: String

    init(text: String, runID: UUID?, artifactID: UUID?, label: String) {
        if let artifactID {
            value = "artifact:\(artifactID.uuidString)"
        } else {
            value = "run:\(runID?.uuidString ?? "none"):\(label):\(ResearchDigest.sha256Hex(text))"
        }
    }
}

private enum ResearchSpeechActivity: Equatable {
    case idle
    case preparing(current: Int, total: Int)
    case playing(current: Int, total: Int)
    case saving(completed: Int, total: Int)

    var isPlayback: Bool {
        switch self {
        case .preparing, .playing: true
        case .idle, .saving: false
        }
    }

    var isBusy: Bool { self != .idle }

    var progress: Double? {
        switch self {
        case .idle: nil
        case let .preparing(current, total), let .playing(current, total):
            Double(max(0, current - 1)) / Double(max(total, 1))
        case let .saving(completed, total):
            Double(completed) / Double(max(total, 1))
        }
    }

    var status: String {
        switch self {
        case .idle: ""
        case let .preparing(current, total): "Preparing \(current) of \(total)"
        case let .playing(current, total): "Playing \(current) of \(total)"
        case let .saving(completed, total): "Saving \(completed) of \(total)"
        }
    }
}

@MainActor
private final class ResearchSpeechPlaybackController: ObservableObject {
    static let shared = ResearchSpeechPlaybackController()

    @Published private(set) var activeKey: ResearchSpeechPlaybackKey?
    @Published private(set) var activity: ResearchSpeechActivity = .idle
    @Published private(set) var savedKeys: Set<ResearchSpeechPlaybackKey> = []
    @Published private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var operationID: UUID?

    func activity(for key: ResearchSpeechPlaybackKey) -> ResearchSpeechActivity {
        activeKey == key ? activity : .idle
    }

    func error(for key: ResearchSpeechPlaybackKey) -> String? {
        activeKey == key ? errorMessage : nil
    }

    func play(
        key: ResearchSpeechPlaybackKey,
        text: String,
        speechAsset: ResearchOfflineAssetRecord?,
        voice: String,
        speed: Float
    ) {
        stop()
        if let speechAsset {
            let id = UUID()
            activeKey = key
            operationID = id
            errorMessage = nil
            activity = .preparing(current: 1, total: 1)
            let playbackToken = KokoroTTSService.shared.newPlaybackToken()
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    let url = try await ResearchOfflinePackManager.shared.localURL(
                        relativePath: speechAsset.relativePath
                    )
                    let data = try Data(contentsOf: url)
                    try await self.play(
                        data: data,
                        current: 1,
                        total: 1,
                        playbackToken: playbackToken,
                        operationID: id
                    )
                } catch is CancellationError {
                    // Stopping speech is a normal user action.
                } catch {
                    guard self.operationID == id else { return }
                    self.errorMessage = error.localizedDescription
                }
                self.finish(id)
            }
            return
        }

        let plainText = MarkdownTextView.extractPlainText(from: text)
        let chunks = KokoroTTSService.shared.speechChunks(from: plainText)
        guard !chunks.isEmpty else {
            activeKey = key
            errorMessage = KokoroTTSServiceError.emptyText.localizedDescription
            return
        }

        let id = UUID()
        activeKey = key
        operationID = id
        errorMessage = nil
        let playbackToken = KokoroTTSService.shared.newPlaybackToken()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await playResearchSpeechChunks(
                    chunks,
                    voice: voice,
                    speed: speed,
                    playbackToken: playbackToken
                ) { current, total in
                    guard self.operationID == id else { return }
                    self.activity = .preparing(current: current, total: total)
                } playData: { data, current, total, token in
                    try await self.play(
                        data: data,
                        current: current,
                        total: total,
                        playbackToken: token,
                        operationID: id
                    )
                }
            } catch is CancellationError {
                // Stopping speech is a normal user action.
            } catch {
                guard self.operationID == id else { return }
                self.errorMessage = error.localizedDescription
            }
            self.finish(id)
        }
    }

    func saveOffline(
        key: ResearchSpeechPlaybackKey,
        text: String,
        runID: UUID,
        artifactID: UUID?,
        voice: String,
        speed: Double,
        onSaved: @escaping @MainActor () -> Void
    ) {
        stop()
        let plainText = MarkdownTextView.extractPlainText(from: text)
        let chunks = KokoroTTSService.shared.speechChunks(from: plainText)
        guard !chunks.isEmpty else {
            activeKey = key
            errorMessage = KokoroTTSServiceError.emptyText.localizedDescription
            return
        }

        let id = UUID()
        activeKey = key
        operationID = id
        errorMessage = nil
        activity = .saving(completed: 0, total: chunks.count)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await KokoroTTSService.shared.synthesizeChunked(
                    text: plainText,
                    voice: voice,
                    speed: Float(speed)
                ) { completed, total in
                    guard self.operationID == id else { return }
                    self.activity = .saving(completed: completed, total: total)
                }
                try Task.checkCancellation()
                _ = try await ResearchOfflinePackManager.shared.saveSpeech(
                    data,
                    runID: runID,
                    artifactID: artifactID,
                    voice: voice,
                    speed: speed
                )
                guard self.operationID == id else { return }
                self.savedKeys.insert(key)
                onSaved()
            } catch is CancellationError {
                // Stopping an unfinished save is a normal user action.
            } catch {
                guard self.operationID == id else { return }
                self.errorMessage = error.localizedDescription
            }
            self.finish(id)
        }
    }

    func stop(key: ResearchSpeechPlaybackKey? = nil) {
        if let key, activeKey != key { return }
        operationID = nil
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        KokoroTTSService.shared.cancelPlayback()
        activeKey = nil
        activity = .idle
        errorMessage = nil
    }

    func clearError(for key: ResearchSpeechPlaybackKey) {
        guard activeKey == key else { return }
        errorMessage = nil
        if activity == .idle { activeKey = nil }
    }

    private func play(
        data: Data,
        current: Int,
        total: Int,
        playbackToken: UUID,
        operationID: UUID
    ) async throws {
        try Task.checkCancellation()
        guard self.operationID == operationID,
              KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
            throw CancellationError()
        }
        let audioPlayer = try AVAudioPlayer(data: data)
        guard audioPlayer.prepareToPlay(), audioPlayer.play() else {
            throw NSError(
                domain: "ResearchMLXSpeech",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The MLX speech audio could not start playing."]
            )
        }
        player = audioPlayer
        activity = .playing(current: current, total: total)
        while audioPlayer.isPlaying {
            try Task.checkCancellation()
            guard self.operationID == operationID,
                  KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
                audioPlayer.stop()
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        player = nil
    }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        task = nil
        player = nil
        activity = .idle
        if errorMessage == nil { activeKey = nil }
    }
}

@MainActor
struct ResearchMLXSpeechControls: View {
    let text: String
    let runID: UUID?
    let artifactID: UUID?
    var label = "report"
    let speechAsset: ResearchOfflineAssetRecord?
    let onOfflineChange: () -> Void

    private let playbackKey: ResearchSpeechPlaybackKey
    @ObservedObject private var playback = ResearchSpeechPlaybackController.shared

    init(
        text: String,
        runID: UUID? = nil,
        artifactID: UUID? = nil,
        label: String = "report",
        speechAsset: ResearchOfflineAssetRecord? = nil,
        onOfflineChange: @escaping () -> Void = {}
    ) {
        self.text = text
        self.runID = runID
        self.artifactID = artifactID
        self.label = label
        self.speechAsset = speechAsset
        self.onOfflineChange = onOfflineChange
        playbackKey = ResearchSpeechPlaybackKey(
            text: text,
            runID: runID,
            artifactID: artifactID,
            label: label
        )
    }

    var body: some View {
        if SummaryService.shared.settings.localTTSEngine == .kokoro {
            let activity = playback.activity(for: playbackKey)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 12) {
                    Button {
                        if activity.isPlayback {
                            playback.stop(key: playbackKey)
                        } else {
                            let settings = SummaryService.shared.settings
                            playback.play(
                                key: playbackKey,
                                text: text,
                                speechAsset: speechAsset,
                                voice: settings.kokoroVoice,
                                speed: Float(settings.kokoroSpeed)
                            )
                        }
                    } label: {
                        Image(systemName: activity.isPlayback ? "stop.circle.fill" : "play.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(activity.isBusy && !activity.isPlayback)
                    .help(activity.isPlayback ? "Stop MLX speech" : "Read this \(label) aloud with MLX TTS")
                    .accessibilityLabel(activity.isPlayback ? "Stop \(label) speech" : "Play \(label) with MLX speech")

                    if let runID {
                        let speechSaved = playback.savedKeys.contains(playbackKey) || speechAsset != nil
                        Button {
                            let settings = SummaryService.shared.settings
                            playback.saveOffline(
                                key: playbackKey,
                                text: text,
                                runID: runID,
                                artifactID: artifactID,
                                voice: settings.kokoroVoice,
                                speed: settings.kokoroSpeed,
                                onSaved: onOfflineChange
                            )
                        } label: {
                            Image(systemName: speechSaved ? "checkmark.circle.fill" : "arrow.down.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(activity.isBusy || speechSaved)
                        .help(speechSaved ? "MLX speech saved offline" : "Save MLX speech offline")
                        .accessibilityLabel(speechSaved ? "Speech saved offline" : "Save speech offline")
                    }
                }

                if let progress = activity.progress {
                    ProgressView(value: progress)
                        .frame(width: 88)
                    Text(activity.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .alert("Speech Unavailable", isPresented: Binding(
                get: { playback.error(for: playbackKey) != nil },
                set: { if !$0 { playback.clearError(for: playbackKey) } }
            )) {
                Button("OK", role: .cancel) { playback.clearError(for: playbackKey) }
            } message: {
                Text(playback.error(for: playbackKey) ?? "Unknown error")
            }
        }
    }
}
