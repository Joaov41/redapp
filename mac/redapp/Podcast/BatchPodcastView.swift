import SwiftUI

@MainActor
struct BatchPodcastView: View {
    let context: BatchPodcastContext
    let runID: UUID?
    @ObservedObject var session: BatchPodcastSession
    let onMinimize: () -> Void
    let onClose: () -> Void

    @ObservedObject private var playbackController: MLXPodcastPlaybackController
    @State private var hostAVoice: KokoroVoice
    @State private var hostBVoice: KokoroVoice
    @State private var speed: Double
    @State private var allowSummariesOnlyFallback: Bool
    @State private var saveTask: Task<Void, Never>?
    @State private var isPreparingExport = false
    @State private var isSavingToResearchLibrary = false
    @State private var savedAudioAssetID: UUID?
    @State private var exportConfirmation: String?

    init(
        context: BatchPodcastContext,
        runID: UUID?,
        session: BatchPodcastSession,
        onMinimize: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.context = context
        self.runID = runID
        self.session = session
        self.onMinimize = onMinimize
        self.onClose = onClose
        _playbackController = ObservedObject(wrappedValue: session.playbackController)
        let selected = KokoroVoice(rawValue: SummaryService.shared.settings.kokoroVoice)
            ?? KokoroVoice.defaultVoice
        _hostAVoice = State(initialValue: selected)
        _hostBVoice = State(initialValue: Self.contrastingVoice(for: selected))
        _speed = State(initialValue: min(max(SummaryService.shared.settings.kokoroSpeed, 0.5), 2.0))
        _allowSummariesOnlyFallback = State(initialValue: !context.isSummariesOnly)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    contextHeader
                    voiceSelection
                    generationControls

                    if let generationError = session.generationError {
                        errorCard(generationError)
                    }

                    if let episode = session.episode {
                        episodePreview(episode)
                        playbackControls(for: episode)
                    } else if !session.isGenerating {
                        emptyPreview
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .navigationTitle("Batch Podcast")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        onMinimize()
                    } label: {
                        Image(systemName: "minus.square")
                    }
                    .accessibilityLabel("Minimize batch podcast")
                    .accessibilityHint("Keeps podcast generation and playback running while you use the app")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        onClose()
                    }
                    .accessibilityLabel("Close batch podcast")
                }
            }
            .onDisappear {
                saveTask?.cancel()
            }
        }
    }

    private var contextHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(context.contextName) · saved batch", systemImage: "waveform.and.mic")
                .font(.headline)

            Text("Uses the comments, summaries, and sources already captured for this batch. Creating an episode does not fetch Reddit again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label("\(context.postSummaries.count) posts", systemImage: "doc.text")
                Label("\(context.commentChunks.count) comment chunks", systemImage: "text.bubble")
                if context.isSummariesOnly {
                    Label("Summaries only", systemImage: "exclamationmark.triangle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if context.isSummariesOnly {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Raw comments were not saved for this live batch.", systemImage: "info.circle")
                        .font(.subheadline.weight(.semibold))
                    Text("This fallback is less complete and uses only the saved post summaries. It is explicit and will not refetch comments.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Use summaries-only fallback", isOn: $allowSummariesOnlyFallback)
                        .toggleStyle(.switch)
                        .accessibilityHint("Allows a less complete podcast based only on saved post summaries")
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var voiceSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hosts")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    voicePicker(title: "Host A", selection: $hostAVoice)
                    voicePicker(title: "Host B", selection: $hostBVoice)
                }
                VStack(spacing: 10) {
                    voicePicker(title: "Host A", selection: $hostAVoice)
                    voicePicker(title: "Host B", selection: $hostBVoice)
                }
            }

            HStack {
                Text("Speed")
                    .font(.subheadline)
                Slider(value: $speed, in: 0.5...2.0, step: 0.1)
                Text(String(format: "%.1fx", speed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Voice choices apply to this episode only; global MLX settings stay unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func voicePicker(
        title: String,
        selection: Binding<KokoroVoice>
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(KokoroVoice.allCases) { voice in
                Text(voice.displayName).tag(voice)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(title) MLX voice")
    }

    private var generationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if SummaryService.shared.settings.localTTSEngine != .kokoro || !KokoroTTSService.shared.isAvailable {
                Label("Set Local TTS to MLX TTS in Settings to play or save this episode.", systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    session.isGenerating ? cancelGeneration() : generate()
                } label: {
                    if session.isGenerating {
                        Label("Cancel", systemImage: "xmark")
                    } else {
                        Label(session.episode == nil ? "Generate Script" : "Regenerate Script", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canGenerate && !session.isGenerating)
                .accessibilityLabel(session.isGenerating ? "Cancel podcast generation" : (session.episode == nil ? "Generate podcast script" : "Regenerate podcast script"))

                if let generationProgress = session.generationProgress, session.isGenerating {
                    ProgressView()
                    Text(generationProgress.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if session.isGenerating, let generationProgress = session.generationProgress {
                ProgressView(value: generationFraction(generationProgress))
                    .tint(.accentColor)
            }
        }
    }

    private var emptyPreview: some View {
        ContentUnavailableView(
            "No script yet",
            systemImage: "text.badge.plus",
            description: Text("Generate a grounded two-host script from this saved batch.")
        )
    }

    private func episodePreview(_ episode: PodcastEpisode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(episode.title)
                    .font(.title3.weight(.semibold))
                Text(episode.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(episode.spokenWordCount) words · about \(formattedDuration(episode.estimatedDuration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ForEach(episode.turns) { turn in
                VStack(alignment: .leading, spacing: 5) {
                    Text(turn.speaker.displayName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(turn.speaker == .hostA ? Color.accentColor : Color.orange)
                    Text(turn.text)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func playbackControls(for episode: PodcastEpisode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button {
                    switch playbackController.state {
                    case .playing:
                        playbackController.pause()
                    case .paused:
                        playbackController.resume()
                    default:
                        playbackController.play(
                            episode: episode,
                            hostAVoice: hostAVoice,
                            hostBVoice: hostBVoice,
                            speed: speed
                        )
                    }
                } label: {
                    Label(playbackLabel, systemImage: playbackIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(playbackController.state == .saving || isPreparingExport || isSavingToResearchLibrary || !KokoroTTSService.shared.isAvailable)
                .accessibilityLabel(playbackLabel)

                Button {
                    playbackController.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!playbackController.state.isBusy)
                .accessibilityLabel("Stop podcast playback")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    savePodcastButton(for: episode)
                    saveToResearchLibraryButton(for: episode)
                }
                VStack(alignment: .leading, spacing: 10) {
                    savePodcastButton(for: episode)
                    saveToResearchLibraryButton(for: episode)
                }
            }

            if let exportConfirmation {
                Label(exportConfirmation, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if playbackController.state.isBusy || playbackController.state == .finished {
                ProgressView(value: playbackController.progress)
                Text(playbackController.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = playbackController.errorMessage {
                errorCard(error)
            }
            if session.savedScriptArtifactID == nil {
                Text(runID == nil ? "Save the batch to Research Library before saving this script or audio there. You can still export the podcast WAV to Files." : "The script will be linked to this batch revision when generated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func savePodcastButton(for episode: PodcastEpisode) -> some View {
        Button {
            exportPodcast(episode)
        } label: {
            if isPreparingExport {
                ProgressView()
            } else {
                Label("Save Podcast…", systemImage: "folder.badge.plus")
            }
        }
        .buttonStyle(.bordered)
        .disabled(isPreparingExport || isSavingToResearchLibrary || !KokoroTTSService.shared.isAvailable)
        .accessibilityLabel("Save podcast WAV")
        .accessibilityHint("Opens the system file picker and exports a complete WAV file")
    }

    private func saveToResearchLibraryButton(for episode: PodcastEpisode) -> some View {
        Button {
            saveToResearchLibrary(episode)
        } label: {
            if isSavingToResearchLibrary {
                ProgressView()
            } else {
                Label(savedAudioAssetID == nil ? "Save to Research Library" : "Saved to Research Library", systemImage: savedAudioAssetID == nil ? "books.vertical" : "checkmark.circle.fill")
            }
        }
        .buttonStyle(.bordered)
        .disabled(isPreparingExport || isSavingToResearchLibrary || savedAudioAssetID != nil || session.savedScriptArtifactID == nil || runID == nil || !KokoroTTSService.shared.isAvailable)
        .accessibilityLabel(savedAudioAssetID == nil ? "Save podcast audio to Research Library" : "Podcast audio saved to Research Library")
    }

    private var playbackLabel: String {
        switch playbackController.state {
        case .playing: return "Pause"
        case .paused: return "Resume"
        default: return "Play"
        }
    }

    private var playbackIcon: String {
        switch playbackController.state {
        case .playing: return "pause.fill"
        case .paused: return "play.fill"
        default: return "play.fill"
        }
    }

    private var canGenerate: Bool {
        !context.commentChunks.isEmpty || allowSummariesOnlyFallback
    }

    private func generate() {
        guard canGenerate else { return }
        saveTask?.cancel()
        playbackController.stop()
        savedAudioAssetID = nil
        exportConfirmation = nil
        session.generate(context: context)
    }

    private func cancelGeneration() {
        session.cancelGeneration()
    }

    private func exportPodcast(_ episode: PodcastEpisode) {
        saveTask?.cancel()
        session.generationError = nil
        exportConfirmation = nil
        isPreparingExport = true
        saveTask = Task { @MainActor in
            var temporaryFileURL: URL?
            defer {
                if let temporaryFileURL {
                    removeExportTemporaryDirectory(for: temporaryFileURL)
                }
                isPreparingExport = false
            }
            do {
                let fileURL = try await playbackController.renderEpisodeForExport(
                    episode,
                    hostAVoice: hostAVoice,
                    hostBVoice: hostBVoice,
                    speed: speed
                )
                temporaryFileURL = fileURL
                try Task.checkCancellation()
                let didExport = try PodcastWAVSavePanel.export(
                    sourceURL: fileURL,
                    suggestedFileName: fileURL.lastPathComponent
                )
                if didExport {
                    exportConfirmation = "Podcast WAV saved."
                }
            } catch is CancellationError {
            } catch {
                session.generationError = error.localizedDescription
            }
        }
    }

    private func saveToResearchLibrary(_ episode: PodcastEpisode) {
        guard let runID, let artifactID = session.savedScriptArtifactID else {
            session.generationError = BatchPodcastError.researchRunUnavailable.localizedDescription
            return
        }
        saveTask?.cancel()
        session.generationError = nil
        isSavingToResearchLibrary = true
        saveTask = Task { @MainActor in
            do {
                let assetID = try await playbackController.saveEpisode(
                    episode,
                    hostAVoice: hostAVoice,
                    hostBVoice: hostBVoice,
                    speed: speed,
                    runID: runID,
                    artifactID: artifactID
                ) { _, _ in }
                savedAudioAssetID = assetID
                isSavingToResearchLibrary = false
            } catch is CancellationError {
                isSavingToResearchLibrary = false
            } catch {
                session.generationError = error.localizedDescription
                isSavingToResearchLibrary = false
            }
        }
    }

    private func removeExportTemporaryDirectory(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix("redapp-podcast-export-") else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func errorCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func generationFraction(_ progress: BatchPodcastProgress) -> Double {
        switch progress {
        case let .analyzingComments(current, total):
            return 0.55 * Double(current) / Double(max(total, 1))
        case .consolidatingEvidence: return 0.65
        case .outlining: return 0.75
        case .writingScript: return 0.86
        case .repairingJSON: return 0.92
        case .validating: return 0.97
        case .complete: return 1
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    private static func contrastingVoice(for selected: KokoroVoice) -> KokoroVoice {
        if let voice = KokoroVoice.allCases.first(where: { $0 != selected && $0 == .marius }) {
            return voice
        }
        return KokoroVoice.allCases.first(where: { $0 != selected }) ?? selected
    }
}
