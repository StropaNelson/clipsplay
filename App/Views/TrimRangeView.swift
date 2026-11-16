import SwiftUI
import AVFoundation

/// Filmstrip (or waveform) range selector with draggable ends, like a video editor's trim bar.
struct TrimRangeView: View {
    let url: URL?
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    var minimumDuration: Double = 0.1
    var isAudio = false
    var tint: Color = .yellow
    var onScrub: (Double) -> Void = { _ in }

    @State private var dragOrigin: (start: Double, end: Double)?

    private let height: CGFloat = 56
    private let handleWidth: CGFloat = 16

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = max(geometry.size.width - handleWidth * 2, 1)
                let safeDuration = max(duration, minimumDuration)
                let startX = handleWidth + CGFloat(start / safeDuration) * width
                let endX = handleWidth + CGFloat(end / safeDuration) * width

                ZStack(alignment: .topLeading) {
                    Group {
                        if isAudio {
                            WaveformView(
                                url: url,
                                sourceStart: 0,
                                sourceDuration: safeDuration,
                                color: .green
                            )
                            .background(Color.green.opacity(0.15))
                        } else {
                            FilmstripView(
                                url: url,
                                sourceStart: 0,
                                sourceDuration: safeDuration,
                                width: width,
                                height: height,
                                tint: .gray
                            )
                        }
                    }
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .offset(x: handleWidth)

                    Color.black.opacity(0.6)
                        .frame(width: max(0, startX - handleWidth), height: height)
                        .offset(x: handleWidth)
                    Color.black.opacity(0.6)
                        .frame(width: max(0, handleWidth + width - endX), height: height)
                        .offset(x: endX)

                    Rectangle()
                        .stroke(tint, lineWidth: 3)
                        .frame(width: max(0, endX - startX), height: height)
                        .contentShape(Rectangle())
                        .offset(x: startX)
                        .gesture(moveGesture(width: width, safeDuration: safeDuration))

                    handle(systemImage: "chevron.compact.left")
                        .offset(x: startX - handleWidth)
                        .gesture(edgeGesture(isStart: true, width: width, safeDuration: safeDuration))
                    handle(systemImage: "chevron.compact.right")
                        .offset(x: endX)
                        .gesture(edgeGesture(isStart: false, width: width, safeDuration: safeDuration))
                }
            }
            .frame(height: height)

            HStack {
                Text(Self.label(start))
                Spacer()
                Text(String(format: "%.1fs", max(0, end - start)))
                    .fontWeight(.semibold)
                Spacer()
                Text(Self.label(end))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func handle(systemImage: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(tint)
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.black)
        }
        .frame(width: handleWidth, height: height)
        .contentShape(Rectangle().inset(by: -10))
    }

    private func edgeGesture(isStart: Bool, width: CGFloat, safeDuration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = dragOrigin ?? (start: start, end: end)
                dragOrigin = origin
                let delta = Double(value.translation.width / width) * safeDuration
                if isStart {
                    start = min(max(0, origin.start + delta), end - minimumDuration)
                    onScrub(start)
                } else {
                    end = max(min(safeDuration, origin.end + delta), start + minimumDuration)
                    onScrub(end)
                }
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func moveGesture(width: CGFloat, safeDuration: Double) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let origin = dragOrigin ?? (start: start, end: end)
                dragOrigin = origin
                let length = origin.end - origin.start
                let delta = Double(value.translation.width / width) * safeDuration
                let newStart = min(max(0, origin.start + delta), safeDuration - length)
                start = newStart
                end = newStart + length
                onScrub(start)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    static func label(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00.0" }
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, rest)
    }
}

/// Peak waveform for a slice of a media file's first audio track.
struct WaveformView: View {
    let url: URL?
    let sourceStart: Double
    let sourceDuration: Double
    var color: Color = .green
    var gain: Float = 1

    @State private var peaks: [Float] = []

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty, sourceDuration > 0 else { return }
            let rate = WaveformProvider.bucketsPerSecond
            let first = max(0, Int(sourceStart * rate))
            let last = min(peaks.count, Int((sourceStart + sourceDuration) * rate))
            guard last > first else { return }
            let count = last - first
            let barWidth = max(1, size.width / CGFloat(count))
            let step = max(1, Int(ceil(Double(count) / Double(max(size.width / 2, 1)))))
            let mid = size.height / 2
            var index = first
            while index < last {
                let peak = CGFloat(min(1, peaks[index] * max(gain, 0.05)))
                let x = CGFloat(index - first) * barWidth
                let h = max(1, peak * size.height * 0.9)
                context.fill(
                    Path(CGRect(x: x, y: mid - h / 2, width: max(1, barWidth * CGFloat(step) * 0.7), height: h)),
                    with: .color(color)
                )
                index += step
            }
        }
        .task(id: url?.path ?? "") {
            guard let url else { return }
            peaks = await WaveformProvider.shared.peaks(for: url)
        }
    }
}

actor WaveformProvider {
    static let shared = WaveformProvider()
    static let bucketsPerSecond = 20.0

    private var cache: [URL: [Float]] = [:]

    func peaks(for url: URL) async -> [Float] {
        if let cached = cache[url] { return cached }
        let result = (try? await load(url)) ?? []
        cache[url] = result
        return result
    }

    private func load(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let sampleRate = 8000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let samplesPerBucket = Int(sampleRate / Self.bucketsPerSecond)
        var peaks: [Float] = []
        var currentPeak: Int16 = 0
        var countInBucket = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Int16](repeating: 0, count: length / 2)
            let status = data.withUnsafeMutableBytes { pointer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: pointer.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for sample in data {
                let magnitude = sample == Int16.min ? Int16.max : abs(sample)
                if magnitude > currentPeak { currentPeak = magnitude }
                countInBucket += 1
                if countInBucket >= samplesPerBucket {
                    peaks.append(Float(currentPeak) / Float(Int16.max))
                    currentPeak = 0
                    countInBucket = 0
                }
            }
        }
        if countInBucket > 0 {
            peaks.append(Float(currentPeak) / Float(Int16.max))
        }
        let maxPeak = peaks.max() ?? 0
        guard maxPeak > 0 else { return peaks }
        return peaks.map { min(1, $0 / maxPeak) }
    }
}
