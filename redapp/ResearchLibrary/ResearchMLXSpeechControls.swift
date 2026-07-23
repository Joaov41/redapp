import AVFoundation
import SwiftUI

@MainActor
struct ResearchMLXSpeechControls: View {
    let text: String
    let runID: UUID?
    let artifactID: UUID?
    var label = "report"

    @State private var player: AVAudioPlayer?
    @State private var task: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var activity: Activity = .idle
    @State private var speechSaved = false
    @State private var errorMessage: String?

    init(
        text: String,
        runID: UUID? = nil,
        artifactID: UUID? = nil,
        label: String = "report"
    ) {
        self.text = text
        self.runID = runID
        self.artifactID = artifactID
        self.label = label
    }

    var body: some View {
        if SummaryService.shared.settings.localTTSEngine == .kokoro {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 12) {
                    Button {
                        activity.isPlayback ? stop() : play()
                    } label: {
                        Image(systemName: activity.isPlayback ? "stop.circle.fill" : "play.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(activity.isBusy && !activity.isPlayback)
                    .help(activity.isPlayback ? "Stop MLX speech" : "Read this \(label) aloud with MLX TTS")
                    .accessibilityLabel(activity.isPlayback ? "Stop \(label) speech" : "Play \(label) with MLX speech")

                    if runID != nil {
                        Button {
                            saveOffline()
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
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
            .onDisappear { stop() }
        }
    }

    private func play() {
        stop()
        let plainText = MarkdownTextView.extractPlainText(from: text)
        let chunks = KokoroTTSService.shared.speechChunks(from: plainText)
        guard !chunks.isEmpty else {
            errorMessage = KokoroTTSServiceError.emptyText.localizedDescription
            return
        }

        let id = UUID()
        operationID = id
        let settings = SummaryService.shared.settings
        let playbackToken = KokoroTTSService.shared.newPlaybackToken()
        task = Task {
            do {
                for (index, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
                        throw CancellationError()
                    }
                    activity = .preparing(current: index + 1, total: chunks.count)
                    let data = try await KokoroTTSService.shared.synthesize(
                        text: chunk,
                        voice: settings.kokoroVoice,
                        speed: Float(settings.kokoroSpeed)
                    )
                    try await play(
                        data: data,
                        current: index + 1,
                        total: chunks.count,
                        playbackToken: playbackToken
                    )
                }
            } catch is CancellationError {
                // Stopping speech is a normal user action.
            } catch {
                if operationID == id { errorMessage = error.localizedDescription }
            }
            finish(id)
        }
    }

    private func saveOffline() {
        guard let runID else { return }
        stop()
        let plainText = MarkdownTextView.extractPlainText(from: text)
        let chunks = KokoroTTSService.shared.speechChunks(from: plainText)
        guard !chunks.isEmpty else {
            errorMessage = KokoroTTSServiceError.emptyText.localizedDescription
            return
        }

        let id = UUID()
        operationID = id
        let settings = SummaryService.shared.settings
        activity = .saving(completed: 0, total: chunks.count)
        task = Task {
            do {
                let data = try await KokoroTTSService.shared.synthesizeChunked(
                    text: plainText,
                    voice: settings.kokoroVoice,
                    speed: Float(settings.kokoroSpeed)
                ) { completed, total in
                    guard operationID == id else { return }
                    activity = .saving(completed: completed, total: total)
                }
                try Task.checkCancellation()
                _ = try await ResearchOfflinePackManager.shared.saveSpeech(
                    data,
                    runID: runID,
                    artifactID: artifactID,
                    voice: settings.kokoroVoice,
                    speed: settings.kokoroSpeed
                )
                guard operationID == id else { return }
                speechSaved = true
            } catch is CancellationError {
                // Leaving the report cancels an unfinished save.
            } catch {
                if operationID == id { errorMessage = error.localizedDescription }
            }
            finish(id)
        }
    }

    private func play(
        data: Data,
        current: Int,
        total: Int,
        playbackToken: UUID
    ) async throws {
        try Task.checkCancellation()
        guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
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
            guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
                audioPlayer.stop()
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func stop() {
        operationID = nil
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        KokoroTTSService.shared.cancelPlayback()
        activity = .idle
    }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        task = nil
        player = nil
        activity = .idle
    }

    private enum Activity: Equatable {
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
}
