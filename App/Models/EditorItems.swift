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

    var duration: Double { max(0, sourceEnd - sourceStart) }
    var endTime: Double { timelineStart + duration }
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

    var end: Double { start + segment.duration }
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
                overlap = max(0, min(segment.transitionDuration, previousDuration / 2, segment.duration / 2))
            }
            let start = max(0, cursor - overlap)
            items.append(StoryItem(segment: segment, track: track, start: start, overlap: overlap))
            cursor = start + segment.duration
            previousDuration = segment.duration
        }
        return items
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
