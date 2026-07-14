import WidgetKit
import AppIntents

enum WidgetDisplayMode: String, AppEnum {
    case highlight
    case progress

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Display Style")
    }

    static var caseDisplayRepresentations: [WidgetDisplayMode: DisplayRepresentation] {
        [
            .highlight: DisplayRepresentation(title: "Highlights"),
            .progress: DisplayRepresentation(title: "Progress")
        ]
    }
}

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Batch Summary Widget" }
    static var description: IntentDescription { "Track the latest Reddit batch summaries from your Home Screen." }

    @Parameter(title: "Display Mode", default: .highlight)
    var displayMode: WidgetDisplayMode
}

extension ConfigurationAppIntent {
    static var highlightPreview: ConfigurationAppIntent {
        let intent = ConfigurationAppIntent()
        intent.displayMode = .highlight
        return intent
    }

    static var progressPreview: ConfigurationAppIntent {
        let intent = ConfigurationAppIntent()
        intent.displayMode = .progress
        return intent
    }
}
