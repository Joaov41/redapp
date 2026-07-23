#if os(macOS)
import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications

enum ScheduledSummaryManagerError: LocalizedError {
    case invalidSubreddit
    case invalidPostLimit
    case noSelectedDays

    var errorDescription: String? {
        switch self {
        case .invalidSubreddit: return "Enter a subreddit name."
        case .invalidPostLimit: return "Choose between 1 and 100 posts."
        case .noSelectedDays: return "Select at least one day for this schedule."
        }
    }
}

@MainActor
final class ScheduledSummaryManager: ObservableObject {
    static let shared = ScheduledSummaryManager()
    static let windowID = "scheduled-summaries"

    @Published private(set) var schedules: [ScheduledSummaryDefinition] = []
    @Published private(set) var executions: [ScheduledSummaryExecution] = []
    @Published private(set) var activeExecutionID: UUID?
    @Published private(set) var backgroundServiceStatus = "Not registered"
    @Published var lastError: String?
    @Published var presentedResearchRunID: UUID?

    private let store = ScheduledSummaryStore.shared
    private let runner = ScheduledSummaryRunner.shared
    private let agent = SMAppService.agent(plistName: "com.jv.redapp.scheduled-summary-agent.plist")
    private var timer: Timer?
    private var didStart = false

    nonisolated static func needsBackgroundAgent(for schedules: [ScheduledSummaryDefinition]) -> Bool {
        schedules.contains(where: \.isEnabled)
    }

    private init() {
        do {
            let loaded = try store.load()
            schedules = loaded.schedules
            executions = loaded.executions.map { execution in
                guard execution.state == .running || execution.state == .queued else { return execution }
                var interrupted = execution
                interrupted.state = .failed
                interrupted.status = "The previous run was interrupted."
                interrupted.failureMessage = "The Mac app stopped before the scheduled summary completed."
                interrupted.completedAt = Date()
                return interrupted
            }
            normalizeNextRuns()
            persist()
        } catch {
            lastError = error.localizedDescription
        }
        refreshAgentStatus()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        MacScheduledSummaryNotificationDelegate.install()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                await ScheduledSummaryManager.shared.checkForDueSchedules()
            }
        }
        // Reconcile both directions at launch. An earlier app version may have
        // left the helper registered even after every schedule was removed.
        refreshBackgroundRegistration()
        Task { await checkForDueSchedules() }
    }

    func upsert(_ value: ScheduledSummaryDefinition) throws {
        var schedule = value
        schedule.subreddit = schedule.normalizedSubreddit
        guard !schedule.subreddit.isEmpty else { throw ScheduledSummaryManagerError.invalidSubreddit }
        guard (1...100).contains(schedule.postLimit) else { throw ScheduledSummaryManagerError.invalidPostLimit }
        if schedule.recurrence == .customDays, schedule.weekdays.isEmpty {
            throw ScheduledSummaryManagerError.noSelectedDays
        }
        schedule.updatedAt = Date()
        schedule.nextRunAt = schedule.isEnabled ? schedule.nextOccurrence(after: Date()) : nil
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
        schedules.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        persist()
        refreshBackgroundRegistration()
        if schedule.notificationsEnabled {
            requestNotificationAuthorization()
        }
    }

    func delete(scheduleID: UUID) {
        schedules.removeAll { $0.id == scheduleID }
        persist()
        refreshBackgroundRegistration()
    }

    func setEnabled(_ enabled: Bool, scheduleID: UUID) {
        guard let index = schedules.firstIndex(where: { $0.id == scheduleID }) else { return }
        schedules[index].isEnabled = enabled
        schedules[index].updatedAt = Date()
        schedules[index].nextRunAt = enabled ? schedules[index].nextOccurrence(after: Date()) : nil
        persist()
        refreshBackgroundRegistration()
    }

    func runNow(scheduleID: UUID) {
        guard activeExecutionID == nil,
              let schedule = schedules.first(where: { $0.id == scheduleID }) else { return }
        Task { await execute(schedule: schedule, scheduledFor: Date()) }
    }

    func checkForDueSchedules(now: Date = Date()) async {
        guard activeExecutionID == nil else { return }
        normalizeNextRuns(referenceDate: now)
        guard let due = schedules
            .filter({ $0.isEnabled && ($0.nextRunAt ?? .distantFuture) <= now })
            .sorted(by: { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) })
            .first else {
            persist()
            return
        }
        await execute(schedule: due, scheduledFor: due.nextRunAt ?? now)
    }

    func handle(url: URL) -> Bool {
        guard url.scheme == "redapp" else { return false }
        switch url.host {
        case "scheduled-summary-check":
            Task { await checkForDueSchedules() }
            return true
        case "scheduled-summaries":
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let rawRunID = components.queryItems?.first(where: { $0.name == "runID" })?.value,
               let runID = UUID(uuidString: rawRunID) {
                presentedResearchRunID = runID
            }
            NSApp.activate(ignoringOtherApps: true)
            return true
        default:
            return false
        }
    }

    func registerBackgroundAgent() {
        do {
            if agent.status != .enabled {
                try agent.register()
            }
            refreshAgentStatus()
        } catch {
            lastError = "Scheduled summaries could not be enabled in the background: \(error.localizedDescription)"
            refreshAgentStatus()
        }
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func execute(schedule: ScheduledSummaryDefinition, scheduledFor: Date) async {
        guard activeExecutionID == nil else { return }
        var execution = ScheduledSummaryExecution(schedule: schedule, scheduledFor: scheduledFor, state: .running)
        execution.startedAt = Date()
        execution.status = "Starting scheduled summary…"
        executions.insert(execution, at: 0)
        activeExecutionID = execution.id

        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index].lastRunAt = Date()
            schedules[index].nextRunAt = schedules[index].nextOccurrence(after: max(Date(), scheduledFor))
        }
        persist()

        do {
            let result = try await runner.run(schedule: schedule) { [weak self] progress, status in
                guard let self,
                      let index = self.executions.firstIndex(where: { $0.id == execution.id }) else { return }
                self.executions[index].progress = min(max(progress, 0), 1)
                self.executions[index].status = status
                self.persist()
            }
            if let index = executions.firstIndex(where: { $0.id == execution.id }) {
                executions[index].state = .succeeded
                executions[index].progress = 1
                executions[index].status = "Saved to Research Library"
                executions[index].completedAt = Date()
                executions[index].coverage = result.coverage
                executions[index].researchRunID = result.runID
            }
            if schedule.notificationsEnabled {
                sendNotification(
                    title: "Scheduled summary complete",
                    body: "\(schedule.displayName) was saved to Research Library.",
                    runID: result.runID
                )
            }
        } catch {
            if let index = executions.firstIndex(where: { $0.id == execution.id }) {
                executions[index].state = .failed
                executions[index].status = "Scheduled summary failed"
                executions[index].failureMessage = error.localizedDescription
                executions[index].completedAt = Date()
            }
            if schedule.notificationsEnabled {
                sendNotification(
                    title: "Scheduled summary failed",
                    body: "\(schedule.displayName): \(error.localizedDescription)",
                    runID: nil
                )
            }
        }
        activeExecutionID = nil
        persist()
        await checkForDueSchedules()
    }

    private func normalizeNextRuns(referenceDate: Date = Date()) {
        for index in schedules.indices {
            if !schedules[index].isEnabled {
                schedules[index].nextRunAt = nil
            } else if schedules[index].nextRunAt == nil {
                schedules[index].nextRunAt = schedules[index].nextOccurrence(after: referenceDate)
            }
        }
    }

    private func persist() {
        do {
            try store.save(schedules: schedules, executions: executions)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshBackgroundRegistration() {
        if Self.needsBackgroundAgent(for: schedules) {
            registerBackgroundAgent()
        } else if agent.status == .enabled || agent.status == .requiresApproval {
            Task {
                do {
                    try await agent.unregister()
                } catch {
                    await MainActor.run { self.lastError = error.localizedDescription }
                }
                await MainActor.run { self.refreshAgentStatus() }
            }
        } else {
            refreshAgentStatus()
        }
    }

    private func refreshAgentStatus() {
        switch agent.status {
        case .enabled: backgroundServiceStatus = "Allowed in Background"
        case .requiresApproval: backgroundServiceStatus = "Approval required in Login Items"
        case .notRegistered: backgroundServiceStatus = "Not registered"
        case .notFound: backgroundServiceStatus = "Not registered"
        @unknown default: backgroundServiceStatus = "Unknown"
        }
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
        }
    }

    private func sendNotification(title: String, body: String, runID: UUID?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let runID { content.userInfo["runID"] = runID.uuidString }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

final class MacScheduledSummaryNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacScheduledSummaryNotificationDelegate()

    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let runID = response.notification.request.content.userInfo["runID"] as? String
        var components = URLComponents()
        components.scheme = "redapp"
        components.host = "scheduled-summaries"
        if let runID { components.queryItems = [URLQueryItem(name: "runID", value: runID)] }
        if let url = components.url { NSWorkspace.shared.open(url) }
        completionHandler()
    }
}
#endif
