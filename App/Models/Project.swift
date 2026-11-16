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
    var episodes: [Episode]
    var mediaAssets: [MediaAsset]
    var introTemplate: SegmentTemplate?
    var outroTemplate: SegmentTemplate?
    var recapSettings: RecapSettings
    var coverSettings: CoverSettings
    
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
        self.episodes = []
        self.mediaAssets = []
        self.introTemplate = nil
        self.outroTemplate = nil
        self.recapSettings = RecapSettings()
        self.coverSettings = CoverSettings()
    }
    
    var sourceVideoFileURL: URL {
        URL(fileURLWithPath: sourceVideoURL)
    }
    
    mutating func updateTimestamp() {
        updatedAt = Date()
    }
    
    mutating func regenerateEpisodes() {
        let count = Int(ceil(sourceVideoDuration / episodeLength))
        episodes = (0..<count).map { index in
            let start = Double(index) * episodeLength
            let end = min(sourceVideoDuration, start + episodeLength)
            return Episode(
                index: index,
                mainStart: start,
                mainEnd: end,
                introTemplate: introTemplate,
                outroTemplate: outroTemplate,
                recapSettings: recapSettings
            )
        }
        updateTimestamp()
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
        
        if recapSettings.enabled {
            if recapSettings.mode == .automatic && index > 0 {
                let recapEnd = mainStart
                let recapStart = max(0, recapEnd - recapSettings.duration)
                self.recapSegments = [VideoSegment(startTime: recapStart, endTime: recapEnd, sourceType: .mainVideo)]
            } else if recapSettings.mode == .manual {
                self.recapSegments = recapSettings.manualSegments.map { VideoSegment(startTime: $0.startTime, endTime: $0.endTime, sourceType: .mainVideo) }
            }
        }
    }
    
    var mainDuration: Double { mainEnd - mainStart }
    var totalDuration: Double {
        var dur = mainDuration
        if let intro = effectiveIntro { dur += intro.duration }
        if let outro = effectiveOutro { dur += outro.duration }
        dur += recapSegments.reduce(0) { $0 + $1.duration }
        dur += customRecapSegments.reduce(0) { $0 + $1.duration }
        return dur
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
            recapSegments = settings.manualSegments.map { VideoSegment(startTime: $0.startTime, endTime: $0.endTime, sourceType: .mainVideo) }
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
    
    init(startTime: Double, endTime: Double, sourceType: SourceType, assetID: UUID? = nil, trackIndex: Int = 0, isEnabled: Bool = true) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.sourceType = sourceType
        self.assetID = assetID
        self.trackIndex = trackIndex
        self.isEnabled = isEnabled
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
        VideoSegment(startTime: startTime, endTime: endTime, sourceType: sourceType, assetID: assetID)
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
    
    init(name: String, fileURL: URL, type: AssetType, duration: Double, naturalSize: CGSize, fileSize: Int64, thumbnailURL: URL?) {
        self.id = UUID()
        self.name = name
        self.fileURL = fileURL.path
        self.type = type
        self.duration = duration
        self.naturalSize = CGSizeCodable(naturalSize)
        self.fileSize = fileSize
        self.createdAt = Date()
        self.thumbnailURL = thumbnailURL?.path
    }
    
    var url: URL { URL(fileURLWithPath: fileURL) }
    var thumbnailFileURL: URL? { thumbnailURL.map { URL(fileURLWithPath: $0) } }

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