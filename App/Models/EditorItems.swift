import Foundation
import SwiftUI
import UIKit

enum TransitionStyle: String, Codable, CaseIterable, Identifiable {
    case none = "Corte seco"
    case dissolve = "Dissolver"
    case fadeBlack = "Fade preto"
    case fadeWhite = "Fade branco"
    case slideLeft = "Deslizar ←"
    case slideRight = "Deslizar →"
    case slideUp = "Deslizar ↑"
    case push = "Empurrar"
    case zoom = "Zoom"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .none: return "scissors"
        case .dissolve: return "circle.lefthalf.filled"
        case .fadeBlack: return "circle.fill"
        case .fadeWhite: return "circle"
        case .slideLeft: return "arrow.left.square"
        case .slideRight: return "arrow.right.square"
        case .slideUp: return "arrow.up.square"
        case .push: return "arrow.left.arrow.right"
        case .zoom: return "plus.magnifyingglass"
        }
    }
}

struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
}

/// Where a text/audio item repeats. `nil` means it belongs to a single episode.
enum ClipAnchor: String, Codable, CaseIterable, Identifiable {
    case allEpisodes = "Todos os episódios"
    case intro = "Todas as aberturas"
    case outro = "Todos os encerramentos"

    var id: String { rawValue }
}

enum TextOverlayStyle: String, Codable, CaseIterable, Identifiable {
    case plain = "Simples"
    case shadow = "Sombra"
    case box = "Caixa"

    var id: String { rawValue }
}

struct TextOverlay: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var startTime: Double
    var duration: Double
    /// Center of the text, normalized to the video frame (0...1, origin top-left).
    var positionX: Double = 0.5
    var positionY: Double = 0.8
    /// Font size as a fraction of the video height.
    var fontScale: Double = 0.07
    var color: RGBAColor = .white
    var style: TextOverlayStyle = .shadow
    var isBold: Bool = true
    var isCaption: Bool?
    var anchor: ClipAnchor?
    /// Word timings relative to `startTime`; captions with words highlight the spoken word.
    var words: [TranscriptWord]?

    var endTime: Double { startTime + duration }

    func isVisible(at time: Double) -> Bool {
        time >= startTime && time < endTime
    }
}

enum AudioClipKind: String, Codable, CaseIterable, Identifiable {
    case music = "Música"
    case narration = "Narração"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .music: return "music.note"
        case .narration: return "mic.fill"
        }
    }
}

struct AudioClip: Codable, Identifiable, Hashable {
    var id = UUID()
    var assetID: UUID
    var name: String
    var kind: AudioClipKind
    var timelineStart: Double
    var sourceStart: Double
    var sourceEnd: Double
    var volume: Float
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var anchor: ClipAnchor?

    var duration: Double { max(0, sourceEnd - sourceStart) }
    var endTime: Double { timelineStart + duration }
}

/// Picture-in-picture image or video placed above the main video.
/// A recognized word, timed in seconds.
struct TranscriptWord: Codable, Hashable {
    var text: String
    var start: Double
    var end: Double
}

/// User framing of a clip on top of the fit/fill layout. Offsets are fractions of the frame.
struct ClipTransform: Codable, Hashable {
    var scale: Double = 1
    var rotation: Double = 0
    var offsetX: Double = 0
    var offsetY: Double = 0

    static let identity = ClipTransform()
}

struct TimelineMarker: Codable, Identifiable, Hashable {
    var id = UUID()
    var time: Double
}

struct MediaOverlay: Codable, Identifiable, Hashable {
    var id = UUID()
    var assetID: UUID
    var name: String
    var isVideo: Bool
    var startTime: Double
    var duration: Double
    var sourceStart: Double = 0
    /// Center normalized to the video frame (0...1, origin top-left).
    var centerX: Double = 0.72
    var centerY: Double = 0.28
    /// Width as a fraction of the video width.
    var widthFraction: Double = 0.4
    var volume: Float = 0
    var storedOpacity: Double?
    var storedRotation: Double?

    var opacity: Double {
        get { storedOpacity ?? 1 }
        set { storedOpacity = newValue }
    }

    var rotation: Double {
        get { storedRotation ?? 0 }
        set { storedRotation = newValue }
    }

    var endTime: Double { startTime + duration }

    func isVisible(at time: Double) -> Bool {
        time >= startTime && time < endTime
    }
}

/// Result of the trim sheet used when choosing an intro/outro/recap clip.
struct ClipSelection {
    var startTime: Double
    var endTime: Double
    var narration: MediaAsset?
    var clipVolume: Float = 1
}

struct StoryItem {
    let segment: VideoSegment
    let track: TrackType
    let start: Double
    /// Seconds this clip overlaps the previous one (its incoming transition).
    let overlap: Double

    var end: Double { start + segment.timelineDuration }
}

extension VideoSegment {
    var transition: TransitionStyle {
        get { transitionStyle ?? .dissolve }
        set { transitionStyle = newValue }
    }

    var transitionDuration: Double {
        get { transitionLength ?? 0.5 }
        set { transitionLength = newValue }
    }

    var clipVolume: Float {
        get { volume ?? 1 }
        set { volume = newValue }
    }

    var narrationLevel: Float {
        get { narrationVolume ?? 1 }
        set { narrationVolume = newValue }
    }

    var playbackSpeed: Double {
        get { max(0.001, speed ?? 1) }
        set { speed = newValue == 1 ? nil : newValue }
    }

    /// Length on the timeline after applying the playback speed.
    var timelineDuration: Double { duration / playbackSpeed }

    var clipTransform: ClipTransform {
        get {
            ClipTransform(
                scale: transformScale ?? 1,
                rotation: transformRotation ?? 0,
                offsetX: transformOffsetX ?? 0,
                offsetY: transformOffsetY ?? 0
            )
        }
        set {
            transformScale = newValue.scale == 1 ? nil : newValue.scale
            transformRotation = newValue.rotation == 0 ? nil : newValue.rotation
            transformOffsetX = newValue.offsetX == 0 ? nil : newValue.offsetX
            transformOffsetY = newValue.offsetY == 0 ? nil : newValue.offsetY
        }
    }

    /// A new piece of this clip starting at `sourceTime`, keeping speed, framing, volume and narration.
    func continuation(from sourceTime: Double) -> VideoSegment {
        var piece = VideoSegment(
            startTime: sourceTime,
            endTime: endTime,
            sourceType: sourceType,
            assetID: assetID,
            transitionStyle: TransitionStyle.none,
            narrationAssetID: narrationAssetID,
            volume: volume
        )
        piece.narrationVolume = narrationVolume
        piece.narrationOffset = (narrationOffset ?? 0) + (sourceTime - startTime) / playbackSpeed
        piece.speed = speed
        piece.clipTransform = clipTransform
        return piece
    }

    /// Freeze frames are one-frame source ranges stretched over the timeline.
    var isFreezeFrame: Bool { playbackSpeed < 0.2 }
}

extension Episode {
    /// Pieces of the source video used as this episode's main content (split/cut tool).
    var mainClips: [VideoSegment] {
        get {
            if let stored = storedMainClips, !stored.isEmpty { return stored }
            return [VideoSegment(id: id, startTime: mainStart, endTime: mainEnd, sourceType: .mainVideo)]
        }
        set { storedMainClips = newValue }
    }

    var textOverlays: [TextOverlay] {
        get { storedTextOverlays ?? [] }
        set { storedTextOverlays = newValue }
    }

    var audioClips: [AudioClip] {
        get { storedAudioClips ?? [] }
        set { storedAudioClips = newValue }
    }

    var mediaOverlays: [MediaOverlay] {
        get { storedMediaOverlays ?? [] }
        set { storedMediaOverlays = newValue }
    }

    var markers: [TimelineMarker] {
        get { storedMarkers ?? [] }
        set { storedMarkers = newValue.sorted { $0.time < $1.time } }
    }

    /// Sequential layout of every video clip: intro → recaps → main pieces → outro.
    /// Overlaps are capped at half of each neighbour, so at most two clips are ever on screen.
    func storyline() -> [StoryItem] {
        var entries: [(VideoSegment, TrackType)] = []
        if let intro = effectiveIntro, intro.isEnabled, intro.duration > 0 { entries.append((intro, .intro)) }
        for recap in effectiveRecaps where recap.isEnabled && recap.duration > 0 { entries.append((recap, .recap)) }
        for clip in mainClips where clip.duration > 0 { entries.append((clip, .main)) }
        if let outro = effectiveOutro, outro.isEnabled, outro.duration > 0 { entries.append((outro, .outro)) }

        var items: [StoryItem] = []
        var cursor = 0.0
        var previousDuration = 0.0
        for (index, entry) in entries.enumerated() {
            let (segment, track) = entry
            var overlap = 0.0
            if index > 0, segment.transition != .none {
                overlap = max(0, min(segment.transitionDuration, previousDuration / 2, segment.timelineDuration / 2))
            }
            let start = max(0, cursor - overlap)
            items.append(StoryItem(segment: segment, track: track, start: start, overlap: overlap))
            cursor = start + segment.timelineDuration
            previousDuration = segment.timelineDuration
        }
        return items
    }

    /// Timeline time where items anchored to `anchor` start in this episode.
    func anchorStart(_ anchor: ClipAnchor) -> Double? {
        switch anchor {
        case .allEpisodes: return 0
        case .intro: return storyline().first { $0.track == .intro }?.start
        case .outro: return storyline().first { $0.track == .outro }?.start
        }
    }

    /// Episode overlays plus project-wide ones placed on this episode's timeline.
    func resolvedOverlays(global: [TextOverlay]) -> [TextOverlay] {
        textOverlays + global.compactMap { overlay in
            guard let anchor = overlay.anchor, let base = anchorStart(anchor) else { return nil }
            var placed = overlay
            placed.startTime += base
            return placed
        }
    }

    func resolvedAudioClips(global: [AudioClip]) -> [AudioClip] {
        audioClips + global.compactMap { clip in
            guard let anchor = clip.anchor, let base = anchorStart(anchor) else { return nil }
            var placed = clip
            placed.timelineStart += base
            return placed
        }
    }

    /// Turns per-episode custom templates into concrete segments with stable IDs.
    mutating func normalizeCustomTemplates() {
        if let custom = customIntroTemplate {
            introSegment = custom.toSegment()
            customIntroTemplate = nil
            useGlobalIntro = true
        }
        if let custom = customOutroTemplate {
            outroSegment = custom.toSegment()
            customOutroTemplate = nil
            useGlobalOutro = true
        }
        if !customRecapSegments.isEmpty {
            recapSegments = customRecapSegments
            customRecapSegments = []
            useGlobalRecap = true
        }
    }

    mutating func modifySegment(id segmentID: UUID, _ body: (inout VideoSegment) -> Void) {
        normalizeCustomTemplates()
        if var intro = introSegment, intro.id == segmentID {
            body(&intro)
            introSegment = intro
            return
        }
        if var outro = outroSegment, outro.id == segmentID {
            body(&outro)
            outroSegment = outro
            return
        }
        if let index = recapSegments.firstIndex(where: { $0.id == segmentID }) {
            body(&recapSegments[index])
            return
        }
        var clips = mainClips
        if let index = clips.firstIndex(where: { $0.id == segmentID }) {
            body(&clips[index])
            mainClips = clips
        }
    }

    @discardableResult
    mutating func removeSegment(id segmentID: UUID) -> Bool {
        normalizeCustomTemplates()
        if introSegment?.id == segmentID {
            introSegment = nil
            useGlobalIntro = false
            return true
        }
        if outroSegment?.id == segmentID {
            outroSegment = nil
            useGlobalOutro = false
            return true
        }
        if let index = recapSegments.firstIndex(where: { $0.id == segmentID }) {
            recapSegments.remove(at: index)
            useGlobalRecap = !recapSegments.isEmpty
            return true
        }
        var clips = mainClips
        if clips.count > 1, let index = clips.firstIndex(where: { $0.id == segmentID }) {
            clips.remove(at: index)
            mainClips = clips
            return true
        }
        return false
    }
}
