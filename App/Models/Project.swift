import Foundation
import CoreMedia
import AVFoundation

struct Project: Codable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var sourceVideoURL: String
    var sourceVideoDuration: Double
    var sourceVideoNaturalSize: CGSizeCodable
    var sourceVideoTransform: CGAffineTransformCodable
    var episodeLength: Double
    var seriesTitle: String
    var episodeTitleTemplate: String
    var aspectRatio: AspectRatio
    var resolution: ExportResolution
    var fitMode: FitMode
    var operation: ProjectOperation?
    var episodes: [Episode]
    var mediaAssets: [MediaAsset]
    var introTemplate: SegmentTemplate?
    var outroTemplate: SegmentTemplate?
    var recapSettings: RecapSettings
    var coverSettings: CoverSettings
    var transcriptSRT: String?
    /// Word timings of the transcript, against the source video sequence.
    var transcriptWords: [TranscriptWord]?
    /// Source-sequence duration known to be covered by the saved transcript.
    /// nil means legacy data, which is only trusted for single-video projects.
    var transcriptSequenceDuration: Double?
    /// Project vocabulary (brands, names, technical terms) used to bias transcription and corrections.
    var transcriptionVocabulary: [String]?
    var sceneCuts: [Double]?
    /// Original source clips concatenated for analysis/transcription. Each clip keeps
    /// its own source range plus the offset where it starts in the sequence.
    var storedSourceClips: [VideoSegment]?
    var storedGlobalOverlays: [TextOverlay]?
    var storedGlobalAudioClips: [AudioClip]?
    /// Reusable text style templates ("identidade") saved by the user.
    var textTemplates: [TextStyleTemplate]?

    var globalOverlays: [TextOverlay] {
        get { storedGlobalOverlays ?? [] }
        set { storedGlobalOverlays = newValue }
    }

    var globalAudioClips: [AudioClip] {
        get { storedGlobalAudioClips ?? [] }
        set { storedGlobalAudioClips = newValue }
    }
    
    init(name: String, sourceVideoURL: URL, sourceVideoDuration: Double, naturalSize: CGSize, transform: CGAffineTransform) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.updatedAt = Date()
        self.sourceVideoURL = sourceVideoURL.path
        self.sourceVideoDuration = sourceVideoDuration
        self.sourceVideoNaturalSize = CGSizeCodable(naturalSize)
        self.sourceVideoTransform = CGAffineTransformCodable(transform)
        self.episodeLength = 60
        self.seriesTitle = "Minha Série"
        self.episodeTitleTemplate = "Episódio"
        self.aspectRatio = .original
        self.resolution = .original
        self.fitMode = .fit
        self.operation = nil
        self.episodes = []
        self.mediaAssets = []
        self.introTemplate = nil
        self.outroTemplate = nil
        self.recapSettings = RecapSettings()
        self.coverSettings = CoverSettings()
        self.transcriptionVocabulary = nil
        self.storedSourceClips = nil
    }
    
    var sourceVideoFileURL: URL {
        StoredFileLocator.resolve(sourceVideoURL)
    }

    /// Media used as the source for analysis/transcription. A single-video project
    /// falls back to the recorded source; multi-video imports store all parts here.
    var sourceClips: [VideoSegment] {
        get {
            if let clips = storedSourceClips, !clips.isEmpty { return clips }
            let episodeClips = episodes.first?.mainClips ?? []
            guard episodeClips.contains(where: { $0.sourceType == .clipAsset || $0.sequenceStartTime > 0.001 }) else {
                return [VideoSegment(
                    startTime: 0,
                    endTime: sourceVideoDuration,
                    sourceType: .mainVideo,
                    sequenceStart: 0
                )]
            }

            var result = [VideoSegment(
                startTime: 0,
                endTime: sourceVideoDuration,
                sourceType: .mainVideo,
                sequenceStart: 0
            )]
            var cursor = sourceVideoDuration
            var seenAssets: Set<UUID> = []
            for clip in episodeClips where clip.sourceType == .clipAsset {
                guard let assetID = clip.assetID, !seenAssets.contains(assetID) else { continue }
                seenAssets.insert(assetID)
                let assetDuration = mediaAssets.first { $0.id == assetID }?.duration ?? clip.endTime
                let base = clip.sequenceStartTime > 0.001 ? clip.sequenceStartTime : cursor
                result.append(VideoSegment(
                    startTime: 0,
                    endTime: assetDuration,
                    sourceType: .clipAsset,
                    assetID: assetID,
                    sequenceStart: base
                ))
                cursor = max(cursor, base + assetDuration)
            }
            return result.count > 1 ? result : [VideoSegment(
                startTime: 0,
                endTime: sourceVideoDuration,
                sourceType: .mainVideo,
                sequenceStart: 0
            )]
        }
        set { storedSourceClips = newValue.isEmpty ? nil : newValue }
    }

    var sequenceSourceDuration: Double {
        max(sourceVideoDuration, sourceClips.map(\.sequenceEndTime).max() ?? 0)
    }

    func sourceURL(for clip: VideoSegment) -> URL? {
        if clip.sourceType == .mainVideo { return sourceVideoFileURL }
        guard let assetID = clip.assetID else { return nil }
        return mediaAssets.first { $0.id == assetID }?.url
    }

    func sourceLocation(at sequenceTime: Double) -> (url: URL, time: Double)? {
        guard let clip = sourceClips.first(where: {
            sequenceTime >= $0.sequenceStartTime + $0.startTime && sequenceTime < $0.sequenceStartTime + $0.endTime
        }) ?? sourceClips.last,
              let url = sourceURL(for: clip) else { return nil }
        let local = min(clip.endTime, max(clip.startTime, sequenceTime - clip.sequenceStartTime))
        return (url, local)
    }

    var transcriptionSources: [TranscriptionSource] {
        sourceClips.compactMap { clip in
            guard let url = sourceURL(for: clip) else { return nil }
            return TranscriptionSource(
                name: url.lastPathComponent,
                url: url,
                offset: clip.sequenceStartTime,
                startTime: clip.startTime,
                endTime: clip.endTime
            )
        }
    }

    /// Returns the offset where this asset starts in the transcript sequence, adding
    /// it to the source list when a library clip is used as main content.
    mutating func registerSourceClip(for asset: MediaAsset) -> Double {
        if asset.url.path == sourceVideoFileURL.path { return 0 }
        if let existing = sourceClips.first(where: { $0.assetID == asset.id }) {
            return existing.sequenceStartTime
        }
        let offset = sequenceSourceDuration
        var clips = sourceClips
        clips.append(VideoSegment(
            startTime: 0,
            endTime: asset.duration,
            sourceType: .clipAsset,
            assetID: asset.id,
            sequenceStart: offset
        ))
        sourceClips = clips
        return offset
    }

    /// Converts a range in the concatenated source sequence into playable timeline clips.
    func sourceSegments(in range: ClosedRange<Double>) -> [VideoSegment] {
        sourceClips.compactMap { source in
            let sourceOffset = source.sequenceStartTime
            let clipSequenceStart = sourceOffset + source.startTime
            let clipSequenceEnd = sourceOffset + source.endTime
            guard range.upperBound > clipSequenceStart, range.lowerBound < clipSequenceEnd else { return nil }
            let localStart = max(source.startTime, range.lowerBound - sourceOffset)
            let localEnd = min(source.endTime, range.upperBound - sourceOffset)
            guard localEnd - localStart > 0.05 else { return nil }
            var piece = VideoSegment(
                startTime: localStart,
                endTime: localEnd,
                sourceType: source.sourceType,
                assetID: source.assetID,
                sequenceStart: sourceOffset
            )
            piece.clipTransform = source.clipTransform
            piece.adjustments = source.adjustments
            return piece
        }
    }
    
    mutating func updateTimestamp() {
        updatedAt = Date()
    }
    
    mutating func regenerateEpisodes() {
        let sequenceDuration = sequenceSourceDuration
        if operation == .speechEdit {
            var episode = Episode(
                index: 0,
                mainStart: 0,
                mainEnd: sequenceDuration,
                introTemplate: introTemplate,
                outroTemplate: outroTemplate,
                recapSettings: recapSettings
            )
            episode.displayTitle = "Clipe inteiro"
            episode.mainClips = sourceSegments(in: 0...sequenceDuration)
            episodes = [episode]
            updateTimestamp()
            return
        }
        let count = EpisodePlanner.episodeCount(totalDuration: sequenceDuration, targetLength: episodeLength)
        let ideal = EpisodePlanner.idealCuts(totalDuration: sequenceDuration, count: count)
        let hardBoundaries = sourceClips.dropFirst().map { $0.sequenceStartTime + $0.startTime }
        let cuts = EpisodePlanner.snappedCuts(
            ideal: ideal,
            totalDuration: sequenceDuration,
            words: transcriptWords ?? [],
            quietPoints: [],
            hardBoundaries: hardBoundaries
        ).map(\.time)
        episodes = buildEpisodes(fromCuts: cuts)
        updateTimestamp()
    }
    
    /// Rebuilds episodes at detected topic boundaries instead of fixed-length slices.
    /// Slivers shorter than ~5s are merged into the surrounding segment.
    /// Returns the number of boundary cuts applied (0 when none could be used).
    @discardableResult
    mutating func createEpisodes(at boundaries: [Double]) -> Int {
        let minimum = 5.0
        let sequenceDuration = sequenceSourceDuration
        var cuts = boundaries
            .sorted()
            .filter { $0 > minimum && $0 < sequenceDuration - minimum }
        var merged: [Double] = []
        for cut in cuts {
            if let last = merged.last, cut - last < minimum { continue }
            merged.append(cut)
        }
        cuts = merged
        guard !cuts.isEmpty else { return 0 }
        episodes = buildEpisodes(fromCuts: cuts)
        updateTimestamp()
        return cuts.count
    }

    /// Sequential series ("novelinha"): the whole sequence split in order, no gaps.
    /// Empty cuts produce a single episode covering the whole sequence.
    mutating func createSequentialEpisodes(at cuts: [Double]) {
        let sequenceDuration = sequenceSourceDuration
        let minimum = 2.0
        var ordered = cuts.sorted().filter { $0 > minimum && $0 < sequenceDuration - minimum }
        var deduped: [Double] = []
        for cut in ordered {
            if let last = deduped.last, cut - last < minimum { continue }
            deduped.append(cut)
        }
        ordered = deduped
        episodes = buildEpisodes(fromCuts: ordered)
        updateTimestamp()
    }

    private mutating func buildEpisodes(fromCuts cuts: [Double]) -> [Episode] {
        let sequenceDuration = sequenceSourceDuration
        var ranges: [(Double, Double)] = []
        var cursor = 0.0
        for cut in cuts {
            ranges.append((cursor, cut))
            cursor = cut
        }
        ranges.append((cursor, sequenceDuration))
        return ranges.enumerated().map { index, range in
            var episode = Episode(
                index: index,
                mainStart: range.0,
                mainEnd: range.1,
                introTemplate: introTemplate,
                outroTemplate: outroTemplate,
                recapSettings: recapSettings
            )
            episode.mainClips = sourceSegments(in: range.0...range.1)
            if let recap = episode.recapSegments.first, recap.sourceType == .mainVideo {
                episode.recapSegments = sourceSegments(in: recap.startTime...recap.endTime)
            }
            return episode
        }
    }
}

enum AspectRatio: String, Codable, CaseIterable, Identifiable {
    case original = "Original"
    case landscape16_9 = "16:9"
    case portrait9_16 = "9:16"
    case square1_1 = "1:1"
    case portrait4_5 = "4:5"
    case portrait3_4 = "3:4"
    
    var id: String { rawValue }
    
    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .landscape16_9: return 16.0/9.0
        case .portrait9_16: return 9.0/16.0
        case .square1_1: return 1.0
        case .portrait4_5: return 4.0/5.0
        case .portrait3_4: return 3.0/4.0
        }
    }
}

enum ExportResolution: String, Codable, CaseIterable, Identifiable {
    case original = "Original"
    case p480 = "480p"
    case p720 = "720p"
    case p1080 = "1080p"
    case p1440 = "1440p"
    case p2160 = "2160p"
    
    var id: String { rawValue }
    
    var presetName: String {
        switch self {
        case .original: return AVAssetExportPresetHighestQuality
        case .p480: return AVAssetExportPreset640x480
        case .p720: return AVAssetExportPreset1280x720
        case .p1080: return AVAssetExportPreset1920x1080
        case .p1440, .p2160: return AVAssetExportPresetHighestQuality
        }
    }
    
    var longSide: CGFloat? {
        switch self {
        case .original: return nil
        case .p480: return 854
        case .p720: return 1280
        case .p1080: return 1920
        case .p1440: return 2560
        case .p2160: return 3840
        }
    }
}

enum FitMode: String, Codable, CaseIterable, Identifiable {
    case fit = "Ajustar"
    case fill = "Preencher"
    
    var id: String { rawValue }
}

struct Episode: Codable, Identifiable {
    let id: UUID
    var index: Int
    var mainStart: Double
    var mainEnd: Double
    var introSegment: VideoSegment?
    var recapSegments: [VideoSegment]
    var outroSegment: VideoSegment?
    var customIntroTemplate: SegmentTemplate?
    var customOutroTemplate: SegmentTemplate?
    var customRecapSegments: [VideoSegment]
    var useGlobalIntro: Bool
    var useGlobalOutro: Bool
    var useGlobalRecap: Bool
    var mainTimelineStartTime: Double?
    var storedMainClips: [VideoSegment]?
    var storedTextOverlays: [TextOverlay]?
    var storedAudioClips: [AudioClip]?
    var storedMediaOverlays: [MediaOverlay]?
    var storedMarkers: [TimelineMarker]?
    var displayTitle: String?
    /// Optional output-specific format generated by automation; nil follows the project/export setting.
    var outputAspectRatio: AspectRatio?
    /// Distinguishes a manually curated recap after normalization clears transient custom fields.
    var usesCustomRecapSegments: Bool?
    
    init(index: Int, mainStart: Double, mainEnd: Double, introTemplate: SegmentTemplate?, outroTemplate: SegmentTemplate?, recapSettings: RecapSettings) {
        self.id = UUID()
        self.index = index
        self.mainStart = mainStart
        self.mainEnd = mainEnd
        self.introSegment = introTemplate?.toSegment()
        self.outroSegment = outroTemplate?.toSegment()
        self.recapSegments = []
        self.customIntroTemplate = nil
        self.customOutroTemplate = nil
        self.customRecapSegments = []
        self.useGlobalIntro = introTemplate != nil
        self.useGlobalOutro = outroTemplate != nil
        self.useGlobalRecap = true
        self.mainTimelineStartTime = nil
        self.outputAspectRatio = nil
        self.usesCustomRecapSegments = nil
        
        if recapSettings.enabled {
            if recapSettings.mode == .automatic && index > 0 {
                let recapEnd = mainStart
                let recapStart = max(0, recapEnd - recapSettings.duration)
                self.recapSegments = [VideoSegment(startTime: recapStart, endTime: recapEnd, sourceType: .mainVideo)]
            } else if recapSettings.mode == .manual {
                self.recapSegments = recapSettings.manualSegments
            }
        }
    }
    
    var mainDuration: Double { mainClips.reduce(0) { $0 + $1.timelineDuration } }

    var title: String { displayTitle ?? "Episódio \(index + 1)" }

    /// Drops fixed timeline positions so clips flow sequentially (intro → recap → main → outro).
    mutating func clearTimelinePins() {
        mainTimelineStartTime = nil
        introSegment?.timelineStartTime = nil
        outroSegment?.timelineStartTime = nil
        for index in recapSegments.indices { recapSegments[index].timelineStartTime = nil }
        for index in customRecapSegments.indices { customRecapSegments[index].timelineStartTime = nil }
    }
    var totalDuration: Double {
        storyline().last?.end ?? 0
    }
    
    var effectiveIntro: VideoSegment? {
        if let custom = customIntroTemplate?.toSegment() { return custom }
        if useGlobalIntro { return introSegment }
        return nil
    }
    
    var effectiveOutro: VideoSegment? {
        if let custom = customOutroTemplate?.toSegment() { return custom }
        if useGlobalOutro { return outroSegment }
        return nil
    }
    
    var effectiveRecaps: [VideoSegment] {
        if !customRecapSegments.isEmpty { return customRecapSegments }
        if useGlobalRecap { return recapSegments }
        return []
    }
    
    mutating func regenerateRecap(previousEpisodeEnd: Double?, settings: RecapSettings) {
        guard settings.enabled else { recapSegments = []; return }
        if settings.mode == .automatic, let prevEnd = previousEpisodeEnd {
            let end = min(prevEnd, mainStart)
            let start = max(0, end - settings.duration)
            recapSegments = [VideoSegment(startTime: start, endTime: end, sourceType: .mainVideo)]
        } else if settings.mode == .manual {
            recapSegments = settings.manualSegments
        }
    }
}

struct VideoSegment: Codable, Identifiable, Hashable {
    let id: UUID
    var startTime: Double
    var endTime: Double
    var sourceType: SourceType
    var assetID: UUID?
    var trackIndex: Int
    var isEnabled: Bool
    var timelineStartTime: Double?
    var transitionStyle: TransitionStyle?
    var transitionLength: Double?
    var volume: Float?
    var narrationAssetID: UUID?
    var narrationVolume: Float?
    var narrationOffset: Double?
    /// Extra fade applied to the clip's own audio, on top of transition crossfades (seconds).
    var audioFadeIn: Double?
    var audioFadeOut: Double?
    var speed: Double?
    var transformScale: Double?
    var transformRotation: Double?
    var transformOffsetX: Double?
    var transformOffsetY: Double?
    var adjustments: ClipAdjustments?
    /// Offset of this clip's source inside the concatenated project source sequence.
    /// nil means the primary video, which starts at zero.
    var sequenceStart: Double?
    
    init(
        id: UUID = UUID(),
        startTime: Double,
        endTime: Double,
        sourceType: SourceType,
        assetID: UUID? = nil,
        trackIndex: Int = 0,
        isEnabled: Bool = true,
        timelineStartTime: Double? = nil,
        transitionStyle: TransitionStyle? = nil,
        narrationAssetID: UUID? = nil,
        volume: Float? = nil,
        sequenceStart: Double? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.sourceType = sourceType
        self.assetID = assetID
        self.trackIndex = trackIndex
        self.isEnabled = isEnabled
        self.timelineStartTime = timelineStartTime
        self.transitionStyle = transitionStyle
        self.narrationAssetID = narrationAssetID
        self.volume = volume
        self.sequenceStart = sequenceStart
    }
    
    var duration: Double { max(0, endTime - startTime) }
    var timeRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: startTime, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
    }
}

enum SourceType: String, Codable, CaseIterable, Identifiable {
    case mainVideo = "Vídeo Principal"
    case introAsset = "Asset de Introdução"
    case outroAsset = "Asset de Encerramento"
    case recapAsset = "Asset de Recapitulação"
    case audioAsset = "Asset de Áudio"
    case imageAsset = "Asset de Imagem"
    case clipAsset = "Clipe da Biblioteca"
    
    var id: String { rawValue }
}

struct SegmentTemplate: Codable, Identifiable {
    let id: UUID
    var name: String
    var sourceType: SourceType
    var assetID: UUID?
    var startTime: Double
    var endTime: Double
    var targetTrack: TrackType
    var narrationAssetID: UUID?
    var clipVolume: Float?
    
    init(name: String, sourceType: SourceType, assetID: UUID?, startTime: Double, endTime: Double, targetTrack: TrackType) {
        self.id = UUID()
        self.name = name
        self.sourceType = sourceType
        self.assetID = assetID
        self.startTime = startTime
        self.endTime = endTime
        self.targetTrack = targetTrack
    }
    
    func toSegment() -> VideoSegment {
        VideoSegment(
            startTime: startTime,
            endTime: endTime,
            sourceType: sourceType,
            assetID: assetID,
            narrationAssetID: narrationAssetID,
            volume: clipVolume
        )
    }
}

enum TrackType: String, Codable, CaseIterable, Identifiable {
    case intro = "Introdução"
    case recap = "Recapitulação"
    case main = "Conteúdo Principal"
    case outro = "Encerramento"
    case audio = "Áudio/Música"
    case overlay = "Textos/Gráficos"
    
    var id: String { rawValue }
    
    var displayOrder: Int {
        switch self {
        case .intro: return 0
        case .recap: return 1
        case .main: return 2
        case .outro: return 3
        case .audio: return 4
        case .overlay: return 5
        }
    }
}

struct RecapSettings: Codable {
    var enabled: Bool = false
    var mode: RecapMode = .manual
    var duration: Double = 8
    var manualSegments: [VideoSegment] = []
    
    enum RecapMode: String, Codable, CaseIterable, Identifiable {
        case manual = "Manual"
        case automatic = "Final do Episódio Anterior"
        var id: String { rawValue }
    }
}

struct CoverSettings: Codable {
    var enabled: Bool = true
    var mode: CoverMode = .captureFrame
    var templateName: String = "Padrão"
    var captureTime: Double = 0
    var customImageAssetID: UUID?
    
    enum CoverMode: String, Codable, CaseIterable, Identifiable {
        case captureFrame = "Capturar Quadro"
        case template = "Modelo Padrão"
        case customImage = "Imagem Personalizada"
        var id: String { rawValue }
    }
}

struct MediaAsset: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var fileURL: String
    var type: AssetType
    var duration: Double
    var naturalSize: CGSizeCodable
    var fileSize: Int64
    var createdAt: Date
    var thumbnailURL: String?
    
    init(name: String, fileURL: URL, type: AssetType, duration: Double, naturalSize: CGSize, fileSize: Int64, thumbnailURL: URL?, createdAt: Date? = nil) {
        self.id = UUID()
        self.name = name
        self.fileURL = fileURL.path
        self.type = type
        self.duration = duration
        self.naturalSize = CGSizeCodable(naturalSize)
        self.fileSize = fileSize
        self.createdAt = createdAt ?? Date()
        self.thumbnailURL = thumbnailURL?.path
    }
    
    var url: URL { StoredFileLocator.resolve(fileURL) }
    var thumbnailFileURL: URL? { thumbnailURL.map { StoredFileLocator.resolve($0) } }

    static func == (lhs: MediaAsset, rhs: MediaAsset) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum AssetType: String, Codable, CaseIterable, Identifiable {
    case video = "Vídeo"
    case audio = "Áudio"
    case image = "Imagem"
    var id: String { rawValue }
}

struct CGSizeCodable: Codable, Equatable {
    var width: CGFloat
    var height: CGFloat
    
    init(_ size: CGSize = .zero) {
        self.width = size.width
        self.height = size.height
    }
    
    var cgSize: CGSize { CGSize(width: width, height: height) }
}

struct CGAffineTransformCodable: Codable, Equatable {
    var a: CGFloat
    var b: CGFloat
    var c: CGFloat
    var d: CGFloat
    var tx: CGFloat
    var ty: CGFloat
    
    init(_ transform: CGAffineTransform = .identity) {
        self.a = transform.a
        self.b = transform.b
        self.c = transform.c
        self.d = transform.d
        self.tx = transform.tx
        self.ty = transform.ty
    }
    
    var cgAffineTransform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

extension Project {
    static func sample() -> Project {
        Project(name: "Projeto Exemplo", sourceVideoURL: URL(fileURLWithPath: "/tmp/sample.mov"), sourceVideoDuration: 600, naturalSize: CGSize(width: 1920, height: 1080), transform: .identity)
    }
}

/// Projects store absolute paths, but the app container path can change between runs
/// (e.g. when Swift Playgrounds reinstalls the app). Falls back to the app's media folders.
enum StoredFileLocator {
    private static let folders = ["ClipStudio_Media", "ClipStudio_Thumbnails"]

    static func resolve(_ path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) { return url }
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return url }
        for folder in folders {
            let candidate = docs
                .appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
