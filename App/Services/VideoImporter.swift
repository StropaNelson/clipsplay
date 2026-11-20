import Foundation
import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// File-backed video received from the system photo picker without loading the
/// whole asset into memory.
struct GalleryVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("gallery_\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return GalleryVideo(url: destination)
        }
    }
}

/// A video selected by the user that was probed but not imported yet. Shown in
/// the pre-import reorder sheet; `recordedAt` drives the automatic ordering.
struct PendingVideo: Identifiable, Hashable {
    let id: UUID = UUID()
    var url: URL
    var name: String
    var duration: Double
    var recordedAt: Date?
    var thumbnailURL: URL?
}

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
        let recordedAt = await recordingDate(of: sourceURL)

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
            thumbnailURL: thumbnailURL,
            createdAt: recordedAt
        )
        project.mediaAssets.append(assetItem)

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
            thumbnailURL: thumbnailURL,
            createdAt: await recordingDate(of: sourceURL)
        )

        return assetItem
    }
    
    /// Probes a video file without importing it, returning name, duration and
    /// the original recording date used to order multi-video imports.
    func probeVideo(at url: URL) async throws -> PendingVideo {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw ImportError.invalidDuration
        }

        return PendingVideo(
            url: url,
            name: url.lastPathComponent,
            duration: duration,
            recordedAt: await recordingDate(of: url)
        )
    }

    /// Probes each url in order. Files that fail probing stay in the result
    /// with duration 0 and no recording date so the user still sees them.
    func probeVideos(_ urls: [URL]) async -> [PendingVideo] {
        var videos: [PendingVideo] = []
        videos.reserveCapacity(urls.count)
        for url in urls {
            if let video = try? await probeVideo(at: url) {
                videos.append(video)
            } else {
                videos.append(PendingVideo(url: url, name: url.lastPathComponent, duration: 0))
            }
        }
        return videos
    }

    /// Loads each picked photo-library item into a temp file and probes it,
    /// preserving the selection order. Callers must keep the returned temp
    /// urls alive until the project is created.
    func probeGalleryItems(_ items: [PhotosPickerItem]) async -> [PendingVideo] {
        var videos: [PendingVideo] = []
        videos.reserveCapacity(items.count)
        for item in items {
            guard let galleryVideo = try? await item.loadTransferable(type: GalleryVideo.self) else { continue }
            if let video = try? await probeVideo(at: galleryVideo.url) {
                videos.append(video)
            } else {
                videos.append(PendingVideo(url: galleryVideo.url, name: galleryVideo.url.lastPathComponent, duration: 0))
            }
        }
        return videos
    }

    /// Orders videos by recording date; items without a date keep their
    /// relative order and are placed at the end.
    func sortedByRecording(_ videos: [PendingVideo]) -> [PendingVideo] {
        videos
            .enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.recordedAt, rhs.element.recordedAt) {
                case let (left?, right?):
                    return left == right ? lhs.offset < rhs.offset : left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// Best-effort recording date: creation-date metadata first, then the
    /// file's modification and creation dates.
    private func recordingDate(of url: URL) async -> Date? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: url)
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata where item.commonKey == .commonKeyCreationDate
                || item.key as? String == "com.apple.quicktime.creationdate" {
                if let date = try? await item.load(.dateValue) {
                    return date
                }
            }
        }

        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]) {
            if let modified = values.contentModificationDate {
                return modified
            }
            if let created = values.creationDate {
                return created
            }
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
            if let modified = attributes[.modificationDate] as? Date {
                return modified
            }
            if let created = attributes[.creationDate] as? Date {
                return created
            }
        }
        return nil
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