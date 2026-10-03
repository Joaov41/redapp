#if os(iOS)
import Foundation
import ActivityKit

@available(iOS 16.1, *)
struct BatchSummaryAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String
        var processedPosts: Int
        var totalPosts: Int
        var progress: Double
    }

    var subreddit: String
}

@available(iOS 16.1, *)
final class BatchSummaryLiveActivityController {
    static let shared = BatchSummaryLiveActivityController()

    private let activityQueue = DispatchQueue(label: "com.redapp.reddit.batchsummary.liveactivity")
    private var currentActivity: Activity<BatchSummaryAttributes>?

    func start(subreddit: String, totalPosts: Int) {
        activityQueue.async { [weak self] in
            guard let self else { return }
            if self.currentActivity != nil {
                // End any in-flight activity before starting a new one
                Task {
                    await self.end(with: "Starting new batch", processedPosts: 0, totalPosts: totalPosts, dismissal: .immediate)
                }
            }

            let attributes = BatchSummaryAttributes(subreddit: subreddit)
            let initialState = BatchSummaryAttributes.ContentState(
                status: "Preparing batch summary…",
                processedPosts: 0,
                totalPosts: max(totalPosts, 1),
                progress: 0.0
            )

            let content = ActivityContent(state: initialState, staleDate: nil)
            do {
                self.currentActivity = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                print("Failed to start Live Activity for batch summary: \(error)")
            }
        }
    }

    func update(status: String, processedPosts: Int, totalPosts: Int, progress: Double) {
        activityQueue.async { [weak self] in
            guard let self, let activity = self.currentActivity else { return }
            let clampedProgress = max(0.0, min(1.0, progress))
            let state = BatchSummaryAttributes.ContentState(
                status: status,
                processedPosts: processedPosts,
                totalPosts: max(totalPosts, 1),
                progress: clampedProgress
            )
            let content = ActivityContent(state: state, staleDate: nil)

            Task {
                await activity.update(content)
            }
        }
    }

    func end(with status: String, processedPosts: Int, totalPosts: Int, dismissal: ActivityUIDismissalPolicy = .default) {
        activityQueue.async { [weak self] in
            guard let self, let activity = self.currentActivity else { return }
            let finalState = BatchSummaryAttributes.ContentState(
                status: status,
                processedPosts: processedPosts,
                totalPosts: max(totalPosts, 1),
                progress: min(1.0, Double(processedPosts) / Double(max(totalPosts, 1)))
            )
            let content = ActivityContent(state: finalState, staleDate: nil)

            Task {
                await activity.end(content, dismissalPolicy: dismissal)
            }
            self.currentActivity = nil
        }
    }

    func cancel(reason: String, processedPosts: Int, totalPosts: Int) {
        activityQueue.async { [weak self] in
            guard let self, let activity = self.currentActivity else { return }
            let state = BatchSummaryAttributes.ContentState(
                status: reason,
                processedPosts: processedPosts,
                totalPosts: max(totalPosts, 1),
                progress: min(1.0, Double(processedPosts) / Double(max(totalPosts, 1)))
            )
            let content = ActivityContent(state: state, staleDate: nil)

            Task {
                await activity.end(content, dismissalPolicy: .immediate)
            }
            self.currentActivity = nil
        }
    }
}
#endif
