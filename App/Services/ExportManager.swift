import Foundation
import AVFoundation
import UIKit

actor ExportManager {
    static let shared = ExportManager()
    
    private let processor = VideoProcessor.shared
    private let timelineEngine = TimelineEngine.shared
    private let storage = ProjectStorage.shared
    
    private init() {}
    
    func exportEpisode(
        project: Project,
        episode: Episode,
        episodeNumber: Int,
        settings: ExportSettings,
        additionalAssets: [UUID: URL],
        progressHandler: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> ExportResult {
        progressHandler(ExportProgress(stage: .preparing, episode: episodeNumber, progress: 0, message: "Preparando composição..."))
        
        let output = try await timelineEngine.buildEpisodeComposition(
            project: project,
            episode: episode,
            additionalAssets: additionalAssets,
            settings: settings
        )
        let composition = output.composition
        
        progressHandler(ExportProgress(stage: .composing, episode: episodeNumber, progress: 0.1, message: "Montando segmentos..."))
        
        let exportDir = await storage.getExportDirectory()
        let videoURL = exportDir.appendingPathComponent(
            String(format: "%@_%02d.mp4", settings.fileNamePrefix, episodeNumber)
        )
        
        progressHandler(ExportProgress(stage: .exporting, episode: episodeNumber, progress: 0.2, message: "Exportando vídeo..."))
        
        let images: [ImageOverlayRender] = episode.mediaOverlays.filter { !$0.isVideo }.compactMap { overlay in
            guard let asset = project.mediaAssets.first(where: { $0.id == overlay.assetID }),
                  let image = UIImage(contentsOfFile: asset.url.path)?.cgImage else { return nil }
            return ImageOverlayRender(image: image, overlay: overlay)
        }
        var overlays = episode.resolvedOverlays(global: project.globalOverlays)
        if settings.excludeCaptions {
            overlays = overlays.filter { $0.isCaption != true }
        }
        let videoComposition = await processor.applyTextOverlays(
            overlays,
            images: images,
            to: output.videoComposition
        )
        try await processor.exportComposition(
            composition,
            to: videoURL,
            preset: settings.resolution.presetName,
            videoComposition: videoComposition,
            audioMix: output.audioMix
        )
        
        progressHandler(ExportProgress(stage: .exporting, episode: episodeNumber, progress: 0.9, message: "Finalizando vídeo..."))
        
        var coverURL: URL?
        if settings.includeCovers {
            progressHandler(ExportProgress(stage: .generatingCover, episode: episodeNumber, progress: 0.92, message: "Gerando capa..."))
            let coverSettings = CoverSettings(
                enabled: true,
                mode: settings.coverMode,
                templateName: "Padrão",
                captureTime: settings.coverCaptureTime,
                customImageAssetID: nil
            )
            let coverData = try await processor.generateCover(for: project, episode: episode, episodeNumber: episodeNumber, settings: coverSettings)
            coverURL = exportDir.appendingPathComponent(
                String(format: "%@_%02d.jpg", settings.fileNamePrefix, episodeNumber)
            )
            try coverData.write(to: coverURL!, options: .atomic)
        }
        
        progressHandler(ExportProgress(stage: .completed, episode: episodeNumber, progress: 1.0, message: "Concluído"))
        
        return ExportResult(
            episodeNumber: episodeNumber,
            videoURL: videoURL,
            coverURL: coverURL,
            duration: composition.duration.seconds,
            fileSize: (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int64) ?? 0
        )
    }
    
    func exportAllEpisodes(
        project: Project,
        settings: ExportSettings,
        selectedEpisodes: Set<Int>? = nil,
        progressHandler: @escaping @Sendable (BatchExportProgress) -> Void
    ) async throws -> BatchExportResult {
        let episodesToExport = selectedEpisodes.map { indices in
            project.episodes.filter { indices.contains($0.index + 1) }
        } ?? project.episodes
        
        guard !episodesToExport.isEmpty else {
            throw ExportError.noEpisodesSelected
        }
        
        var assetURLs: [UUID: URL] = [:]
        for asset in project.mediaAssets {
            assetURLs[asset.id] = asset.url
        }
        
        var results: [ExportResult] = []
        var errors: [ExportErrorDetail] = []
        
        let total = episodesToExport.count
        
        for (index, episode) in episodesToExport.enumerated() {
            let episodeNumber = episode.index + 1
            progressHandler(BatchExportProgress(
                currentEpisode: episodeNumber,
                totalEpisodes: total,
                overallProgress: Double(index) / Double(total),
                currentStage: .preparing,
                message: "Processando episódio \(episodeNumber) de \(total)..."
            ))
            
            do {
                let result = try await exportEpisode(
                    project: project,
                    episode: episode,
                    episodeNumber: episodeNumber,
                    settings: settings,
                    additionalAssets: assetURLs
                ) { epProgress in
                    let overall = (Double(index) + epProgress.progress * 0.95) / Double(total)
                    progressHandler(BatchExportProgress(
                        currentEpisode: episodeNumber,
                        totalEpisodes: total,
                        overallProgress: overall,
                        currentStage: epProgress.stage,
                        message: epProgress.message
                    ))
                }
                results.append(result)
            } catch {
                errors.append(ExportErrorDetail(episodeNumber: episodeNumber, error: error.localizedDescription))
                progressHandler(BatchExportProgress(
                    currentEpisode: episodeNumber,
                    totalEpisodes: total,
                    overallProgress: Double(index + 1) / Double(total),
                    currentStage: .failed,
                    message: "Erro no episódio \(episodeNumber): \(error.localizedDescription)"
                ))
            }
        }
        
        progressHandler(BatchExportProgress(
            currentEpisode: 0,
            totalEpisodes: total,
            overallProgress: 1.0,
            currentStage: .completed,
            message: "Exportação em lote concluída"
        ))
        
        return BatchExportResult(results: results, errors: errors)
    }
    
    func createZIP(from results: [ExportResult], projectName: String) async throws -> URL {
        let exportDir = await storage.getExportDirectory()
        let zipName = "\(projectName)_\(Int(Date().timeIntervalSince1970)).zip"
        let zipURL = exportDir.appendingPathComponent(zipName)
        
        let files = results.flatMap { [$0.videoURL] + ($0.coverURL.map { [$0] } ?? []) }
        let data = try SimpleZIP.make(from: files)
        try data.write(to: zipURL, options: .atomic)
        
        return zipURL
    }
}

struct ExportSettings {
    var aspectRatio: AspectRatio = .original
    var resolution: ExportResolution = .original
    var fitMode: FitMode = .fit
    var includeCovers: Bool = true
    var coverMode: CoverSettings.CoverMode = .template
    var coverCaptureTime: Double = 0
    var fileNamePrefix: String = "Episodio"
    var quality: ExportQuality = .high
    /// Multiplicar conteúdo: variant without burned-in captions.
    var excludeCaptions: Bool = false
}

enum ExportQuality: String, CaseIterable, Identifiable {
    case low = "Baixa"
    case medium = "Média"
    case high = "Alta"
    case maximum = "Máxima"
    
    var id: String { rawValue }
    
    var presetName: String {
        switch self {
        case .low: return AVAssetExportPresetLowQuality
        case .medium: return AVAssetExportPresetMediumQuality
        case .high: return AVAssetExportPreset1920x1080
        case .maximum: return AVAssetExportPresetHighestQuality
        }
    }
}

struct ExportProgress {
    let stage: ExportStage
    let episode: Int
    let progress: Double
    let message: String
}

enum ExportStage: String, CaseIterable {
    case preparing = "Preparando"
    case composing = "Compondo"
    case exporting = "Exportando"
    case generatingCover = "Gerando Capa"
    case completed = "Concluído"
    case failed = "Falhou"
}

struct ExportResult {
    let episodeNumber: Int
    let videoURL: URL
    let coverURL: URL?
    let duration: Double
    let fileSize: Int64
    
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    var formattedDuration: String {
        let h = Int(duration) / 3600
        let m = (Int(duration) % 3600) / 60
        let s = Int(duration) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

struct BatchExportProgress {
    let currentEpisode: Int
    let totalEpisodes: Int
    let overallProgress: Double
    let currentStage: ExportStage
    let message: String
}

struct BatchExportResult {
    let results: [ExportResult]
    let errors: [ExportErrorDetail]
    
    var successCount: Int { results.count }
    var failureCount: Int { errors.count }
    var totalSize: Int64 { results.reduce(0) { $0 + $1.fileSize } }
}

struct ExportErrorDetail {
    let episodeNumber: Int
    let error: String
}

enum ExportError: LocalizedError {
    case noEpisodesSelected
    case exportFailed(String)
    case zipCreationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noEpisodesSelected: return "Nenhum episódio selecionado para exportação."
        case .exportFailed(let msg): return "Falha na exportação: \(msg)"
        case .zipCreationFailed(let msg): return "Falha ao criar ZIP: \(msg)"
        }
    }
}

extension ExportManager {
    func estimateTotalExportTime(for project: Project, settings: ExportSettings) -> TimeInterval {
        let totalDuration = project.episodes.reduce(0) { $0 + $1.totalDuration }
        let qualityMultiplier: Double
        switch settings.quality {
        case .low: qualityMultiplier = 0.3
        case .medium: qualityMultiplier = 0.5
        case .high: qualityMultiplier = 0.8
        case .maximum: qualityMultiplier = 1.2
        }
        return totalDuration * qualityMultiplier * Double(project.episodes.count)
    }
}