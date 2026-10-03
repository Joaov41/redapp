import AVFoundation
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

private final class ResearchSpeechApplicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(isActive: Bool) {
        active = isActive
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

private final class ResearchSpeechMLXActivity: @unchecked Sendable {
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

#if os(iOS)
private final class ResearchSpeechSynthesisCoordinator: @unchecked Sendable {
    static let shared = ResearchSpeechSynthesisCoordinator()

    private let applicationGate = ResearchSpeechApplicationGate(
        isActive: UIApplication.shared.applicationState == .active
    )
    private let mlxActivity = ResearchSpeechMLXActivity()
    private var observers: [NSObjectProtocol] = []

    private init() {
        let applicationGate = self.applicationGate
        let mlxActivity = self.mlxActivity
        observers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                applicationGate.setActive(false)
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                mlxActivity.waitUntilIdle()
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                applicationGate.setActive(true)
            }
        ]
    }

    func synthesize(
        text: String,
        voice: String,
        speed: Float,
        playbackToken: UUID
    ) async throws -> Data {
        await applicationGate.waitUntilActive()
        try Task.checkCancellation()
        guard KokoroTTSService.shared.isPlaybackTokenCurrent(playbackToken) else {
            throw CancellationError()
        }

        let mlxActivity = self.mlxActivity
        mlxActivity.begin()
        let synthesisTask = Task.detached(priority: .userInitiated) {
            defer { mlxActivity.end() }
            return try await KokoroTTSService.shared.synthesize(
                text: text,
                voice: voice,
                speed: speed
            )
        }
        return try await withTaskCancellationHandler {
            try await synthesisTask.value
        } onCancel: {
            synthesisTask.cancel()
        }
    }
}
#endif

private func synthesizeResearchSpeechChunk(
    text: String,
    voice: String,
    speed: Float,
    playbackToken: UUID
) async throws -> Data {
    #if os(iOS)
    return try await ResearchSpeechSynthesisCoordinator.shared.synthesize(
        text: text,
        voice: voice,
        speed: speed,
        playbackToken: playbackToken
    )
    #else
    return try await KokoroTTSService.shared.synthesize(
        text: text,
        voice: voice,
        speed: speed
    )
    #endif
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
                        play()
                    } label: {
                        Image(systemName: "play.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(activity.isBusy)
                    .help("Read this \(label) aloud")
                    .accessibilityLabel("Read \(label) aloud")

                    Button {
                        stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop reading")
                    .accessibilityLabel("Stop \(label) speech")

                    if runID != nil {
                        Button {
                            saveOffline()
                        } label: {
                            Image(systemName: speechSaved ? "checkmark.circle.fill" : "arrow.down.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(activity.isBusy || speechSaved)
                        .help(speechSaved ? "Spoken version saved offline" : "Save spoken version for offline")
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
                try configureSpeechAudioSession()
                try await playResearchSpeechChunks(
                    chunks,
                    voice: settings.kokoroVoice,
                    speed: Float(settings.kokoroSpeed),
                    playbackToken: playbackToken
                ) { current, total in
                    activity = .preparing(current: current, total: total)
                } playData: { data, current, total, token in
                    try await play(
                        data: data,
                        current: current,
                        total: total,
                        playbackToken: token
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

    private func configureSpeechAudioSession() throws {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP]
            )
        } catch {
            try audioSession.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
            )
        }
        try audioSession.setActive(true)
        #endif
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
                userInfo: [NSLocalizedDescriptionKey: "The spoken version could not start playing."]
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
