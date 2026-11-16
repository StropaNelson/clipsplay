import Foundation
import AVFoundation
import UniformTypeIdentifiers
import UIKit

actor VideoImporter {
    static let shared = VideoImporter()
    
    private let fileManager = FileManager.default
    private let storage = ProjectStorage.shared
    
    private init() {}
    
    func importVideo(from sourceURL: URL, projectName: String? = nil) async throws -> Project {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw ImportError.invalidDuration
        }
        
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw ImportError.noVideoTrack
        }
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        
        let mediaDir = await storage.getMediaAssetsDirectory()
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destName = "source_\(UUID().uuidString).\(ext)"
        let destURL = mediaDir.appendingPathComponent(destName)
        
        try fileManager.copyItem(at: sourceURL, to: destURL)
        
        let thumbnailURL = try await generateThumbnail(for: asset, at: min(1, duration), saveTo: mediaDir)
        
        var project = Project(
            name: projectName ?? sourceURL.deletingPathExtension().lastPathComponent,
            sourceVideoURL: destURL,
            sourceVideoDuration: duration,
            naturalSize: naturalSize,
            transform: transform
        )
        
        let assetItem = MediaAsset(
            name: sourceURL.lastPathComponent,
            fileURL: destURL,
            type: .video,
            duration: duration,
            naturalSize: naturalSize,
            fileSize: (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0,
            thumbnailURL: thumbnailURL
        )
        project.mediaAssets.append(assetItem)
        
        try await storage.saveProject(project)
        return project
    }
    
    func importMediaAsset(from sourceURL: URL, type: AssetType) async throws -> MediaAsset {
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        
        let mediaDir = await storage.getMediaAssetsDirectory()
        let ext = sourceURL.pathExtension.isEmpty ? defaultExtension(for: type) : sourceURL.pathExtension
        let destName = "\(type.rawValue.lowercased())_\(UUID().uuidString).\(ext)"
        let destURL = mediaDir.appendingPathComponent(destName)
        
        try fileManager.copyItem(at: sourceURL, to: destURL)
        
        var duration: Double = 0
        var naturalSize: CGSize = .zero
        
        if type == .video || type == .audio {
            let asset = AVURLAsset(url: destURL)
            if type == .video {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let track = tracks.first {
                    naturalSize = try await track.load(.naturalSize)
                }
            }
            duration = try await asset.load(.duration).seconds
        } else if type == .image {
            if let image = UIImage(contentsOfFile: destURL.path) {
                naturalSize = image.size
            }
        }
        
        let thumbnailURL: URL?
        if type == .video {
            thumbnailURL = try await generateThumbnail(for: AVURLAsset(url: destURL), at: min(1, duration), saveTo: mediaDir)
        } else if type == .image {
            thumbnailURL = destURL
        } else {
            thumbnailURL = nil
        }
        
        let assetItem = MediaAsset(
            name: sourceURL.lastPathComponent,
            fileURL: destURL,
            type: type,
            duration: duration,
            naturalSize: naturalSize,
            fileSize: (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0,
            thumbnailURL: thumbnailURL
        )
        
        return assetItem
    }
    
    func generateThumbnail(for asset: AVURLAsset, at time: Double, saveTo directory: URL) async throws -> URL {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        
        let cgImage = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
        let image = UIImage(cgImage: cgImage)
        
        let thumbName = "thumb_\(UUID().uuidString).jpg"
        let thumbURL = directory.appendingPathComponent(thumbName)
        
        if let data = image.jpegData(compressionQuality: 0.7) {
            try data.write(to: thumbURL, options: .atomic)
        }
        return thumbURL
    }
    
    func regenerateThumbnails(for project: Project) async throws -> Project {
        var project = project
        for (index, asset) in project.mediaAssets.enumerated() where asset.type == .video {
            let assetURL = asset.url
            let avAsset = AVURLAsset(url: assetURL)
            let thumbURL = try await generateThumbnail(for: avAsset, at: min(1, asset.duration), saveTo: await storage.getThumbnailsDirectory())
            project.mediaAssets[index].thumbnailURL = thumbURL.path
        }
        try await storage.saveProject(project)
        return project
    }
    
    private func defaultExtension(for type: AssetType) -> String {
        switch type {
        case .video: return "mov"
        case .audio: return "m4a"
        case .image: return "jpg"
        }
    }
    
    enum ImportError: LocalizedError {
        case noVideoTrack
        case invalidDuration
        case copyFailed
        case thumbnailGenerationFailed
        
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "O arquivo não contém uma faixa de vídeo válida."
            case .invalidDuration: return "Não foi possível determinar a duração do vídeo."
            case .copyFailed: return "Falha ao copiar o arquivo para o armazenamento do app."
            case .thumbnailGenerationFailed: return "Falha ao gerar miniatura."
            }
        }
    }
}

extension VideoImporter {
    static let supportedVideoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
    static let supportedAudioTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
    static let supportedImageTypes: [UTType] = [.image, .jpeg, .png, .heic, .tiff, .bmp]
    
    static var allSupportedTypes: [UTType] {
        supportedVideoTypes + supportedAudioTypes + supportedImageTypes
    }
}