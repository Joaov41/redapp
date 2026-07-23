#if os(macOS)
import Foundation
import XCTest
@testable import redapp

final class ScheduledSummaryTests: XCTestCase {
    func testDailyRecurrenceUsesConfiguredTimeZoneAndTime() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-15T08:30:00Z"))
        let schedule = ScheduledSummaryDefinition(
            subreddit: "SwiftUI",
            feedType: .hot,
            postLimit: 10,
            recurrence: .daily,
            hour: 9,
            minute: 15,
            timeZoneID: "UTC",
            provider: .gemini
        )

        XCTAssertEqual(
            schedule.nextOccurrence(after: start),
            ISO8601DateFormatter().date(from: "2026-07-15T09:15:00Z")
        )
    }

    func testCustomDayRecurrenceSkipsUnselectedDays() throws {
        let monday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-13T10:00:00Z"))
        let schedule = ScheduledSummaryDefinition(
            subreddit: "r/OpenAI",
            feedType: .top,
            topTimeRange: .week,
            postLimit: 50,
            recurrence: .customDays,
            weekdays: [4],
            hour: 9,
            minute: 0,
            timeZoneID: "UTC",
            provider: .summarizeDaemon
        )

        XCTAssertEqual(
            schedule.nextOccurrence(after: monday),
            ISO8601DateFormatter().date(from: "2026-07-15T09:00:00Z")
        )
        XCTAssertEqual(schedule.normalizedSubreddit, "OpenAI")
    }

    @MainActor
    func testScheduledSummariesAlwaysUseTheCommentAnalysisLimit() {
        XCTAssertEqual(ScheduledSummaryRunner.analyzedCommentLimit, 500)
    }

    func testBackgroundAgentIsNeededOnlyForAnEnabledSchedule() {
        let enabled = ScheduledSummaryDefinition(subreddit: "SwiftUI", isEnabled: true)
        let paused = ScheduledSummaryDefinition(subreddit: "OpenAI", isEnabled: false)

        XCTAssertFalse(ScheduledSummaryManager.needsBackgroundAgent(for: []))
        XCTAssertFalse(ScheduledSummaryManager.needsBackgroundAgent(for: [paused]))
        XCTAssertTrue(ScheduledSummaryManager.needsBackgroundAgent(for: [paused, enabled]))
    }

    func testMacAppEmbedsScheduledSummaryLaunchAgent() throws {
        let appBundle = Bundle.main.bundleURL
        let agentURL = appBundle
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.jv.redapp.scheduled-summary-agent.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: agentURL.path), agentURL.path)

        let propertyList = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: agentURL),
            options: [],
            format: nil
        )
        let values = try XCTUnwrap(propertyList as? [String: Any])
        XCTAssertEqual(values["Label"] as? String, "com.jv.redapp.scheduled-summary-agent")
        XCTAssertEqual(values["StartInterval"] as? Int, 300)
        XCTAssertEqual(values["BundleProgram"] as? String, "Contents/MacOS/redapp-schedule-agent")

        let helperURL = appBundle.appendingPathComponent("Contents/MacOS/redapp-schedule-agent")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helperURL.path), helperURL.path)

        let process = Process()
        let output = Pipe()
        process.executableURL = helperURL
        process.arguments = ["--print-app-path"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let resolvedPath = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(process.terminationStatus, 0, resolvedPath)
        XCTAssertEqual(
            resolvedPath,
            appBundle.resolvingSymlinksInPath().standardizedFileURL.path
        )

        let scheduleStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-agent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: scheduleStoreURL) }

        func wakeDecision(nextRunAt: Date?, isEnabled: Bool) throws -> String {
            let formatter = ISO8601DateFormatter()
            var schedule: [String: Any] = ["isEnabled": isEnabled]
            if let nextRunAt {
                schedule["nextRunAt"] = formatter.string(from: nextRunAt)
            }
            let data = try JSONSerialization.data(withJSONObject: ["schedules": [schedule]])
            try data.write(to: scheduleStoreURL, options: .atomic)

            let decisionProcess = Process()
            let decisionOutput = Pipe()
            decisionProcess.executableURL = helperURL
            decisionProcess.arguments = [
                "--schedule-store-path", scheduleStoreURL.path,
                "--print-wake-decision"
            ]
            decisionProcess.standardOutput = decisionOutput
            decisionProcess.standardError = decisionOutput
            try decisionProcess.run()
            decisionProcess.waitUntilExit()
            XCTAssertEqual(decisionProcess.terminationStatus, 0)
            return String(
                decoding: decisionOutput.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        XCTAssertEqual(try wakeDecision(nextRunAt: nil, isEnabled: true), "skip")
        XCTAssertEqual(try wakeDecision(nextRunAt: Date().addingTimeInterval(3_600), isEnabled: true), "skip")
        XCTAssertEqual(try wakeDecision(nextRunAt: Date().addingTimeInterval(-60), isEnabled: false), "skip")
        XCTAssertEqual(try wakeDecision(nextRunAt: Date().addingTimeInterval(-60), isEnabled: true), "open")
    }
}
#endif
