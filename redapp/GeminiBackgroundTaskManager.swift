#if os(iOS)
import Foundation
import BackgroundTasks
import OSLog
import UIKit

/// Enhanced Background Task Manager for Gemini/AI operations
/// Supports both user-initiated (iOS 26+) and deferred background processing (iOS 13+)
/// Enables execution even when device is locked
final class GeminiBackgroundTaskManager {
    static let shared = GeminiBackgroundTaskManager()

    private let logger = Logger(subsystem: "com.redapp.reddit", category: "GeminiBackgroundTask")

    enum LongRunningTaskIdentifier {
        case geminiProcessing
        case summarization
    }

    // Task identifiers - must match Info.plist BGTaskSchedulerPermittedIdentifiers
    private let bundleIdentifierPrefix: String = {
        if let id = Bundle.main.bundleIdentifier, !id.isEmpty {
            return id
        }
        return "red.redapp"
    }()

    private var continuedTaskIdentifier: String { "\(bundleIdentifierPrefix).geminiTask" }
    private var processingTaskIdentifier: String { "\(bundleIdentifierPrefix).geminiProcessing" }
    private var summarizationTaskIdentifier: String { "\(bundleIdentifierPrefix).summarization" }
    private var refreshTaskIdentifier: String { "\(bundleIdentifierPrefix).geminiRefresh" }

    private let stateQueue = DispatchQueue(label: "com.redapp.reddit.backgroundTask.state")

    private var isRegistered = false
    private weak var activeHandle: GeminiBackgroundTaskHandle?
    private var dependentHandles: [ObjectIdentifier: GeminiBackgroundTaskHandle] = [:]
    private var activeTask: BGTask?

    // Track background processing tasks for locked device execution
    private var activeLongRunningTask: BGProcessingTask?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    private init() { }

    /// Register all background task handlers at app launch
    func prepareForLaunch() {
        registerAllHandlers()
        registerLifecycleObservers()
    }

    /// Begin a user-initiated background task (iOS 26+)
    /// For immediate tasks that should continue briefly when app backgrounds
    @available(iOS 26.0, *)
    func beginTask(title: String, subtitle: String, totalUnitCount: Int64 = 100) -> GeminiBackgroundTaskHandle? {
        registerAllHandlers()

        let handle: GeminiBackgroundTaskHandle = stateQueue.sync {
            let isRoot = self.activeHandle == nil
            let newHandle = GeminiBackgroundTaskHandle(manager: self, totalUnitCount: totalUnitCount, isRootHandle: isRoot)
            if isRoot {
                self.activeHandle = newHandle
            } else {
                self.dependentHandles[ObjectIdentifier(newHandle)] = newHandle
            }
            return newHandle
        }

        handle.reportProgress(completedUnitCount: 1)

        if handle.isRootHandle {
            handle.setRequiresSystemSignal(true)
            do {
                try submitContinuedRequest(title: title, subtitle: subtitle)
                handle.notifyTaskStarted()
            } catch {
                handle.setRequiresSystemSignal(false)
                handle.notifyTaskStarted()
                logger.error("❌ Failed to submit BGContinuedProcessingTaskRequest: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            logger.info("ℹ️ Reusing existing Gemini background task (dependent request)")
            handle.notifyTaskStarted()
        }
        return handle
    }

    /// Begin a long-running background task for immediate execution
    /// Uses UIBackgroundTask assertion (~30 sec) + iOS 26 BGContinuedProcessingTask (longer)
    /// This is for user-initiated actions (like tapping "Summarize" or "Ask Question")
    func beginLongRunningTask(identifier: LongRunningTaskIdentifier, title: String) -> GeminiBackgroundTaskHandle {
        let resolvedIdentifier: String
        switch identifier {
        case .geminiProcessing:
            resolvedIdentifier = processingTaskIdentifier
        case .summarization:
            resolvedIdentifier = summarizationTaskIdentifier
        }

        return beginLongRunningTask(identifier: resolvedIdentifier, title: title)
    }

    private func beginLongRunningTask(identifier: String, title: String) -> GeminiBackgroundTaskHandle {
        registerAllHandlers()

        let handle: GeminiBackgroundTaskHandle = stateQueue.sync {
            let isRoot = self.activeHandle == nil
            let newHandle = GeminiBackgroundTaskHandle(manager: self, totalUnitCount: 100, isRootHandle: isRoot)
            newHandle.taskIdentifier = identifier

            if isRoot {
                self.activeHandle = newHandle
            } else {
                self.dependentHandles[ObjectIdentifier(newHandle)] = newHandle
            }
            return newHandle
        }

        handle.taskIdentifier = identifier

        // Use iOS 26+ BGContinuedProcessingTask if available for extended execution
        if handle.isRootHandle {
            if #available(iOS 26.0, *) {
                handle.setRequiresSystemSignal(true)
                do {
                    try submitContinuedRequest(title: title, subtitle: "Background execution")
                    logger.info("✅ Submitted iOS 26+ continued processing task: \(title)")
                    submitProcessingRequest(identifier: identifier, title: title)
                    handle.notifyTaskStarted()
                } catch {
                    handle.setRequiresSystemSignal(false)
                    handle.notifyTaskStarted()
                    logger.error("❌ Failed to submit BGContinuedProcessingTaskRequest: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                // On iOS 13-25, UIBackgroundTask gives us ~30 seconds
                // For longer tasks, you'd need to restructure to use BGProcessingTask differently
                handle.notifyTaskStarted()
                logger.info("✅ Started background task (30 sec protection): \(title)")
            }
        } else {
            logger.info("ℹ️ Attached dependent Gemini task '\(title)' to existing background session")
            handle.notifyTaskStarted()
        }

        return handle
    }

    private func registerAllHandlers() {
        guard !isRegistered else { return }

        logger.info("🔧 Registering background task handlers...")

        // Register iOS 26+ continued processing task
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedTaskIdentifier, using: nil) { [weak self] task in
                guard let self else { return }
                self.configureContinuedTask(task: task)
            }
            logger.info("✅ Registered: \(self.continuedTaskIdentifier)")
        }

        // Register BGProcessingTask for long-running work (works when locked)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskIdentifier, using: nil) { [weak self] task in
            guard let self else { return }
            self.configureProcessingTask(task: task as! BGProcessingTask)
        }

        // Register summarization BGProcessingTask (used by batch summarize)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: summarizationTaskIdentifier, using: nil) { [weak self] task in
            guard let self else { return }
            self.configureProcessingTask(task: task as! BGProcessingTask)
        }

        // Register BGAppRefreshTask for periodic updates
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) { [weak self] task in
            guard let self else { return }
            self.configureRefreshTask(task: task as! BGAppRefreshTask)
        }

        isRegistered = true
        logger.info("✅ Registered all background task handlers (4 total)")
    }

    private func registerLifecycleObservers() {
        guard backgroundObserver == nil else { return }

        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.handlesSnapshot().forEach { $0.applicationDidEnterBackground() }
        }

        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.handlesSnapshot().forEach { $0.applicationWillEnterForeground() }
        }
    }

    @available(iOS 26.0, *)
    private func configureContinuedTask(task: BGTask) {
        logger.info("Configured BGContinuedProcessingTask handler")

        self.stateQueue.sync {
            self.activeTask = task
        }

        task.expirationHandler = { [weak self] in
            guard let self else { return }

            self.notifyAllHandlesOfCancellation()

            self.stateQueue.sync {
                self.activeTask?.setTaskCompleted(success: false)
                self.activeTask = nil
                self.activeLongRunningTask?.setTaskCompleted(success: false)
                self.activeLongRunningTask = nil
                self.activeHandle = nil
                self.dependentHandles.removeAll()
            }

            self.logger.info("Gemini background task expired or cancelled by system")
        }

        if let continuedTask = task as? BGContinuedProcessingTask,
           let handle = self.stateQueue.sync(execute: { self.activeHandle }) {
            continuedTask.progress.totalUnitCount = handle.progress.totalUnitCount
            continuedTask.progress.completedUnitCount = handle.progress.completedUnitCount
            handle.attach(taskProgress: continuedTask.progress)
            handle.notifyTaskStarted(releaseBackgroundAssertion: true)
        }
    }

    private func configureProcessingTask(task: BGProcessingTask) {
        logger.info("🔄 Configured BGProcessingTask handler (works when locked)")

        self.stateQueue.sync {
            self.activeLongRunningTask = task
        }

        // Allow the task to run even when device is locked
        task.expirationHandler = { [weak self] in
            guard let self else { return }

            self.notifyAllHandlesOfCancellation()

            self.stateQueue.sync {
                self.activeLongRunningTask?.setTaskCompleted(success: false)
                self.activeLongRunningTask = nil
                self.activeHandle = nil
                self.dependentHandles.removeAll()
            }

            self.logger.warning("⚠️ BGProcessingTask expired (this shouldn't happen for long tasks)")
        }

        // Notify handle that task is ready
        if let handle = self.stateQueue.sync(execute: { self.activeHandle }) {
            handle.notifyTaskStarted(releaseBackgroundAssertion: true)
        }
    }

    private func configureRefreshTask(task: BGAppRefreshTask) {
        logger.info("🔄 Configured BGAppRefreshTask handler")

        task.expirationHandler = { [weak self] in
            self?.logger.info("BGAppRefreshTask expired")
            task.setTaskCompleted(success: false)
        }

        // This is for periodic refresh - implement your logic here if needed
        task.setTaskCompleted(success: true)
    }

    @available(iOS 26.0, *)
    private func submitContinuedRequest(title: String, subtitle: String) throws {
        let request = BGContinuedProcessingTaskRequest(identifier: continuedTaskIdentifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        try BGTaskScheduler.shared.submit(request)
        logger.info("✅ Submitted BGContinuedProcessingTaskRequest for Gemini operation")
    }

    private func submitProcessingRequest(identifier: String, title: String) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true  // Gemini API needs network
        request.requiresExternalPower = false  // Allow on battery
        request.earliestBeginDate = Date()  // Start ASAP

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("✅ Submitted BGProcessingTaskRequest '\(identifier)' (works when locked)")
        } catch {
            logger.error("❌ Failed to submit BGProcessingTaskRequest: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Schedule a periodic background refresh task
    func schedulePeriodicRefresh(earliestBeginDate: Date? = nil) {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = earliestBeginDate ?? Date(timeIntervalSinceNow: 15 * 60) // Default: 15 minutes

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("✅ Scheduled periodic refresh task")
        } catch {
            logger.error("❌ Failed to schedule refresh task: \(error.localizedDescription)")
        }
    }

    fileprivate func complete(_ handle: GeminiBackgroundTaskHandle, success: Bool) {
        self.stateQueue.sync {
            guard self.activeHandle === handle else {
                self.logger.info("Ignoring completion for non-root Gemini handle")
                return
            }

            // Complete whichever task is active
            self.activeTask?.setTaskCompleted(success: success)
            self.activeLongRunningTask?.setTaskCompleted(success: success)

            self.activeTask = nil
            self.activeLongRunningTask = nil
            self.activeHandle = nil
            self.dependentHandles.removeAll()
        }

        self.logger.info("✅ Gemini background task finished with success = \(success ? "true" : "false")")
    }

    fileprivate func completeDependent(_ handle: GeminiBackgroundTaskHandle, success: Bool) {
        self.stateQueue.sync {
            self.dependentHandles.removeValue(forKey: ObjectIdentifier(handle))
        }
        self.logger.info("✅ Gemini dependent task finished with success = \(success ? "true" : "false")")
    }

    /// Cancel all pending background tasks
    func cancelAllPendingTasks() {
        notifyAllHandlesOfCancellation()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedTaskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingTaskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: summarizationTaskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskIdentifier)
        stateQueue.sync {
            activeHandle = nil
            dependentHandles.removeAll()
            activeTask = nil
            activeLongRunningTask = nil
        }
        logger.info("🚫 Cancelled all pending background tasks")
    }

    private func handlesSnapshot() -> [GeminiBackgroundTaskHandle] {
        return stateQueue.sync {
            var handles: [GeminiBackgroundTaskHandle] = []
            if let root = self.activeHandle {
                handles.append(root)
            }
            handles.append(contentsOf: self.dependentHandles.values)
            return handles
        }
    }

    private func notifyAllHandlesOfCancellation() {
        let handles = handlesSnapshot()
        handles.forEach { $0.notifyCancellation() }
    }
}

/// Handle for tracking and controlling a background Gemini task
final class GeminiBackgroundTaskHandle {
    fileprivate let progress: Progress
    private var taskProgress: Progress?
    private weak var manager: GeminiBackgroundTaskManager?
    private let stateLock = NSLock()

    private var cancellationHandlers: [() -> Void] = []
    private(set) var isCancelled = false
    private var finished = false
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var started = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var requiresSystemSignal = false
    private var backgroundReleaseWorkItem: DispatchWorkItem?
    fileprivate let isRootHandle: Bool

    // Track the task identifier for long-running tasks
    var taskIdentifier: String?

    // Callback when background processing task actually starts
    var onTaskStarted: (() -> Void)?

    fileprivate init(manager: GeminiBackgroundTaskManager, totalUnitCount: Int64, isRootHandle: Bool) {
        self.manager = manager
        self.progress = Progress(totalUnitCount: totalUnitCount)
        self.isRootHandle = isRootHandle
        // Only root handles should create UIBackgroundTask assertions
        // Dependent handles reuse the root's background protection to avoid conflicts
        if isRootHandle {
            beginBackgroundAssertion()
        }
    }

    func reportProgress(fractionCompleted fraction: Double) {
        stateLock.lock()
        let clampedFraction = max(0, min(1, fraction))
        progress.completedUnitCount = Int64(Double(progress.totalUnitCount) * clampedFraction)
        taskProgress?.completedUnitCount = progress.completedUnitCount
        stateLock.unlock()
    }

    func reportProgress(completedUnitCount: Int64) {
        stateLock.lock()
        let clamped = max(0, min(completedUnitCount, progress.totalUnitCount))
        progress.completedUnitCount = clamped
        taskProgress?.completedUnitCount = clamped
        stateLock.unlock()
    }

    func registerCancellationHandler(_ handler: @escaping () -> Void) {
        stateLock.lock()
        cancellationHandlers.append(handler)
        let shouldCallImmediately = isCancelled
        stateLock.unlock()

        if shouldCallImmediately {
            handler()
        }
    }

    fileprivate func setRequiresSystemSignal(_ value: Bool) {
        stateLock.lock()
        requiresSystemSignal = value
        stateLock.unlock()
    }

    fileprivate func notifyCancellation() {
        stateLock.lock()
        guard !isCancelled else {
            stateLock.unlock()
            return
        }
        isCancelled = true
        let handlers = cancellationHandlers
        let taskId = taskIdentifier ?? "unknown"
        let isRoot = isRootHandle
        stateLock.unlock()

        print("⚠️ [BackgroundTask] Cancellation triggered for \(isRoot ? "ROOT" : "dependent") handle (\(taskId)), calling \(handlers.count) handlers")
        handlers.forEach { $0() }
        resumePendingStartContinuation()
        endBackgroundAssertionIfNeeded()
    }

    var cancelled: Bool {
        stateLock.lock()
        let cancelled = isCancelled
        stateLock.unlock()
        return cancelled
    }

    func waitForTaskStartIfNeeded() async {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            stateLock.lock()
            let shouldWait = requiresSystemSignal && !started
            stateLock.unlock()

            guard shouldWait else { return }

            await withCheckedContinuation { continuation in
                stateLock.lock()
                if started || !requiresSystemSignal {
                    stateLock.unlock()
                    continuation.resume()
                    return
                }
                startContinuation = continuation
                stateLock.unlock()
            }
        }
        #else
        return
        #endif
    }

    func finish(success: Bool) {
        stateLock.lock()
        guard !finished else {
            stateLock.unlock()
            return
        }
        finished = true
        taskProgress = nil
        stateLock.unlock()

        if isRootHandle {
            manager?.complete(self, success: success)
        } else {
            manager?.completeDependent(self, success: success)
        }
        endBackgroundAssertionIfNeeded()
    }

    fileprivate func attach(taskProgress: Progress) {
        stateLock.lock()
        taskProgress.totalUnitCount = progress.totalUnitCount
        taskProgress.completedUnitCount = progress.completedUnitCount
        self.taskProgress = taskProgress
        stateLock.unlock()
    }

    fileprivate func notifyTaskStarted(releaseBackgroundAssertion: Bool = false) {
        var continuation: CheckedContinuation<Void, Never>?
        var shouldInvokeCallback = false
        var callback: (() -> Void)?
        let shouldReleaseAssertion = releaseBackgroundAssertion

        stateLock.lock()
        if !started {
            started = true
            requiresSystemSignal = false
            continuation = startContinuation
            startContinuation = nil
            shouldInvokeCallback = true
        }
        callback = onTaskStarted
        stateLock.unlock()

        continuation?.resume()

        if shouldInvokeCallback {
            callback?()
        }

        if shouldReleaseAssertion {
            endBackgroundAssertionIfNeeded()
        }
    }

    private func beginBackgroundAssertion() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.stateLock.lock()
            let alreadyActive = self.backgroundTaskIdentifier != .invalid
            self.stateLock.unlock()

            guard !alreadyActive else { return }

            let application = UIApplication.shared
            let identifier = application.beginBackgroundTask(withName: "GeminiSummary") { [weak self] in
                self?.handleBackgroundTaskExpiration()
            }

            self.stateLock.lock()
            self.backgroundTaskIdentifier = identifier
            self.stateLock.unlock()

            self.scheduleBackgroundAssertionReleaseIfNeeded()
        }
    }

    private func handleBackgroundTaskExpiration() {
        notifyCancellation()
        endBackgroundAssertionIfNeeded()
    }

    private func endBackgroundAssertionIfNeeded() {
        let identifier: UIBackgroundTaskIdentifier
        stateLock.lock()
        identifier = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        stateLock.unlock()

        guard identifier != .invalid else { return }

        backgroundReleaseWorkItem?.cancel()
        backgroundReleaseWorkItem = nil

        DispatchQueue.main.async {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }

    private func resumePendingStartContinuation() {
        var continuation: CheckedContinuation<Void, Never>?

        stateLock.lock()
        continuation = startContinuation
        startContinuation = nil
        requiresSystemSignal = false
        stateLock.unlock()

        continuation?.resume()
    }

    func applicationDidEnterBackground() {
        scheduleBackgroundAssertionReleaseIfNeeded()
    }

    func applicationWillEnterForeground() {
        stateLock.lock()
        let shouldCancel = backgroundReleaseWorkItem != nil
        stateLock.unlock()

        guard shouldCancel else { return }

        backgroundReleaseWorkItem?.cancel()
        backgroundReleaseWorkItem = nil
    }

    private func scheduleBackgroundAssertionReleaseIfNeeded() {
        stateLock.lock()
        let identifier = backgroundTaskIdentifier
        stateLock.unlock()

        guard identifier != .invalid else { return }
        guard UIApplication.shared.applicationState != .active else { return }

        backgroundReleaseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.endBackgroundAssertionIfNeeded()
        }
        backgroundReleaseWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: workItem)
    }
}
#endif
