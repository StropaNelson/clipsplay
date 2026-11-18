import Foundation

/// Versioned exchange package ("clipbrief") sent to an external AI so it can
/// author a ClipPlan without ever seeing the media. All times are integer
/// milliseconds on the concatenated source sequence.
struct ClipBrief: Codable {
    var clipbrief_version: Int = 1
    var min_plan_version: Int = 1
    var generated_at: String
    var project_name: String
    var source: ClipBriefSource
    var transcript: [ClipBriefSentence]
    var pauses: [ClipBriefRange]
    var scene_cuts: [Int]
    var topics: [ClipBriefTopic]
    var hooks: [ClipBriefHook]
    var energy_peaks: [ClipBriefRange]
    var vocabulary: [String]
    var assets: [ClipBriefAsset]
    var episodes_state: [ClipBriefEpisodeState]?
    var capabilities: ClipBriefCapabilities

    init(
        generated_at: String,
        project_name: String,
        source: ClipBriefSource,
        transcript: [ClipBriefSentence] = [],
        pauses: [ClipBriefRange] = [],
        scene_cuts: [Int] = [],
        topics: [ClipBriefTopic] = [],
        hooks: [ClipBriefHook] = [],
        energy_peaks: [ClipBriefRange] = [],
        vocabulary: [String] = [],
        assets: [ClipBriefAsset] = [],
        episodes_state: [ClipBriefEpisodeState]? = nil,
        capabilities: ClipBriefCapabilities
    ) {
        self.generated_at = generated_at
        self.project_name = project_name
        self.source = source
        self.transcript = transcript
        self.pauses = pauses
        self.scene_cuts = scene_cuts
        self.topics = topics
        self.hooks = hooks
        self.energy_peaks = energy_peaks
        self.vocabulary = vocabulary
        self.assets = assets
        self.episodes_state = episodes_state
        self.capabilities = capabilities
    }
}

struct ClipBriefSource: Codable {
    /// Duration of the concatenated source sequence in ms.
    var duration_ms: Int
    /// Oriented pixel size of the main video (transform applied).
    var width: Int
    var height: Int
    /// How many clips feed the source sequence.
    var source_clip_count: Int
}

/// A spoken sentence with source-sequence bounds.
struct ClipBriefSentence: Codable {
    var id: String      // "s_N"
    var in_ms: Int
    var out_ms: Int
    var text: String
}

struct ClipBriefRange: Codable, Hashable {
    var in_ms: Int
    var out_ms: Int

    var duration_ms: Int { max(0, out_ms - in_ms) }
}

struct ClipBriefTopic: Codable {
    var time_ms: Int
    var label: String
}

struct ClipBriefHook: Codable {
    var in_ms: Int
    var out_ms: Int
    var text: String
    var score: Double
}

struct ClipBriefAsset: Codable, Hashable {
    var id: String      // UUID string of the media asset
    var name: String
    var type: String    // "video" | "audio" | "image"
    var duration_ms: Int
}

/// Snapshot of one episode so a plan can target pieces by stable ids.
struct ClipBriefEpisodeState: Codable {
    var episode_id: String      // "ep_N" (1-based, follows project.episodes order)
    var title: String
    var segments: [ClipBriefSegmentState]
    var texts: [ClipBriefTextState]
    var audio: [ClipBriefAudioState]
}

struct ClipBriefSegmentState: Codable {
    var id: String              // "seg_N" inside the episode
    var track: String           // "intro" | "recap" | "main" | "outro"
    /// Main-track clips use source-sequence ms; vinheta tracks use asset-local ms.
    var source_in_ms: Int
    var source_out_ms: Int
}

struct ClipBriefTextState: Codable {
    var id: String              // "txt_N" inside the episode
    var text: String
    var start_ms: Int           // episode timeline
    var duration_ms: Int
}

struct ClipBriefAudioState: Codable {
    var id: String              // "aud_N" inside the episode
    var asset_id: String
    var kind: String            // "music" | "narration" | "videoSound"
    var volume: Double
    var start_ms: Int           // episode timeline
    var end_ms: Int
}

/// What the paired ClipPlan may express; mirrored in the prompt so the AI only
/// produces things this app version understands.
struct ClipBriefCapabilities: Codable {
    var plan_version: Int
    var scope: String               // "outputs" | "editExisting"
    var max_outputs: Int
    var max_operations: Int
    var time_unit: String           // "ms"
    var formats: [String]
    var caption_styles: [String]
    var text_positions: [String]
    var text_styles: [String]
    var text_colors: [String]
    var transition_styles: [String]
    var operation_kinds: [String]
    /// Whether this app version applies `operations` plans in place (undoes as one step).
    var operations_executable: Bool
}
