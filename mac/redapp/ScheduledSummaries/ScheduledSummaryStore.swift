#if os(macOS)
import Foundation

@MainActor
final class ScheduledSummaryStore {
    static let shared = ScheduledSummaryStore()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {}

    func load() throws -> ScheduledSummaryPersistenceEnvelope {
        let url = try storageURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return ScheduledSummaryPersistenceEnvelope()
        }
        return try decoder.decode(ScheduledSummaryPersistenceEnvelope.self, from: Data(contentsOf: url))
    }

    func save(schedules: [ScheduledSummaryDefinition], executions: [ScheduledSummaryExecution]) throws {
        let url = try storageURL()
        let envelope = ScheduledSummaryPersistenceEnvelope(
            schedules: schedules,
            executions: Array(executions.sorted { $0.scheduledFor > $1.scheduledFor }.prefix(200))
        )
        try encoder.encode(envelope).write(to: url, options: .atomic)
    }

    private func storageURL() throws -> URL {
        let directory: URL
        if let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.jv.redapp") {
            directory = group.appendingPathComponent("ScheduledSummaries", isDirectory: true)
        } else {
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directory = support
                .appendingPathComponent("redapp", isDirectory: true)
                .appendingPathComponent("ScheduledSummaries", isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("schedules-v1.json")
    }
}
#endif
