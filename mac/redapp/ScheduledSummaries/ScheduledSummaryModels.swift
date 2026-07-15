#if os(macOS)
import Foundation

enum ScheduledSummaryRecurrence: String, Codable, CaseIterable, Identifiable {
    case daily
    case weekdays
    case customDays

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daily: return "Every day"
        case .weekdays: return "Weekdays"
        case .customDays: return "Selected days"
        }
    }
}

enum ScheduledSummaryExecutionState: String, Codable {
    case queued
    case running
    case succeeded
    case failed

    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .succeeded: return "Complete"
        case .failed: return "Failed"
        }
    }
}

struct ScheduledSummaryDefinition: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var subreddit: String
    var feedTypeRawValue: String
    var topTimeRangeRawValue: String
    var postLimit: Int
    var recurrence: ScheduledSummaryRecurrence
    var weekdays: Set<Int>
    var hour: Int
    var minute: Int
    var timeZoneID: String
    var provider: SummaryProvider
    var notificationsEnabled: Bool
    var isEnabled: Bool
    var nextRunAt: Date?
    var lastRunAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        subreddit: String = "",
        feedType: PostType = .new,
        topTimeRange: TopPostTimeRange = .day,
        postLimit: Int = 25,
        recurrence: ScheduledSummaryRecurrence = .daily,
        weekdays: Set<Int> = [2],
        hour: Int = 9,
        minute: Int = 0,
        timeZoneID: String = TimeZone.current.identifier,
        provider: SummaryProvider = SummaryService.shared.settings.selectedSummaryProvider,
        notificationsEnabled: Bool = true,
        isEnabled: Bool = true,
        nextRunAt: Date? = nil,
        lastRunAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subreddit = subreddit
        self.feedTypeRawValue = feedType.rawValue
        self.topTimeRangeRawValue = topTimeRange.rawValue
        self.postLimit = postLimit
        self.recurrence = recurrence
        self.weekdays = weekdays
        self.hour = hour
        self.minute = minute
        self.timeZoneID = timeZoneID
        self.provider = provider
        self.notificationsEnabled = notificationsEnabled
        self.isEnabled = isEnabled
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var feedType: PostType {
        get { PostType(rawValue: feedTypeRawValue) ?? .new }
        set { feedTypeRawValue = newValue.rawValue }
    }

    var topTimeRange: TopPostTimeRange {
        get { TopPostTimeRange(rawValue: topTimeRangeRawValue) ?? .day }
        set { topTimeRangeRawValue = newValue.rawValue }
    }

    var normalizedSubreddit: String {
        subreddit
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^/?r/", with: "", options: [.regularExpression, .caseInsensitive])
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "r/\(normalizedSubreddit) summary" : trimmed
    }

    var feedDescription: String {
        feedType == .top ? "Top · \(topTimeRange.displayName)" : feedType.displayName
    }

    func nextOccurrence(after date: Date) -> Date? {
        guard isEnabled else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        let allowedWeekdays: Set<Int>
        switch recurrence {
        case .daily:
            allowedWeekdays = Set(1...7)
        case .weekdays:
            allowedWeekdays = Set(2...6)
        case .customDays:
            allowedWeekdays = weekdays.isEmpty ? [calendar.component(.weekday, from: date)] : weekdays
        }

        var searchStart = date
        for _ in 0..<9 {
            var components = DateComponents()
            components.hour = min(max(hour, 0), 23)
            components.minute = min(max(minute, 0), 59)
            components.second = 0
            guard let candidate = calendar.nextDate(
                after: searchStart,
                matching: components,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            ) else { return nil }
            if allowedWeekdays.contains(calendar.component(.weekday, from: candidate)) {
                return candidate
            }
            searchStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: candidate)) ?? candidate
        }
        return nil
    }
}

struct ScheduledSummaryExecution: Codable, Identifiable, Hashable {
    var id: UUID
    var scheduleID: UUID
    var scheduleName: String
    var subreddit: String
    var scheduledFor: Date
    var state: ScheduledSummaryExecutionState
    var progress: Double
    var status: String
    var startedAt: Date?
    var completedAt: Date?
    var coverage: ResearchCoverageInput?
    var researchRunID: UUID?
    var failureMessage: String?

    init(
        id: UUID = UUID(),
        schedule: ScheduledSummaryDefinition,
        scheduledFor: Date,
        state: ScheduledSummaryExecutionState = .queued
    ) {
        self.id = id
        self.scheduleID = schedule.id
        self.scheduleName = schedule.displayName
        self.subreddit = schedule.normalizedSubreddit
        self.scheduledFor = scheduledFor
        self.state = state
        self.progress = 0
        self.status = state == .queued ? "Waiting to start" : state.displayName
    }
}

struct ScheduledSummaryPersistenceEnvelope: Codable {
    var schemaVersion = 1
    var schedules: [ScheduledSummaryDefinition] = []
    var executions: [ScheduledSummaryExecution] = []
}

struct ScheduledSummaryRunResult {
    let runID: UUID
    let coverage: ResearchCoverageInput
}
#endif
