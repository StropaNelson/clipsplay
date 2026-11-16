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

    func extractAudioForTranscription(
        from sourceURL: URL,
        to outputURL: URL,
        startTime: Double = 0,
        duration: Double? = nil
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let sourceTrack = sourceTracks.first else {
            throw ProcessorError.noAudioTrack
        }

        let assetDuration = try await asset.load(.duration).seconds
        let rangeDuration = min(duration ?? assetDuration, assetDuration - startTime)
        guard startTime >= 0, rangeDuration > 0 else {
            throw ProcessorError.invalidTimeRange
        }
        let composition = AVMutableComposition()
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ProcessorError.cannotCreateTrack
        }
        try audioTrack.insertTimeRange(
            CMTimeRange(
                start: CMTime(seconds: startTime, preferredTimescale: 600),
                duration: CMTime(seconds: rangeDuration, preferredTimescale: 600)
            ),
            of: sourceTrack,
            at: .zero
        )

        try? FileManager.default.removeItem(at: outputURL)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ProcessorError.exportSessionUnavailable
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        try await runExport(ExportSessionBox(exporter))
    }
    
    func createComposition(
        from segments: [CompositionSegment],
        sourceURL: URL,
        additionalAssets: [UUID: URL],
        aspect: AspectRatio,
        resolution: ExportResolution,
        fitMode: FitMode
    ) async throws -> CompositionBuildResult {
        let asset = AVURLAsset(url: sourceURL)
        let sourceVideoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = sourceVideoTracks.first else { throw ProcessorError.noVideoTrack }
        let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        let sourceAudio = sourceAudioTracks.first
        let sourceSize = try await sourceVideo.load(.naturalSize)
        let sourceTransform = try await sourceVideo.load(.preferredTransform)
        
        let composition = AVMutableComposition()
        guard let videoTrackA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let videoTrackB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrackA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrackB = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ProcessorError.cannotCreateTrack
        }

        let videoTracks = [videoTrackA, videoTrackB]
        let audioTracks = [audioTrackA, audioTrackB]
        let transitionLimit = 0.35
        var cursor = CMTime.zero
        var previousDuration: CMTime?
        var clipLayouts: [CompositionClipLayout] = []
        var audioLayouts: [(start: CMTime, end: CMTime, track: AVMutableCompositionTrack, hasAudio: Bool)] = []

        for segment in segments where segment.timeRange.duration.seconds > 0 {
            let source = try await getTrackForSegment(
                segment,
                sourceVideo: sourceVideo,
                sourceAudio: sourceAudio,
                additionalAssets: additionalAssets
            )
            guard let sourceTimeRange = intersection(
                of: segment.timeRange,
                with: source.video.timeRange
            ), CMTimeCompare(sourceTimeRange.duration, .zero) > 0 else {
                throw ProcessorError.invalidTimeRange
            }
            let duration = sourceTimeRange.duration
            let overlapDuration: CMTime
            if let previousDuration {
                let overlap = min(transitionLimit, min(previousDuration.seconds / 3, duration.seconds / 3))
                overlapDuration = CMTime(seconds: max(0, overlap), preferredTimescale: 600)
            } else {
                overlapDuration = .zero
            }

            let start = segment.timelineStartTime.map {
                CMTime(seconds: $0, preferredTimescale: 600)
            } ?? CMTimeSubtract(cursor, overlapDuration)
            guard start.seconds.isFinite, start.seconds >= 0 else {
                throw ProcessorError.invalidTimeRange
            }
            let end = CMTimeAdd(start, duration)
            let lane = clipLayouts.count % 2
            let compositionVideoTrack = videoTracks[lane]
            try compositionVideoTrack.insertTimeRange(sourceTimeRange, of: source.video, at: start)

            let naturalSize = try await source.video.load(.naturalSize)
            let transform = try await source.video.load(.preferredTransform)
            clipLayouts.append(CompositionClipLayout(
                track: compositionVideoTrack,
                start: start,
                end: end,
                naturalSize: naturalSize,
                preferredTransform: transform
            ))

            let compositionAudioTrack = audioTracks[lane]
            if let sourceAudio = source.audio,
               let audioTimeRange = intersection(of: sourceTimeRange, with: sourceAudio.timeRange),
               CMTimeCompare(audioTimeRange.duration, .zero) > 0 {
                let audioStart = CMTimeAdd(start, CMTimeSubtract(audioTimeRange.start, sourceTimeRange.start))
                let audioEnd = CMTimeAdd(audioStart, audioTimeRange.duration)
                try compositionAudioTrack.insertTimeRange(audioTimeRange, of: sourceAudio, at: audioStart)
                audioLayouts.append((audioStart, audioEnd, compositionAudioTrack, true))
            }

            cursor = CMTimeCompare(cursor, end) > 0 ? cursor : end
            previousDuration = duration
        }

        guard !clipLayouts.isEmpty else { throw ProcessorError.invalidTimeRange }

        let renderSize = calculateRenderSize(
            aspect: aspect,
            resolution: resolution,
            naturalSize: sourceSize,
            transform: sourceTransform
        )
        let videoComposition = makeCrossfadeVideoComposition(
            clips: clipLayouts,
            renderSize: renderSize,
            fitMode: fitMode,
            duration: cursor
        )
        let audioMix = makeCrossfadeAudioMix(layouts: audioLayouts)
        return CompositionBuildResult(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix
        )
    }
    
    func exportComposition(
        _ composition: AVComposition,
        to outputURL: URL,
        preset: String,
        videoComposition: AVVideoComposition? = nil,
        audioMix: AVAudioMix? = nil
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ProcessorError.exportSessionUnavailable
        }
        
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = videoComposition
        exporter.audioMix = audioMix
        
        try await runExport(ExportSessionBox(exporter))
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

    private func makeCrossfadeVideoComposition(
        clips: [CompositionClipLayout],
        renderSize: CGSize,
        fitMode: FitMode,
        duration: CMTime
    ) -> AVMutableVideoComposition {
        let boundaries = ([CMTime.zero, duration] + clips.flatMap { [$0.start, $0.end] })
            .sorted { CMTimeCompare($0, $1) < 0 }
            .reduce(into: [CMTime]()) { result, time in
                if result.last.map({ CMTimeCompare($0, time) != 0 }) ?? true {
                    result.append(time)
                }
            }

        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            guard CMTimeCompare(end, start) > 0 else { continue }
            let activeClips = clips
                .filter { CMTimeCompare($0.start, start) <= 0 && CMTimeCompare($0.end, end) >= 0 }
                .sorted { CMTimeCompare($0.start, $1.start) < 0 }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: start, end: end)
            guard !activeClips.isEmpty else {
                instruction.backgroundColor = UIColor.black.cgColor
                instructions.append(instruction)
                continue
            }
            let layers = activeClips.map { clip -> AVMutableVideoCompositionLayerInstruction in
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: clip.track)
                layer.setTransform(
                    renderTransform(for: clip, renderSize: renderSize, fitMode: fitMode),
                    at: start
                )
                layer.setOpacity(1, at: start)
                return layer
            }

            if activeClips.count == 2 {
                let outgoing = layers[0]
                let incoming = layers[1]
                let transitionRange = CMTimeRange(start: start, end: end)
                outgoing.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: transitionRange)
                incoming.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: transitionRange)
                instruction.layerInstructions = [incoming, outgoing]
            } else {
                instruction.layerInstructions = layers
            }
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        return videoComposition
    }

    private func intersection(of requestedRange: CMTimeRange, with availableRange: CMTimeRange) -> CMTimeRange? {
        let start = CMTimeCompare(requestedRange.start, availableRange.start) < 0
            ? availableRange.start
            : requestedRange.start
        let requestedEnd = CMTimeAdd(requestedRange.start, requestedRange.duration)
        let availableEnd = CMTimeAdd(availableRange.start, availableRange.duration)
        let end = CMTimeCompare(requestedEnd, availableEnd) > 0 ? availableEnd : requestedEnd
        guard start.isNumeric, end.isNumeric, CMTimeCompare(end, start) > 0 else { return nil }
        return CMTimeRange(start: start, end: end)
    }

    private func renderTransform(
        for clip: CompositionClipLayout,
        renderSize: CGSize,
        fitMode: FitMode
    ) -> CGAffineTransform {
        let transformedRect = CGRect(origin: .zero, size: clip.naturalSize)
            .applying(clip.preferredTransform)
        let orientedWidth = abs(transformedRect.width)
        let orientedHeight = abs(transformedRect.height)
        let scaleX = renderSize.width / max(orientedWidth, 1)
        let scaleY = renderSize.height / max(orientedHeight, 1)
        let scale = fitMode == .fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
        var transform = clip.preferredTransform.concatenating(
            CGAffineTransform(translationX: -transformedRect.minX, y: -transformedRect.minY)
        )
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        transform = transform.concatenating(
            CGAffineTransform(
                translationX: (renderSize.width - orientedWidth * scale) / 2,
                y: (renderSize.height - orientedHeight * scale) / 2
            )
        )
        return transform
    }

    private func makeCrossfadeAudioMix(
        layouts: [(start: CMTime, end: CMTime, track: AVMutableCompositionTrack, hasAudio: Bool)]
    ) -> AVAudioMix? {
        guard layouts.contains(where: \.hasAudio) else { return nil }
        var parametersByTrack: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        for layout in layouts where layout.hasAudio {
            let parameters = parametersByTrack[layout.track.trackID]
                ?? AVMutableAudioMixInputParameters(track: layout.track)
            parameters.setVolume(1, at: layout.start)
            parametersByTrack[layout.track.trackID] = parameters
        }

        if layouts.count > 1 {
            for index in 1..<layouts.count {
                let outgoing = layouts[index - 1]
                let incoming = layouts[index]
                let overlapStart = incoming.start
                let overlapEnd = CMTimeCompare(outgoing.end, incoming.end) < 0 ? outgoing.end : incoming.end
                guard CMTimeCompare(overlapEnd, overlapStart) > 0 else { continue }
                let range = CMTimeRange(start: overlapStart, end: overlapEnd)

                if outgoing.hasAudio,
                   let parameters = parametersByTrack[outgoing.track.trackID] {
                    parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: range)
                }
                if incoming.hasAudio,
                   let parameters = parametersByTrack[incoming.track.trackID] {
                    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: range)
                }
            }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = Array(parametersByTrack.values)
        return mix
    }
    
    nonisolated func calculateRenderSize(aspect: AspectRatio, resolution: ExportResolution, naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
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
    
    private func runExport(_ exporterBox: ExportSessionBox) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporterBox.session.exportAsynchronously {
                switch exporterBox.session.status {
                case .completed: continuation.resume()
                case .failed: continuation.resume(throwing: exporterBox.session.error ?? ProcessorError.exportFailed)
                case .cancelled: continuation.resume(throwing: ProcessorError.exportCancelled)
                default: continuation.resume(throwing: exporterBox.session.error ?? ProcessorError.exportFailed)
                }
            }
        }
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
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
    let timelineStartTime: Double?
}

struct CompositionBuildResult {
    let composition: AVMutableComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
}

private struct CompositionClipLayout {
    let track: AVMutableCompositionTrack
    let start: CMTime
    let end: CMTime
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
}

enum ProcessorError: LocalizedError {
    case noVideoTrack
    case noAudioTrack
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
        case .noAudioTrack: return "O arquivo não contém áudio para transcrever."
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