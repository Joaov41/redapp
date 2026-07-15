#if os(macOS)
import SwiftUI

struct ScheduledSummaryCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Research") {
            Button("Scheduled Summaries…") {
                openWindow(id: ScheduledSummaryManager.windowID)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }
    }
}

@MainActor
struct ScheduledSummariesView: View {
    @ObservedObject private var manager = ScheduledSummaryManager.shared
    @State private var selectedScheduleID: UUID?
    @State private var draft: ScheduledSummaryDefinition?
    @State private var isCreating = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedScheduleID) {
                Section("Schedules") {
                    ForEach(manager.schedules) { schedule in
                        ScheduledSummarySidebarRow(schedule: schedule)
                            .tag(schedule.id)
                            .contextMenu {
                                Button(schedule.isEnabled ? "Pause" : "Enable") {
                                    manager.setEnabled(!schedule.isEnabled, scheduleID: schedule.id)
                                }
                                Button("Run Now") { manager.runNow(scheduleID: schedule.id) }
                                    .disabled(manager.activeExecutionID != nil)
                                Divider()
                                Button("Delete", role: .destructive) {
                                    manager.delete(scheduleID: schedule.id)
                                    if selectedScheduleID == schedule.id { selectedScheduleID = nil }
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Scheduled Summaries")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: createDraft) {
                        Label("New Schedule", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let draft {
                ScheduledSummaryEditorView(
                    draft: Binding(
                        get: { self.draft ?? draft },
                        set: { self.draft = $0 }
                    ),
                    isCreating: isCreating,
                    executions: manager.executions.filter { $0.scheduleID == draft.id },
                    onSave: saveDraft,
                    onCancel: cancelDraft,
                    onRunNow: {
                        saveDraft()
                        manager.runNow(scheduleID: draft.id)
                    }
                )
            } else {
                ContentUnavailableView {
                    Label("No Schedule Selected", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Create a schedule to save recurring subreddit summaries with comments to Research Library.")
                } actions: {
                    Button("Create Schedule", action: createDraft)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            manager.start()
            if selectedScheduleID == nil { selectedScheduleID = manager.schedules.first?.id }
            loadSelectedDraft()
        }
        .onChange(of: selectedScheduleID) { _, _ in loadSelectedDraft() }
        .alert("Scheduled Summaries", isPresented: Binding(
            get: { manager.lastError != nil },
            set: { if !$0 { manager.lastError = nil } }
        )) {
            Button("OK") { manager.lastError = nil }
        } message: {
            Text(manager.lastError ?? "Unknown error")
        }
        .sheet(isPresented: Binding(
            get: { manager.presentedResearchRunID != nil },
            set: { if !$0 { manager.presentedResearchRunID = nil } }
        )) {
            if let runID = manager.presentedResearchRunID {
                NavigationStack {
                    ResearchRunDetailView(runID: runID)
                        .frame(minWidth: 760, minHeight: 680)
                }
            }
        }
    }

    private func loadSelectedDraft() {
        guard let selectedScheduleID,
              let selected = manager.schedules.first(where: { $0.id == selectedScheduleID }) else {
            if !isCreating { draft = nil }
            return
        }
        draft = selected
        isCreating = false
    }

    private func createDraft() {
        let schedule = ScheduledSummaryDefinition()
        draft = schedule
        selectedScheduleID = schedule.id
        isCreating = true
    }

    private func saveDraft() {
        guard let draft else { return }
        do {
            try manager.upsert(draft)
            isCreating = false
            selectedScheduleID = draft.id
            self.draft = manager.schedules.first(where: { $0.id == draft.id })
        } catch {
            manager.lastError = error.localizedDescription
        }
    }

    private func cancelDraft() {
        if isCreating {
            selectedScheduleID = manager.schedules.first?.id
        }
        isCreating = false
        loadSelectedDraft()
    }
}

private struct ScheduledSummarySidebarRow: View {
    let schedule: ScheduledSummaryDefinition

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: schedule.isEnabled ? "calendar.badge.clock" : "pause.circle")
                .foregroundStyle(schedule.isEnabled ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(schedule.isEnabled ? nextRunText : "Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var nextRunText: String {
        guard let next = schedule.nextRunAt else { return "Next run unavailable" }
        return "Next: \(next.formatted(date: .abbreviated, time: .shortened))"
    }
}

@MainActor
private struct ScheduledSummaryEditorView: View {
    @ObservedObject private var manager = ScheduledSummaryManager.shared
    @Binding var draft: ScheduledSummaryDefinition
    let isCreating: Bool
    let executions: [ScheduledSummaryExecution]
    let onSave: () -> Void
    let onCancel: () -> Void
    let onRunNow: () -> Void

    private let weekdaySymbols = Calendar.current.shortWeekdaySymbols

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                backgroundServiceCard
                Form {
                    Section("What to summarize") {
                        TextField("Schedule name", text: $draft.name, prompt: Text("r/\(draft.normalizedSubreddit) summary"))
                        HStack {
                            Text("r/")
                                .foregroundStyle(.secondary)
                            TextField("Subreddit", text: $draft.subreddit)
                        }
                        Picker("Feed", selection: Binding(
                            get: { draft.feedType },
                            set: { draft.feedType = $0 }
                        )) {
                            Text("New").tag(PostType.new)
                            Text("Hot").tag(PostType.hot)
                            Text("Top").tag(PostType.top)
                        }
                        if draft.feedType == .top {
                            Picker("Top period", selection: Binding(
                                get: { draft.topTimeRange },
                                set: { draft.topTimeRange = $0 }
                            )) {
                                ForEach(TopPostTimeRange.allCases) { range in
                                    Text(range.displayName).tag(range)
                                }
                            }
                        }
                        Stepper("Posts: \(draft.postLimit)", value: $draft.postLimit, in: 1...100)
                        LabeledContent("Comments") {
                            Text("Required · up to \(ScheduledSummaryRunner.analyzedCommentLimit) per post")
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("When") {
                        Picker("Repeat", selection: $draft.recurrence) {
                            ForEach(ScheduledSummaryRecurrence.allCases) { recurrence in
                                Text(recurrence.displayName).tag(recurrence)
                            }
                        }
                        if draft.recurrence == .customDays {
                            HStack {
                                ForEach(1...7, id: \.self) { weekday in
                                    Toggle(weekdaySymbols[weekday - 1], isOn: Binding(
                                        get: { draft.weekdays.contains(weekday) },
                                        set: { enabled in
                                            if enabled { draft.weekdays.insert(weekday) }
                                            else { draft.weekdays.remove(weekday) }
                                        }
                                    ))
                                    .toggleStyle(.button)
                                    .controlSize(.small)
                                }
                            }
                        }
                        DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                        Picker("Time zone", selection: $draft.timeZoneID) {
                            ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { zone in
                                Text(zone.replacingOccurrences(of: "_", with: " ")).tag(zone)
                            }
                        }
                    }

                    Section("Generation") {
                        Picker("Summary provider", selection: $draft.provider) {
                            ForEach(SummaryProvider.allCases.filter { $0 != .webAI }, id: \.rawValue) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        Text("Web AI is unavailable because scheduled work must run without an interactive browser.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("Notify when the run finishes", isOn: $draft.notificationsEnabled)
                        Toggle("Schedule enabled", isOn: $draft.isEnabled)
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Button(isCreating ? "Create Schedule" : "Save Changes", action: onSave)
                        .buttonStyle(.borderedProminent)
                    Button("Cancel", action: onCancel)
                    Spacer()
                    Button("Run Now", action: onRunNow)
                        .disabled(manager.activeExecutionID != nil || draft.normalizedSubreddit.isEmpty)
                }

                executionHistory
            }
            .padding(24)
        }
        .background(Color.black)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isCreating ? "New scheduled summary" : draft.displayName)
                .font(.largeTitle.bold())
            Text("The app will fetch every returned post’s comments, write the individual summaries, create the overall subreddit overview, and save a new Research Library revision.")
                .foregroundStyle(.secondary)
        }
    }

    private var backgroundServiceCard: some View {
        HStack(spacing: 12) {
            Image(systemName: manager.backgroundServiceStatus == "Allowed in Background" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(manager.backgroundServiceStatus == "Allowed in Background" ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(manager.backgroundServiceStatus)
                    .font(.headline)
                Text("The Mac must be on and you must be logged in. A missed run executes once after wake or login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if manager.backgroundServiceStatus != "Allowed in Background" {
                Button("Allow in Background") {
                    manager.registerBackgroundAgent()
                    manager.openLoginItemsSettings()
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var executionHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("History")
                .font(.title2.bold())
            if executions.isEmpty {
                Text("No scheduled runs yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(executions) { execution in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: executionIcon(execution.state))
                                .foregroundStyle(executionColor(execution.state))
                            Text(execution.state.displayName)
                                .font(.headline)
                            Spacer()
                            Text(execution.scheduledFor.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        if execution.state == .running {
                            ProgressView(value: execution.progress)
                        }
                        Text(execution.failureMessage ?? execution.status)
                            .font(.subheadline)
                            .foregroundStyle(execution.state == .failed ? .orange : .secondary)
                        if let coverage = execution.coverage {
                            Text("\(coverage.postsAnalyzed) posts · \(coverage.commentsAnalyzed) comments analyzed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let runID = execution.researchRunID {
                            Button("Open saved revision") { manager.presentedResearchRunID = runID }
                                .buttonStyle(.link)
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                var calendar = Calendar.current
                calendar.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current
                return calendar.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                var calendar = Calendar.current
                calendar.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current
                draft.hour = calendar.component(.hour, from: date)
                draft.minute = calendar.component(.minute, from: date)
            }
        )
    }

    private func executionIcon(_ state: ScheduledSummaryExecutionState) -> String {
        switch state {
        case .queued: return "clock"
        case .running: return "progress.indicator"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func executionColor(_ state: ScheduledSummaryExecutionState) -> Color {
        switch state {
        case .queued: return .secondary
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .orange
        }
    }
}
#endif
