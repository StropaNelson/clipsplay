import Foundation
import CoreMedia
import AVFoundation

actor TimelineEngine {
    static let shared = TimelineEngine()
    
    private init() {}
    
    func buildEpisodeComposition(project: Project, episode: Episode, additionalAssets: [UUID: URL]) async throws -> (composition: AVMutableComposition, segments: [CompositionSegment]) {
        let processor = VideoProcessor.shared
        var segments: [CompositionSegment] = []
        
        if let intro = episode.effectiveIntro {
            segments.append(CompositionSegment(
                sourceType: intro.sourceType,
                assetID: intro.assetID,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: intro.startTime, preferredTimescale: 600),
                    duration: CMTime(seconds: intro.duration, preferredTimescale: 600)
                ),
                targetTrack: .intro
            ))
        }
        
        for recap in episode.effectiveRecaps {
            segments.append(CompositionSegment(
                sourceType: recap.sourceType,
                assetID: recap.assetID,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: recap.startTime, preferredTimescale: 600),
                    duration: CMTime(seconds: recap.duration, preferredTimescale: 600)
                ),
                targetTrack: .recap
            ))
        }
        
        segments.append(CompositionSegment(
            sourceType: .mainVideo,
            assetID: nil,
            timeRange: CMTimeRange(
                start: CMTime(seconds: episode.mainStart, preferredTimescale: 600),
                duration: CMTime(seconds: episode.mainDuration, preferredTimescale: 600)
            ),
            targetTrack: .main
        ))
        
        if let outro = episode.effectiveOutro {
            segments.append(CompositionSegment(
                sourceType: outro.sourceType,
                assetID: outro.assetID,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: outro.startTime, preferredTimescale: 600),
                    duration: CMTime(seconds: outro.duration, preferredTimescale: 600)
                ),
                targetTrack: .outro
            ))
        }
        
        let composition = try await processor.createComposition(from: segments, sourceURL: project.sourceVideoFileURL, additionalAssets: additionalAssets)
        return (composition, segments)
    }
    
    func buildPreviewComposition(project: Project, episode: Episode, additionalAssets: [UUID: URL], maxDuration: Double = 30) async throws -> AVMutableComposition {
        let (composition, _) = try await buildEpisodeComposition(project: project, episode: episode, additionalAssets: additionalAssets)
        
        let totalDuration = composition.duration.seconds
        if totalDuration <= maxDuration { return composition }
        
        let trimmed = AVMutableComposition()
        guard let vTrack = trimmed.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TimelineError.cannotCreateTrack
        }
        let aTrack = composition.tracks(withMediaType: .audio).first != nil ? 
            trimmed.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        
        let sourceVideo = composition.tracks(withMediaType: .video).first!
        let sourceAudio = composition.tracks(withMediaType: .audio).first
        
        try vTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTime(seconds: maxDuration, preferredTimescale: 600)),
            of: sourceVideo,
            at: .zero
        )
        vTrack.preferredTransform = sourceVideo.preferredTransform
        
        if let sourceAudio, let aTrack {
            try aTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: CMTime(seconds: maxDuration, preferredTimescale: 600)),
                of: sourceAudio,
                at: .zero
            )
        }
        
        return trimmed
    }
    
    nonisolated func computeTrackSegments(for episode: Episode, project: Project) -> [TrackSegments] {
        var tracks: [TrackType: [TimelineSegment]] = [:]
        
        for trackType in TrackType.allCases {
            tracks[trackType] = []
        }
        
        var currentTime = 0.0
        
        if let intro = episode.effectiveIntro {
            tracks[.intro]?.append(TimelineSegment(
                id: intro.id,
                trackType: .intro,
                startTime: currentTime,
                duration: intro.duration,
                sourceStartTime: intro.startTime,
                sourceEndTime: intro.endTime,
                sourceType: intro.sourceType,
                assetID: intro.assetID,
                isEnabled: intro.isEnabled
            ))
            currentTime += intro.duration
        }
        
        for recap in episode.effectiveRecaps {
            tracks[.recap]?.append(TimelineSegment(
                id: recap.id,
                trackType: .recap,
                startTime: currentTime,
                duration: recap.duration,
                sourceStartTime: recap.startTime,
                sourceEndTime: recap.endTime,
                sourceType: recap.sourceType,
                assetID: recap.assetID,
                isEnabled: recap.isEnabled
            ))
            currentTime += recap.duration
        }
        
        tracks[.main]?.append(TimelineSegment(
            id: UUID(),
            trackType: .main,
            startTime: currentTime,
            duration: episode.mainDuration,
            sourceStartTime: episode.mainStart,
            sourceEndTime: episode.mainEnd,
            sourceType: .mainVideo,
            assetID: nil,
            isEnabled: true
        ))
        currentTime += episode.mainDuration
        
        if let outro = episode.effectiveOutro {
            tracks[.outro]?.append(TimelineSegment(
                id: outro.id,
                trackType: .outro,
                startTime: currentTime,
                duration: outro.duration,
                sourceStartTime: outro.startTime,
                sourceEndTime: outro.endTime,
                sourceType: outro.sourceType,
                assetID: outro.assetID,
                isEnabled: outro.isEnabled
            ))
            currentTime += outro.duration
        }
        
        return TrackType.allCases.compactMap { type in
            guard let segments = tracks[type], !segments.isEmpty else { return nil }
            return TrackSegments(trackType: type, segments: segments, totalDuration: currentTime)
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