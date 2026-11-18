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

/// A short text card on the output timeline. `start_ms` is the output-time ms;
/// negative values count back from the end of the output. `at_segment` anchors
/// the card to the Nth merged segment (1-based, output order); `at` picks its
/// start ("start", default) or its end. `start_ms` still applies on top of the
/// anchor (default 0).
struct ClipPlanText: Codable {
    var text: String
    var start_ms: Int?                  // output timeline; negative = from the end
    var duration_ms: Int
    var position: String?               // "top" | "center" | "bottom" (missing = bottom)
    var style: String?                  // "plain" | "shadow" | "box" (missing = box)
    var color: String?                  // "white" | "yellow" | "black" (missing = white)
    var at_segment: Int?                // 1-based segment index within the output
    var at: String?                     // "start" | "end" (missing = "start")
}

/// One edit over an episode referenced by its stable "ep_N" id. Params stay
/// flat and optional; the validator checks each op's required fields.
struct ClipPlanOperation: Codable {
    var op: String
    var target: String                  // episode id, "ep_N"

    // cut_range / set_vinheta (in_ms, out_ms): cut_range uses source-sequence
    // ms; set_vinheta uses asset-local ms. trim_segment: source-sequence ms on
    // main slots, asset-local on vinheta slots.
    var in_ms: Int?
    var out_ms: Int?
    // remove_silences
    var min_ms: Int?
    // set_volume (one of the two ids is required) / set_transition (segment_id)
    // / set_speed / set_adjustments / set_transform / trim_segment / split /
    // remove_segment / reorder (order) / set_chroma (segment_id → error)
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
    // add_text (start_ms may be negative = from the episode end; at_segment/at
    // anchor to the seg_N storyline position) / add_overlay / set_overlay
    var text: String?
    var start_ms: Int?
    var duration_ms: Int?
    var at_segment: Int?
    var at: String?
    // set_captions / auto_framing
    var enabled: Bool?
    // set_vinheta
    var track: String?
    var asset_id: String?
    // set_speed
    var speed: Double?
    // set_adjustments
    var brightness: Double?
    var contrast: Double?
    var saturation: Double?
    var warmth: Double?
    var vignette: Double?
    var remove_background: Bool?
    // set_transform / add_overlay / set_overlay
    var scale: Double?
    var rotation: Double?
    var offset_x: Double?
    var offset_y: Double?
    // split
    var at_ms: Int?
    // reorder
    var order: [String]?
    // rename
    var title: String?
    // set_audio / add_audio
    var fade_in_ms: Int?
    var fade_out_ms: Int?
    var duck_level: Double?
    var kind: String?
    var source_in_ms: Int?
    var source_out_ms: Int?
    // set_overlay / remove_overlay / set_chroma / add_overlay (chroma_enabled)
    var overlay_id: String?
    var center_x: Double?
    var center_y: Double?
    var width_fraction: Double?
    var opacity: Double?
    var chroma_enabled: Bool?
    var chroma_r: Double?
    var chroma_g: Double?
    var chroma_b: Double?
    var chroma_tolerance: Double?
    // set_chroma (hex "#RRGGBB" via `color`, `tolerance` 0-1) / set_overlay sourceStart
    var tolerance: Double?
    var source_start_ms: Int?
    // add_marker / remove_marker
    var time_ms: Int?
}

/// One row of the ops vocabulary shared by the prompt table and the brief's
/// capabilities: the op name plus its flat parameter signature (with ranges).
struct ClipPlanOperationSpec: Codable {
    var op: String
    var params: String
    /// Optional one-line hint shown in the compact (mini) prompt.
    var detail: String?
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
    /// Every TransitionStyle case name — the plan vocabulary is case names
    /// ("slideLeft"), never the Portuguese display strings.
    static let transitionStyles = [
        "none", "dissolve", "fadeBlack", "fadeWhite", "slideLeft", "slideRight",
        "slideUp", "push", "zoom", "wipe", "iris"
    ]
    static let vinhetaTracks = ["intro", "outro"]
    static let audioKinds = ["music", "narration", "videoSound"]
    static let anchorKinds = ["start", "end"]
    static let roles = ["main"]

    /// Full ops vocabulary with required/optional params — the prompt table
    /// and `capabilities.operations` are both generated from this list.
    static let operationSpecs: [ClipPlanOperationSpec] = [
        ClipPlanOperationSpec(op: "cut_range", params: "{in_ms, out_ms}", detail: "corta o intervalo de origem do episódio"),
        ClipPlanOperationSpec(op: "remove_silences", params: "{min_ms?}", detail: "remove pausas da fala no episódio"),
        ClipPlanOperationSpec(op: "set_volume", params: "{segment_id|audio_id, volume 0-1}", detail: nil),
        ClipPlanOperationSpec(op: "set_speed", params: "{segment_id, speed 0.2-4}", detail: "velocidade do clipe"),
        ClipPlanOperationSpec(op: "set_adjustments", params: "{segment_id, brightness? -1..1, contrast? 0.25-4, saturation? 0-2, warmth? -1..1, vignette? 0-1, remove_background? bool}", detail: "cor/luz do clipe"),
        ClipPlanOperationSpec(op: "set_transform", params: "{segment_id, scale? 0.25-4, rotation? -180..180, offset_x? -1..1, offset_y? -1..1}", detail: "zoom/rotação/posição do clipe"),
        ClipPlanOperationSpec(op: "move_text", params: "{text_id, position}", detail: nil),
        ClipPlanOperationSpec(op: "set_text_style", params: "{text_id, style?, color?, size? 0-0.5}", detail: nil),
        ClipPlanOperationSpec(op: "add_text", params: "{text, start_ms?, duration_ms, at_segment?, at?, position?, style?, color?}", detail: "cartão de texto na timeline do episódio"),
        ClipPlanOperationSpec(op: "set_captions", params: "{enabled, style?}", detail: nil),
        ClipPlanOperationSpec(op: "auto_framing", params: "{enabled}", detail: nil),
        ClipPlanOperationSpec(op: "set_aspect", params: "{format}", detail: "formato de saída do episódio"),
        ClipPlanOperationSpec(op: "set_transition", params: "{segment_id, style}", detail: "transição de entrada do clipe"),
        ClipPlanOperationSpec(op: "set_vinheta", params: "{track intro|outro, asset_id, in_ms, out_ms}", detail: "vinheta de um asset de vídeo"),
        ClipPlanOperationSpec(op: "trim_segment", params: "{segment_id, in_ms?, out_ms?}", detail: "ajusta o trecho de origem do clipe"),
        ClipPlanOperationSpec(op: "split", params: "{segment_id, at_ms}", detail: "divide um clipe main no tempo de origem"),
        ClipPlanOperationSpec(op: "remove_segment", params: "{segment_id}", detail: "remove o clipe (main fecha a lacuna)"),
        ClipPlanOperationSpec(op: "reorder", params: "{order:[seg_N,...]}", detail: "reordena os clipes main do episódio"),
        ClipPlanOperationSpec(op: "rename", params: "{title ≤80}", detail: "renomeia o episódio"),
        ClipPlanOperationSpec(op: "delete_episode", params: "{}", detail: "apaga o episódio inteiro"),
        ClipPlanOperationSpec(op: "set_audio", params: "{audio_id, volume? 0-1, fade_in_ms?, fade_out_ms?, duck_level? 0-1}", detail: nil),
        ClipPlanOperationSpec(op: "remove_audio", params: "{audio_id}", detail: nil),
        ClipPlanOperationSpec(op: "add_audio", params: "{asset_id, kind? music|narration|videoSound, start_ms?, source_in_ms?, source_out_ms?, volume? 0-1, fade_in_ms?, fade_out_ms?, duck_level? 0-1}", detail: "novo clipe de áudio"),
        ClipPlanOperationSpec(op: "add_overlay", params: "{asset_id, start_ms?, duration_ms?, center_x? 0-1, center_y? 0-1, width_fraction? 0.05-1, volume? 0-1, opacity? 0-1, rotation? -180..180, chroma_enabled?}", detail: "imagem/vídeo PiP novo"),
        ClipPlanOperationSpec(op: "set_overlay", params: "{overlay_id, center_x?, center_y?, width_fraction?, start_ms?, duration_ms?, source_start_ms?, opacity?, rotation?, volume?, chroma_enabled?, chroma_r?/chroma_g?/chroma_b? 0-1, chroma_tolerance? 0-1}", detail: "edita um PiP (chroma = fundo verde)"),
        ClipPlanOperationSpec(op: "set_chroma", params: "{overlay_id|segment_id, enabled, color? \"#RRGGBB\", tolerance? 0-1}", detail: "chroma key num PiP (seg_N é rejeitado: chroma só em overlays)"),
        ClipPlanOperationSpec(op: "remove_overlay", params: "{overlay_id}", detail: nil),
        ClipPlanOperationSpec(op: "add_marker", params: "{time_ms}", detail: "marcador na timeline do episódio"),
        ClipPlanOperationSpec(op: "remove_marker", params: "{time_ms}", detail: "remove o marcador mais próximo (±500 ms)")
    ]
    static let operationKinds = operationSpecs.map(\.op)

    /// Placement/timing rules also mirrored in the prompt and the brief's
    /// capabilities.notes.
    static let capabilityNotes = [
        "start_ms negativo conta a partir do fim da linha do tempo (-4000 = últimos 4 s)",
        "at_segment + at (\"start\"|\"end\") ancora um texto ao trecho N (1-based); nas saídas, N é o índice do segmento em segments; nos episódios, o índice do seg_N",
        "timeline_in_ms/timeline_out_ms de cada seg_N mostram onde o trecho está na linha do tempo do episódio"
    ]
}
