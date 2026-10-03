#if os(iOS)
import Foundation
import Combine

@MainActor
final class BatchPodcastSession: ObservableObject {
    let service: BatchPodcastService
    let playbackController: MLXPodcastPlaybackController

    @Published private(set) var context: BatchPodcastContext?
    @Published private(set) var runID: UUID?
    @Published private(set) var episode: PodcastEpisode?
    @Published private(set) var generationProgress: BatchPodcastProgress?
    @Published var generationError: String?
    @Published private(set) var isGenerating = false
    @Published private(set) var savedScriptArtifactID: UUID?

    private var generationTask: Task<Void, Never>?
    private var generationID = UUID()

    init(
        service: BatchPodcastService = BatchPodcastService(),
        playbackController: MLXPodcastPlaybackController? = nil
    ) {
        self.service = service
        self.playbackController = playbackController ?? MLXPodcastPlaybackController()
    }

    func begin(context: BatchPodcastContext, runID: UUID?) {
        playbackController.stop()
        generationTask?.cancel()
        generationTask = nil
        generationID = UUID()
        self.context = context
        self.runID = runID
        episode = nil
        generationProgress = nil
        generationError = nil
        isGenerating = false
        savedScriptArtifactID = nil
    }

    func generate(context: BatchPodcastContext? = nil) {
        guard let context = context ?? self.context else { return }
        generationTask?.cancel()
        episode = nil
        savedScriptArtifactID = nil
        generationError = nil
        generationProgress = nil
        isGenerating = true
        let operationID = UUID()
        generationID = operationID

        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let generated = try await service.generateEpisode(from: context) { [weak self] update in
                    guard let self, self.generationID == operationID else { return }
                    self.generationProgress = update
                }
                try Task.checkCancellation()
                guard generationID == operationID else { return }
                episode = generated
                persistScript(generated, context: context)
                isGenerating = false
            } catch is CancellationError {
                isGenerating = false
                generationProgress = nil
            } catch {
                generationError = error.localizedDescription
                isGenerating = false
            }
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        generationID = UUID()
        isGenerating = false
        generationProgress = nil
    }

    func invalidate() {
        playbackController.stop()
        generationTask?.cancel()
        generationTask = nil
        generationID = UUID()
        episode = nil
        generationProgress = nil
        generationError = nil
        isGenerating = false
        savedScriptArtifactID = nil
        context = nil
        runID = nil
    }

    private func persistScript(_ episode: PodcastEpisode, context: BatchPodcastContext) {
        guard let runID else {
            generationError = BatchPodcastError.researchRunUnavailable.localizedDescription
            return
        }
        do {
            guard let run = try ResearchLibraryStore.shared.run(id: runID),
                  run.sourceDigest == episode.sourceDigest else {
                throw BatchPodcastError.digestMismatch
            }
            let artifact = try ResearchLibraryStore.shared.addArtifact(
                runID: runID,
                kind: .podcastScript,
                title: episode.title,
                body: ResearchJSON.encode(episode),
                format: "podcast-json",
                coverage: context.coverage
            )
            savedScriptArtifactID = artifact.id
        } catch {
            generationError = error.localizedDescription
        }
    }
}

@MainActor
enum BatchPodcastSessionStore {
    static let shared = BatchPodcastSession()
}
#endif
