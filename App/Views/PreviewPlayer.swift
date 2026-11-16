import SwiftUI
import AVKit
import AVFoundation

@MainActor
struct PreviewPlayerView: View {
    let player: AVPlayer
    let onSeek: (Double) -> Void
    let onPlayPause: () -> Void
    let onSkipBackward: () -> Void
    let onSkipForward: () -> Void
    
    @State private var currentTime: CMTime = .zero
    @State private var duration: CMTime = .zero
    @State private var isPlaying = false
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var timeObserver: Any?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VideoPlayer(player: player)
                    .disabled(true)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls.toggle()
                        }
                        resetControlsTimer()
                    }
                
                if showControls {
                    VStack {
                        Spacer()
                        
                        HStack(spacing: 20) {
                            Button(action: onSkipBackward) {
                                Image(systemName: "gobackward.10")
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(width: 50, height: 50)
                                    .background(.black.opacity(0.5), in: Circle())
                            }
                            
                            Button(action: onPlayPause) {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 36, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(width: 70, height: 70)
                                    .background(.black.opacity(0.6), in: Circle())
                            }
                            
                            Button(action: onSkipForward) {
                                Image(systemName: "goforward.10")
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(width: 50, height: 50)
                                    .background(.black.opacity(0.5), in: Circle())
                            }
                        }
                        .padding(.bottom, 20)
                        
                        VStack(spacing: 4) {
                            Slider(
                                value: Binding(
                                    get: { currentTime.seconds / max(duration.seconds, 1) },
                                    set: { onSeek($0 * duration.seconds) }
                                ),
                                in: 0...1
                            )
                            .tint(.white)
                            .padding(.horizontal, 20)
                            
                            HStack {
                                Text(formatTime(currentTime.seconds))
                                    .font(.caption.monospacedDigit())
                                Spacer()
                                Text(formatTime(duration.seconds))
                                    .font(.caption.monospacedDigit())
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                        }
                        .background(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                }
            }
        }
        .onAppear {
            setupTimeObserver()
        }
        .onDisappear {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
            }
            controlsTimer?.invalidate()
        }
    }
    
    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                currentTime = time
                if let item = player.currentItem {
                    duration = item.duration
                }
                isPlaying = player.timeControlStatus == .playing
            }
        }
    }
    
    private func resetControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls = false
                }
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total/60, total%60)
    }
}

struct CompactPreviewPlayer: View {
    let player: AVPlayer
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void
    let onPlayPause: () -> Void
    
    @State private var isPlaying = false
    
    var body: some View {
        VStack(spacing: 8) {
            VideoPlayer(player: player)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
            HStack(spacing: 16) {
                Button(action: { onSeek(max(0, currentTime - 10)) }) {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                }
                
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                }
                
                Button(action: { onSeek(min(duration, currentTime + 10)) }) {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                }
                
                Slider(
                    value: Binding(
                        get: { currentTime / max(duration, 1) },
                        set: { onSeek($0 * duration) }
                    ),
                    in: 0...1
                )
                
                Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 100)
            }
            .padding(.horizontal)
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct ThumbnailStripView: View {
    let asset: AVAsset
    let duration: Double
    let count: Int
    let onTap: (Double) -> Void
    
    @State private var thumbnails: [UIImage?] = []
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { index in
                    Group {
                        if let thumb = thumbnails[index] {
                            Image(uiImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.2))
                                .overlay { ProgressView() }
                        }
                    }
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        let time = Double(index) * duration / Double(count)
                        onTap(time)
                    }
                }
            }
            .padding(.horizontal)
        }
        .task {
            await generateThumbnails()
        }
    }
    
    private func generateThumbnails() async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 135)
        
        var results: [UIImage?] = Array(repeating: nil, count: count)
        
        for i in 0..<count {
            let time = CMTime(seconds: Double(i) * duration / Double(count), preferredTimescale: 600)
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                results[i] = UIImage(cgImage: cgImage)
            } catch {
                results[i] = nil
            }
        }
        
        await MainActor.run {
            thumbnails = results
        }
    }
}