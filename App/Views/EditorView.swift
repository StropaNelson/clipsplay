import SwiftUI
import AVKit
import AVFoundation
import PhotosUI

enum EditorTheme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let panelRaised = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let timelineBackground = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let stage = Color.black
    static let accent = Color(red: 0.16, green: 0.62, blue: 1.0)
    static let divider = Color.white.opacity(0.08)
}

enum EditorPanel: String, CaseIterable, Identifiable {
    case media = "Mídia"
    case episodes = "Episódios"
    case export = "Exportar"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .media: return "photo.on.rectangle.angled"
        case .episodes: return "film.stack"
        case .export: return "square.and.arrow.up"
        }
    }
}

struct ClipPickRequest: Identifiable {
    let id = UUID()
    let track: TrackType
}

@MainActor
struct EditorView: View {
    let project: Project
    @StateObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingTranscription = false
    @State private var sidePanel: EditorPanel? = .media
    @State private var sheetPanel: EditorPanel?
    @State private var clipPickRequest: ClipPickRequest?
    @State private var editingSegment: TimelineSegment?

    init(project: Project) {
        self.project = project
        self._viewModel = StateObject(wrappedValue: EditorViewModel(project: project))
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                topBar
                Divider().overlay(EditorTheme.divider)
                workspace
                    .frame(height: geometry.size.height * 0.52)
                transportBar
                Divider().overlay(EditorTheme.divider)
                TimelineView(
                    segments: viewModel.orderedSegments,
                    totalDuration: viewModel.timelineDuration,
                    currentTime: viewModel.currentTime,
                    selectedSegmentID: viewModel.selectedSegmentID,
                    canAddIntro: viewModel.selectedEpisode != nil && viewModel.timelineTracks[.intro]?.isEmpty ?? true,
                    canAddOutro: viewModel.selectedEpisode != nil && viewModel.timelineTracks[.outro]?.isEmpty ?? true,
                    sourceURL: { viewModel.sourceURL(for: $0) },
                    onSeek: { viewModel.seek(to: $0) },
                    onSelect: { viewModel.selectedSegmentID = $0?.id },
                    onAddIntro: { clipPickRequest = ClipPickRequest(track: .intro) },
                    onAddOutro: { clipPickRequest = ClipPickRequest(track: .outro) }
                )
                .frame(maxHeight: .infinity)
                Divider().overlay(EditorTheme.divider)
                toolBar
            }
        }
        .background(EditorTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
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
        .sheet(item: $sheetPanel) { panel in
            panelContent(panel)
        }
        .sheet(item: $clipPickRequest) { request in
            ClipAssetPickerSheet(
                track: request.track,
                assets: viewModel.mediaAssets.filter { $0.type == .video },
                onImportAsset: { asset in
                    Task { await viewModel.addMediaAsset(asset) }
                },
                onAssign: { asset, start, end in
                    Task { await viewModel.assign(asset, to: request.track, startTime: start, endTime: end) }
                }
            )
        }
        .sheet(item: $editingSegment) { segment in
            SegmentEditorView(
                segment: segment,
                trackType: segment.trackType,
                project: viewModel.currentProject,
                episode: viewModel.selectedEpisode,
                onSave: { viewModel.updateSegment($0) },
                onDelete: { viewModel.removeSegment(segment) }
            )
        }
        .alert("Erro", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .task {
            await viewModel.loadProjectData()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                Task {
                    await viewModel.saveProject()
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(EditorTheme.panelRaised, in: Circle())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                episodeMenu
            }

            Spacer()

            Menu {
                Button { Task { await viewModel.saveProject() } } label: {
                    Label("Salvar", systemImage: "square.and.arrow.down")
                }
                Button { viewModel.showDuplicateSheet = true } label: {
                    Label("Duplicar projeto", systemImage: "doc.on.doc")
                }
                Button { showingTranscription = true } label: {
                    Label("Transcrição", systemImage: "captions.bubble")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(EditorTheme.panelRaised, in: Circle())
            }

            Button {
                open(.export)
            } label: {
                Text("Exportar")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(EditorTheme.accent, in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(EditorTheme.panel)
    }

    private var episodeMenu: some View {
        Menu {
            ForEach(viewModel.episodes) { episode in
                Button {
                    viewModel.selectEpisode(episode)
                } label: {
                    if episode.id == viewModel.selectedEpisode?.id {
                        Label(episode.title, systemImage: "checkmark")
                    } else {
                        Text(episode.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedEpisode?.title ?? "Sem episódio")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
        }
        .disabled(viewModel.episodes.isEmpty)
    }

    // MARK: - Workspace (panel + viewer)

    @ViewBuilder
    private var workspace: some View {
        if isRegular, let panel = sidePanel {
            HStack(spacing: 0) {
                sidePanelView(panel)
                    .frame(width: 360)
                Divider().overlay(EditorTheme.divider)
                viewer
            }
        } else {
            viewer
        }
    }

    private func sidePanelView(_ panel: EditorPanel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(EditorPanel.allCases) { item in
                    Button {
                        sidePanel = item
                    } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                item == panel ? EditorTheme.panelRaised : Color.clear,
                                in: Capsule()
                            )
                            .foregroundStyle(item == panel ? .white : .white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button {
                    sidePanel = nil
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(10)
            .background(EditorTheme.panel)
            panelContent(panel)
        }
        .background(EditorTheme.panel)
    }

    @ViewBuilder
    private func panelContent(_ panel: EditorPanel) -> some View {
        switch panel {
        case .media:
            MediaLibraryView(
                assets: $viewModel.mediaAssets,
                onAdd: { afterDismissingPanelSheet { viewModel.showImportAsset = true } },
                onRemove: { asset in Task { await viewModel.removeMediaAsset(asset) } },
                onSelectForIntro: { asset, start, end in
                    Task { await viewModel.assign(asset, to: .intro, startTime: start, endTime: end) }
                },
                onSelectForOutro: { asset, start, end in
                    Task { await viewModel.assign(asset, to: .outro, startTime: start, endTime: end) }
                },
                onSelectForRecap: { asset, start, end in
                    Task { await viewModel.assign(asset, to: .recap, startTime: start, endTime: end) }
                }
            )
        case .episodes:
            NavigationStack {
                EpisodeListView(
                    episodes: $viewModel.episodes,
                    project: viewModel.currentProject,
                    onSelect: { episode in
                        viewModel.selectEpisode(episode)
                        sheetPanel = nil
                    },
                    onEdit: { episode in viewModel.selectEpisode(episode) },
                    onRegenerate: { length in Task { await viewModel.regenerateEpisodes(length: length) } }
                )
                .navigationTitle("Episódios")
                .navigationBarTitleDisplayMode(.inline)
            }
        case .export:
            ExportView(
                project: viewModel.currentProject,
                episodes: viewModel.episodes,
                settings: $viewModel.exportSettings,
                onExport: { selection in
                    afterDismissingPanelSheet {
                        Task { await viewModel.exportEpisodes(selection: selection) }
                    }
                },
                onExportAll: { afterDismissingPanelSheet { Task { await viewModel.exportAllEpisodes() } } }
            )
        }
    }

    /// SwiftUI can't present a second sheet while the compact panel sheet is still up.
    private func afterDismissingPanelSheet(_ action: @escaping () -> Void) {
        guard sheetPanel != nil else {
            action()
            return
        }
        sheetPanel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: action)
    }

    private func open(_ panel: EditorPanel) {
        if isRegular {
            withAnimation(.easeInOut(duration: 0.2)) {
                sidePanel = sidePanel == panel ? nil : panel
            }
        } else {
            sheetPanel = panel
        }
    }

    private var viewer: some View {
        ZStack {
            EditorTheme.background
            ZStack {
                EditorTheme.stage
                if let player = viewModel.previewPlayer {
                    PlayerCanvasView(player: player)
                } else if !viewModel.isPreviewLoading && viewModel.previewError == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "film")
                            .font(.system(size: 40))
                        Text("Selecione um episódio para pré-visualizar")
                            .font(.footnote)
                    }
                    .foregroundStyle(.white.opacity(0.5))
                }
                if viewModel.isPreviewLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }
                if let previewError = viewModel.previewError {
                    previewErrorView(previewError)
                }
            }
            .aspectRatio(viewModel.canvasAspectRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.togglePlayback() }
    }

    private func previewErrorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.yellow)
            Text("Não foi possível carregar a prévia")
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))
            Button("Tentar novamente") { viewModel.reloadPreview() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    // MARK: - Transport

    private var transportBar: some View {
        HStack(spacing: 18) {
            if isRegular {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sidePanel = sidePanel == nil ? .media : nil
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
            }
            Text("\(viewModel.currentTimeString) / \(viewModel.durationString)")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Button { viewModel.seek(to: 0) } label: {
                Image(systemName: "backward.end.fill")
            }
            Button { viewModel.stepFrame(by: -1) } label: {
                Image(systemName: "backward.frame.fill")
            }
            Button { viewModel.togglePlayback() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24))
                    .frame(width: 36)
            }
            Button { viewModel.stepFrame(by: 1) } label: {
                Image(systemName: "forward.frame.fill")
            }
            Button { viewModel.seek(to: viewModel.timelineDuration) } label: {
                Image(systemName: "forward.end.fill")
            }
            Spacer()
            Text(viewModel.canvasLabel)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(EditorTheme.panelRaised, in: Capsule())
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.system(size: 17))
        .foregroundStyle(.white)
        .disabled(viewModel.previewPlayer == nil && viewModel.selectedEpisode == nil)
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(EditorTheme.panel)
    }

    // MARK: - Bottom toolbar

    @ViewBuilder
    private var toolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if let segment = viewModel.selectedSegment {
                    toolButton("Fechar", icon: "xmark") { viewModel.selectedSegmentID = nil }
                    Divider().frame(height: 30).overlay(EditorTheme.divider)
                    toolButton("Editar", icon: "slider.horizontal.3") { editingSegment = segment }
                    if segment.trackType != .main {
                        toolButton("Trocar", icon: "arrow.triangle.2.circlepath") {
                            clipPickRequest = ClipPickRequest(track: segment.trackType)
                        }
                        toolButton("Excluir", icon: "trash", role: .destructive) {
                            viewModel.removeSegment(segment)
                        }
                    }
                } else {
                    toolButton("Mídia", icon: "photo.on.rectangle.angled") { open(.media) }
                    toolButton("Importar", icon: "plus.rectangle.on.folder") { viewModel.showImportAsset = true }
                    toolButton("Episódios", icon: "film.stack") { open(.episodes) }
                    Divider().frame(height: 30).overlay(EditorTheme.divider)
                    toolButton("Abertura", icon: "play.rectangle.on.rectangle") { clipPickRequest = ClipPickRequest(track: .intro) }
                    toolButton("Recap", icon: "arrow.counterclockwise") { clipPickRequest = ClipPickRequest(track: .recap) }
                    toolButton("Encerramento", icon: "flag.checkered") { clipPickRequest = ClipPickRequest(track: .outro) }
                    Divider().frame(height: 30).overlay(EditorTheme.divider)
                    toolButton("Legendas", icon: "captions.bubble") { showingTranscription = true }
                    toolButton("Exportar", icon: "square.and.arrow.up") { open(.export) }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 64)
        .background(EditorTheme.panel)
    }

    private func toolButton(_ title: String, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(role == .destructive ? Color.red : Color.white.opacity(0.85))
            .frame(minWidth: 64, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Player canvas

struct PlayerCanvasView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: - Clip picker

struct ClipAssetPickerSheet: View {
    let track: TrackType
    let assets: [MediaAsset]
    let onImportAsset: (MediaAsset) -> Void
    let onAssign: (MediaAsset, Double, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trimRequest: AssetTrimRequest?
    @State private var showingImport = false

    private func onImport() { showingImport = true }

    private var title: String {
        switch track {
        case .intro: return "Escolher abertura"
        case .outro: return "Escolher encerramento"
        case .recap: return "Escolher recapitulação"
        default: return "Escolher vídeo"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if assets.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("Nenhum vídeo na biblioteca")
                            .font(.headline)
                        Text("Importe um vídeo para usar como \(track.shortLabel.lowercased()).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button(action: onImport) {
                            Label("Importar vídeo", systemImage: "plus")
                        }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(assets) { asset in
                                Button {
                                    trimRequest = AssetTrimRequest(asset: asset, track: track)
                                } label: {
                                    assetTile(asset)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onImport) {
                        Label("Importar", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $trimRequest) { request in
                AssetTrimSheet(asset: request.asset, track: request.track) { start, end in
                    onAssign(request.asset, start, end)
                    dismiss()
                }
            }
            .sheet(isPresented: $showingImport) {
                AssetImportSheet { asset in onImportAsset(asset) }
            }
        }
    }

    private func assetTile(_ asset: MediaAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Color.black
                if let thumbnail = asset.thumbnailFileURL,
                   let image = UIImage(contentsOfFile: thumbnail.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                Text(TimelineView.rulerLabel(asset.duration))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(6)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(asset.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
    }
}

// MARK: - View model

@MainActor
class EditorViewModel: ObservableObject {
    @Published var episodes: [Episode] = []
    @Published var mediaAssets: [MediaAsset] = []
    @Published var selectedEpisode: Episode?
    @Published var timelineTracks: [TrackType: [TimelineSegment]] = [:]
    @Published var selectedSegmentID: UUID?
    @Published var previewPlayer: AVPlayer?
    @Published var isPreviewLoading = false
    @Published var previewError: String?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var currentTimeString = "00:00"
    @Published var durationString = "00:00"
    @Published var exportSettings = ExportSettings() {
        didSet {
            guard oldValue.aspectRatio != exportSettings.aspectRatio
                    || oldValue.fitMode != exportSettings.fitMode
                    || oldValue.resolution != exportSettings.resolution else { return }
            reloadPreview()
        }
    }
    @Published var showImportAsset = false
    @Published var showExportProgress = false
    @Published var showDuplicateSheet = false
    @Published var errorMessage: String?
    @Published var exportProgress: BatchExportProgress?

    private var project: Project
    private let storage = ProjectStorage.shared
    private let timelineEngine = TimelineEngine.shared
    private let exportManager = ExportManager.shared
    private var timeObserver: Any?
    private var timeObserverPlayer: AVPlayer?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var previewSourceAssets: [AVAsset] = []

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

    var currentProject: Project {
        var snapshot = project
        snapshot.episodes = episodes
        snapshot.mediaAssets = mediaAssets
        snapshot.aspectRatio = exportSettings.aspectRatio
        snapshot.resolution = exportSettings.resolution
        snapshot.fitMode = exportSettings.fitMode
        return snapshot
    }

    var orderedSegments: [TimelineSegment] {
        timelineTracks.values.flatMap { $0 }.sorted { $0.startTime < $1.startTime }
    }

    var timelineDuration: Double {
        orderedSegments.map(\.endTime).max() ?? 0
    }

    var selectedSegment: TimelineSegment? {
        guard let selectedSegmentID else { return nil }
        return orderedSegments.first { $0.id == selectedSegmentID }
    }

    var canvasAspectRatio: CGFloat {
        if let ratio = exportSettings.aspectRatio.ratio { return ratio }
        return 16 / 9
    }

    var canvasLabel: String {
        exportSettings.aspectRatio == .original ? "Original" : exportSettings.aspectRatio.rawValue
    }

    func sourceURL(for segment: TimelineSegment) -> URL? {
        switch segment.sourceType {
        case .mainVideo:
            return project.sourceVideoFileURL
        default:
            guard let assetID = segment.assetID else { return nil }
            return mediaAssets.first { $0.id == assetID }?.url
        }
    }

    // MARK: Project

    func loadProjectData() async {
        do {
            let loaded = try await storage.loadProject(id: project.id)
            project = loaded
            episodes = loaded.episodes.map { original -> Episode in
                var episode = original
                episode.clearTimelinePins()
                return episode
            }
            mediaAssets = loaded.mediaAssets
            if let first = episodes.first { selectEpisode(first) }
        } catch {
            errorMessage = "Erro ao carregar projeto: \(Self.describe(error))"
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
            errorMessage = "Erro ao salvar: \(Self.describe(error))"
        }
    }

    func duplicateProject(name: String) async {
        do {
            _ = try await storage.duplicateProject(project, newName: name)
        } catch {
            errorMessage = "Erro ao duplicar: \(Self.describe(error))"
        }
    }

    func selectEpisode(_ episode: Episode) {
        selectedEpisode = episode
        selectedSegmentID = nil
        currentTime = 0
        updateTimelineForEpisode(episode)
        loadPreview(for: episode, keepTime: false)
    }

    func regenerateEpisodes(length: Double) async {
        project.episodeLength = length
        project.regenerateEpisodes()
        episodes = project.episodes
        if let first = episodes.first { selectedEpisode = first }
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

    // MARK: Clip assignment

    func assign(_ asset: MediaAsset, to track: TrackType, startTime: Double, endTime: Double) async {
        guard asset.type == .video else { return }
        let start = max(0, min(startTime, asset.duration))
        let end = max(start, min(endTime, asset.duration))
        guard end - start >= 0.1 else {
            errorMessage = "O trecho escolhido é curto demais."
            return
        }

        switch track {
        case .intro:
            project.introTemplate = SegmentTemplate(
                name: asset.name,
                sourceType: .introAsset,
                assetID: asset.id,
                startTime: start,
                endTime: end,
                targetTrack: .intro
            )
            for index in episodes.indices {
                episodes[index].introSegment = project.introTemplate?.toSegment()
                episodes[index].customIntroTemplate = nil
                episodes[index].useGlobalIntro = true
                episodes[index].clearTimelinePins()
            }
        case .outro:
            project.outroTemplate = SegmentTemplate(
                name: asset.name,
                sourceType: .outroAsset,
                assetID: asset.id,
                startTime: start,
                endTime: end,
                targetTrack: .outro
            )
            for index in episodes.indices {
                episodes[index].outroSegment = project.outroTemplate?.toSegment()
                episodes[index].customOutroTemplate = nil
                episodes[index].useGlobalOutro = true
                episodes[index].clearTimelinePins()
            }
        case .recap:
            let segment = VideoSegment(
                startTime: start,
                endTime: end,
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
                episodes[index].clearTimelinePins()
            }
        default:
            return
        }
        await persistProjectChanges()
    }

    // MARK: Timeline editing

    func updateSegment(_ segment: TimelineSegment) {
        var tracks = timelineTracks
        var list = tracks[segment.trackType] ?? []
        if let index = list.firstIndex(where: { $0.id == segment.id }) {
            list[index] = segment
        } else {
            list.append(segment)
        }
        tracks[segment.trackType] = list
        updateTimelineTracks(tracks)
    }

    func removeSegment(_ segment: TimelineSegment) {
        guard segment.trackType != .main else { return }
        var tracks = timelineTracks
        tracks[segment.trackType]?.removeAll { $0.id == segment.id }
        if selectedSegmentID == segment.id { selectedSegmentID = nil }
        updateTimelineTracks(tracks)
    }

    func updateTimelineTracks(_ tracks: [TrackType: [TimelineSegment]]) {
        timelineTracks = tracks
        guard let episodeIndex = selectedEpisodeIndex else { return }

        var updatedEpisode = episodes[episodeIndex]
        if let main = tracks[.main]?.first {
            updatedEpisode.mainStart = main.sourceStartTime
            updatedEpisode.mainEnd = main.sourceEndTime
        }
        if let intro = tracks[.intro]?.first {
            updatedEpisode.introSegment = videoSegment(from: intro)
            updatedEpisode.customIntroTemplate = nil
            updatedEpisode.useGlobalIntro = true
        } else {
            updatedEpisode.customIntroTemplate = nil
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
            updatedEpisode.customOutroTemplate = nil
            updatedEpisode.useGlobalOutro = false
        }
        updatedEpisode.clearTimelinePins()
        episodes[episodeIndex] = updatedEpisode
        selectedEpisode = updatedEpisode
        Task {
            await persistProjectChanges()
        }
    }

    private var selectedEpisodeIndex: Int? {
        guard let selectedEpisode else { return nil }
        return episodes.firstIndex { $0.id == selectedEpisode.id }
    }

    private func videoSegment(from segment: TimelineSegment) -> VideoSegment {
        VideoSegment(
            id: segment.id,
            startTime: segment.sourceStartTime,
            endTime: segment.sourceEndTime,
            sourceType: segment.sourceType,
            assetID: segment.assetID,
            trackIndex: 0,
            isEnabled: segment.isEnabled,
            timelineStartTime: nil
        )
    }

    private func persistProjectChanges() async {
        project.episodes = episodes
        project.mediaAssets = mediaAssets
        do {
            try await storage.saveProject(project)
        } catch {
            errorMessage = "Erro ao salvar projeto: \(Self.describe(error))"
        }
        refreshSelectedEpisode()
    }

    private func refreshSelectedEpisode() {
        guard let selectedEpisode else {
            if let first = episodes.first { selectEpisode(first) }
            return
        }
        guard let updatedEpisode = episodes.first(where: { $0.id == selectedEpisode.id }) ?? episodes.first else { return }
        self.selectedEpisode = updatedEpisode
        updateTimelineForEpisode(updatedEpisode)
        loadPreview(for: updatedEpisode, keepTime: true)
    }

    private func updateTimelineForEpisode(_ episode: Episode) {
        var tracks: [TrackType: [TimelineSegment]] = [:]
        for track in timelineEngine.computeTrackSegments(for: episode, project: project) {
            tracks[track.trackType] = track.segments
        }
        timelineTracks = tracks
        if let selectedSegmentID, !orderedSegments.contains(where: { $0.id == selectedSegmentID }) {
            self.selectedSegmentID = nil
        }
        durationString = timeString(timelineDuration)
    }

    // MARK: Preview

    func reloadPreview() {
        guard let selectedEpisode else { return }
        loadPreview(for: selectedEpisode, keepTime: true)
    }

    func loadPreview(for episode: Episode, keepTime: Bool) {
        previewTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        let resumeTime = keepTime ? currentTime : 0
        let projectSnapshot = currentProject
        let assetURLs = Dictionary(mediaAssets.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })

        previewPlayer?.pause()
        isPlaying = false
        isPreviewLoading = true
        previewError = nil

        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.timelineEngine.buildPreviewComposition(
                    project: projectSnapshot,
                    episode: episode,
                    additionalAssets: assetURLs
                )
                guard generation == self.previewGeneration, !Task.isCancelled else { return }
                let playerItem = AVPlayerItem(asset: output.composition)
                playerItem.videoComposition = output.videoComposition
                playerItem.audioMix = output.audioMix
                let player = AVPlayer(playerItem: playerItem)
                self.previewSourceAssets = output.sourceAssets
                self.setupTimeObserver(for: player)
                self.previewPlayer = player
                self.isPreviewLoading = false
                self.durationString = self.timeString(output.composition.duration.seconds)
                if resumeTime > 0 {
                    self.seek(to: resumeTime)
                } else {
                    self.updateTime(0)
                }
            } catch {
                guard generation == self.previewGeneration, !Task.isCancelled else { return }
                self.isPreviewLoading = false
                self.previewPlayer = nil
                self.previewError = Self.describe(error)
            }
        }
    }

    private func setupTimeObserver(for player: AVPlayer) {
        if let timeObserver, let timeObserverPlayer {
            timeObserverPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self, weak player] time in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, player === self.previewPlayer else { return }
                self.updateTime(time.seconds)
                self.isPlaying = player.timeControlStatus != .paused
            }
        }
        timeObserverPlayer = player
    }

    private func updateTime(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = max(0, seconds)
        currentTimeString = timeString(currentTime)
    }

    func togglePlayback() {
        guard let player = previewPlayer else { return }
        if player.timeControlStatus != .paused {
            player.pause()
            isPlaying = false
        } else {
            let duration = player.currentItem?.duration.seconds ?? 0
            if duration.isFinite, duration > 0, player.currentTime().seconds >= duration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: Double) {
        let clamped = max(0, min(time, timelineDuration))
        updateTime(clamped)
        previewPlayer?.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func stepFrame(by frames: Int) {
        previewPlayer?.pause()
        isPlaying = false
        seek(to: currentTime + Double(frames) / 30)
    }

    // MARK: Export

    func exportEpisodes(selection: Set<Int>?) async {
        showExportProgress = true
        exportProgress = nil

        do {
            let result = try await exportManager.exportAllEpisodes(
                project: currentProject,
                settings: exportSettings,
                selectedEpisodes: selection
            ) { progress in
                Task { @MainActor in
                    self.exportProgress = progress
                }
            }

            if exportSettings.includeCovers, !result.results.isEmpty {
                _ = try await exportManager.createZIP(from: result.results, projectName: project.name)
            }

            showExportProgress = false
            exportProgress = BatchExportProgress(
                currentEpisode: 0,
                totalEpisodes: result.results.count,
                overallProgress: 1.0,
                currentStage: .completed,
                message: "Exportação concluída: \(result.successCount) episódios"
            )
        } catch {
            showExportProgress = false
            errorMessage = "Erro na exportação: \(Self.describe(error))"
        }
    }

    func exportAllEpisodes() async {
        await exportEpisodes(selection: nil)
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let nsError = error as NSError
        var parts = [nsError.localizedDescription]
        if let reason = nsError.localizedFailureReason { parts.append(reason) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("Causa: \(underlying.domain) \(underlying.code)")
        }
        parts.append("(\(nsError.domain) \(nsError.code))")
        return parts.joined(separator: " ")
    }
}
