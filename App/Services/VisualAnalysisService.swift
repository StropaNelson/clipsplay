import Foundation
import AVFoundation
import CoreGraphics
import UIKit

actor VisualAnalysisService {
    static let shared = VisualAnalysisService()

    private init() {}

    func detectSceneCuts(
        in videoURL: URL,
        duration: Double,
        sampleInterval: Double = 1.5
    ) async -> [Double] {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 96, height: 54)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

            let safeDuration = max(0, duration)
            guard safeDuration > 2 else { return [Double]() }
            let interval = max(0.75, sampleInterval)
            let count = min(600, max(2, Int(ceil(safeDuration / interval))))
            var signatures: [[Double]] = []
            var times: [Double] = []

            for index in 0..<count {
                let time = min(safeDuration - 0.05, Double(index) * safeDuration / Double(max(1, count - 1)))
                guard time >= 0 else { continue }
                autoreleasepool {
                    if let image = try? generator.copyCGImage(
                        at: CMTime(seconds: time, preferredTimescale: 600),
                        actualTime: nil
                    ), let signature = Self.signature(for: image) {
                        signatures.append(signature)
                        times.append(time)
                    }
                }
            }
            guard signatures.count > 1 else { return [] }

            var differences: [Double] = []
            for index in 1..<signatures.count {
                differences.append(Self.distance(signatures[index - 1], signatures[index]))
            }
            let mean = differences.reduce(0, +) / Double(differences.count)
            let variance = differences.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(differences.count)
            let deviation = sqrt(variance)
            let threshold = min(0.42, max(0.16, mean + deviation * 1.25))

            var cuts: [Double] = []
            for (index, difference) in differences.enumerated() where difference >= threshold {
                let time = times[index + 1]
                if cuts.last.map({ time - $0 >= interval * 1.4 }) ?? true {
                    cuts.append(time)
                }
            }
            return cuts
        }.value
    }

    private nonisolated static func signature(for image: CGImage) -> [Double]? {
        let width = 12
        let height = 4
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        var didDraw = false
        data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            didDraw = true
        }
        guard didDraw else { return nil }

        var result: [Double] = []
        result.reserveCapacity(12 * 3 + 1)
        var luminance = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * bytesPerPixel
                let r = Double(data[offset]) / 255
                let g = Double(data[offset + 1]) / 255
                let b = Double(data[offset + 2]) / 255
                result.append(contentsOf: [r, g, b])
                luminance += r * 0.2126 + g * 0.7152 + b * 0.0722
            }
        }
        result.append(luminance / Double(width * height))
        return result
    }

    private nonisolated static func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total = 0.0
        for index in a.indices { total += abs(a[index] - b[index]) }
        return total / Double(a.count)
    }
}
