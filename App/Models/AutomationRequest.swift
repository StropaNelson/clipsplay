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
    /// Target platforms for "Multiplicar conteúdo" (one output per moment × platform).
    var platforms: [PublishPlatform]
    /// Length band used to find complete moments.
    var momentLength: MomentLength
    /// Sequential "novelinha" split settings for "Criar episódios".
    var episodePlan: EpisodePlanSettings

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
        analyzeScenes: Bool = true,
        platforms: [PublishPlatform] = [.vertical],
        momentLength: MomentLength = .short,
        episodePlan: EpisodePlanSettings = EpisodePlanSettings()
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
        self.platforms = platforms
        self.momentLength = momentLength
        self.episodePlan = episodePlan
    }

    static func `default`(for operation: ProjectOperation) -> AutomationRequest {
        switch operation {
        case .multiply:
            return AutomationRequest(
                operation: operation,
                clipKinds: [.clips],
                resultCount: 6,
                formats: [.portrait9_16],
                captions: CaptionAutomationSettings(enabled: true, dynamic: true),
                autoFraming: true,
                generateCovers: true,
                outputPreset: .socialClips,
                platforms: [.vertical],
                momentLength: .short
            )
        case .speechEdit:
            return AutomationRequest(
                operation: operation,
                clipKinds: [.segments],
                resultCount: 1,
                formats: [.original],
                captions: CaptionAutomationSettings(enabled: false, dynamic: false),
                autoFraming: false,
                removeSilences: true,
                removeFillers: true,
                generateCovers: false,
                outputPreset: .fastReview,
                analyzeScenes: false
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
                formats: [.original],
                captions: CaptionAutomationSettings(enabled: false, dynamic: false),
                autoFraming: false,
                generateCovers: true,
                outputPreset: .series
            )
        }
    }
}

/// Distribution target for multiplied content; each maps to one output format.
enum PublishPlatform: String, Codable, CaseIterable, Identifiable {
    case vertical = "Reels · TikTok · Shorts"
    case feed = "Feed 4:5"
    case square = "Quadrado 1:1"
    case youtube = "YouTube 16:9"

    var id: String { rawValue }

    var aspectRatio: AspectRatio {
        switch self {
        case .vertical: return .portrait9_16
        case .feed: return .portrait4_5
        case .square: return .square1_1
        case .youtube: return .landscape16_9
        }
    }

    var shortName: String {
        switch self {
        case .vertical: return "Vertical"
        case .feed: return "Feed"
        case .square: return "Quadrado"
        case .youtube: return "YouTube"
        }
    }

    var icon: String {
        switch self {
        case .vertical: return "rectangle.portrait"
        case .feed: return "rectangle.portrait.inset.filled"
        case .square: return "square"
        case .youtube: return "play.rectangle"
        }
    }
}

/// Structure of the sequential episode split ("novelinha").
struct EpisodePlanSettings: Codable, Hashable {
    /// 0 = use the planner's suggested length.
    var targetLength: Double = 0
    var seriesTitle: String = ""
    var introCard = true
    var outroCard = true
    var recap = false
    var recapDuration: Double = 6
    var introAssetID: UUID?
    var outroAssetID: UUID?
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
