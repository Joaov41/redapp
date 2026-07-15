import Foundation

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

let helperURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let appURL = helperURL
    .deletingLastPathComponent() // MacOS
    .deletingLastPathComponent() // Contents
    .deletingLastPathComponent() // redapp.app

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
