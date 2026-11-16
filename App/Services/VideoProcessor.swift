import Foundation
import AVFoundation
import CoreMedia
import UIKit

actor VideoProcessor {
    static let shared = VideoProcessor()
    
    private init() {}
    
    func getVideoInfo(for url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { throw ProcessorError.noVideoTrack }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let hasAudio = !audioTracks.isEmpty
        
        let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        
        return VideoInfo(
            duration: duration,
            naturalSize: naturalSize,
            preferredTransform: transform,
            frameRate: frameRate,
            hasAudio: hasAudio,
            fileSize: fileSize ?? 0
        )
    }
    
    func extractSegment(from sourceURL: URL, startTime: Double, endTime: Double, outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let composition = AVMutableComposition()
        
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sourceVideoTracks = try? await asset.loadTracks(withMediaType: .video),
              let sourceVideo = sourceVideoTracks.first else {
            throw ProcessorError.cannotCreateTrack
        }
        
        let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first
        let audioTrack = sourceAudio != nil ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        
        let timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            duration: CMTime(seconds: endTime - startTime, preferredTimescale: 600)
        )
        
        try videoTrack.insertTimeRange(timeRange, of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
        
        if let sourceAudio, let audioTrack {
            try audioTrack.insertTimeRange(timeRange, of: sourceAudio, at: .zero)
        }
        
        try await exportComposition(composition, to: outputURL, preset: AVAssetExportPresetHighestQuality)
    }
    
    func createComposition(from segments: [CompositionSegment], sourceURL: URL, additionalAssets: [UUID: URL]) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first else { throw ProcessorError.noVideoTrack }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let sourceAudio = audioTracks.first
        let sourceTransform = try await sourceVideo.load(.preferredTransform)
        
        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProcessorError.cannotCreateTrack
        }
        let aTrack = sourceAudio != nil ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        
        var cursor = CMTime.zero
        for segment in segments {
            let tracks = try await getTrackForSegment(segment, sourceVideo: sourceVideo, sourceAudio: sourceAudio, additionalAssets: additionalAssets)
            let range = segment.timeRange
            try vTrack.insertTimeRange(range, of: tracks.video, at: cursor)
            if let sourceAudio = tracks.audio, let aTrack = aTrack {
                try aTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        
        vTrack.preferredTransform = sourceTransform
        return composition
    }
    
    func exportComposition(_ composition: AVComposition, to outputURL: URL, preset: String, videoComposition: AVVideoComposition? = nil) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ProcessorError.exportSessionUnavailable
        }
        
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = videoComposition
        
        try await runExport(exporter)
    }
    
    func createVideoComposition(for track: AVCompositionTrack, renderSize: CGSize, transform: CGAffineTransform, sourceSize: CGSize, fitMode: FitMode) -> AVMutableVideoComposition {
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: track.timeRange.duration)
        
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        
        let transformedRect = CGRect(origin: .zero, size: sourceSize).applying(transform)
        var base = transform.concatenating(CGAffineTransform(translationX: -transformedRect.minX, y: -transformedRect.minY))
        let orientedW = abs(transformedRect.width)
        let orientedH = abs(transformedRect.height)
        let sx = renderSize.width / max(orientedW, 1)
        let sy = renderSize.height / max(orientedH, 1)
        let scale = fitMode == .fill ? max(sx, sy) : min(sx, sy)
        base = base.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let scaledW = orientedW * scale
        let scaledH = orientedH * scale
        let tx = (renderSize.width - scaledW) / 2
        let ty = (renderSize.height - scaledH) / 2
        base = base.concatenating(CGAffineTransform(translationX: tx, y: ty))
        layer.setTransform(base, at: .zero)
        
        instruction.layerInstructions = [layer]
        videoComp.instructions = [instruction]
        return videoComp
    }
    
    func calculateRenderSize(aspect: AspectRatio, resolution: ExportResolution, naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let sourceW = abs(rect.width)
        let sourceH = abs(rect.height)
        
        guard let ratio = aspect.ratio else { return CGSize(width: sourceW, height: sourceH) }
        guard let longSide = resolution.longSide else { return CGSize(width: sourceW, height: sourceH) }
        
        if ratio >= 1 { return CGSize(width: longSide, height: longSide/ratio) }
        return CGSize(width: longSide*ratio, height: longSide)
    }
    
    func generateCover(for project: Project, episode: Episode, episodeNumber: Int, settings: CoverSettings) async throws -> Data {
        switch settings.mode {
        case .template:
            return try makeTemplateCover(project: project, episode: episode, number: episodeNumber)
        case .captureFrame:
            return try await captureFrameCover(project: project, episode: episode, captureTime: settings.captureTime)
        case .customImage:
            guard let assetID = settings.customImageAssetID,
                  let asset = project.mediaAssets.first(where: { $0.id == assetID }),
                  asset.type == .image,
                  let data = try? Data(contentsOf: asset.url) else {
                return try makeTemplateCover(project: project, episode: episode, number: episodeNumber)
            }
            return data
        }
    }
    
    private func makeTemplateCover(project: Project, episode: Episode, number: Int) throws -> Data {
        let size = CGSize(width: 1080, height: 1350)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: 0.055, green: 0.09, blue: 0.16, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let title = "\(project.seriesTitle)\n\(project.episodeTitleTemplate) \(number)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 76),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            (title as NSString).draw(in: CGRect(x: 70, y: 470, width: 940, height: 360), withAttributes: attrs)
            let sub = "CLIPSTUDIO"
            (sub as NSString).draw(in: CGRect(x: 70, y: 1120, width: 940, height: 80), withAttributes: [
                .font: UIFont.systemFont(ofSize: 30, weight: .semibold),
                .foregroundColor: UIColor.systemBlue,
                .paragraphStyle: paragraph
            ])
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
    
    private func captureFrameCover(project: Project, episode: Episode, captureTime: Double) async throws -> Data {
        let asset = AVURLAsset(url: project.sourceVideoFileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        
        let time = CMTime(seconds: captureTime, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        let image = UIImage(cgImage: cgImage)
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
    
    private func getTrackForSegment(_ segment: CompositionSegment, sourceVideo: AVAssetTrack, sourceAudio: AVAssetTrack?, additionalAssets: [UUID: URL]) async throws -> (video: AVAssetTrack, audio: AVAssetTrack?) {
        switch segment.sourceType {
        case .mainVideo:
            return (sourceVideo, sourceAudio)
        case .introAsset, .outroAsset, .recapAsset, .audioAsset:
            guard let assetID = segment.assetID,
                  let url = additionalAssets[assetID] else {
                throw ProcessorError.missingAsset
            }
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let videoTrack = videoTracks.first else { throw ProcessorError.noVideoTrack }
            return (videoTrack, audioTracks.first)
        case .imageAsset:
            throw ProcessorError.unsupportedOperation
        }
    }
    
    private func runExport(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed: continuation.resume()
                case .failed: continuation.resume(throwing: exporter.error ?? ProcessorError.exportFailed)
                case .cancelled: continuation.resume(throwing: ProcessorError.exportCancelled)
                default: continuation.resume(throwing: exporter.error ?? ProcessorError.exportFailed)
                }
            }
        }
    }
}

struct VideoInfo {
    let duration: Double
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let frameRate: Float
    let hasAudio: Bool
    let fileSize: Int64
    
    var orientedSize: CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }
}

struct CompositionSegment {
    let sourceType: SourceType
    let assetID: UUID?
    let timeRange: CMTimeRange
    let targetTrack: TrackType
}

enum ProcessorError: LocalizedError {
    case noVideoTrack
    case cannotCreateTrack
    case exportSessionUnavailable
    case exportFailed
    case exportCancelled
    case missingAsset
    case unsupportedOperation
    case invalidTimeRange
    
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "O arquivo não contém uma faixa de vídeo."
        case .cannotCreateTrack: return "Não foi possível criar a faixa de composição."
        case .exportSessionUnavailable: return "Não foi possível iniciar a exportação com essas configurações."
        case .exportFailed: return "A exportação falhou."
        case .exportCancelled: return "A exportação foi cancelada."
        case .missingAsset: return "Asset referenciado não encontrado."
        case .unsupportedOperation: return "Operação não suportada para este tipo de segmento."
        case .invalidTimeRange: return "Intervalo de tempo inválido."
        }
    }
}

extension VideoProcessor {
    func validateComposition(_ composition: AVComposition) -> Bool {
        guard let videoTrack = composition.tracks(withMediaType: .video).first else { return false }
        return videoTrack.timeRange.duration.seconds > 0
    }
    
    func estimateExportDuration(for composition: AVComposition, preset: String) -> TimeInterval {
        let duration = composition.duration.seconds
        switch preset {
        case AVAssetExportPreset640x480: return duration * 0.3
        case AVAssetExportPreset1280x720: return duration * 0.5
        case AVAssetExportPreset1920x1080: return duration * 0.8
        default: return duration * 1.2
        }
    }
}