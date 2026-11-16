import SwiftUI
import CoreMedia

struct TimelineView: View {
    let episode: Episode?
    let project: Project
    let tracks: [TrackType: [TimelineSegment]]
    let onTrackUpdate: ([TrackType: [TimelineSegment]]) -> Void
    let onPlayheadMove: (Double) -> Void
    
    @State private var zoomLevel: Double = 1.0
    @State private var horizontalOffset: Double = 0
    @State private var playheadPosition: Double = 0
    @State private var selectedSegment: TimelineSegment?
    @State private var showingSegmentEditor = false
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var dragSegment: TimelineSegment?
    @State private var dragTrack: TrackType?
    
    private let trackHeight: CGFloat = 60
    private let rulerHeight: CGFloat = 40
    private let minZoom: Double = 0.25
    private let maxZoom: Double = 20.0
    private let basePixelsPerSecond: CGFloat = 20
    
    var totalDuration: Double {
        episode?.totalDuration ?? project.sourceVideoDuration
    }
    
    var visibleDuration: Double {
        totalDuration / zoomLevel
    }
    
    var pixelsPerSecond: CGFloat {
        basePixelsPerSecond * zoomLevel
    }
    
    var contentWidth: CGFloat {
        CGFloat(totalDuration) * pixelsPerSecond
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        timelineContent
                            .frame(width: max(contentWidth, geometry.size.width), height: trackHeight * CGFloat(TrackType.allCases.count) + rulerHeight)
                    }
                }
                
                zoomControls
                
                if let episode = episode {
                    playheadView(geometry: geometry, episode: episode)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .bottom) {
            timelineToolbar
        }
        .sheet(isPresented: $showingSegmentEditor) {
            if let segment = selectedSegment, let trackType = dragTrack ?? trackForSegment(segment) {
                SegmentEditorView(
                    segment: segment,
                    trackType: trackType,
                    project: project,
                    episode: episode,
                    onSave: { updated in
                        updateSegment(segment, with: updated)
                    },
                    onDelete: {
                        deleteSegment(segment)
                    }
                )
            }
        }
    }
    
    private var timelineContent: some View {
        VStack(spacing: 0) {
            timeRuler
            
            ForEach(TrackType.allCases) { trackType in
                TrackView(
                    trackType: trackType,
                    segments: tracks[trackType] ?? [],
                    totalDuration: totalDuration,
                    pixelsPerSecond: pixelsPerSecond,
                    horizontalOffset: horizontalOffset,
                    onSegmentTap: { segment in
                        selectedSegment = segment
                        dragTrack = trackType
                        showingSegmentEditor = true
                    },
                    onSegmentDrag: { segment, translation in
                        handleSegmentDrag(segment, trackType: trackType, translation: translation)
                    },
                    onSegmentDragEnd: { segment, translation in
                        finalizeSegmentDrag(segment, trackType: trackType, translation: translation)
                    }
                )
            }
        }
    }
    
    private var timeRuler: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(height: rulerHeight)
            
            let majorInterval = majorTickInterval()
            let startTime = horizontalOffset / pixelsPerSecond
            let endTime = startTime + visibleDuration
            let tickCount = max(0, Int((endTime - startTime) / majorInterval) + 1)
            
            ForEach(0..<tickCount, id: \.self) { index in
                timeRulerTick(index: index, startTime: startTime, majorInterval: majorInterval)
            }
        }
    }

    @ViewBuilder
    private func timeRulerTick(index: Int, startTime: Double, majorInterval: Double) -> some View {
        let time = startTime + Double(index) * majorInterval
        if time >= 0 && time <= totalDuration {
            let x = (time - horizontalOffset / pixelsPerSecond) * pixelsPerSecond
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1, height: rulerHeight)

                Text(formatTime(time))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(x: 2, y: 2)
            }
            .position(x: x, y: rulerHeight / 2)
        }
    }
    
    private func majorTickInterval() -> Double {
        let interval = visibleDuration / 10
        if interval <= 1 { return 0.5 }
        if interval <= 5 { return 1 }
        if interval <= 15 { return 5 }
        if interval <= 60 { return 15 }
        if interval <= 120 { return 30 }
        return 60
    }
    
    private func playheadView(geometry: GeometryProxy, episode: Episode) -> some View {
        let x = playheadPosition * pixelsPerSecond
        let totalHeight = trackHeight * CGFloat(TrackType.allCases.count) + rulerHeight
        
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: totalHeight)
            
            Triangle()
                .fill(Color.red)
                .frame(width: 16, height: 16)
                .offset(x: -8, y: -8)
            
            Text(formatTime(playheadPosition))
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red, in: Capsule())
                .offset(x: -40, y: -28)
        }
        .position(x: x, y: totalHeight / 2)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let newX = value.location.x
                    let newTime = newX / pixelsPerSecond
                    playheadPosition = max(0, min(totalDuration, newTime))
                    onPlayheadMove(playheadPosition)
                }
        )
    }
    
    private var zoomControls: some View {
        VStack {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Button { zoomIn() } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    Button { zoomOut() } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Button { zoomFit() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding()
            }
            Spacer()
        }
    }
    
    private var timelineToolbar: some View {
        HStack(spacing: 16) {
            Label("Zoom: \(Int(zoomLevel * 100))%", systemImage: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Button {
                addSegment(to: .intro)
            } label: {
                Label("Adicionar Intro", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(episode == nil)
            
            Button {
                addSegment(to: .recap)
            } label: {
                Label("Adicionar Recap", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(episode == nil)
            
            Button {
                addSegment(to: .outro)
            } label: {
                Label("Adicionar Outro", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(episode == nil)
        }
        .padding()
        .background(.thinMaterial)
    }
    
    private func zoomIn() {
        withAnimation(.spring(response: 0.2)) {
            zoomLevel = min(maxZoom, zoomLevel * 1.5)
        }
    }
    
    private func zoomOut() {
        withAnimation(.spring(response: 0.2)) {
            zoomLevel = max(minZoom, zoomLevel / 1.5)
        }
    }
    
    private func zoomFit() {
        withAnimation(.spring(response: 0.3)) {
            zoomLevel = 1.0
            horizontalOffset = 0
        }
    }
    
    private func addSegment(to trackType: TrackType) {
        guard let episode = episode else { return }
        let newSegment = TimelineSegment(
            id: UUID(),
            trackType: trackType,
            startTime: playheadPosition,
            duration: 5,
            sourceStartTime: 0,
            sourceEndTime: 5,
            sourceType: trackType == .main ? .mainVideo : .introAsset,
            assetID: nil,
            isEnabled: true
        )
        var updatedTracks = tracks
        updatedTracks[trackType, default: []].append(newSegment)
        onTrackUpdate(updatedTracks)
    }
    
    private func handleSegmentDrag(_ segment: TimelineSegment, trackType: TrackType, translation: CGSize) {
        dragSegment = segment
        dragOffset = translation
        isDragging = true
    }
    
    private func finalizeSegmentDrag(_ segment: TimelineSegment, trackType: TrackType, translation: CGSize) {
        let timeDelta = Double(translation.width) / pixelsPerSecond
        var updatedTracks = tracks
        
        if var trackSegments = updatedTracks[trackType],
           let index = trackSegments.firstIndex(where: { $0.id == segment.id }) {
            var updatedSegment = trackSegments[index]
            updatedSegment.startTime = max(0, min(totalDuration - updatedSegment.duration, segment.startTime + timeDelta))
            trackSegments[index] = updatedSegment
            updatedTracks[trackType] = trackSegments
            onTrackUpdate(updatedTracks)
        }
        
        dragSegment = nil
        dragOffset = .zero
        isDragging = false
    }
    
    private func updateSegment(_ segment: TimelineSegment, with updated: TimelineSegment) {
        var updatedTracks = tracks
        if var trackSegments = updatedTracks[updated.trackType],
           let index = trackSegments.firstIndex(where: { $0.id == segment.id }) {
            trackSegments[index] = updated
            updatedTracks[updated.trackType] = trackSegments
            onTrackUpdate(updatedTracks)
        }
    }
    
    private func deleteSegment(_ segment: TimelineSegment) {
        var updatedTracks = tracks
        if var trackSegments = updatedTracks[segment.trackType] {
            trackSegments.removeAll { $0.id == segment.id }
            updatedTracks[segment.trackType] = trackSegments
            onTrackUpdate(updatedTracks)
        }
        showingSegmentEditor = false
    }
    
    private func trackForSegment(_ segment: TimelineSegment) -> TrackType? {
        return tracks.first { $0.value.contains(where: { $0.id == segment.id }) }?.key
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct TrackView: View {
    let trackType: TrackType
    let segments: [TimelineSegment]
    let totalDuration: Double
    let pixelsPerSecond: CGFloat
    let horizontalOffset: Double
    let onSegmentTap: (TimelineSegment) -> Void
    let onSegmentDrag: (TimelineSegment, CGSize) -> Void
    let onSegmentDragEnd: (TimelineSegment, CGSize) -> Void
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(trackColor.opacity(0.08))
                .frame(height: 60)
            
            ForEach(segments) { segment in
                SegmentView(
                    segment: segment,
                    trackType: trackType,
                    pixelsPerSecond: pixelsPerSecond,
                    onTap: { onSegmentTap(segment) },
                    onDrag: { translation in onSegmentDrag(segment, translation) },
                    onDragEnd: { translation in onSegmentDragEnd(segment, translation) }
                )
            }
            
            if segments.isEmpty {
                Text(trackType.rawValue)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .padding(.top, 8)
            }
        }
        .frame(height: 60)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(trackColor)
                .frame(width: 3)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
    }
    
    private var trackColor: Color {
        switch trackType {
        case .intro: return .purple
        case .recap: return .orange
        case .main: return .blue
        case .outro: return .green
        case .audio: return .pink
        case .overlay: return .cyan
        }
    }
}

struct SegmentView: View {
    let segment: TimelineSegment
    let trackType: TrackType
    let pixelsPerSecond: CGFloat
    let onTap: () -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: (CGSize) -> Void
    
    var body: some View {
        let x = segment.startTime * pixelsPerSecond
        let width = max(20, segment.duration * pixelsPerSecond)
        
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(trackColor.opacity(segment.isEnabled ? 0.8 : 0.3))
                .frame(width: width, height: 40)
            
            if width > 50 {
                Text(segmentLabel)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .lineLimit(1)
            }
        }
        .position(x: x + width / 2, y: 30)
        .gesture(
            TapGesture().onEnded { onTap() }
        )
        .gesture(
            DragGesture()
                .onChanged { onDrag($0.translation) }
                .onEnded { onDragEnd($0.translation) }
        )
        .contextMenu {
            Button("Editar") { onTap() }
            Button("Duplicar") { /* duplicate */ }
            Button("Excluir", role: .destructive) { /* delete */ }
        }
    }
    
    private var trackColor: Color {
        switch trackType {
        case .intro: return .purple
        case .recap: return .orange
        case .main: return .blue
        case .outro: return .green
        case .audio: return .pink
        case .overlay: return .cyan
        }
    }
    
    private var segmentLabel: String {
        let sourceLabel: String
        switch segment.sourceType {
        case .mainVideo: sourceLabel = "Principal"
        case .introAsset: sourceLabel = "Intro"
        case .outroAsset: sourceLabel = "Outro"
        case .recapAsset: sourceLabel = "Recap"
        case .audioAsset: sourceLabel = "Áudio"
        case .imageAsset: sourceLabel = "Imagem"
        }
        return "\(sourceLabel) \(formatTime(segment.sourceStartTime))–\(formatTime(segment.sourceEndTime))"
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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
    @State private var duration: Double
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
        _duration = State(initialValue: segment.duration)
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
                    HStack {
                        Text("Duração")
                        Spacer()
                        TextField("", value: $duration, format: .number)
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
                        updated.duration = duration
                        updated.sourceStartTime = sourceStartTime
                        updated.sourceEndTime = sourceEndTime
                        updated.isEnabled = isEnabled
                        updated.sourceType = sourceType
                        updated.assetID = selectedAsset?.id
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(sourceEndTime <= sourceStartTime || duration <= 0)
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