import Foundation

/// User choices for a guided automation run. Defaults are intentionally
/// product-oriented, while every generated result remains editable afterward.
struct AutomationRequest: Codable {
    var operation: ProjectOperation
    var clipKinds: [ClipSuggestionKind]
    var resultCount: Int
    var formats: [AspectRatio]
    var captions: CaptionAutomationSettings
    var autoFraming: Bool
    var removeSilences: Bool
    var removeFillers: Bool
    var generateCovers: Bool
    var outputPreset: ProductionPreset
    var localeIdentifier: String
    var allowServerTranscription: Bool
    var analyzeScenes: Bool

    init(
        operation: ProjectOperation,
        clipKinds: [ClipSuggestionKind] = [.clips],
        resultCount: Int = 6,
        formats: [AspectRatio] = [.portrait9_16],
        captions: CaptionAutomationSettings = CaptionAutomationSettings(),
        autoFraming: Bool = true,
        removeSilences: Bool = false,
        removeFillers: Bool = false,
        generateCovers: Bool = true,
        outputPreset: ProductionPreset = .balanced,
        localeIdentifier: String = "pt-BR",
        allowServerTranscription: Bool = false,
        analyzeScenes: Bool = true
    ) {
        self.operation = operation
        self.clipKinds = clipKinds
        self.resultCount = resultCount
        self.formats = formats
        self.captions = captions
        self.autoFraming = autoFraming
        self.removeSilences = removeSilences
        self.removeFillers = removeFillers
        self.generateCovers = generateCovers
        self.outputPreset = outputPreset
        self.localeIdentifier = localeIdentifier
        self.allowServerTranscription = allowServerTranscription
        self.analyzeScenes = analyzeScenes
    }

    static func `default`(for operation: ProjectOperation) -> AutomationRequest {
        switch operation {
        case .multiply:
            return AutomationRequest(
                operation: operation,
                clipKinds: [.clips, .teasers],
                resultCount: 6,
                formats: [.portrait9_16, .square1_1],
                captions: CaptionAutomationSettings(enabled: true, dynamic: true),
                autoFraming: true,
                generateCovers: true,
                outputPreset: .socialClips
            )
        case .podcast:
            return AutomationRequest(
                operation: operation,
                clipKinds: [.segments],
                resultCount: 1,
                formats: [.original],
                captions: CaptionAutomationSettings(enabled: true, dynamic: false),
                autoFraming: false,
                removeSilences: true,
                removeFillers: true,
                generateCovers: false,
                outputPreset: .podcastCleanUp
            )
        case .episodes:
            return AutomationRequest(
                operation: operation,
                clipKinds: [.segments],
                resultCount: 4,
                formats: [.landscape16_9],
                captions: CaptionAutomationSettings(enabled: false, dynamic: false),
                autoFraming: false,
                generateCovers: true,
                outputPreset: .series
            )
        }
    }
}

struct CaptionAutomationSettings: Codable, Hashable {
    var enabled: Bool
    var dynamic: Bool

    init(enabled: Bool = true, dynamic: Bool = false) {
        self.enabled = enabled
        self.dynamic = dynamic
    }
}

enum ProductionPreset: String, Codable, CaseIterable, Identifiable {
    case balanced = "Equilibrado"
    case socialClips = "Redes sociais"
    case podcastCleanUp = "Podcast limpo"
    case series = "Série"
    case fastReview = "Revisão rápida"

    var id: String { rawValue }
}
