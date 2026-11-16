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

    private let ciContext = CIContext()
    private let contextQueue = DispatchQueue(label: "clipstudio.filtercompositor.rendercontext")
    private let framingQueue = DispatchQueue(label: "clipstudio.filtercompositor.framing")
    private var renderContext: AVVideoCompositionRenderContext?
    private var shouldCancel = false
    private var framingTrackers: [CMPersistentTrackID: AutoFramingTracker] = [:]

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [String(kCVPixelBufferPixelFormatTypeKey): [
            kCVPixelFormatType_32BGRA,
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
            guard !cancelled, let context, let buffer = context.newPixelBuffer() else {
                request.finishCancelledRequest()
                return
            }
            let frame = compositeFrame(request: request)
            let size = request.renderContext.videoComposition.renderSize
            ciContext.render(frame, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
            request.finish(withComposedVideoFrame: buffer)
        }
    }

    private func compositeFrame(request: AVAsynchronousVideoCompositionRequest) -> CIImage {
        let composition = request.renderContext.videoComposition
        let renderSize = composition.renderSize
        var canvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: renderSize))
        guard let composition = composition as? FilterVideoComposition else { return canvas }

        let time = request.compositionTime.seconds
        var clips: [(CMPersistentTrackID, TrackRenderInfo)] = []
        var overlays: [(CMPersistentTrackID, TrackRenderInfo)] = []
        for (trackID, infos) in composition.trackRenders {
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
                    fitMode: composition.fitMode,
                    image: framingSource,
                    trackID: trackID,
                    time: time
                )
                opacity = 1
                if let incoming, let outgoing, incoming.0 == trackID || outgoing.0 == trackID {
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
        if composition.fadeEdges, composition.contentDuration > 0 {
            let fade = 0.5
            let alpha = min(1, min(time / fade, (composition.contentDuration - time) / fade))
            if alpha < 0.999 {
                result = result.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, alpha))
                ])
            }
        }
        return result
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
        guard let kernel = Self.chromaKernel else { return input }
        let key = settings.color
        return kernel.apply(
            extent: input.extent,
            arguments: [
                input,
                CIVector(x: key.red, y: key.green, z: key.blue),
                max(0.05, min(1, settings.tolerance))
            ]
        ) ?? input
    }

    private static let chromaKernel: CIColorKernel? = CIColorKernel(source: """
    kernel vec4 chromaKey(__sample s, vec3 keyColor, float tolerance) {
        float d = distance(s.rgb, keyColor);
        float alpha = smoothstep(tolerance * 0.5, tolerance * 1.5, d);
        return vec4(s.rgb, s.a * alpha);
    }
    """)

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
              let mask = request.results?.first else { return nil }
        let maskImage = CIImage(cvImageBuffer: mask)
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
        if let lastTarget, abs(time - lastDetectionTime) < 0.2 { return lastTarget }
        if lastTarget == nil, abs(time - lastDetectionTime) < 0.2 { return nil }
        lastDetectionTime = time
        guard let detected = detectSubject(in: image) else { return lastTarget }
        if let lastTarget {
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
