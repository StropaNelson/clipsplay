import SwiftUI
import AVFoundation
import CoreMedia
import UIKit

extension TrackType {
    var color: Color {
        switch self {
        case .intro: return Color(red: 0.62, green: 0.40, blue: 1.0)
        case .recap: return Color(red: 1.0, green: 0.60, blue: 0.20)
        case .main: return Color(red: 0.16, green: 0.62, blue: 1.0)
        case .outro: return Color(red: 0.20, green: 0.80, blue: 0.50)
        case .audio: return .pink
        case .overlay: return .cyan
        }
    }

    var shortLabel: String {
        switch self {
        case .intro: return "INTRO"
        case .recap: return "RECAP"
        case .main: return "PRINCIPAL"
        case .outro: return "FINAL"
        case .audio: return "ÁUDIO"
        case .overlay: return "TEXTO"
        }
    }

    var icon: String {
        switch self {
        case .intro: return "play.rectangle.on.rectangle"
        case .recap: return "arrow.counterclockwise"
        case .main: return "film"
        case .outro: return "flag.checkered"
        case .audio: return "music.note"
        case .overlay: return "textformat"
        }
    }
}

/// Storyline timeline: ruler, a single video lane with filmstrip clips, playhead and zoom.
struct TimelineView: View {
    let segments: [TimelineSegment]
    let totalDuration: Double
    let currentTime: Double
    let selectedSegmentID: UUID?
    let canAddIntro: Bool
    let canAddOutro: Bool
    let sourceURL: (TimelineSegment) -> URL?
    let onSeek: (Double) -> Void
    let onSelect: (TimelineSegment?) -> Void
    let onAddIntro: () -> Void
    let onAddOutro: () -> Void

    @State private var pixelsPerSecond: CGFloat = 20
    @State private var pinchBase: CGFloat?
    @State private var didFit = false

    private let headerWidth: CGFloat = 64
    private let leadingInset: CGFloat = 76
    private let trailingInset: CGFloat = 140
    private let rulerHeight: CGFloat = 26
    private let clipHeight: CGFloat = 62
    private let minPPS: CGFloat = 4
    private let maxPPS: CGFloat = 240

    private var safeDuration: Double { max(totalDuration, 0.1) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    trackHeaders
                    ScrollView(.horizontal, showsIndicators: false) {
                        timelineContent
                    }
                    .simultaneousGesture(pinchGesture)
                }
                Spacer(minLength: 0)
                zoomBar(width: geometry.size.width)
            }
            .onAppear {
                guard !didFit else { return }
                didFit = true
                fit(width: geometry.size.width)
            }
            .onChange(of: totalDuration) { _ in
                fit(width: geometry.size.width)
            }
        }
        .background(EditorTheme.timelineBackground)
    }

    private var trackHeaders: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight + 10)
            VStack(spacing: 4) {
                Image(systemName: "film")
                    .font(.system(size: 15, weight: .semibold))
                Text("Vídeo")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.75))
            .frame(width: headerWidth, height: clipHeight)
            .background(EditorTheme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
            .padding(.leading, 6)
        }
        .frame(width: headerWidth + 6)
    }

    private var contentWidth: CGFloat {
        leadingInset + CGFloat(safeDuration) * pixelsPerSecond + trailingInset
    }

    private func xPosition(for time: Double) -> CGFloat {
        leadingInset + CGFloat(time) * pixelsPerSecond
    }

    private func time(at x: CGFloat) -> Double {
        min(safeDuration, max(0, Double((x - leadingInset) / pixelsPerSecond)))
    }

    private var timelineContent: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
                ruler
                lane
            }
            playhead
        }
        .frame(width: contentWidth, alignment: .topLeading)
    }

    private var ruler: some View {
        let pps = pixelsPerSecond
        let inset = leadingInset
        let duration = safeDuration
        let major = majorTickInterval(pps: pps)
        let minorCount = major >= 1 ? 5 : 2
        return Canvas { context, size in
            let minor = major / Double(minorCount)
            var tick = 0
            var t = 0.0
            while t <= duration + 0.0001 {
                let x = inset + CGFloat(t) * pps
                let isMajor = tick % minorCount == 0
                let height: CGFloat = isMajor ? 10 : 5
                let rect = CGRect(x: x, y: size.height - height, width: 1, height: height)
                context.fill(Path(rect), with: .color(.white.opacity(isMajor ? 0.55 : 0.25)))
                if isMajor {
                    context.draw(
                        Text(Self.rulerLabel(t)).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundColor(.white.opacity(0.6)),
                        at: CGPoint(x: x + 3, y: 2),
                        anchor: .topLeading
                    )
                }
                tick += 1
                t = Double(tick) * minor
            }
        }
        .frame(width: contentWidth, height: rulerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in onSeek(time(at: value.location.x)) }
        )
    }

    private var lane: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: contentWidth, height: clipHeight)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(nil) }

            if canAddIntro {
                addButton(title: "Intro", systemImage: "plus", action: onAddIntro)
                    .offset(x: 8)
            }

            ForEach(segments) { segment in
                let width = max(8, CGFloat(segment.duration) * pixelsPerSecond)
                TimelineClipView(
                    segment: segment,
                    width: width,
                    height: clipHeight,
                    isSelected: segment.id == selectedSegmentID,
                    sourceURL: sourceURL(segment)
                )
                .offset(x: xPosition(for: segment.startTime))
                .onTapGesture { onSelect(segment) }
            }

            if canAddOutro {
                addButton(title: "Final", systemImage: "plus", action: onAddOutro)
                    .offset(x: xPosition(for: safeDuration) + 10)
            }
        }
        .frame(width: contentWidth, height: clipHeight, alignment: .topLeading)
    }

    private func addButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .bold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.black)
            .frame(width: 58, height: clipHeight)
            .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var playhead: some View {
        let x = xPosition(for: min(max(currentTime, 0), safeDuration))
        let height = rulerHeight + 10 + clipHeight + 6
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: height)
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .offset(y: -3)
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
        .offset(x: x - 5)
        .frame(width: 10, alignment: .top)
        .allowsHitTesting(false)
    }

    private func zoomBar(width: CGFloat) -> some View {
        HStack(spacing: 10) {
            Text("\(Self.rulerLabel(currentTime)) / \(Self.rulerLabel(totalDuration))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Button { zoom(by: 1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
            Slider(
                value: Binding(
                    get: { Double(log(pixelsPerSecond)) },
                    set: { pixelsPerSecond = CGFloat(exp($0)) }
                ),
                in: Double(log(minPPS))...Double(log(maxPPS))
            )
            .frame(maxWidth: 160)
            Button { zoom(by: 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { fit(width: width) } label: { Image(systemName: "arrow.left.and.right.square") }
        }
        .font(.system(size: 15))
        .foregroundStyle(.white.opacity(0.8))
        .tint(EditorTheme.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let base = pinchBase ?? pixelsPerSecond
                pinchBase = base
                pixelsPerSecond = clamp(base * scale)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func zoom(by factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) {
            pixelsPerSecond = clamp(pixelsPerSecond * factor)
        }
    }

    private func fit(width: CGFloat) {
        let available = width - headerWidth - leadingInset - trailingInset
        pixelsPerSecond = clamp(max(available, 120) / CGFloat(safeDuration))
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(maxPPS, max(minPPS, value))
    }

    private func majorTickInterval(pps: CGFloat) -> Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return candidates.first { CGFloat($0) * pps >= 64 } ?? 600
    }

    static func rulerLabel(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct TimelineClipView: View {
    let segment: TimelineSegment
    let width: CGFloat
    let height: CGFloat
    let isSelected: Bool
    let sourceURL: URL?

    var body: some View {
        let color = segment.trackType.color
        ZStack(alignment: .topLeading) {
            FilmstripView(
                url: sourceURL,
                sourceStart: segment.sourceStartTime,
                sourceDuration: max(segment.sourceDuration, 0.1),
                width: width,
                height: height,
                tint: color
            )
            LinearGradient(
                colors: [.black.opacity(0.65), .clear],
                startPoint: .top,
                endPoint: .center
            )
            if width > 44 {
                HStack(spacing: 4) {
                    Text(segment.trackType.shortLabel)
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(color, in: RoundedRectangle(cornerRadius: 3))
                    if width > 110 {
                        Text(TimelineView.rulerLabel(segment.duration))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    }
                }
                .foregroundStyle(.white)
                .padding(5)
            }
            if !segment.isEnabled {
                Color.black.opacity(0.55)
                Image(systemName: "eye.slash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.white : color.opacity(0.9), lineWidth: isSelected ? 3 : 1.5)
        )
        .contentShape(Rectangle())
    }
}

struct FilmstripView: View {
    let url: URL?
    let sourceStart: Double
    let sourceDuration: Double
    let width: CGFloat
    let height: CGFloat
    let tint: Color

    @State private var frames: [Int: UIImage] = [:]

    private var frameCount: Int {
        max(1, min(40, Int((width / (height * 16 / 9)).rounded(.up))))
    }

    var body: some View {
        let count = frameCount
        let frameWidth = width / CGFloat(count)
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                ZStack {
                    tint.opacity(0.35)
                    if let image = frames[index] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: frameWidth, height: height)
                .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .task(id: taskKey(count: count)) {
            await loadFrames(count: count)
        }
    }

    private func taskKey(count: Int) -> String {
        "\(url?.path ?? "")|\(sourceStart)|\(sourceDuration)|\(count)"
    }

    @MainActor
    private func loadFrames(count: Int) async {
        frames = [:]
        guard let url else { return }
        for index in 0..<count {
            if Task.isCancelled { return }
            let time = sourceStart + sourceDuration * (Double(index) + 0.5) / Double(count)
            if let image = await ThumbnailProvider.shared.thumbnail(url: url, time: time) {
                frames[index] = image
            }
        }
    }
}

actor ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private var cache: [String: UIImage] = [:]
    private var generators: [URL: AVAssetImageGenerator] = [:]

    func thumbnail(url: URL, time: Double) -> UIImage? {
        let key = "\(url.path)#\(Int((time * 4).rounded()))"
        if let cached = cache[key] { return cached }
        let generator: AVAssetImageGenerator
        if let existing = generators[url] {
            generator = existing
        } else {
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 200)
            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            generators[url] = generator
        }
        guard let cgImage = try? generator.copyCGImage(
            at: CMTime(seconds: max(0, time), preferredTimescale: 600),
            actualTime: nil
        ) else { return nil }
        let image = UIImage(cgImage: cgImage)
        if cache.count > 600 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

struct SegmentEditorView: View {
    let segment: TimelineSegment
    let trackType: TrackType
    let project: Project
    let episode: Episode?
    let onSave: (TimelineSegment) -> Void
    let onDelete: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var startTime: Double
    @State private var sourceStartTime: Double
    @State private var sourceEndTime: Double
    @State private var isEnabled: Bool
    @State private var sourceType: SourceType
    @State private var selectedAsset: MediaAsset?
    
    init(segment: TimelineSegment, trackType: TrackType, project: Project, episode: Episode?, onSave: @escaping (TimelineSegment) -> Void, onDelete: @escaping () -> Void) {
        self.segment = segment
        self.trackType = trackType
        self.project = project
        self.episode = episode
        self.onSave = onSave
        self.onDelete = onDelete
        
        _startTime = State(initialValue: segment.startTime)
        _sourceStartTime = State(initialValue: segment.sourceStartTime)
        _sourceEndTime = State(initialValue: segment.sourceEndTime)
        _isEnabled = State(initialValue: segment.isEnabled)
        _sourceType = State(initialValue: segment.sourceType)
        _selectedAsset = State(initialValue: segment.assetID.flatMap { assetID in
            project.mediaAssets.first { $0.id == assetID }
        })
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Posição na Timeline") {
                    HStack {
                        Text("Início")
                        Spacer()
                        TextField("", value: $startTime, format: .number)
                            .keyboardType(.decimalPad)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                        Text("s")
                    }
                    Toggle("Ativo", isOn: $isEnabled)
                }
                
                Section("Origem do Conteúdo") {
                    Picker("Tipo", selection: $sourceType) {
                        ForEach(availableSourceTypes) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .onChange(of: sourceType) { _ in
                        if let selectedAsset, !filteredAssets.contains(where: { $0.id == selectedAsset.id }) {
                            self.selectedAsset = nil
                        }
                    }
                    
                    if sourceType != .mainVideo {
                        Picker("Asset", selection: $selectedAsset) {
                            Text("Nenhum").tag(nil as MediaAsset?)
                            ForEach(filteredAssets) { asset in
                                Text(asset.name).tag(asset as MediaAsset?)
                            }
                        }
                    }
                    
                    HStack {
                        Text("Início no arquivo")
                        Spacer()
                        TextField("", value: $sourceStartTime, format: .number)
                            .keyboardType(.decimalPad)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Fim no arquivo")
                        Spacer()
                        TextField("", value: $sourceEndTime, format: .number)
                            .keyboardType(.decimalPad)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                Section {
                    Button("Excluir Segmento", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Editar \(trackType.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        var updated = segment
                        updated.startTime = startTime
                        updated.sourceStartTime = sourceStartTime
                        updated.sourceEndTime = sourceEndTime
                        updated.duration = sourceEndTime - sourceStartTime
                        updated.isEnabled = isEnabled
                        updated.sourceType = sourceType
                        updated.assetID = selectedAsset?.id
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(
                        startTime < 0
                            || sourceStartTime < 0
                            || sourceEndTime <= sourceStartTime
                            || (sourceType != .mainVideo && selectedAsset == nil)
                            || sourceEndTime > (selectedAsset?.duration ?? project.sourceVideoDuration)
                    )
                }
            }
        }
    }
    
    private var availableSourceTypes: [SourceType] {
        switch trackType {
        case .intro: return [.introAsset, .mainVideo]
        case .recap: return [.recapAsset, .mainVideo]
        case .main: return [.mainVideo]
        case .outro: return [.outroAsset, .mainVideo]
        case .audio: return [.audioAsset]
        case .overlay: return [.imageAsset]
        }
    }
    
    private var filteredAssets: [MediaAsset] {
        switch sourceType {
        case .introAsset, .outroAsset, .recapAsset: return project.mediaAssets.filter { $0.type == .video }
        case .audioAsset: return project.mediaAssets.filter { $0.type == .audio }
        case .imageAsset: return project.mediaAssets.filter { $0.type == .image }
        default: return []
        }
    }
}