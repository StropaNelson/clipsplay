import SwiftUI
import AVKit
import PhotosUI

@MainActor
struct EditorView: View {
    let project: Project
    @StateObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingTranscription = false
    
    init(project: Project) {
        self.project = project
        self._viewModel = StateObject(wrappedValue: EditorViewModel(project: project))
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                
                VStack(spacing: 0) {
                    previewArea
                    
                    tabBar
                    
                    tabContent
                }
            }
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Projetos") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Salvar", systemImage: "square.and.arrow.down") { Task { await viewModel.saveProject() } }
                        Button("Duplicar", systemImage: "doc.on.doc") { viewModel.showDuplicateSheet = true }
                        Button("Transcrição", systemImage: "captions.bubble") { showingTranscription = true }
                        Divider()
                        Button("Exportar Episódios", systemImage: "square.and.arrow.up") { viewModel.selectedTab = .export }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $viewModel.showDuplicateSheet) {
                DuplicateProjectSheet(
                    projectName: "\(project.name) (Cópia)",
                    onConfirm: { name in
                        Task { await viewModel.duplicateProject(name: name) }
                    },
                    onCancel: { viewModel.showDuplicateSheet = false }
                )
            }
            .sheet(isPresented: $viewModel.showImportAsset) {
                AssetImportSheet { asset in
                    Task { await viewModel.addMediaAsset(asset) }
                }
            }
            .sheet(isPresented: $viewModel.showExportProgress) {
                ExportProgressView(viewModel: viewModel)
            }
            .sheet(isPresented: $showingTranscription) {
                TranscriptionView(project: project)
            }
            .alert("Erro", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .task {
                await viewModel.loadProjectData()
            }
        }
    }
    
    @ViewBuilder
    private var previewArea: some View {
        if let player = viewModel.previewPlayer {
            VideoPlayer(player: player)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 0))
                .overlay(alignment: .bottom) {
                    previewControls
                }
        } else {
            RoundedRectangle(cornerRadius: 0)
                .fill(Color.black)
                .frame(height: 280)
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "film")
                            .font(.system(size: 50))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Selecione um episódio para pré-visualizar")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
        }
    }
    
    private var previewControls: some View {
        HStack(spacing: 16) {
            Button {
                viewModel.seekBackward()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.title2)
            }
            
            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
            }
            
            Button {
                viewModel.seekForward()
            } label: {
                Image(systemName: "goforward.10")
                    .font(.title2)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text(viewModel.currentTimeString)
                    .font(.caption.monospacedDigit())
                Text(viewModel.durationString)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            
            Slider(value: $viewModel.playbackProgress, in: 0...1) { editing in
                if !editing { viewModel.seekToProgress() }
            }
            .frame(width: 120)
            .tint(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
    
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(EditorTab.allCases) { tab in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            viewModel.selectedTab = tab
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 20, weight: .medium))
                            Text(tab.title)
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(viewModel.selectedTab == tab ? .primary : .secondary)
                        .frame(minWidth: 80)
                        .padding(.vertical, 12)
                        .background(
                            Rectangle()
                                .fill(viewModel.selectedTab == tab ? Color.accentColor.opacity(0.15) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 0.5)
        }
    }
    
    @ViewBuilder
    private var tabContent: some View {
        Group {
            switch viewModel.selectedTab {
            case .episodes:
                EpisodeListView(
                    episodes: $viewModel.episodes,
                    project: project,
                    onSelect: { episode in viewModel.selectEpisode(episode) },
                    onEdit: { episode in viewModel.editEpisode(episode) },
                    onRegenerate: { length in Task { await viewModel.regenerateEpisodes(length: length) } }
                )
            case .assets:
                MediaLibraryView(
                    assets: $viewModel.mediaAssets,
                    onAdd: { viewModel.showImportAsset = true },
                    onRemove: { asset in Task { await viewModel.removeMediaAsset(asset) } },
                    onSelectForIntro: { asset, start, end in
                        Task { await viewModel.assignAssetToIntro(asset, startTime: start, endTime: end) }
                    },
                    onSelectForOutro: { asset, start, end in
                        Task { await viewModel.assignAssetToOutro(asset, startTime: start, endTime: end) }
                    },
                    onSelectForRecap: { asset, start, end in
                        Task { await viewModel.assignAssetToRecap(asset, startTime: start, endTime: end) }
                    }
                )
            case .timeline:
                TimelineView(
                    episode: viewModel.selectedEpisode,
                    project: project,
                    tracks: viewModel.timelineTracks,
                    onTrackUpdate: { tracks in viewModel.updateTimelineTracks(tracks) },
                    onPlayheadMove: { time in viewModel.movePlayhead(to: time) }
                )
            case .export:
                ExportView(
                    project: project,
                    episodes: viewModel.episodes,
                    settings: $viewModel.exportSettings,
                    onExport: { selection in
                        Task { await viewModel.exportEpisodes(selection: selection) }
                    },
                    onExportAll: { Task { await viewModel.exportAllEpisodes() } }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum EditorTab: String, CaseIterable, Identifiable {
    case episodes = "Episódios"
    case assets = "Elementos"
    case timeline = "Timeline"
    case export = "Exportar"
    
    var id: String { rawValue }
    
    var title: String { rawValue }
    
    var icon: String {
        switch self {
        case .episodes: return "film.stack"
        case .assets: return "square.stack.3d.down.right"
        case .timeline: return "timeline.selection"
        case .export: return "square.and.arrow.up"
        }
    }
}

@MainActor
class EditorViewModel: ObservableObject {
    @Published var selectedTab: EditorTab = .episodes
    @Published var episodes: [Episode] = []
    @Published var mediaAssets: [MediaAsset] = []
    @Published var selectedEpisode: Episode?
    @Published var timelineTracks: [TrackType: [TimelineSegment]] = [:]
    @Published var previewPlayer: AVPlayer?
    @Published var isPlaying = false
    @Published var playbackProgress: Double = 0
    @Published var currentTimeString = "00:00"
    @Published var durationString = "00:00"
    @Published var exportSettings = ExportSettings()
    @Published var showImportAsset = false
    @Published var showExportProgress = false
    @Published var showDuplicateSheet = false
    @Published var errorMessage: String?
    @Published var exportProgress: BatchExportProgress?
    
    private var project: Project
    private let storage = ProjectStorage.shared
    private let importer = VideoImporter.shared
    private let processor = VideoProcessor.shared
    private let timelineEngine = TimelineEngine.shared
    private let exportManager = ExportManager.shared
    private var timeObserver: Any?
    private var timeObserverPlayer: AVPlayer?
    
    init(project: Project) {
        self.project = project
        self.episodes = project.episodes
        self.mediaAssets = project.mediaAssets
        self.exportSettings = ExportSettings(
            aspectRatio: project.aspectRatio,
            resolution: project.resolution,
            fitMode: project.fitMode,
            includeCovers: project.coverSettings.enabled,
            coverMode: project.coverSettings.mode,
            coverCaptureTime: project.coverSettings.captureTime,
            fileNamePrefix: project.episodeTitleTemplate,
            quality: .high
        )
    }
    
    func loadProjectData() async {
        do {
            let loaded = try await storage.loadProject(id: project.id)
            project = loaded
            episodes = loaded.episodes
            mediaAssets = loaded.mediaAssets
            if let first = episodes.first { selectEpisode(first) }
        } catch {
            errorMessage = "Erro ao carregar projeto: \(error.localizedDescription)"
        }
    }
    
    func saveProject() async {
        var updated = project
        updated.episodes = episodes
        updated.mediaAssets = mediaAssets
        updated.aspectRatio = exportSettings.aspectRatio
        updated.resolution = exportSettings.resolution
        updated.fitMode = exportSettings.fitMode
        updated.coverSettings = CoverSettings(
            enabled: exportSettings.includeCovers,
            mode: exportSettings.coverMode,
            templateName: "Padrão",
            captureTime: exportSettings.coverCaptureTime,
            customImageAssetID: nil
        )
        
        do {
            try await storage.saveProject(updated)
            project = updated
        } catch {
            errorMessage = "Erro ao salvar: \(error.localizedDescription)"
        }
    }
    
    func duplicateProject(name: String) async {
        do {
            _ = try await storage.duplicateProject(project, newName: name)
        } catch {
            errorMessage = "Erro ao duplicar: \(error.localizedDescription)"
        }
    }
    
    func selectEpisode(_ episode: Episode) {
        selectedEpisode = episode
        updateTimelineForEpisode(episode)
        loadPreview(for: episode)
    }
    
    func editEpisode(_ episode: Episode) {
        // Open episode detail editor
    }
    
    func regenerateEpisodes(length: Double) async {
        project.episodeLength = length
        project.regenerateEpisodes()
        episodes = project.episodes
        await persistProjectChanges()
    }
    
    func addMediaAsset(_ asset: MediaAsset) async {
        mediaAssets.append(asset)
        await persistProjectChanges()
    }
    
    func removeMediaAsset(_ asset: MediaAsset) async {
        mediaAssets.removeAll { $0.id == asset.id }
        await persistProjectChanges()
    }
    
    func assignAssetToIntro(_ asset: MediaAsset, startTime: Double, endTime: Double) async {
        guard asset.type == .video else { return }
        project.introTemplate = SegmentTemplate(
            name: asset.name,
            sourceType: .introAsset,
            assetID: asset.id,
            startTime: startTime,
            endTime: endTime,
            targetTrack: .intro
        )
        for index in episodes.indices {
            episodes[index].introSegment = project.introTemplate?.toSegment()
            episodes[index].customIntroTemplate = nil
            episodes[index].useGlobalIntro = true
        }
        await persistProjectChanges()
    }
    
    func assignAssetToOutro(_ asset: MediaAsset, startTime: Double, endTime: Double) async {
        guard asset.type == .video else { return }
        project.outroTemplate = SegmentTemplate(
            name: asset.name,
            sourceType: .outroAsset,
            assetID: asset.id,
            startTime: startTime,
            endTime: endTime,
            targetTrack: .outro
        )
        for index in episodes.indices {
            episodes[index].outroSegment = project.outroTemplate?.toSegment()
            episodes[index].customOutroTemplate = nil
            episodes[index].useGlobalOutro = true
        }
        await persistProjectChanges()
    }
    
    func assignAssetToRecap(_ asset: MediaAsset, startTime: Double, endTime: Double) async {
        guard asset.type == .video else { return }
        let segment = VideoSegment(
            startTime: startTime,
            endTime: endTime,
            sourceType: .recapAsset,
            assetID: asset.id
        )
        project.recapSettings.enabled = true
        project.recapSettings.mode = .manual
        project.recapSettings.manualSegments = [segment]
        for index in episodes.indices {
            episodes[index].recapSegments = [segment]
            episodes[index].customRecapSegments = []
            episodes[index].useGlobalRecap = true
        }
        await persistProjectChanges()
    }
    
    private func persistProjectChanges() async {
        project.episodes = episodes
        project.mediaAssets = mediaAssets
        do {
            try await storage.saveProject(project)
        } catch {
            errorMessage = "Erro ao salvar projeto: \(error.localizedDescription)"
        }
        refreshSelectedEpisode()
    }

    private func refreshSelectedEpisode() {
        guard let selectedEpisode,
              let updatedEpisode = episodes.first(where: { $0.id == selectedEpisode.id }) else { return }
        self.selectedEpisode = updatedEpisode
        updateTimelineForEpisode(updatedEpisode)
        loadPreview(for: updatedEpisode)
    }
    
    private func updateTimelineForEpisode(_ episode: Episode) {
        timelineTracks = [:]
        let tracks = timelineEngine.computeTrackSegments(for: episode, project: project)
        for track in tracks {
            timelineTracks[track.trackType] = track.segments
        }
    }
    
    func updateTimelineTracks(_ tracks: [TrackType: [TimelineSegment]]) {
        timelineTracks = tracks
        guard let selectedEpisode = self.selectedEpisode,
              let episodeIndex = episodes.firstIndex(where: { $0.id == selectedEpisode.id }) else { return }

        var updatedEpisode = episodes[episodeIndex]
        if let main = tracks[.main]?.first {
            updatedEpisode.mainStart = main.sourceStartTime
            updatedEpisode.mainEnd = main.sourceEndTime
            updatedEpisode.mainTimelineStartTime = main.startTime
        }
        if let intro = tracks[.intro]?.first {
            updatedEpisode.introSegment = videoSegment(from: intro)
            updatedEpisode.customIntroTemplate = nil
            updatedEpisode.useGlobalIntro = true
        } else {
            updatedEpisode.useGlobalIntro = false
        }
        updatedEpisode.recapSegments = (tracks[.recap] ?? []).map(videoSegment(from:))
        updatedEpisode.customRecapSegments = []
        updatedEpisode.useGlobalRecap = !updatedEpisode.recapSegments.isEmpty
        if let outro = tracks[.outro]?.first {
            updatedEpisode.outroSegment = videoSegment(from: outro)
            updatedEpisode.customOutroTemplate = nil
            updatedEpisode.useGlobalOutro = true
        } else {
            updatedEpisode.useGlobalOutro = false
        }
        episodes[episodeIndex] = updatedEpisode
        project.episodes = episodes
        selectedEpisode = updatedEpisode
        Task {
            await persistProjectChanges()
        }
    }

    private func videoSegment(from segment: TimelineSegment) -> VideoSegment {
        VideoSegment(
            startTime: segment.sourceStartTime,
            endTime: segment.sourceEndTime,
            sourceType: segment.sourceType,
            assetID: segment.assetID,
            trackIndex: 0,
            isEnabled: segment.isEnabled,
            timelineStartTime: segment.startTime
        )
    }
    
    func movePlayhead(to time: Double) {
        previewPlayer?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
    }
    
    func loadPreview(for episode: Episode) {
        Task {
            do {
                let assetURLs = Dictionary(uniqueKeysWithValues: mediaAssets.map { ($0.id, $0.url) })
                let output = try await timelineEngine.buildPreviewComposition(
                    project: project,
                    episode: episode,
                    additionalAssets: assetURLs
                )
                await MainActor.run {
                    let playerItem = AVPlayerItem(asset: output.composition)
                    playerItem.videoComposition = output.videoComposition
                    playerItem.audioMix = output.audioMix
                    let player = AVPlayer(playerItem: playerItem)
                    self.previewPlayer = player
                    setupTimeObserver(for: player)
                    self.durationString = timeString(episode.totalDuration)
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Erro ao carregar prévia: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func setupTimeObserver(for player: AVPlayer) {
        if let timeObserver, let timeObserverPlayer {
            timeObserverPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTimeString = self.timeString(time.seconds)
                if let duration = player.currentItem?.duration.seconds, duration > 0 {
                    self.playbackProgress = time.seconds / duration
                }
            }
        }
        timeObserverPlayer = player
    }
    
    func togglePlayback() {
        if isPlaying {
            previewPlayer?.pause()
        } else {
            previewPlayer?.play()
        }
        isPlaying.toggle()
    }
    
    func seekBackward() {
        guard let player = previewPlayer else { return }
        let current = player.currentTime().seconds
        let newTime = max(0, current - 10)
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
    }
    
    func seekForward() {
        guard let player = previewPlayer else { return }
        let current = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? current
        let newTime = min(duration, current + 10)
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
    }
    
    func seekToProgress() {
        guard let player = previewPlayer,
              let duration = player.currentItem?.duration.seconds else { return }
        let target = playbackProgress * duration
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }
    
    func exportEpisodes(selection: Set<Int>?) async {
        showExportProgress = true
        exportProgress = nil
        
        do {
            let result = try await exportManager.exportAllEpisodes(
                project: project,
                settings: exportSettings,
                selectedEpisodes: selection
            ) { progress in
                Task { @MainActor in
                    self.exportProgress = progress
                }
            }
            
            if exportSettings.includeCovers, !result.results.isEmpty {
                _ = try await exportManager.createZIP(from: result.results, projectName: project.name)
                // Share zip
            }
            
            await MainActor.run {
                showExportProgress = false
                exportProgress = BatchExportProgress(
                    currentEpisode: 0,
                    totalEpisodes: result.results.count,
                    overallProgress: 1.0,
                    currentStage: .completed,
                    message: "Exportação concluída: \(result.successCount) episódios"
                )
            }
        } catch {
            await MainActor.run {
                showExportProgress = false
                errorMessage = "Erro na exportação: \(error.localizedDescription)"
            }
        }
    }
    
    func exportAllEpisodes() async {
        await exportEpisodes(selection: nil)
    }
    
    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total/60, total%60)
    }
}