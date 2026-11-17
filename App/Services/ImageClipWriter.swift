import UIKit
import AVFoundation
import CoreImage

/// Renders a still image into a short H.264 video clip (used for logos/image vinhetas).
enum ImageClipWriter {
    enum ImageClipError: LocalizedError {
        case cannotWrite

        var errorDescription: String? {
            switch self {
            case .cannotWrite: return "Não foi possível criar o clipe da imagem."
            }
        }
    }

    static func makeClip(image: UIImage, duration: Double, canvasSize: CGSize) async throws -> URL {
        let scale = image.scale > 0 ? image.scale : 1
        var width = Int(canvasSize.width.rounded())
        var height = Int(canvasSize.height.rounded())
        if width <= 0 || height <= 0 {
            width = Int((image.size.width * scale).rounded())
            height = Int((image.size.height * scale).rounded())
        }
        width = max(2, (width / 2) * 2)
        height = max(2, (height / 2) * 2)
        let size = CGSize(width: width, height: height)
        let fps: Int32 = 30
        let frameCount = max(1, Int((duration * Double(fps)).rounded()))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("imageclip_\(UUID().uuidString).mp4")

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: url, fileType: .mp4)
        } catch {
            throw ImageClipError.cannotWrite
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else {
            throw ImageClipError.cannotWrite
        }

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        renderFrame(image: normalized(image), into: buffer, size: size)

        guard writer.canAdd(input) else { throw ImageClipError.cannotWrite }
        writer.add(input)
        guard writer.startWriting() else { throw ImageClipError.cannotWrite }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 20_000_000)
                try Task.checkCancellation()
            }
            let time = CMTime(value: Int64(frame), timescale: fps)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw ImageClipError.cannotWrite
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw ImageClipError.cannotWrite }
        return url
    }

    /// Redraws at scale 1 so `cgImage` pixels and `size` points agree and orientation is up.
    private static func normalized(_ image: UIImage) -> UIImage {
        let scale = image.scale > 0 ? image.scale : 1
        let pixelSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }

    private static func renderFrame(image: UIImage, into buffer: CVPixelBuffer, size: CGSize) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: space,
            bitmapInfo: bitmapInfo
        ) else { return }

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        guard let cgImage = image.cgImage else { return }

        let imageSize = image.size
        // Blurred, darkened aspect-fill background so vertical images don't show black bars.
        let fillScale = max(size.width / imageSize.width, size.height / imageSize.height)
        let fillSize = CGSize(width: imageSize.width * fillScale, height: imageSize.height * fillScale)
        let fillRect = CGRect(x: (size.width - fillSize.width) / 2,
                              y: (size.height - fillSize.height) / 2,
                              width: fillSize.width,
                              height: fillSize.height)
        var background = CIImage(cgImage: cgImage)
            .cropped(to: CGRect(origin: .zero, size: imageSize))
        background = background.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: min(imageSize.width, imageSize.height) * 0.08
        ]).cropped(to: CGRect(origin: .zero, size: imageSize))
        if let colorSpace = context.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) {
            let ciContext = CIContext(options: [.workingColorSpace: colorSpace])
            if let blurred = ciContext.createCGImage(background, from: background.extent) {
                context.draw(blurred, in: fillRect)
            }
        }
        context.setFillColor(UIColor.black.withAlphaComponent(0.35).cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        // Crisp aspect-fit foreground.
        let fitScale = min(size.width / imageSize.width, size.height / imageSize.height)
        let fitSize = CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
        let fitRect = CGRect(x: (size.width - fitSize.width) / 2,
                             y: (size.height - fitSize.height) / 2,
                             width: fitSize.width,
                             height: fitSize.height)
        context.draw(cgImage, in: fitRect)
    }
}
