import Foundation
import AVFoundation
import UIKit
import CoreGraphics

actor CoverGenerator {
    static let shared = CoverGenerator()
    
    private init() {}
    
    func generateCovers(for project: Project, settings: CoverSettings, episodes: [Episode]) async throws -> [Int: Data] {
        var covers: [Int: Data] = [:]
        
        for episode in episodes {
            let coverData = try await generateCover(for: project, episode: episode, number: episode.index + 1, settings: settings)
            covers[episode.index + 1] = coverData
        }
        
        return covers
    }
    
    func generateCover(for project: Project, episode: Episode, number: Int, settings: CoverSettings) async throws -> Data {
        switch settings.mode {
        case .template:
            return try makeTemplateCover(project: project, episode: episode, number: number)
        case .captureFrame:
            return try await captureFrameCover(project: project, episode: episode, captureTime: settings.captureTime)
        case .customImage:
            return try await customImageCover(project: project, settings: settings)
        }
    }
    
    private func makeTemplateCover(project: Project, episode: Episode, number: Int) throws -> Data {
        let size = CGSize(width: 1080, height: 1920)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor(red: 0.05, green: 0.08, blue: 0.15, alpha: 1).cgColor,
                    UIColor(red: 0.12, green: 0.18, blue: 0.30, alpha: 1).cgColor
                ] as CFArray,
                locations: [0.0, 1.0]
            )!
            cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: size.height),
                options: []
            )
            
            drawDecorativeElements(in: cgContext, size: size)
            
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = 8
            
            let seriesFont = UIFont.systemFont(ofSize: 48, weight: .light)
            let seriesAttrs: [NSAttributedString.Key: Any] = [
                .font: seriesFont,
                .foregroundColor: UIColor.white.withAlphaComponent(0.7),
                .paragraphStyle: paragraph
            ]
            (project.seriesTitle as NSString).draw(
                in: CGRect(x: 80, y: 200, width: size.width - 160, height: 60),
                withAttributes: seriesAttrs
            )
            
            let titleFont = UIFont.boldSystemFont(ofSize: 84)
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let episodeTitle = "\(project.episodeTitleTemplate) \(number)"
            (episodeTitle as NSString).draw(
                in: CGRect(x: 80, y: 280, width: size.width - 160, height: 200),
                withAttributes: titleAttrs
            )
            
            let metaFont = UIFont.systemFont(ofSize: 28, weight: .medium)
            let metaAttrs: [NSAttributedString.Key: Any] = [
                .font: metaFont,
                .foregroundColor: UIColor.systemBlue,
                .paragraphStyle: paragraph
            ]
            let duration = String(format: "%.0f min", episode.totalDuration / 60)
            let metaText = "CLIPSTUDIO  •  \(duration)  •  \(project.aspectRatio.rawValue)"
            (metaText as NSString).draw(
                in: CGRect(x: 80, y: size.height - 200, width: size.width - 160, height: 40),
                withAttributes: metaAttrs
            )
            
            let badgeRect = CGRect(x: size.width - 180, y: 80, width: 120, height: 120)
            cgContext.setFillColor(UIColor.systemBlue.withAlphaComponent(0.9).cgColor)
            cgContext.fillEllipse(in: badgeRect)
            let badgeFont = UIFont.boldSystemFont(ofSize: 48)
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: badgeFont,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            ("\(number)" as NSString).draw(
                in: badgeRect.insetBy(dx: 20, dy: 20),
                withAttributes: badgeAttrs
            )
        }
        
        return image.jpegData(compressionQuality: 0.92) ?? Data()
    }
    
    private func drawDecorativeElements(in context: CGContext, size: CGSize) {
        context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.15).cgColor)
        context.setLineWidth(1.5)
        
        for i in 0..<6 {
            let x = CGFloat(i) * size.width / 5
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x + 100, y: size.height))
        }
        context.strokePath()
        
        let centerX = size.width / 2
        let centerY = size.height * 0.35
        for i in 0..<3 {
            let radius = CGFloat(80 + i * 120)
            context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.08 - CGFloat(i) * 0.02).cgColor)
            context.setLineWidth(2)
            context.addEllipse(in: CGRect(
                x: centerX - radius,
                y: centerY - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.strokePath()
        }
    }
    
    private func captureFrameCover(project: Project, episode: Episode, captureTime: Double) async throws -> Data {
        let asset = AVURLAsset(url: project.sourceVideoFileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        
        let time = CMTime(seconds: captureTime, preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        let image = UIImage(cgImage: cgImage)
        
        return await cropAndResize(image: image, targetSize: CGSize(width: 1080, height: 1920))
    }
    
    private func customImageCover(project: Project, settings: CoverSettings) async throws -> Data {
        guard let assetID = settings.customImageAssetID,
              let asset = project.mediaAssets.first(where: { $0.id == assetID }),
              asset.type == .image,
              let image = UIImage(contentsOfFile: asset.url.path) else {
            throw CoverError.customImageNotFound
        }
        
        return await cropAndResize(image: image, targetSize: CGSize(width: 1080, height: 1920))
    }
    
    private func cropAndResize(image: UIImage, targetSize: CGSize) async -> Data {
        let sourceRatio = image.size.width / image.size.height
        let targetRatio = targetSize.width / targetSize.height
        
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let result = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            
            let drawRect: CGRect
            if sourceRatio > targetRatio {
                let height = targetSize.height
                let width = height * sourceRatio
                drawRect = CGRect(x: (targetSize.width - width) / 2, y: 0, width: width, height: height)
            } else {
                let width = targetSize.width
                let height = width / sourceRatio
                drawRect = CGRect(x: 0, y: (targetSize.height - height) / 2, width: width, height: height)
            }
            
            image.draw(in: drawRect)
        }
        
        return result.jpegData(compressionQuality: 0.92) ?? Data()
    }
    
    func generatePlaceholderCover(size: CGSize = CGSize(width: 1080, height: 1920)) -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 48, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.5),
                .paragraphStyle: paragraph
            ]
            
            ("Sem Capa" as NSString).draw(
                in: CGRect(x: 40, y: size.height / 2 - 24, width: size.width - 80, height: 48),
                withAttributes: attrs
            )
        }
        
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
}

enum CoverError: LocalizedError {
    case customImageNotFound
    case captureFailed
    case invalidSettings
    
    var errorDescription: String? {
        switch self {
        case .customImageNotFound: return "Imagem personalizada não encontrada."
        case .captureFailed: return "Falha ao capturar quadro do vídeo."
        case .invalidSettings: return "Configurações de capa inválidas."
        }
    }
}

extension CoverGenerator {
    func generateThumbnails(for project: Project, count: Int = 20) async throws -> [Data] {
        let asset = AVURLAsset(url: project.sourceVideoFileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        
        var thumbnails: [Data] = []
        let duration = project.sourceVideoDuration
        let interval = duration / Double(count)
        
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) * interval, preferredTimescale: 600)
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                let image = UIImage(cgImage: cgImage)
                if let data = image.jpegData(compressionQuality: 0.7) {
                    thumbnails.append(data)
                }
            } catch {
                thumbnails.append(generatePlaceholderCover(size: CGSize(width: 320, height: 180)))
            }
        }
        
        return thumbnails
    }
}