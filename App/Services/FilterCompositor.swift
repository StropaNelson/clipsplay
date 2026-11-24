import AVFoundation
import CoreImage
import UIKit
import Vision

/// A video composition that renders through ClipFilterCompositor, applying
/// per-clip Core Image adjustments and chroma key on video overlays.
final class FilterVideoComposition: AVMutableVideoComposition, @unchecked Sendable {
    /// Render infos per track; tracks are reused by several non-overlapping clips.
    var trackRenders: [CMPersistentTrackID: [TrackRenderInfo]] = [:]
    var fitMode: FitMode = .fit
    /// When set, fades the whole frame to black at both ends of the content.
    var fadeEdges = false
    var contentDuration = 0.0
    /// Burned-in text overlays (episode timeline time).
    var textOverlays: [TextOverlay] = []
    /// Burned-in image/video overlays already rasterized to CGImage.
    var imageOverlays: [ImageOverlayRender] = []
    /// Burned-in animated graphic elements in episode timeline time.
    var motionElements: [MotionElement] = []

    /// AVFoundation copies video compositions on assignment, and the copy loses
    /// this subclass — so render data travels inside the instruction objects,
    /// which are passed through untouched. Call once all properties are final.
    func installCustomInstructions() {
        let payload = FilterRenderPayload(
            trackRenders: trackRenders,
            fitMode: fitMode,
            fadeEdges: fadeEdges,
            contentDuration: contentDuration,
            textOverlays: textOverlays,
            imageOverlays: imageOverlays,
            motionElements: motionElements
        )
        instructions = instructions.map { instruction in
            let custom = FilterCompositionInstruction(
                timeRange: instruction.timeRange,
                requiredSourceTrackIDs: Self.requiredTrackIDs(of: instruction),
                payload: payload
            )
            custom.backgroundColor = (instruction as? AVVideoCompositionInstruction)?.backgroundColor
            return custom
        }
        customVideoCompositorClass = ClipFilterCompositor.self
    }

    private static func requiredTrackIDs(of instruction: AVVideoCompositionInstructionProtocol) -> [NSValue] {
        if let custom = instruction as? FilterCompositionInstruction {
            return custom.requiredSourceTrackIDs ?? []
        }
        guard let mutable = instruction as? AVMutableVideoCompositionInstruction else { return [] }
        return mutable.layerInstructions.map { NSNumber(value: $0.trackID) }
    }

    /// Fallback payload for paths where the subclass object itself survives.
    var renderPayload: FilterRenderPayload {
        FilterRenderPayload(
            trackRenders: trackRenders,
            fitMode: fitMode,
            fadeEdges: fadeEdges,
            contentDuration: contentDuration,
            textOverlays: textOverlays,
            imageOverlays: imageOverlays,
            motionElements: motionElements
        )
    }
}

/// Everything the compositor needs for one run of instructions; carried inside
/// the instruction so it survives AVFoundation's composition copies.
final class FilterRenderPayload: @unchecked Sendable {
    let trackRenders: [CMPersistentTrackID: [TrackRenderInfo]]
    let fitMode: FitMode
    let fadeEdges: Bool
    let contentDuration: Double
    let textOverlays: [TextOverlay]
    let imageOverlays: [ImageOverlayRender]
    let motionElements: [MotionElement]

    init(trackRenders: [CMPersistentTrackID: [TrackRenderInfo]], fitMode: FitMode,
         fadeEdges: Bool, contentDuration: Double,
         textOverlays: [TextOverlay], imageOverlays: [ImageOverlayRender],
         motionElements: [MotionElement]) {
        self.trackRenders = trackRenders
        self.fitMode = fitMode
        self.fadeEdges = fadeEdges
        self.contentDuration = contentDuration
        self.textOverlays = textOverlays
        self.imageOverlays = imageOverlays
        self.motionElements = motionElements
    }
}

/// Replaces built-in instructions when the custom compositor is active; the
/// compositor draws clips/transitions/overlays itself from `payload`.
final class FilterCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    var enablePostProcessing = false
    var containsTweening = true
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID = kCMPersistentTrackID_Invalid
    var backgroundColor: CGColor?
    let payload: FilterRenderPayload

    init(timeRange: CMTimeRange, requiredSourceTrackIDs: [NSValue], payload: FilterRenderPayload) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = requiredSourceTrackIDs
        self.payload = payload
        super.init()
    }
}

struct TrackRenderInfo {
    enum Kind { case clip, overlay }
    let kind: Kind
    let start: Double
    let end: Double
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    // main clips
    var transform: ClipTransform = .identity
    var transition: TransitionStyle = .none
    // video overlays
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var widthFraction: Double = 0.4
    var overlayOpacity: Double = 1
    var overlayRotation: Double = 0
    // filters
    var adjustments: ClipAdjustments?
    var chromaKey: ChromaKeySettings?
}

/// Renders each composition frame: applies Core Image filters per track,
/// then draws every track with the same geometry math as the instruction pipeline.
final class ClipFilterCompositor: NSObject, AVVideoCompositing {

    /// Export color space: render targets are Rec.709 SDR buffers, matching
    /// `supportsWideColorSourceFrames = false` and the H.264 output tagging.
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    private let ciContext = CIContext()
    private let contextQueue = DispatchQueue(label: "clipstudio.filtercompositor.rendercontext")
    private let framingQueue = DispatchQueue(label: "clipstudio.filtercompositor.framing")
    private let chromaCacheQueue = DispatchQueue(label: "clipstudio.filtercompositor.chromacache")
    private var renderContext: AVVideoCompositionRenderContext?
    private var shouldCancel = false
    private var framingTrackers: [CMPersistentTrackID: AutoFramingTracker] = [:]
    private var chromaCubeCache: [ChromaKeySettings: Data] = [:]

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [String(kCVPixelBufferPixelFormatTypeKey): [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [String(kCVPixelBufferPixelFormatTypeKey): [kCVPixelFormatType_32BGRA]]
    }

    var supportsWideColorSourceFrames: Bool { false }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        contextQueue.sync { renderContext = newRenderContext }
    }

    func cancelAllPendingVideoCompositionRequests() {
        contextQueue.sync { shouldCancel = true }
        contextQueue.sync { shouldCancel = false }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            var context: AVVideoCompositionRenderContext?
            var cancelled = false
            contextQueue.sync {
                context = renderContext
                cancelled = shouldCancel
            }
            guard !cancelled, let context = context, let buffer = context.newPixelBuffer() else {
                request.finishCancelledRequest()
                return
            }
            let frame = compositeFrame(request: request)
            let size = request.renderContext.videoComposition.renderSize
            ciContext.render(frame, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: outputColorSpace)
            // Tag the buffer so the encoder records the right color metadata;
            // untagged output gets misinterpreted and comes out darker.
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                                  kCVImageBufferColorPrimaries_ITU_R_709_2, CVAttachmentMode.shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                                  kCVImageBufferTransferFunction_ITU_R_709_2, CVAttachmentMode.shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                                  kCVImageBufferYCbCrMatrix_ITU_R_709_2, CVAttachmentMode.shouldPropagate)
            request.finish(withComposedVideoFrame: buffer)
        }
    }

    private func compositeFrame(request: AVAsynchronousVideoCompositionRequest) -> CIImage {
        let composition = request.renderContext.videoComposition
        let renderSize = composition.renderSize
        var canvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: renderSize))

        let payload: FilterRenderPayload?
        if let instruction = request.videoCompositionInstruction as? FilterCompositionInstruction {
            payload = instruction.payload
        } else if let filterComposition = composition as? FilterVideoComposition {
            payload = filterComposition.renderPayload
        } else {
            payload = nil
        }
        guard let payload = payload else { return canvas }

        let time = request.compositionTime.seconds
        var clips: [(CMPersistentTrackID, TrackRenderInfo)] = []
        var overlays: [(CMPersistentTrackID, TrackRenderInfo)] = []
        for (trackID, infos) in payload.trackRenders {
            for info in infos where time >= info.start && time < info.end {
                switch info.kind {
                case .clip: clips.append((trackID, info))
                case .overlay: overlays.append((trackID, info))
                }
            }
        }
        clips.sort { $0.1.start < $1.1.start }
        overlays.sort { $0.1.start < $1.1.start }

        // Transition state between the two most recent active clips.
        var incoming: (CMPersistentTrackID, TrackRenderInfo)?
        var outgoing: (CMPersistentTrackID, TrackRenderInfo)?
        var progress = 1.0
        if clips.count >= 2 {
            incoming = clips[clips.count - 1]
            outgoing = clips[clips.count - 2]
            let window = max(0.001, outgoing!.1.end - incoming!.1.start)
            progress = min(1, max(0, (time - incoming!.1.start) / window))
            if incoming!.1.transition == .fadeWhite {
                canvas = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(origin: .zero, size: renderSize))
            }
        }

        for (trackID, info) in clips + overlays {
            guard let sourceBuffer = request.sourceFrame(byTrackID: trackID) else { continue }
            var image = CIImage(cvImageBuffer: sourceBuffer)
            let framingSource = image
            if let adjustments = info.adjustments, !adjustments.isIdentity {
                image = applyAdjustments(adjustments, to: image)
            }
            if let chroma = info.chromaKey, chroma.enabled {
                image = applyChromaKey(chroma, to: image)
            }
            if info.adjustments?.removeBackground == true {
                image = removePersonBackground(from: image) ?? image
            }
            var transform: CGAffineTransform
            var opacity: Double
            switch info.kind {
            case .clip:
                transform = clipTransform(
                    info,
                    renderSize: renderSize,
                    fitMode: payload.fitMode,
                    image: framingSource,
                    trackID: trackID,
                    time: time
                )
                opacity = 1
                if let incoming = incoming, let outgoing = outgoing, incoming.0 == trackID || outgoing.0 == trackID {
                    let isIncoming = incoming.0 == trackID
                    let adjusted = transitionGeometry(
                        style: incoming.1.transition,
                        progress: progress,
                        isIncoming: isIncoming,
                        base: transform,
                        renderSize: renderSize
                    )
                    transform = adjusted.0
                    opacity = adjusted.1
                    if let crop = adjusted.2 {
                        image = image.transformed(by: transform).cropped(to: crop)
                        canvas = opacity < 0.999
                            ? image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)]).composited(over: canvas)
                            : image.composited(over: canvas)
                        continue
                    }
                }
            case .overlay:
                transform = overlayTransform(info, renderSize: renderSize)
                opacity = info.overlayOpacity
            }
            if opacity < 0.999 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
                ])
            }
            canvas = image.transformed(by: transform).composited(over: canvas)
        }
        var result = canvas.cropped(to: CGRect(origin: .zero, size: renderSize))
        if payload.fadeEdges, payload.contentDuration > 0 {
            let fade = 0.5
            let alpha = min(1, min(time / fade, (payload.contentDuration - time) / fade))
            if alpha < 0.999 {
                result = result.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, alpha))
                ])
            }
        }
        for render in payload.imageOverlays where render.overlay.isVisible(at: time) {
            result = compositeImageOverlay(render, over: result, time: time, renderSize: renderSize)
        }
        for element in payload.motionElements where element.isVisible(at: time) {
            result = compositeMotionElement(element, over: result, time: time, renderSize: renderSize)
        }
        for overlay in payload.textOverlays where overlay.isVisible(at: time) {
            result = compositeTextOverlay(overlay, over: result, time: time, renderSize: renderSize)
        }
        return result
    }

    private func compositeMotionElement(_ element: MotionElement, over canvas: CIImage,
                                       time: Double, renderSize: CGSize) -> CIImage {
        guard let image = MotionElementRasterizer.shared.image(
            for: element,
            at: time,
            renderSize: renderSize
        ) else { return canvas }
        let rect = MotionRenderer.boundingRect(element, canvasSize: renderSize)
        let placed = image.transformed(by: CGAffineTransform(
            translationX: rect.minX,
            y: renderSize.height - rect.maxY
        ))
        return placed.composited(over: canvas)
    }

    /// PiP-style image overlay: centered at normalized top-left-origin point,
    /// width fraction of the render width, rotation negated for the y-flipped space.
    private func compositeImageOverlay(_ render: ImageOverlayRender, over canvas: CIImage,
                                       time: Double, renderSize: CGSize) -> CIImage {
        let overlay = render.overlay
        let elapsed = time - overlay.startTime
        let opacity = Double(overlay.opacity) * OverlayMath.visibilityFade(elapsed: elapsed, duration: overlay.duration)
        guard opacity > 0.001 else { return canvas }
        var image = CIImage(cgImage: render.image)
        let width = CGFloat(overlay.widthFraction) * renderSize.width
        let scale = width / max(1, image.extent.width)
        let center = OverlayMath.ciPoint(x: overlay.centerX, y: overlay.centerY,
                                         width: Double(renderSize.width), height: Double(renderSize.height))
        var transform = CGAffineTransform(translationX: -image.extent.midX, y: -image.extent.midY)
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        transform = transform.concatenating(CGAffineTransform(rotationAngle: CGFloat(-overlay.rotation * .pi / 180)))
        transform = transform.concatenating(CGAffineTransform(translationX: CGFloat(center.x), y: CGFloat(center.y)))
        image = image.transformed(by: transform)
        if opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
            ])
        }
        return image.composited(over: canvas)
    }

    /// Burned-in text: rasterized on demand (cached per overlay + highlighted word),
    /// then placed/animated exactly like the editor preview.
    private func compositeTextOverlay(_ overlay: TextOverlay, over canvas: CIImage,
                                      time: Double, renderSize: CGSize) -> CIImage {
        let elapsed = time - overlay.startTime
        let highlighted = highlightedWordIndex(for: overlay, elapsed: elapsed)
        guard var image = TextOverlayRasterizer.shared.image(for: overlay, highlighted: highlighted,
                                                             renderSize: renderSize) else { return canvas }
        let visibility = OverlayMath.visibilityFade(elapsed: elapsed, duration: overlay.duration)
        let state = OverlayMath.animationState(
            entrance: overlay.animation,
            exit: overlay.exitAnimation,
            startTime: overlay.startTime,
            duration: overlay.duration,
            time: time,
            renderHeight: Double(renderSize.height)
        )
        let opacity = visibility * state.opacity
        guard opacity > 0.001 else { return canvas }
        let center = OverlayMath.ciPoint(x: overlay.positionX, y: overlay.positionY,
                                         width: Double(renderSize.width), height: Double(renderSize.height))
        var transform = CGAffineTransform(translationX: -image.extent.midX, y: -image.extent.midY)
        transform = transform.concatenating(CGAffineTransform(scaleX: CGFloat(state.scale), y: CGFloat(state.scale)))
        transform = transform.concatenating(CGAffineTransform(
            translationX: CGFloat(center.x), y: CGFloat(center.y + state.dy)
        ))
        image = image.transformed(by: transform)
        if opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
            ])
        }
        return image.composited(over: canvas)
    }

    private func highlightedWordIndex(for overlay: TextOverlay, elapsed: Double) -> Int? {
        guard let words = overlay.highlightWords else { return nil }
        for (index, word) in words.enumerated() {
            let end = index + 1 < words.count ? words[index + 1].start : overlay.duration
            if elapsed >= word.start && elapsed < end { return index }
        }
        return words.isEmpty ? nil : words.count - 1
    }

    private func applyAdjustments(_ adjustments: ClipAdjustments, to input: CIImage) -> CIImage {
        var image = input
        image = image.applyingFilter("CIColorControls", parameters: [
            "inputSaturation": adjustments.saturation,
            "inputBrightness": adjustments.brightness * 0.2,
            "inputContrast": adjustments.contrast
        ])
        if adjustments.warmth != 0 {
            let target = 6500 - adjustments.warmth * 2500
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: target, y: 0)
            ])
        }
        if adjustments.vignette > 0.001 {
            let extent = image.extent
            image = image.applyingFilter("CIVignette", parameters: [
                "inputRadius": 1.6,
                "inputIntensity": adjustments.vignette * 2,
                "inputCenter": CIVector(x: extent.midX, y: extent.midY)
            ])
        }
        return image
    }

    private func applyChromaKey(_ settings: ChromaKeySettings, to input: CIImage) -> CIImage {
        guard let mask = chromaMask(settings, for: input) else { return input }
        return input.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": CIImage.empty(),
            "inputMaskImage": mask
        ])
    }

    private func chromaMask(_ settings: ChromaKeySettings, for input: CIImage) -> CIImage? {
        let data = chromaCacheQueue.sync {
            if let cached = chromaCubeCache[settings] { return cached }
            let generated = Self.chromaCubeData(for: settings)
            chromaCubeCache[settings] = generated
            return generated
        }
        return CIFilter(name: "CIColorCube", parameters: [
            kCIInputImageKey: input,
            "inputCubeDimension": 32,
            "inputCubeData": data
        ])?.outputImage
    }

    private static func chromaCubeData(for settings: ChromaKeySettings, dimension: Int = 32) -> Data {
        var data = Data(count: dimension * dimension * dimension * 4 * MemoryLayout<Float>.stride)
        data.withUnsafeMutableBytes { buffer in
            let values = buffer.bindMemory(to: Float.self)
            let keyR = Float(settings.color.red)
            let keyG = Float(settings.color.green)
            let keyB = Float(settings.color.blue)
            let edge0 = Float(max(0.001, settings.tolerance * 0.5))
            let edge1 = Float(max(Double(edge0) + 0.001, settings.tolerance * 1.5))
            var index = 0
            for b in 0..<dimension {
                for g in 0..<dimension {
                    for r in 0..<dimension {
                        let red = Float(r) / Float(dimension - 1)
                        let green = Float(g) / Float(dimension - 1)
                        let blue = Float(b) / Float(dimension - 1)
                        let distance = sqrt(pow(red - keyR, 2) + pow(green - keyG, 2) + pow(blue - keyB, 2))
                        var alpha = max(0, min(1, (distance - edge0) / max(0.0001, edge1 - edge0)))
                        alpha = alpha * alpha * (3 - 2 * alpha)
                        values[index] = alpha
                        values[index + 1] = alpha
                        values[index + 2] = alpha
                        values[index + 3] = alpha
                        index += 4
                    }
                }
            }
        }
        return data
    }

    /// Same placement math as the instruction pipeline: fit/fill + user transform.
    private func clipTransform(
        _ info: TrackRenderInfo,
        renderSize: CGSize,
        fitMode: FitMode,
        image: CIImage,
        trackID: CMPersistentTrackID,
        time: Double
    ) -> CGAffineTransform {
        let transformedRect = CGRect(origin: .zero, size: info.naturalSize)
            .applying(info.preferredTransform)
        let orientedWidth = abs(transformedRect.width)
        let orientedHeight = abs(transformedRect.height)
        let scaleX = renderSize.width / max(orientedWidth, 1)
        let scaleY = renderSize.height / max(orientedHeight, 1)
        let effectiveFitMode: FitMode = info.adjustments?.autoFraming == true ? .fill : fitMode
        let scale = effectiveFitMode == .fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
        var transform = info.preferredTransform.concatenating(
            CGAffineTransform(translationX: -transformedRect.minX, y: -transformedRect.minY)
        )
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        transform = transform.concatenating(CGAffineTransform(
            translationX: (renderSize.width - orientedWidth * scale) / 2,
            y: (renderSize.height - orientedHeight * scale) / 2
        ))
        let user = info.transform
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
        if info.adjustments?.autoFraming == true,
           let target = autoFramingTarget(trackID: trackID, clipStart: info.start, image: image, time: time) {
            let mappedTarget = target.applying(transform)
            let mappedSource = CGRect(origin: .zero, size: info.naturalSize).applying(transform)
            let desired = CGPoint(x: renderSize.width * 0.5, y: renderSize.height * 0.42)
            var dx = desired.x - mappedTarget.x
            var dy = desired.y - mappedTarget.y
            let minDX = renderSize.width - mappedSource.maxX
            let maxDX = -mappedSource.minX
            let minDY = renderSize.height - mappedSource.maxY
            let maxDY = -mappedSource.minY
            if minDX <= maxDX { dx = min(max(dx, minDX), maxDX) } else { dx = 0 }
            if minDY <= maxDY { dy = min(max(dy, minDY), maxDY) } else { dy = 0 }
            transform = transform.concatenating(CGAffineTransform(translationX: dx, y: dy))
        }
        return transform
    }

    private func autoFramingTarget(trackID: CMPersistentTrackID, clipStart: Double, image: CIImage, time: Double) -> CGPoint? {
        framingQueue.sync {
            let tracker = framingTrackers[trackID] ?? AutoFramingTracker()
            tracker.resetIfClipChanged(clipStart)
            framingTrackers[trackID] = tracker
            return tracker.target(for: image, at: time)
        }
    }

    private func overlayTransform(_ info: TrackRenderInfo, renderSize: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: info.naturalSize).applying(info.preferredTransform)
        let orientedWidth = max(abs(rect.width), 1)
        let orientedHeight = abs(rect.height)
        let scale = CGFloat(info.widthFraction) * renderSize.width / orientedWidth
        return info.preferredTransform
            .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: -orientedWidth * scale / 2, y: -orientedHeight * scale / 2))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(info.overlayRotation * .pi / 180)))
            .concatenating(CGAffineTransform(
                translationX: CGFloat(info.centerX) * renderSize.width,
                y: CGFloat(info.centerY) * renderSize.height
            ))
    }

    /// Per-frame geometry for the incoming/outgoing clips of a transition.
    private func transitionGeometry(
        style: TransitionStyle,
        progress: Double,
        isIncoming: Bool,
        base: CGAffineTransform,
        renderSize: CGSize
    ) -> (CGAffineTransform, Double, CGRect?) {
        let width = renderSize.width
        let height = renderSize.height
        let t = progress
        switch style {
        case .none:
            return (base, 1, nil)
        case .dissolve:
            return (base, isIncoming ? t : 1, nil)
        case .fadeBlack, .fadeWhite:
            return (base, isIncoming ? max(0, t * 2 - 1) : max(0, 1 - t * 2), nil)
        case .slideLeft:
            return isIncoming ? (base.concatenating(CGAffineTransform(translationX: width * (1 - t), y: 0)), 1, nil) : (base, 1, nil)
        case .slideRight:
            return isIncoming ? (base.concatenating(CGAffineTransform(translationX: -width * (1 - t), y: 0)), 1, nil) : (base, 1, nil)
        case .slideUp:
            return isIncoming ? (base.concatenating(CGAffineTransform(translationX: 0, y: height * (1 - t))), 1, nil) : (base, 1, nil)
        case .push:
            return isIncoming
                ? (base.concatenating(CGAffineTransform(translationX: width * (1 - t), y: 0)), 1, nil)
                : (base.concatenating(CGAffineTransform(translationX: -width * t, y: 0)), 1, nil)
        case .zoom:
            if isIncoming {
                let center = CGPoint(x: width / 2, y: height / 2)
                let scale = 1.3 - 0.3 * t
                let zoomed = base
                    .concatenating(CGAffineTransform(translationX: -center.x, y: -center.y))
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
                return (zoomed, t, nil)
            }
            return (base, 1, nil)
        case .wipe:
            guard isIncoming else { return (base, 1, nil) }
            return (base, 1, CGRect(x: 0, y: 0, width: width * t, height: height))
        case .iris:
            guard isIncoming else { return (base, 1, nil) }
            let w = width * t, h = height * t
            return (base, 1, CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h))
        }
    }
}

extension ClipFilterCompositor {
    /// Masks the frame to the person in it; returns nil when segmentation fails.
    private func removePersonBackground(from input: CIImage) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: input, options: [:])
        guard (try? handler.perform([request])) != nil,
              let mask = request.results?.first?.pixelBuffer else { return nil }
        let maskImage = CIImage(cvPixelBuffer: mask)
        // The mask arrives in the frame's pixel space; stretch it over the input extent.
        let extent = input.extent
        let scaled = maskImage.transformed(by: CGAffineTransform(
            scaleX: extent.width / maskImage.extent.width,
            y: extent.height / maskImage.extent.height
        ))
        return input.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": CIImage.empty(),
            "inputMaskImage": scaled
        ])
    }
}

private final class AutoFramingTracker {
    private var lastTarget: CGPoint?
    private var lastDetectionTime = -Double.greatestFiniteMagnitude
    private var clipStart = -Double.greatestFiniteMagnitude

    func resetIfClipChanged(_ start: Double) {
        guard abs(start - clipStart) > 0.001 else { return }
        clipStart = start
        lastTarget = nil
        lastDetectionTime = -Double.greatestFiniteMagnitude
    }

    func target(for image: CIImage, at time: Double) -> CGPoint? {
        if let lastTarget = lastTarget, abs(time - lastDetectionTime) < 0.35 { return lastTarget }
        if lastTarget == nil, abs(time - lastDetectionTime) < 0.35 { return nil }
        lastDetectionTime = time
        let extent = image.extent
        let detectionScale = min(1, 320 / max(extent.width, extent.height))
        guard detectionScale > 0 else { return lastTarget }
        let detectionImage = detectionScale < 0.999
            ? image.transformed(by: CGAffineTransform(scaleX: detectionScale, y: detectionScale))
            : image
        guard var detected = detectSubject(in: detectionImage) else { return lastTarget }
        detected = CGPoint(
            x: extent.minX + (detected.x - detectionImage.extent.minX) / detectionScale,
            y: extent.minY + (detected.y - detectionImage.extent.minY) / detectionScale
        )
        if let lastTarget = lastTarget {
            self.lastTarget = CGPoint(
                x: lastTarget.x * 0.76 + detected.x * 0.24,
                y: lastTarget.y * 0.76 + detected.y * 0.24
            )
        } else {
            lastTarget = detected
        }
        return lastTarget
    }

    private func detectSubject(in image: CIImage) -> CGPoint? {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        let handler = VNImageRequestHandler(ciImage: image, options: [:])

        let faces = VNDetectFaceRectanglesRequest()
        if (try? handler.perform([faces])) != nil,
           let face = faces.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            return point(for: face.boundingBox, in: extent, verticalAnchor: 0.5)
        }

        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        if (try? handler.perform([people])) != nil,
           let person = people.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            return point(for: person.boundingBox, in: extent, verticalAnchor: 0.72)
        }
        return nil
    }

    private func point(for box: CGRect, in extent: CGRect, verticalAnchor: CGFloat) -> CGPoint {
        CGPoint(
            x: extent.minX + box.midX * extent.width,
            y: extent.minY + (1 - (box.minY + box.height * verticalAnchor)) * extent.height
        )
    }
}

/// Rasterizes TextOverlays into CGImages for the compositor, matching the
/// SwiftUI preview look (font, padding, box/shadow/plain styles, caption
/// word highlighting). Thread-safe: startRequest may run concurrently.
final class TextOverlayRasterizer {
    static let shared = TextOverlayRasterizer()

    private let queue = DispatchQueue(label: "clipstudio.textrasterizer")
    private var cache: [String: CIImage] = [:]
    private let cacheLimit = 64

    func image(for overlay: TextOverlay, highlighted: Int?, renderSize: CGSize) -> CIImage? {
        // Content + size in the key: edited text or another export size must re-render.
        let key = "\(overlay.hashValue):\(highlighted ?? -1):\(Int(renderSize.width))x\(Int(renderSize.height))"
        return queue.sync {
            if let cached = cache[key] { return cached }
            guard let rendered = render(overlay, highlighted: highlighted, renderSize: renderSize) else {
                return nil
            }
            if cache.count >= cacheLimit { cache.removeAll() }
            cache[key] = rendered
            return rendered
        }
    }

    private func render(_ overlay: TextOverlay, highlighted: Int?, renderSize: CGSize) -> CIImage? {
        let fontSize = max(8, CGFloat(overlay.fontScale) * renderSize.height)
        let font = UIFont.systemFont(ofSize: fontSize, weight: overlay.isBold ? .bold : .regular)
        let maxWidth = renderSize.width * 0.9
        let attributed = attributedText(overlay, highlighted: highlighted, font: font)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributed.addAttribute(.paragraphStyle, value: paragraph,
                                range: NSRange(location: 0, length: attributed.length))
        let bounds = attributed.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let padding = overlay.style == .box ? fontSize * 0.35 : 0
        // Shadow blur must not clip, so give the image extra margin.
        let shadowMargin = overlay.style == .shadow ? fontSize * 0.16 + 4 : CGFloat(2)
        let imageSize = CGSize(
            width: bounds.width + (padding + shadowMargin) * 2,
            height: bounds.height + (padding + shadowMargin) * 2
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let uiImage = UIGraphicsImageRenderer(size: imageSize, format: format).image { context in
            let cgContext = context.cgContext
            let textRect = CGRect(
                x: padding + shadowMargin,
                y: padding + shadowMargin,
                width: bounds.width,
                height: bounds.height
            )
            if overlay.style == .box {
                let boxColor = overlay.color.isDark
                    ? UIColor.white.withAlphaComponent(0.85)
                    : UIColor.black.withAlphaComponent(0.6)
                cgContext.setFillColor(boxColor.cgColor)
                let boxRect = CGRect(origin: .zero, size: imageSize)
                    .insetBy(dx: shadowMargin, dy: shadowMargin)
                cgContext.addPath(CGPath(
                    roundedRect: boxRect,
                    cornerWidth: fontSize * 0.25,
                    cornerHeight: fontSize * 0.25,
                    transform: nil
                ))
                cgContext.fillPath()
            }
            if overlay.style == .shadow {
                cgContext.saveGState()
                cgContext.setShadow(
                    offset: .zero,
                    blur: fontSize * 0.08,
                    color: UIColor.black.withAlphaComponent(0.85).cgColor
                )
                attributed.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                cgContext.restoreGState()
            } else {
                attributed.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// Text with the spoken word tinted when `highlighted` is set (dynamic captions).
    private func attributedText(_ overlay: TextOverlay, highlighted: Int?, font: UIFont) -> NSMutableAttributedString {
        let base = overlay.color.uiColor
        guard let words = overlay.highlightWords else {
            return NSMutableAttributedString(
                string: overlay.text,
                attributes: [.font: font, .foregroundColor: base]
            )
        }
        let highlight = UIColor(TextOverlay.highlightColor)
        let result = NSMutableAttributedString()
        for (index, word) in words.enumerated() {
            let piece = NSMutableAttributedString(
                string: index == 0 ? word.text : " \(word.text)",
                attributes: [
                    .font: font,
                    .foregroundColor: index == highlighted ? highlight : base
                ]
            )
            result.append(piece)
        }
        return result
    }
}

final class MotionElementRasterizer {
    static let shared = MotionElementRasterizer()

    private let queue = DispatchQueue(label: "clipstudio.motionrasterizer")
    private var cache: [String: CIImage] = [:]
    private let cacheLimit = 64

    func image(for element: MotionElement, at time: Double, renderSize: CGSize) -> CIImage? {
        let canCache = MotionMath.isStatic(element, time: time)
        let key = "\(element.hashValue):\(Int(renderSize.width))x\(Int(renderSize.height))"
        return queue.sync {
            if canCache, let cached = cache[key] { return cached }
            guard let rendered = render(element, at: time, renderSize: renderSize) else { return nil }
            if canCache {
                if cache.count >= cacheLimit { cache.removeAll() }
                cache[key] = rendered
            }
            return rendered
        }
    }

    private func render(_ element: MotionElement, at time: Double, renderSize: CGSize) -> CIImage? {
        let rect = MotionRenderer.boundingRect(element, canvasSize: renderSize)
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let uiImage = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            MotionRenderer.draw(element, at: time, canvasSize: renderSize, in: context.cgContext)
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
