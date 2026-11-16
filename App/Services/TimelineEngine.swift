import Foundation
import CoreMedia
import AVFoundation

actor TimelineEngine {
    static let shared = TimelineEngine()
    
    private init() {}
    
    func buildEpisodeComposition(
        project: Project,
        episode: Episode,
        additionalAssets: [UUID: URL],
        settings: ExportSettings? = nil
    ) async throws -> CompositionBuildResult {
        let segments = episode.storyline().map { item in
            CompositionSegment(
                sourceType: item.segment.sourceType,
                assetID: item.segment.assetID,
                timeRange: item.segment.timeRange,
                targetTrack: item.track,
                timelineStartTime: item.start,
                overlapIn: item.overlap,
                transition: item.segment.transition,
                clipVolume: item.segment.clipVolume,
                audioFadeIn: item.segment.audioFadeIn ?? 0,
                audioFadeOut: item.segment.audioFadeOut ?? 0,
                narrationAssetID: item.segment.narrationAssetID,
                narrationVolume: item.segment.narrationLevel,
                narrationOffset: item.segment.narrationOffset ?? 0,
                speed: item.segment.playbackSpeed,
                transform: item.segment.clipTransform,
                adjustments: item.segment.adjustments
            )
        }
        let audioClips = episode.resolvedAudioClips(global: project.globalAudioClips).map { clip in
            CompositionAudioClip(
                assetID: clip.assetID,
                timelineStart: clip.timelineStart,
                sourceStart: clip.sourceStart,
                sourceEnd: clip.sourceEnd,
                volume: clip.volume,
                fadeIn: clip.fadeIn,
                fadeOut: clip.fadeOut,
                kind: clip.kind,
                duckLevel: clip.duckLevel
            )
        }

        let overlayVideos = episode.mediaOverlays.filter(\.isVideo).map { overlay in
            CompositionOverlayVideo(
                assetID: overlay.assetID,
                timelineStart: overlay.startTime,
                chromaKey: overlay.chromaKey,
                sourceStart: overlay.sourceStart,
                duration: overlay.duration,
                centerX: overlay.centerX,
                centerY: overlay.centerY,
                widthFraction: overlay.widthFraction,
                volume: overlay.volume,
                opacity: overlay.opacity,
                rotation: overlay.rotation
            )
        }

        return try await VideoProcessor.shared.createComposition(
            from: segments,
            audioClips: audioClips,
            overlayVideos: overlayVideos,
            sourceURL: project.sourceVideoFileURL,
            additionalAssets: additionalAssets,
            aspect: settings?.aspectRatio ?? project.aspectRatio,
            resolution: settings?.resolution ?? project.resolution,
            fitMode: settings?.fitMode ?? project.fitMode,
            fadeEdges: settings?.fadeEdges ?? false
        )
    }
    
    func buildPreviewComposition(
        project: Project,
        episode: Episode,
        additionalAssets: [UUID: URL]
    ) async throws -> CompositionBuildResult {
        try await buildEpisodeComposition(
            project: project,
            episode: episode,
            additionalAssets: additionalAssets
        )
    }
    
    nonisolated func computeTrackSegments(for episode: Episode, project: Project) -> [TrackSegments] {
        let items = episode.storyline()
        let timelineEnd = items.map(\.end).max() ?? 0
        var tracks: [TrackType: [TimelineSegment]] = [:]
        for item in items {
            let segment = item.segment
            tracks[item.track, default: []].append(TimelineSegment(
                id: segment.id,
                trackType: item.track,
                startTime: item.start,
                duration: segment.timelineDuration,
                sourceStartTime: segment.startTime,
                sourceEndTime: segment.endTime,
                sourceType: segment.sourceType,
                assetID: segment.assetID,
                isEnabled: segment.isEnabled,
                overlapIn: item.overlap,
                transition: segment.transition,
                transitionDuration: segment.transitionDuration,
                clipVolume: segment.clipVolume,
                audioFadeIn: segment.audioFadeIn ?? 0,
                audioFadeOut: segment.audioFadeOut ?? 0,
                narrationAssetID: segment.narrationAssetID,
                narrationVolume: segment.narrationLevel,
                speed: segment.playbackSpeed,
                transform: segment.clipTransform,
                adjustments: segment.adjustments
            ))
        }
        return TrackType.allCases.compactMap { type in
            guard let segments = tracks[type], !segments.isEmpty else { return nil }
            return TrackSegments(trackType: type, segments: segments, totalDuration: timelineEnd)
        }
    }
    
    func validateTimeline(_ episode: Episode, project: Project) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        
        if let intro = episode.effectiveIntro {
            if intro.duration <= 0 { issues.append(.zeroDuration(track: .intro)) }
            if intro.endTime > project.sourceVideoDuration && intro.sourceType == .mainVideo {
                issues.append(.outOfBounds(track: .intro, max: project.sourceVideoDuration))
            }
        }
        
        for recap in episode.effectiveRecaps {
            if recap.duration <= 0 { issues.append(.zeroDuration(track: .recap)) }
            if recap.endTime > project.sourceVideoDuration && recap.sourceType == .mainVideo {
                issues.append(.outOfBounds(track: .recap, max: project.sourceVideoDuration))
            }
        }
        
        if episode.mainDuration <= 0 { issues.append(.zeroDuration(track: .main)) }
        if episode.mainEnd > project.sourceVideoDuration { issues.append(.outOfBounds(track: .main, max: project.sourceVideoDuration)) }
        
        if let outro = episode.effectiveOutro {
            if outro.duration <= 0 { issues.append(.zeroDuration(track: .outro)) }
            if outro.endTime > project.sourceVideoDuration && outro.sourceType == .mainVideo {
                issues.append(.outOfBounds(track: .outro, max: project.sourceVideoDuration))
            }
        }
        
        return issues
    }
    
    enum TimelineError: LocalizedError {
        case cannotCreateTrack
        case invalidSegment
        case compositionFailed
        
        var errorDescription: String? {
            switch self {
            case .cannotCreateTrack: return "Não foi possível criar faixa de composição."
            case .invalidSegment: return "Segmento de timeline inválido."
            case .compositionFailed: return "Falha ao compor timeline."
            }
        }
    }
    
    enum ValidationIssue: Equatable {
        case zeroDuration(track: TrackType)
        case outOfBounds(track: TrackType, max: Double)
        case overlap(track: TrackType, segment1: UUID, segment2: UUID)
        case gap(track: TrackType, between: UUID, and: UUID)
        
        var message: String {
            switch self {
            case .zeroDuration(let track): return "\(track.rawValue): duração zero"
            case .outOfBounds(let track, let max): return "\(track.rawValue): fora dos limites (máx: \(String(format: "%.1f", max))s)"
            case .overlap(let track, _, _): return "\(track.rawValue): segmentos sobrepostos"
            case .gap(let track, _, _): return "\(track.rawValue): lacuna detectada"
            }
        }
    }
}

struct TimelineSegment: Identifiable {
    let id: UUID
    let trackType: TrackType
    var startTime: Double
    var duration: Double
    var sourceStartTime: Double
    var sourceEndTime: Double
    var sourceType: SourceType
    var assetID: UUID?
    var isEnabled: Bool
    var overlapIn: Double = 0
    var transition: TransitionStyle = .dissolve
    var transitionDuration: Double = 0.5
    var clipVolume: Float = 1
    var audioFadeIn: Double = 0
    var audioFadeOut: Double = 0
    var narrationAssetID: UUID?
    var narrationVolume: Float = 1
    var speed: Double = 1
    var transform = ClipTransform.identity
    var adjustments: ClipAdjustments?
    
    var endTime: Double { startTime + duration }
    var sourceDuration: Double { sourceEndTime - sourceStartTime }
    var isFreeze: Bool { speed < 0.2 }
}

struct TrackSegments: Identifiable {
    let id = UUID()
    let trackType: TrackType
    let segments: [TimelineSegment]
    let totalDuration: Double
}

extension TimelineEngine {
    func createTimeRange(start: Double, end: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: end - start, preferredTimescale: 600)
        )
    }
    
    func snapToFrame(_ time: Double, frameRate: Double = 30) -> Double {
        let frameDuration = 1.0 / frameRate
        return round(time / frameDuration) * frameDuration
    }
}