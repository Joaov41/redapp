import Foundation
import Darwin

private struct ScheduleEnvelope: Decodable {
    let schedules: [ScheduleState]
}

private struct ScheduleState: Decodable {
    let isEnabled: Bool
    let nextRunAt: Date?
}

private func argumentValue(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag),
          CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

private func scheduleStoreURL() -> URL {
    if let override = argumentValue(after: "--schedule-store-path") {
        return URL(fileURLWithPath: override)
    }

    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.jv.redapp", isDirectory: true)
        .appendingPathComponent("ScheduledSummaries", isDirectory: true)
        .appendingPathComponent("schedules-v1.json")
}

private func hasDueSchedule(at date: Date, storeURL: URL) -> Bool {
    guard let data = try? Data(contentsOf: storeURL) else { return false }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let envelope = try? decoder.decode(ScheduleEnvelope.self, from: data) else { return false }
    return envelope.schedules.contains { schedule in
        schedule.isEnabled && (schedule.nextRunAt.map { $0 <= date } ?? false)
    }
}

private func resolvedExecutableURL() -> URL? {
    var requiredSize: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &requiredSize)
    guard requiredSize > 0 else { return nil }

    var buffer = [CChar](repeating: 0, count: Int(requiredSize))
    let result = buffer.withUnsafeMutableBufferPointer { pointer in
        _NSGetExecutablePath(pointer.baseAddress, &requiredSize)
    }
    guard result == 0 else { return nil }

    return URL(fileURLWithPath: String(cString: buffer))
        .resolvingSymlinksInPath()
        .standardizedFileURL
}

guard let helperURL = resolvedExecutableURL() else {
    FileHandle.standardError.write(Data("redapp schedule wake failed: could not resolve the helper executable path\n".utf8))
    exit(EXIT_FAILURE)
}

let appURL = helperURL
    .deletingLastPathComponent() // MacOS
    .deletingLastPathComponent() // Contents
    .deletingLastPathComponent() // redapp.app

var isDirectory: ObjCBool = false
guard appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
      FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue else {
    FileHandle.standardError.write(
        Data("redapp schedule wake failed: resolved application path is invalid: \(appURL.path)\n".utf8)
    )
    exit(EXIT_FAILURE)
}

if CommandLine.arguments.contains("--print-app-path") {
    FileHandle.standardOutput.write(Data("\(appURL.path)\n".utf8))
    exit(EXIT_SUCCESS)
}

let dueScheduleExists = hasDueSchedule(at: Date(), storeURL: scheduleStoreURL())
if CommandLine.arguments.contains("--print-wake-decision") {
    FileHandle.standardOutput.write(Data(dueScheduleExists ? "open\n".utf8 : "skip\n".utf8))
    exit(EXIT_SUCCESS)
}

// launchd checks periodically, but a check must remain invisible unless an
// enabled scheduled summary has actually reached its next run time.
guard dueScheduleExists else {
    exit(EXIT_SUCCESS)
}

let runningCheck = Process()
runningCheck.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
runningCheck.arguments = ["-x", "redapp"]
runningCheck.standardOutput = FileHandle.nullDevice
runningCheck.standardError = FileHandle.nullDevice

do {
    try runningCheck.run()
    runningCheck.waitUntilExit()
    if runningCheck.terminationStatus == 0 {
        // The app's one-minute timer already checks due schedules. Reopening a
        // running app can surface one of its windows and interrupt the user.
        exit(EXIT_SUCCESS)
    }
} catch {
    FileHandle.standardError.write(Data("redapp running-state check failed: \(error.localizedDescription)\n".utf8))
}

let open = Process()
open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
open.arguments = ["-gj", appURL.path]

do {
    try open.run()
    open.waitUntilExit()
    exit(open.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("redapp schedule wake failed: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
