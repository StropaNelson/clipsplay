import Foundation
import AVFoundation
import CoreMedia
import UIKit
import QuartzCore
import CoreText

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
        audioClips: [CompositionAudioClip] = [],
        overlayVideos: [CompositionOverlayVideo] = [],
        sourceURL: URL,
        additionalAssets: [UUID: URL],
        aspect: AspectRatio,
        resolution: ExportResolution,
        fitMode: FitMode
    ) async throws -> CompositionBuildResult {
        // AVAssetTrack only holds a weak reference to its AVAsset. Every asset must stay
        // alive while its tracks are inserted, otherwise AVFoundation fails with
        // "The operation could not be completed" (-11800).
        var retainedAssets: [URL: AVURLAsset] = [:]
        func loadAsset(_ url: URL) throws -> AVURLAsset {
            if let cached = retainedAssets[url] { return cached }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ProcessorError.missingAssetFile(url.lastPathComponent)
            }
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            retainedAssets[url] = asset
            return asset
        }
        func audioTrack(ofAsset assetID: UUID) async throws -> AVAssetTrack? {
            guard let url = additionalAssets[assetID] else { return nil }
            return try await loadAsset(url).loadTracks(withMediaType: .audio).first
        }

        let asset = try loadAsset(sourceURL)
        let sourceVideoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = sourceVideoTracks.first else { throw ProcessorError.noVideoTrack }
        let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        let sourceAudio = sourceAudioTracks.first
        let sourceSize = try await sourceVideo.load(.naturalSize)
        let sourceTransform = try await sourceVideo.load(.preferredTransform)

        let composition = AVMutableComposition()
        var videoLanes: [(track: AVMutableCompositionTrack, end: CMTime)] = []
        var audioLanes: [(track: AVMutableCompositionTrack, end: CMTime)] = []
        var audioPlacements: [AudioPlacement] = []

        func videoLane(startingAt start: CMTime) throws -> Int {
            if let index = videoLanes.firstIndex(where: { CMTimeCompare($0.end, start) <= 0 }) {
                return index
            }
            guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ProcessorError.cannotCreateTrack
            }
            videoLanes.append((video, .zero))
            return videoLanes.count - 1
        }

        func placeAudio(
            _ track: AVAssetTrack,
            sourceRange: CMTimeRange,
            at start: CMTime,
            volume: Float,
            fadeIn: Double,
            fadeOut: Double,
            speed: Double = 1
        ) async throws {
            let available = try await track.load(.timeRange)
            guard let range = intersection(of: sourceRange, with: available) else { return }
            let placedStart = CMTimeAdd(start, CMTimeMultiplyByFloat64(CMTimeSubtract(range.start, sourceRange.start), multiplier: 1 / speed))
            let placedDuration = speed == 1 ? range.duration : CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / speed)
            let end = CMTimeAdd(placedStart, placedDuration)
            let index: Int
            if let free = audioLanes.firstIndex(where: { CMTimeCompare($0.end, placedStart) <= 0 }) {
                index = free
            } else {
                guard let lane = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw ProcessorError.cannotCreateTrack
                }
                audioLanes.append((lane, .zero))
                index = audioLanes.count - 1
            }
            try audioLanes[index].track.insertTimeRange(range, of: track, at: placedStart)
            if speed != 1 {
                audioLanes[index].track.scaleTimeRange(CMTimeRange(start: placedStart, duration: range.duration), toDuration: placedDuration)
            }
            audioLanes[index].end = end
            audioPlacements.append(AudioPlacement(
                track: audioLanes[index].track,
                start: placedStart,
                end: end,
                volume: volume,
                fadeIn: fadeIn,
                fadeOut: fadeOut
            ))
        }

        var clipLayouts: [CompositionClipLayout] = []
        let playable = segments.filter { $0.timeRange.duration.seconds > 0 }

        for (index, segment) in playable.enumerated() {
            let source: (video: AVAssetTrack, audio: AVAssetTrack?)
            switch segment.sourceType {
            case .mainVideo:
                source = (sourceVideo, sourceAudio)
            case .introAsset, .outroAsset, .recapAsset, .audioAsset, .clipAsset:
                guard let assetID = segment.assetID, let url = additionalAssets[assetID] else {
                    throw ProcessorError.missingAsset
                }
                let segmentAsset = try loadAsset(url)
                guard let video = try await segmentAsset.loadTracks(withMediaType: .video).first else {
                    throw ProcessorError.noVideoTrack
                }
                let audio = try await segmentAsset.loadTracks(withMediaType: .audio).first
                source = (video, audio)
            case .imageAsset:
                throw ProcessorError.unsupportedOperation
            }

            let availableVideoRange = try await source.video.load(.timeRange)
            guard let sourceTimeRange = intersection(of: segment.timeRange, with: availableVideoRange) else {
                throw ProcessorError.invalidTimeRange
            }
            var start = CMTime(seconds: segment.timelineStartTime, preferredTimescale: 600)
            if !start.seconds.isFinite || start.seconds < 0 { start = .zero }
            let speed = segment.speed > 0 ? segment.speed : 1
            let timelineDuration = speed == 1 ? sourceTimeRange.duration : CMTimeMultiplyByFloat64(sourceTimeRange.duration, multiplier: 1 / speed)
            let end = CMTimeAdd(start, timelineDuration)
            let laneIndex = try videoLane(startingAt: start)
            let compositionVideoTrack = videoLanes[laneIndex].track
            try compositionVideoTrack.insertTimeRange(sourceTimeRange, of: source.video, at: start)
            if speed != 1 {
                compositionVideoTrack.scaleTimeRange(CMTimeRange(start: start, duration: sourceTimeRange.duration), toDuration: timelineDuration)
            }
            videoLanes[laneIndex].end = end

            let naturalSize = try await source.video.load(.naturalSize)
            let preferredTransform = try await source.video.load(.preferredTransform)
            clipLayouts.append(CompositionClipLayout(
                track: compositionVideoTrack,
                start: start,
                end: end,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                transition: segment.transition,
                transform: segment.transform
            ))

            let fadeOut = index + 1 < playable.count ? playable[index + 1].overlapIn : 0
            if let sourceAudio = source.audio, speed >= 0.2 {
                try await placeAudio(
                    sourceAudio,
                    sourceRange: sourceTimeRange,
                    at: start,
                    volume: segment.clipVolume,
                    fadeIn: segment.overlapIn,
                    fadeOut: fadeOut,
                    speed: speed
                )
            }
            if let narrationID = segment.narrationAssetID,
               let narration = try await audioTrack(ofAsset: narrationID) {
                let narrationRange = CMTimeRange(
                    start: CMTime(seconds: max(0, segment.narrationOffset), preferredTimescale: 600),
                    duration: timelineDuration
                )
                try await placeAudio(
                    narration,
                    sourceRange: narrationRange,
                    at: start,
                    volume: segment.narrationVolume,
                    fadeIn: 0,
                    fadeOut: 0
                )
            }
        }

        guard !clipLayouts.isEmpty else { throw ProcessorError.invalidTimeRange }
        let videoEnd = clipLayouts.map(\.end).max { CMTimeCompare($0, $1) < 0 } ?? .zero

        for clip in audioClips {
            guard let track = try await audioTrack(ofAsset: clip.assetID) else {
                throw ProcessorError.missingAsset
            }
            let start = CMTime(seconds: max(0, clip.timelineStart), preferredTimescale: 600)
            let maxDuration = CMTimeSubtract(videoEnd, start).seconds
            let duration = min(clip.sourceEnd - clip.sourceStart, maxDuration)
            guard duration > 0.05 else { continue }
            try await placeAudio(
                track,
                sourceRange: CMTimeRange(
                    start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600)
                ),
                at: start,
                volume: clip.volume,
                fadeIn: clip.fadeIn,
                fadeOut: clip.fadeOut
            )
        }

        var overlayLayouts: [OverlayLayout] = []
        for overlay in overlayVideos {
            guard let url = additionalAssets[overlay.assetID] else { throw ProcessorError.missingAsset }
            let overlayAsset = try loadAsset(url)
            guard let video = try await overlayAsset.loadTracks(withMediaType: .video).first else { continue }
            let start = CMTime(seconds: max(0, overlay.timelineStart), preferredTimescale: 600)
            let duration = min(overlay.duration, CMTimeSubtract(videoEnd, start).seconds)
            guard duration > 0.05 else { continue }
            let requested = CMTimeRange(
                start: CMTime(seconds: max(0, overlay.sourceStart), preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            )
            guard let range = intersection(of: requested, with: try await video.load(.timeRange)),
                  let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }
            try track.insertTimeRange(range, of: video, at: start)
            let overlaySize = try await video.load(.naturalSize)
            let overlayTransform = try await video.load(.preferredTransform)
            overlayLayouts.append(OverlayLayout(
                track: track,
                start: start,
                end: CMTimeAdd(start, range.duration),
                naturalSize: overlaySize,
                preferredTransform: overlayTransform,
                centerX: overlay.centerX,
                centerY: overlay.centerY,
                widthFraction: overlay.widthFraction,
                opacity: overlay.opacity,
                rotation: overlay.rotation
            ))
            if overlay.volume > 0, let audio = try await overlayAsset.loadTracks(withMediaType: .audio).first {
                try await placeAudio(audio, sourceRange: range, at: start, volume: overlay.volume, fadeIn: 0, fadeOut: 0)
            }
        }

        let renderSize = calculateRenderSize(
            aspect: aspect,
            resolution: resolution,
            naturalSize: sourceSize,
            transform: sourceTransform
        )
        let videoComposition = makeTransitionVideoComposition(
            clips: clipLayouts,
            overlays: overlayLayouts,
            renderSize: renderSize,
            fitMode: fitMode,
            duration: composition.duration
        )
        return CompositionBuildResult(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: makeAudioMix(audioPlacements),
            sourceAssets: retainedAssets.values.map { $0 as AVAsset }
        )
    }

    /// Adds burned-in text for export. Core Animation layers can't be used with AVPlayerItem,
    /// so the editor draws the same overlays with SwiftUI during preview.
    func applyTextOverlays(
        _ overlays: [TextOverlay],
        images: [ImageOverlayRender] = [],
        to videoComposition: AVVideoComposition
    ) -> AVVideoComposition {
        let visible = overlays.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.duration > 0 }
        guard !visible.isEmpty || !images.isEmpty,
              let mutable = videoComposition.mutableCopy() as? AVMutableVideoComposition else {
            return videoComposition
        }
        let size = mutable.renderSize
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.isGeometryFlipped = true
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        for render in images {
            let overlay = render.overlay
            let layer = CALayer()
            let width = CGFloat(overlay.widthFraction) * size.width
            let aspect = CGFloat(render.image.height) / CGFloat(max(render.image.width, 1))
            layer.bounds = CGRect(x: 0, y: 0, width: width, height: width * aspect)
            layer.position = CGPoint(x: overlay.centerX * size.width, y: overlay.centerY * size.height)
            layer.contents = render.image
            layer.contentsGravity = .resizeAspect
            layer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(overlay.rotation * .pi / 180)))
            Self.addVisibility(to: layer, start: overlay.startTime, duration: overlay.duration, opacity: overlay.opacity)
            parent.addSublayer(layer)
        }
        for overlay in visible {
            parent.addSublayer(Self.textLayer(for: overlay, renderSize: size))
        }
        mutable.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parent
        )
        return mutable
    }

    private static func textLayer(for overlay: TextOverlay, renderSize size: CGSize) -> CALayer {
        let fontSize = max(8, CGFloat(overlay.fontScale) * size.height)
        let font = UIFont.systemFont(ofSize: fontSize, weight: overlay.isBold ? .bold : .regular)
        let maxWidth = size.width * 0.9
        let bounds = (overlay.text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).integral
        let padding = overlay.style == .box ? fontSize * 0.35 : 0

        let container = CALayer()
        container.bounds = CGRect(x: 0, y: 0, width: bounds.width + padding * 2, height: bounds.height + padding * 2)
        container.position = CGPoint(x: overlay.positionX * size.width, y: overlay.positionY * size.height)
        if overlay.style == .box {
            container.backgroundColor = UIColor.black.withAlphaComponent(0.6).cgColor
            container.cornerRadius = fontSize * 0.25
        }

        let text = CATextLayer()
        text.string = overlay.text
        text.font = CTFontCreateWithName(font.fontName as CFString, fontSize, nil)
        text.fontSize = fontSize
        text.foregroundColor = overlay.color.uiColor.cgColor
        text.alignmentMode = .center
        text.isWrapped = true
        text.contentsScale = 2
        text.frame = CGRect(x: padding, y: padding, width: bounds.width, height: bounds.height)
        if overlay.style == .shadow {
            text.shadowColor = UIColor.black.cgColor
            text.shadowOpacity = 0.85
            text.shadowRadius = fontSize * 0.08
            text.shadowOffset = .zero
        }
        container.addSublayer(text)

        addVisibility(to: container, start: overlay.startTime, duration: overlay.duration)
        return container
    }

    private static func addVisibility(to layer: CALayer, start: Double, duration: Double, opacity: Double = 1) {
        layer.opacity = 0
        let fade = min(0.2 / max(duration, 0.01), 0.25)
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, opacity, opacity, 0]
        animation.keyTimes = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
        animation.beginTime = start <= 0 ? AVCoreAnimationBeginTimeAtZero : start
        animation.duration = duration
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "visibility")
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
        exporter.audioTimePitchAlgorithm = .spectral
        
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = videoComposition
        exporter.audioMix = audioMix
        
        try await runExport(ExportSessionBox(exporter))
    }
    
    private func makeTransitionVideoComposition(
        clips: [CompositionClipLayout],
        overlays: [OverlayLayout],
        renderSize: CGSize,
        fitMode: FitMode,
        duration: CMTime
    ) -> AVMutableVideoComposition {
        let edges = clips.flatMap { [$0.start, $0.end] } + overlays.flatMap { [$0.start, $0.end] }
        let boundaries = ([CMTime.zero, duration] + edges.filter { CMTimeCompare($0, duration) <= 0 })
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
            instruction.backgroundColor = UIColor.black.cgColor
            let overlayLayers = overlays
                .filter { CMTimeCompare($0.start, start) <= 0 && CMTimeCompare($0.end, end) >= 0 }
                .map { overlay -> AVMutableVideoCompositionLayerInstruction in
                    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: overlay.track)
                    layer.setTransform(overlayTransform(for: overlay, renderSize: renderSize), at: start)
                    layer.setOpacity(Float(overlay.opacity), at: start)
                    return layer
                }
            guard !activeClips.isEmpty else {
                instruction.layerInstructions = overlayLayers.reversed()
                instructions.append(instruction)
                continue
            }

            func layer(for clip: CompositionClipLayout) -> (AVMutableVideoCompositionLayerInstruction, CGAffineTransform) {
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: clip.track)
                let base = renderTransform(for: clip, renderSize: renderSize, fitMode: fitMode)
                layer.setTransform(base, at: start)
                layer.setOpacity(1, at: start)
                return (layer, base)
            }

            if activeClips.count >= 2 {
                let outgoingClip = activeClips[activeClips.count - 2]
                let incomingClip = activeClips[activeClips.count - 1]
                let (outgoing, outgoingBase) = layer(for: outgoingClip)
                let (incoming, incomingBase) = layer(for: incomingClip)
                let range = CMTimeRange(start: start, end: end)
                applyTransition(
                    incomingClip.transition,
                    range: range,
                    renderSize: renderSize,
                    incoming: (incoming, incomingBase),
                    outgoing: (outgoing, outgoingBase),
                    instruction: instruction
                )
                instruction.layerInstructions = overlayLayers.reversed() + [incoming, outgoing]
            } else {
                instruction.layerInstructions = overlayLayers.reversed() + activeClips.map { layer(for: $0).0 }
            }
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        return videoComposition
    }

    private func overlayTransform(for overlay: OverlayLayout, renderSize: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: overlay.naturalSize).applying(overlay.preferredTransform)
        let orientedWidth = max(abs(rect.width), 1)
        let orientedHeight = abs(rect.height)
        let scale = CGFloat(overlay.widthFraction) * renderSize.width / orientedWidth
        return overlay.preferredTransform
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: -orientedWidth * scale / 2, y: -orientedHeight * scale / 2))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(overlay.rotation * .pi / 180)))
            .concatenating(CGAffineTransform(
                translationX: CGFloat(overlay.centerX) * renderSize.width,
                y: CGFloat(overlay.centerY) * renderSize.height
            ))
    }

    private func applyTransition(
        _ style: TransitionStyle,
        range: CMTimeRange,
        renderSize: CGSize,
        incoming: (layer: AVMutableVideoCompositionLayerInstruction, base: CGAffineTransform),
        outgoing: (layer: AVMutableVideoCompositionLayerInstruction, base: CGAffineTransform),
        instruction: AVMutableVideoCompositionInstruction
    ) {
        let width = renderSize.width
        let height = renderSize.height
        func shifted(_ base: CGAffineTransform, x: CGFloat, y: CGFloat) -> CGAffineTransform {
            base.concatenating(CGAffineTransform(translationX: x, y: y))
        }

        switch style {
        case .none:
            break
        case .dissolve:
            incoming.layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: range)
        case .fadeBlack, .fadeWhite:
            if style == .fadeWhite {
                instruction.backgroundColor = UIColor.white.cgColor
            }
            let half = CMTimeMultiplyByFloat64(range.duration, multiplier: 0.5)
            let middle = CMTimeAdd(range.start, half)
            outgoing.layer.setOpacityRamp(
                fromStartOpacity: 1,
                toEndOpacity: 0,
                timeRange: CMTimeRange(start: range.start, end: middle)
            )
            incoming.layer.setOpacity(0, at: range.start)
            incoming.layer.setOpacityRamp(
                fromStartOpacity: 0,
                toEndOpacity: 1,
                timeRange: CMTimeRange(start: middle, end: CMTimeRangeGetEnd(range))
            )
        case .slideLeft:
            incoming.layer.setTransformRamp(
                fromStart: shifted(incoming.base, x: width, y: 0),
                toEnd: incoming.base,
                timeRange: range
            )
        case .slideRight:
            incoming.layer.setTransformRamp(
                fromStart: shifted(incoming.base, x: -width, y: 0),
                toEnd: incoming.base,
                timeRange: range
            )
        case .slideUp:
            incoming.layer.setTransformRamp(
                fromStart: shifted(incoming.base, x: 0, y: height),
                toEnd: incoming.base,
                timeRange: range
            )
        case .push:
            incoming.layer.setTransformRamp(
                fromStart: shifted(incoming.base, x: width, y: 0),
                toEnd: incoming.base,
                timeRange: range
            )
            outgoing.layer.setTransformRamp(
                fromStart: outgoing.base,
                toEnd: shifted(outgoing.base, x: -width, y: 0),
                timeRange: range
            )
        case .zoom:
            let center = CGPoint(x: width / 2, y: height / 2)
            let zoomed = incoming.base
                .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
                .concatenating(CGAffineTransform(scaleX: 1.3, y: 1.3))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            incoming.layer.setTransformRamp(fromStart: zoomed, toEnd: incoming.base, timeRange: range)
            incoming.layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: range)
        }
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
        let user = clip.transform
        if user != .identity {
            let center = CGPoint(x: renderSize.width / 2, y: renderSize.height / 2)
            transform = transform
                .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
                .concatenating(CGAffineTransform(scaleX: CGFloat(user.scale), y: CGFloat(user.scale)))
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(user.rotation * .pi / 180)))
                .concatenating(CGAffineTransform(
                    translationX: center.x + CGFloat(user.offsetX) * renderSize.width,
                    y: center.y + CGFloat(user.offsetY) * renderSize.height
                ))
        }
        return transform
    }

    private func makeAudioMix(_ placements: [AudioPlacement]) -> AVAudioMix? {
        guard !placements.isEmpty else { return nil }
        var parametersByTrack: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        for placement in placements.sorted(by: { CMTimeCompare($0.start, $1.start) < 0 }) {
            let parameters = parametersByTrack[placement.track.trackID]
                ?? AVMutableAudioMixInputParameters(track: placement.track)
            let duration = CMTimeSubtract(placement.end, placement.start).seconds
            guard duration > 0 else { continue }
            var fadeIn = max(0, placement.fadeIn)
            var fadeOut = max(0, placement.fadeOut)
            if fadeIn + fadeOut > duration {
                let scale = duration / (fadeIn + fadeOut)
                fadeIn *= scale
                fadeOut *= scale
            }
            let volume = max(0, placement.volume)
            if fadeIn > 0.01 {
                parameters.setVolumeRamp(
                    fromStartVolume: 0,
                    toEndVolume: volume,
                    timeRange: CMTimeRange(start: placement.start, duration: CMTime(seconds: fadeIn, preferredTimescale: 600))
                )
            } else {
                parameters.setVolume(volume, at: placement.start)
            }
            if fadeOut > 0.01 {
                let fadeDuration = CMTime(seconds: fadeOut, preferredTimescale: 600)
                parameters.setVolumeRamp(
                    fromStartVolume: volume,
                    toEndVolume: 0,
                    timeRange: CMTimeRange(start: CMTimeSubtract(placement.end, fadeDuration), duration: fadeDuration)
                )
            }
            parametersByTrack[placement.track.trackID] = parameters
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = Array(parametersByTrack.values)
        return mix
    }
    
    nonisolated func calculateRenderSize(aspect: AspectRatio, resolution: ExportResolution, naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let sourceW = max(abs(rect.width), 2)
        let sourceH = max(abs(rect.height), 2)
        let ratio = aspect.ratio ?? (sourceW / sourceH)
        let longSide = resolution.longSide ?? max(sourceW, sourceH)
        let size = ratio >= 1
            ? CGSize(width: longSide, height: longSide / ratio)
            : CGSize(width: longSide * ratio, height: longSide)
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
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
    let timelineStartTime: Double
    let overlapIn: Double
    let transition: TransitionStyle
    let clipVolume: Float
    let narrationAssetID: UUID?
    let narrationVolume: Float
    let narrationOffset: Double
    var speed: Double = 1
    var transform = ClipTransform.identity
}

struct CompositionAudioClip {
    let assetID: UUID
    let timelineStart: Double
    let sourceStart: Double
    let sourceEnd: Double
    let volume: Float
    let fadeIn: Double
    let fadeOut: Double
}

struct CompositionOverlayVideo {
    let assetID: UUID
    let timelineStart: Double
    let sourceStart: Double
    let duration: Double
    let centerX: Double
    let centerY: Double
    let widthFraction: Double
    let volume: Float
    var opacity: Double = 1
    var rotation: Double = 0
}

struct ImageOverlayRender {
    let image: CGImage
    let overlay: MediaOverlay
}

private struct OverlayLayout {
    let track: AVMutableCompositionTrack
    let start: CMTime
    let end: CMTime
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let centerX: Double
    let centerY: Double
    let widthFraction: Double
    var opacity: Double = 1
    var rotation: Double = 0
}

struct CompositionBuildResult {
    let composition: AVMutableComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let sourceAssets: [AVAsset]
}

private struct CompositionClipLayout {
    let track: AVMutableCompositionTrack
    let start: CMTime
    let end: CMTime
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let transition: TransitionStyle
    var transform = ClipTransform.identity
}

private struct AudioPlacement {
    let track: AVMutableCompositionTrack
    let start: CMTime
    let end: CMTime
    let volume: Float
    let fadeIn: Double
    let fadeOut: Double
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
    case missingAssetFile(String)
    
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
        case .missingAssetFile(let name): return "Arquivo de mídia não encontrado: \(name). Importe-o novamente."
        }
    }
}
