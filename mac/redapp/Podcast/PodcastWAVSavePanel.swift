import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum PodcastWAVSavePanel {
    static func export(sourceURL: URL, suggestedFileName: String) throws -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save Podcast"
        panel.message = "Choose where to save the completed WAV podcast."
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType(filenameExtension: "wav") ?? .audio]
        panel.nameFieldStringValue = normalizedFileName(suggestedFileName)

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return false
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return true
    }

    nonisolated static func normalizedFileName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Batch Podcast" : trimmed
        return base.lowercased().hasSuffix(".wav") ? base : base + ".wav"
    }
}
