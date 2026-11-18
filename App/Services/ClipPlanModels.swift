import Foundation

/// The AI's answer to a ClipBrief: either brand-new outputs or edits over the
/// episodes listed in `episodes_state`. Exactly one of the two lists is allowed.
struct ClipPlan: Codable {
    var clipplan_version: Int
    var outputs: [ClipPlanOutput]?
    var operations: [ClipPlanOperation]?

    /// Fills missing output ids ("out_N") so messages and previews are stable.
    func normalized() -> ClipPlan {
        var copy = self
        if let outputs = copy.outputs {
            copy.outputs = outputs.enumerated().map { index, output in
                var item = output
                if item.id?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                    item.id = "out_\(index + 1)"
                }
                return item
            }
        }
        return copy
    }
}

struct ClipPlanOutput: Codable {
    var id: String?
    var title: String?
    var format: String                  // "16:9" | "9:16" | "1:1" | "4:5" | "original"
    var resolution: String?
    var segments: [ClipPlanSegment]
    var captions: ClipPlanCaptions?
    var auto_framing: Bool?
    var intro: ClipPlanVinheta?
    var outro: ClipPlanVinheta?
    var texts: [ClipPlanText]?
    var reason: String?
}

struct ClipPlanSegment: Codable {
    var source_in_ms: Int
    var source_out_ms: Int
    var role: String                    // v1: only "main"
}

struct ClipPlanCaptions: Codable {
    var enabled: Bool
    var style: String?                  // "dynamic" | "static" (missing = static)
}

struct ClipPlanVinheta: Codable {
    var asset_id: String
    var in_ms: Int                      // asset-local
    var out_ms: Int
}

/// A short text card on the output timeline.
struct ClipPlanText: Codable {
    var text: String
    var start_ms: Int                   // output timeline
    var duration_ms: Int
    var position: String?               // "top" | "center" | "bottom" (missing = bottom)
    var style: String?                  // "plain" | "shadow" | "box" (missing = box)
    var color: String?                  // "white" | "yellow" | "black" (missing = white)
}

/// One edit over an episode referenced by its stable "ep_N" id. Params stay
/// flat and optional; the validator checks each op's required fields.
struct ClipPlanOperation: Codable {
    var op: String
    var target: String                  // episode id, "ep_N"

    // cut_range / set_vinheta (in_ms, out_ms): cut_range uses source-sequence
    // ms; set_vinheta uses asset-local ms.
    var in_ms: Int?
    var out_ms: Int?
    // remove_silences
    var min_ms: Int?
    // set_volume (one of the two ids is required) / set_transition (segment_id)
    var segment_id: String?
    var audio_id: String?
    var volume: Double?
    // move_text / set_text_style
    var text_id: String?
    var position: String?
    var style: String?
    var color: String?
    var size: Double?
    // set_aspect
    var format: String?
    // add_text
    var text: String?
    var start_ms: Int?
    var duration_ms: Int?
    // set_captions / auto_framing
    var enabled: Bool?
    // set_vinheta
    var track: String?
    var asset_id: String?
}

/// Single source of truth for every literal allowed by the .clipplan contract.
enum ClipPlanContract {
    static let planVersion = 1
    static let maxOutputs = 30
    static let maxOperations = 200

    static let formats = ["16:9", "9:16", "1:1", "4:5", "original"]
    static let captionStyles = ["dynamic", "static"]
    static let textPositions = ["top", "center", "bottom"]
    static let textStyles = ["plain", "shadow", "box"]
    static let textColors = ["white", "yellow", "black"]
    static let transitionStyles = ["none", "dissolve", "fadeBlack", "fadeWhite"]
    static let vinhetaTracks = ["intro", "outro"]
    static let roles = ["main"]
    static let operationKinds = [
        "cut_range", "remove_silences", "set_volume", "move_text",
        "set_text_style", "set_aspect", "set_transition", "add_text",
        "set_captions", "auto_framing", "set_vinheta"
    ]
}
