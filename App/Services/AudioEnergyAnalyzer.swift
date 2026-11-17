import Foundation
import AVFoundation

/// Loudness profile of source audio, decoded locally with AVAssetReader.
/// Levels are normalized 0...1 (mapped from −60 dBFS…0 dBFS RMS per interval).
enum AudioEnergyAnalyzer {
    /// Energy of `url` between local `start` and `end`, one value per `interval` seconds.
    static func energy(url: URL, start: Double, end: Double, interval: Double = 0.1) async throws -> [Float] {
        guard end - start > 0.05 else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: end - start, preferredTimescale: 600)
        )
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let samplesPerFrame = max(1, Int(16_000 * interval))
        var levels: [Float] = []
        var sumSquares = 0.0
        var count = 0
        while !Task.isCancelled, let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = data.withUnsafeMutableBytes { pointer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: pointer.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for sample in data {
                sumSquares += Double(sample) * Double(sample)
                count += 1
                if count >= samplesPerFrame {
                    levels.append(decibelLevel(sumSquares: sumSquares, count: count))
                    sumSquares = 0
                    count = 0
                }
            }
        }
        if count > 0 {
            levels.append(decibelLevel(sumSquares: sumSquares, count: count))
        }
        return levels
    }

    /// Global sequence time of the quietest instant near each requested time.
    /// The search window is clipped to the source clip containing the time.
    static func quietPoints(project: Project, near times: [Double], window: Double = 10) async -> [Double] {
        let interval = 0.5
        var result: [Double] = []
        for time in times {
            guard let clip = project.sourceClips.first(where: {
                time >= $0.sequenceStartTime + $0.startTime && time < $0.sequenceStartTime + $0.endTime
            }) ?? project.sourceClips.last,
                  let url = project.sourceURL(for: clip) else {
                result.append(time)
                continue
            }
            let localTime = time - clip.sequenceStartTime
            let localStart = max(clip.startTime, localTime - window)
            let localEnd = min(clip.endTime, localTime + window)
            guard localEnd - localStart > 0.3 else {
                result.append(time)
                continue
            }
            do {
                let levels = smoothed(
                    try await energy(url: url, start: localStart, end: localEnd, interval: interval),
                    radius: 1
                )
                guard let minIndex = levels.indices.min(by: { levels[$0] < levels[$1] }) else {
                    result.append(time)
                    continue
                }
                let localQuiet = localStart + (Double(minIndex) + 0.5) * interval
                result.append(clip.sequenceStartTime + localQuiet)
            } catch {
                result.append(time)
            }
        }
        return result
    }

    /// Energy over the whole concatenated source sequence; gaps are zero-filled.
    static func sequenceProfile(project: Project, interval: Double = 0.5) async -> [Float] {
        let total = project.sequenceSourceDuration
        guard total > 0 else { return [] }
        var profile = [Float](repeating: 0, count: max(1, Int(ceil(total / interval))))
        for clip in project.sourceClips {
            guard clip.duration > 0.05, let url = project.sourceURL(for: clip) else { continue }
            guard let levels = try? await energy(url: url, start: clip.startTime, end: clip.endTime, interval: interval) else { continue }
            let offset = Int((clip.sequenceStartTime + clip.startTime) / interval)
            for (index, level) in levels.enumerated() {
                let target = offset + index
                if target >= 0 && target < profile.count {
                    profile[target] = level
                }
            }
        }
        return profile
    }

    private static func smoothed(_ levels: [Float], radius: Int) -> [Float] {
        levels.enumerated().map { index, _ in
            let lower = max(0, index - radius)
            let upper = min(levels.count - 1, index + radius)
            return levels[lower...upper].reduce(0, +) / Float(upper - lower + 1)
        }
    }

    private static func decibelLevel(sumSquares: Double, count: Int) -> Float {
        let rms = sqrt(sumSquares / Double(max(1, count)))
        let db = 20 * log10(rms + 1e-9)
        return Float(min(1, max(0, (db + 60) / 60)))
    }
}
