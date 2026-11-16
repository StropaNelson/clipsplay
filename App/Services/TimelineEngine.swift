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
        let processor = VideoProcessor.shared
        var segments: [CompositionSegment] = []
        
        if let intro = episode.effectiveIntro, intro.isEnabled {
            segments.append(CompositionSegment(
                sourceType: intro.sourceType,
                assetID: intro.assetID,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: intro.startTime, preferredTimescale: 600),
                    duration: CMTime(seconds: intro.duration, preferredTimescale: 600)
                ),
                targetTrack: .intro,
                timelineStartTime: intro.timelineStartTime
            ))
        }
        
        for recap in episode.effectiveRecaps where recap.isEnabled {
            segments.append(CompositionSegment(
                sourceType: recap.sourceType,
                assetID: recap.assetID,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: recap.startTime, preferredTimescale: 600),
                    duration: CMTime(seconds: recap.duration, preferredTimescale: 600)
                ),
                targetTrack: .recap,
                timelineStartTime: recap.timelineStartTime
            ))
        }
        
        segments.append(CompositionSegment(
            sourceType: .mainVideo,
            assetID: nil,
            timeRange: CMTimeRange(
                start: CMTime(seconds: episode.mainStart, preferredTimescale: 600),
                duration: CMTime(seconds: episode.mainDuration, preferredTimescale: 600)
            ),
            targetTrack: .main,
            timelineStartTime: episode.mainTimelineStartTime
        ))
        
        if let outro = episode.effectiveOutro, outro.isEnabled {
            segments.append(CompositionSegment(
                sourceType: outro.sourceType,
                assetID: outro.assetID,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: outro.startTime, preferredTimescale: 600),
                    duration: CMTime(seconds: outro.duration, preferredTimescale: 600)
                ),
                targetTrack: .outro,
                timelineStartTime: outro.timelineStartTime
            ))
        }
        
        return try await processor.createComposition(
            from: segments,
            sourceURL: project.sourceVideoFileURL,
            additionalAssets: additionalAssets,
            aspect: settings?.aspectRatio ?? project.aspectRatio,
            resolution: settings?.resolution ?? project.resolution,
            fitMode: settings?.fitMode ?? project.fitMode
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
        var tracks: [TrackType: [TimelineSegment]] = [:]
        
        for trackType in TrackType.allCases {
            tracks[trackType] = []
        }
        
        var currentTime = 0.0
        var timelineEnd = 0.0
        var previousDuration = 0.0
        var hasPreviousSegment = false

        func nextStart(_ customStart: Double?, duration: Double) -> Double {
            let overlap = hasPreviousSegment ? min(0.35, min(previousDuration / 3, duration / 3)) : 0
            return customStart ?? max(0, currentTime - overlap)
        }

        func updateCursor(startTime: Double, duration: Double) {
            let endTime = startTime + duration
            currentTime = max(currentTime, endTime)
            timelineEnd = max(timelineEnd, endTime)
            previousDuration = duration
            hasPreviousSegment = true
        }
        
        if let intro = episode.effectiveIntro, intro.isEnabled {
            let startTime = nextStart(intro.timelineStartTime, duration: intro.duration)
            tracks[.intro]?.append(TimelineSegment(
                id: intro.id,
                trackType: .intro,
                startTime: startTime,
                duration: intro.duration,
                sourceStartTime: intro.startTime,
                sourceEndTime: intro.endTime,
                sourceType: intro.sourceType,
                assetID: intro.assetID,
                isEnabled: intro.isEnabled
            ))
            updateCursor(startTime: startTime, duration: intro.duration)
        }
        
        for recap in episode.effectiveRecaps where recap.isEnabled {
            let startTime = nextStart(recap.timelineStartTime, duration: recap.duration)
            tracks[.recap]?.append(TimelineSegment(
                id: recap.id,
                trackType: .recap,
                startTime: startTime,
                duration: recap.duration,
                sourceStartTime: recap.startTime,
                sourceEndTime: recap.endTime,
                sourceType: recap.sourceType,
                assetID: recap.assetID,
                isEnabled: recap.isEnabled
            ))
            updateCursor(startTime: startTime, duration: recap.duration)
        }
        
        let mainStartTime = nextStart(episode.mainTimelineStartTime, duration: episode.mainDuration)
        tracks[.main]?.append(TimelineSegment(
            id: episode.id,
            trackType: .main,
            startTime: mainStartTime,
            duration: episode.mainDuration,
            sourceStartTime: episode.mainStart,
            sourceEndTime: episode.mainEnd,
            sourceType: .mainVideo,
            assetID: nil,
            isEnabled: true
        ))
        updateCursor(startTime: mainStartTime, duration: episode.mainDuration)
        
        if let outro = episode.effectiveOutro, outro.isEnabled {
            let startTime = nextStart(outro.timelineStartTime, duration: outro.duration)
            tracks[.outro]?.append(TimelineSegment(
                id: outro.id,
                trackType: .outro,
                startTime: startTime,
                duration: outro.duration,
                sourceStartTime: outro.startTime,
                sourceEndTime: outro.endTime,
                sourceType: outro.sourceType,
                assetID: outro.assetID,
                isEnabled: outro.isEnabled
            ))
            updateCursor(startTime: startTime, duration: outro.duration)
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
    
    var endTime: Double { startTime + duration }
    var sourceDuration: Double { sourceEndTime - sourceStartTime }
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