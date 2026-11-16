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

struct NarrationRequest: Identifiable {
    let id = UUID()
    /// nil records onto the audio lane at the playhead; otherwise the narration is linked to this clip.
    let segment: TimelineSegment?
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
    @State private var textEditRequest: TextEditRequest?
    @State private var transitionSegment: TimelineSegment?
    @State private var editingAudio: AudioClip?
    @State private var showingAddAudio = false
    @State private var narrationRequest: NarrationRequest?

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
                    overlays: viewModel.selectedEpisode?.textOverlays ?? [],
                    audioClips: viewModel.selectedEpisode?.audioClips ?? [],
                    totalDuration: viewModel.timelineDuration,
                    currentTime: viewModel.currentTime,
                    selectedID: viewModel.selectedSegmentID,
                    canAddIntro: viewModel.selectedEpisode != nil && viewModel.timelineTracks[.intro]?.isEmpty ?? true,
                    canAddOutro: viewModel.selectedEpisode != nil && viewModel.timelineTracks[.outro]?.isEmpty ?? true,
                    sourceURL: { viewModel.sourceURL(for: $0) },
                    onSeek: { viewModel.seek(to: $0) },
                    onSelect: { viewModel.selectedSegmentID = $0 },
                    onAddIntro: { clipPickRequest = ClipPickRequest(track: .intro) },
                    onAddOutro: { clipPickRequest = ClipPickRequest(track: .outro) },
                    onAddText: { textEditRequest = viewModel.newTextRequest() },
                    onAddAudio: { showingAddAudio = true },
                    onTransitionTap: { transitionSegment = $0 }
                )
                .frame(maxHeight: .infinity)
                Divider().overlay(EditorTheme.divider)
                toolBar
            }
        }
        .background(featureSheets)
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
                onAssign: { asset, selection in
                    Task { await viewModel.assign(asset, to: request.track, selection: selection) }
                }
            )
        }
        .sheet(item: $editingSegment) { segment in
            SegmentEditorView(
                segment: segment,
                trackType: segment.trackType,
                project: viewModel.currentProject,
                onSave: { viewModel.updateSegment($0) },
                onDelete: viewModel.canDelete(segment) ? { viewModel.removeSegment(segment) } : nil
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

            Button {
                viewModel.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(EditorTheme.panelRaised, in: Circle())
            }
            .disabled(!viewModel.canUndo)
            .opacity(viewModel.canUndo ? 1 : 0.4)

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
                onSelectForIntro: { asset, selection in
                    Task { await viewModel.assign(asset, to: .intro, selection: selection) }
                },
                onSelectForOutro: { asset, selection in
                    Task { await viewModel.assign(asset, to: .outro, selection: selection) }
                },
                onSelectForRecap: { asset, selection in
                    Task { await viewModel.assign(asset, to: .recap, selection: selection) }
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
                    TextOverlayLayer(
                        overlays: viewModel.visibleOverlays,
                        selectedID: viewModel.selectedSegmentID,
                        onSelect: { viewModel.selectedSegmentID = $0 },
                        onMove: { id, x, y, finished in viewModel.moveOverlay(id, x: x, y: y, finished: finished) }
                    )
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
                    if segment.trackType == .main {
                        toolButton("Dividir", icon: "scissors") { viewModel.splitAtPlayhead() }
                    }
                    toolButton("Editar", icon: "slider.horizontal.3") { editingSegment = segment }
                    toolButton("Transição", icon: "square.on.square") { transitionSegment = segment }
                    toolButton("Narração", icon: "mic.badge.plus") { narrationRequest = NarrationRequest(segment: segment) }
                    if segment.trackType == .main {
                        toolButton("Duplicar", icon: "plus.square.on.square") { viewModel.duplicateSelected() }
                    } else {
                        toolButton("Trocar", icon: "arrow.triangle.2.circlepath") {
                            clipPickRequest = ClipPickRequest(track: segment.trackType)
                        }
                    }
                    if viewModel.canDelete(segment) {
                        toolButton("Excluir", icon: "trash", role: .destructive) {
                            viewModel.removeSegment(segment)
                        }
                    }
                } else if let overlay = viewModel.selectedOverlay {
                    toolButton("Fechar", icon: "xmark") { viewModel.selectedSegmentID = nil }
                    Divider().frame(height: 30).overlay(EditorTheme.divider)
                    toolButton("Editar", icon: "character.cursor.ibeam") {
                        textEditRequest = TextEditRequest(overlay: overlay, isNew: false)
                    }
                    toolButton("Duplicar", icon: "plus.square.on.square") { viewModel.duplicateSelected() }
                    toolButton("Excluir", icon: "trash", role: .destructive) { viewModel.removeOverlay(overlay.id) }
                } else if let clip = viewModel.selectedAudioClip {
                    toolButton("Fechar", icon: "xmark") { viewModel.selectedSegmentID = nil }
                    Divider().frame(height: 30).overlay(EditorTheme.divider)
                    toolButton("Editar", icon: "slider.horizontal.3") { editingAudio = clip }
                    toolButton("Cursor", icon: "arrow.right.to.line") { viewModel.moveAudioClipToPlayhead(clip.id) }
                    toolButton("Excluir", icon: "trash", role: .destructive) { viewModel.removeAudioClip(clip.id) }
                } else {
                    toolButton("Mídia", icon: "photo.on.rectangle.angled") { open(.media) }
                    toolButton("Episódios", icon: "film.stack") { open(.episodes) }
                    Divider().frame(height: 30).overlay(EditorTheme.divider)
                    toolButton("Dividir", icon: "scissors") { viewModel.splitAtPlayhead() }
                    toolButton("Texto", icon: "textformat") { textEditRequest = viewModel.newTextRequest() }
                    toolButton("Áudio", icon: "music.note") { showingAddAudio = true }
                    toolButton("Narrar", icon: "mic.fill") { narrationRequest = NarrationRequest(segment: nil) }
                    toolButton("Transições", icon: "square.on.square") {
                        if let first = viewModel.orderedSegments.dropFirst().first {
                            transitionSegment = first
                        } else {
                            viewModel.errorMessage = "Adicione pelo menos dois clipes (ou divida o vídeo) para usar transições."
                        }
                    }
                    Divider().frame(height: 30).overlay(EditorTheme.divider)
                    toolButton("Abertura", icon: "play.rectangle.on.rectangle") { clipPickRequest = ClipPickRequest(track: .intro) }
                    toolButton("Recap", icon: "arrow.counterclockwise") { clipPickRequest = ClipPickRequest(track: .recap) }
                    toolButton("Encerramento", icon: "flag.checkered") { clipPickRequest = ClipPickRequest(track: .outro) }
                    Divider().frame(height: 30).overlay(EditorTheme.divider)
                    toolButton("Legendas", icon: "captions.bubble") { showingTranscription = true }
                    toolButton("Importar", icon: "plus.rectangle.on.folder") { viewModel.showImportAsset = true }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 64)
        .background(EditorTheme.panel)
    }

    private var featureSheets: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: $textEditRequest) { request in
                TextOverlayEditorSheet(
                    request: request,
                    episodeDuration: viewModel.timelineDuration,
                    onSave: { viewModel.saveOverlay($0) },
                    onDelete: { viewModel.removeOverlay(request.overlay.id) }
                )
            }
            .sheet(item: $transitionSegment) { segment in
                TransitionPickerSheet(segment: segment) { style, duration, applyToAll in
                    viewModel.setTransition(style, duration: duration, for: segment.id, applyToAll: applyToAll)
                }
            }
            .sheet(isPresented: $showingAddAudio) {
                AddAudioSheet(
                    assets: viewModel.mediaAssets.filter { $0.type == .audio },
                    onImportAsset: { asset in Task { await viewModel.addMediaAsset(asset) } },
                    onAdd: { asset, allEpisodes, atPlayhead in
                        viewModel.addAudio(asset, kind: .music, allEpisodes: allEpisodes, atPlayhead: atPlayhead)
                    }
                )
            }
            .sheet(item: $editingAudio) { clip in
                AudioClipEditorSheet(
                    clip: clip,
                    assetDuration: viewModel.mediaAssets.first { $0.id == clip.assetID }?.duration ?? clip.sourceEnd,
                    episodeDuration: viewModel.timelineDuration,
                    onSave: { viewModel.updateAudioClip($0) },
                    onDelete: { viewModel.removeAudioClip(clip.id) }
                )
            }
            .sheet(item: $narrationRequest) { request in
                NarrationRecorderSheet(
                    title: request.segment.map { "Narração: \($0.trackType.rawValue)" } ?? "Narrar",
                    hint: request.segment == nil
                        ? "A prévia toca sem som enquanto você grava. A narração começa em \(viewModel.currentTimeString)."
                        : "A narração fica vinculada a este clipe e é cortada no fim dele.",
                    onRecordingChanged: { recording in
                        viewModel.narrationRecordingChanged(recording, segment: request.segment)
                    },
                    onSave: { asset in
                        if let segment = request.segment {
                            viewModel.attachNarration(asset, to: segment)
                        } else {
                            viewModel.addTimelineNarration(asset)
                        }
                    }
                )
            }
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
    let onAssign: (MediaAsset, ClipSelection) -> Void

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
                AssetTrimSheet(asset: request.asset, track: request.track) { selection in
                    onAssign(request.asset, selection)
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
    private var undoStack: [UndoState] = []
    private var isDraggingOverlay = false
    private var narrationStartTime: Double?
    @Published var canUndo = false

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
        let rect = CGRect(origin: .zero, size: project.sourceVideoNaturalSize.cgSize)
            .applying(project.sourceVideoTransform.cgAffineTransform)
        guard abs(rect.width) > 1, abs(rect.height) > 1 else { return 16 / 9 }
        return abs(rect.width) / abs(rect.height)
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
                episode.normalizeCustomTemplates()
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

    func assign(_ asset: MediaAsset, to track: TrackType, selection: ClipSelection) async {
        guard asset.type == .video else { return }
        let start = max(0, min(selection.startTime, asset.duration))
        let end = max(start, min(selection.endTime, asset.duration))
        guard end - start >= 0.1 else {
            errorMessage = "O trecho escolhido é curto demais."
            return
        }
        checkpoint()
        if let narration = selection.narration, !mediaAssets.contains(where: { $0.id == narration.id }) {
            mediaAssets.append(narration)
        }
        let volume: Float? = selection.clipVolume < 0.999 ? selection.clipVolume : nil

        switch track {
        case .intro, .outro:
            var template = SegmentTemplate(
                name: asset.name,
                sourceType: track == .intro ? .introAsset : .outroAsset,
                assetID: asset.id,
                startTime: start,
                endTime: end,
                targetTrack: track
            )
            template.narrationAssetID = selection.narration?.id
            template.clipVolume = volume
            if track == .intro {
                project.introTemplate = template
            } else {
                project.outroTemplate = template
            }
            for index in episodes.indices {
                if track == .intro {
                    episodes[index].introSegment = template.toSegment()
                    episodes[index].customIntroTemplate = nil
                    episodes[index].useGlobalIntro = true
                } else {
                    episodes[index].outroSegment = template.toSegment()
                    episodes[index].customOutroTemplate = nil
                    episodes[index].useGlobalOutro = true
                }
                episodes[index].clearTimelinePins()
            }
        case .recap:
            let segment = VideoSegment(
                startTime: start,
                endTime: end,
                sourceType: .recapAsset,
                assetID: asset.id,
                narrationAssetID: selection.narration?.id,
                volume: volume
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

    // MARK: Undo

    private struct UndoState {
        let episodes: [Episode]
        let mediaAssets: [MediaAsset]
        let introTemplate: SegmentTemplate?
        let outroTemplate: SegmentTemplate?
        let recapSettings: RecapSettings
    }

    func checkpoint() {
        undoStack.append(UndoState(
            episodes: episodes,
            mediaAssets: mediaAssets,
            introTemplate: project.introTemplate,
            outroTemplate: project.outroTemplate,
            recapSettings: project.recapSettings
        ))
        if undoStack.count > 40 { undoStack.removeFirst() }
        canUndo = true
    }

    func undo() {
        guard let state = undoStack.popLast() else { return }
        canUndo = !undoStack.isEmpty
        episodes = state.episodes
        mediaAssets = state.mediaAssets
        project.introTemplate = state.introTemplate
        project.outroTemplate = state.outroTemplate
        project.recapSettings = state.recapSettings
        Task { await persistProjectChanges() }
    }

    // MARK: Timeline editing

    private func mutateSelectedEpisode(reloadPreview: Bool = true, _ body: (inout Episode) -> Void) {
        guard let episodeIndex = selectedEpisodeIndex else { return }
        checkpoint()
        var episode = episodes[episodeIndex]
        body(&episode)
        episode.clearTimelinePins()
        episodes[episodeIndex] = episode
        selectedEpisode = episode
        Task { await persistProjectChanges(reloadPreview: reloadPreview) }
    }

    func canDelete(_ segment: TimelineSegment) -> Bool {
        segment.trackType != .main || (timelineTracks[.main]?.count ?? 0) > 1
    }

    func updateSegment(_ segment: TimelineSegment) {
        mutateSelectedEpisode { episode in
            episode.modifySegment(id: segment.id) { video in
                video.startTime = segment.sourceStartTime
                video.endTime = segment.sourceEndTime
                video.sourceType = segment.sourceType
                video.assetID = segment.assetID
                video.isEnabled = true
                video.transition = segment.transition
                video.transitionDuration = segment.transitionDuration
                video.clipVolume = segment.clipVolume
                video.narrationAssetID = segment.narrationAssetID
                video.narrationLevel = segment.narrationVolume
            }
        }
    }

    func removeSegment(_ segment: TimelineSegment) {
        guard canDelete(segment) else { return }
        if selectedSegmentID == segment.id { selectedSegmentID = nil }
        mutateSelectedEpisode { episode in
            _ = episode.removeSegment(id: segment.id)
        }
    }

    func splitAtPlayhead() {
        guard let episode = selectedEpisode else { return }
        let time = currentTime
        guard let item = episode.storyline().first(where: {
            $0.track == .main && time > $0.start + 0.1 && time < $0.end - 0.1
        }) else {
            errorMessage = "Posicione o cursor sobre o conteúdo principal (a pelo menos 0,1s das bordas) para dividir."
            return
        }
        let cut = item.segment.startTime + (time - item.start)
        var newID = UUID()
        mutateSelectedEpisode { episode in
            var clips = episode.mainClips
            guard let index = clips.firstIndex(where: { $0.id == item.segment.id }) else { return }
            var first = clips[index]
            first.endTime = cut
            var second = VideoSegment(
                startTime: cut,
                endTime: clips[index].endTime,
                sourceType: first.sourceType,
                assetID: first.assetID,
                transitionStyle: TransitionStyle.none,
                narrationAssetID: first.narrationAssetID,
                volume: first.volume
            )
            // The second half keeps playing the narration from where the first half stops.
            second.narrationVolume = first.narrationVolume
            second.narrationOffset = (first.narrationOffset ?? 0) + first.duration
            newID = second.id
            clips.replaceSubrange(index...index, with: [first, second])
            episode.mainClips = clips
        }
        selectedSegmentID = newID
    }

    func duplicateSelected() {
        if let segment = selectedSegment, segment.trackType == .main {
            mutateSelectedEpisode { episode in
                var clips = episode.mainClips
                guard let index = clips.firstIndex(where: { $0.id == segment.id }) else { return }
                let original = clips[index]
                var copy = VideoSegment(
                    startTime: original.startTime,
                    endTime: original.endTime,
                    sourceType: original.sourceType,
                    assetID: original.assetID,
                    transitionStyle: TransitionStyle.none,
                    narrationAssetID: original.narrationAssetID,
                    volume: original.volume
                )
                copy.narrationVolume = original.narrationVolume
                copy.narrationOffset = original.narrationOffset
                clips.insert(copy, at: index + 1)
                episode.mainClips = clips
            }
        } else if let overlay = selectedOverlay {
            var copy = overlay
            copy.id = UUID()
            copy.startTime = min(overlay.endTime, max(0, timelineDuration - copy.duration))
            mutateSelectedEpisode(reloadPreview: false) { $0.textOverlays.append(copy) }
            selectedSegmentID = copy.id
        }
    }

    func setTransition(_ style: TransitionStyle, duration: Double, for segmentID: UUID, applyToAll: Bool) {
        let targets = applyToAll ? orderedSegments.dropFirst().map(\.id) : [segmentID]
        mutateSelectedEpisode { episode in
            for id in targets {
                episode.modifySegment(id: id) { video in
                    video.transition = style
                    video.transitionDuration = duration
                }
            }
        }
    }

    // MARK: Text overlays

    var selectedOverlay: TextOverlay? {
        guard let selectedSegmentID else { return nil }
        return selectedEpisode?.textOverlays.first { $0.id == selectedSegmentID }
    }

    var visibleOverlays: [TextOverlay] {
        (selectedEpisode?.textOverlays ?? []).filter {
            $0.isVisible(at: currentTime) || (!isPlaying && $0.id == selectedSegmentID)
        }
    }

    func newTextRequest() -> TextEditRequest {
        let start = min(currentTime, max(0, timelineDuration - 1))
        let duration = max(0.5, min(3, timelineDuration - start))
        return TextEditRequest(overlay: TextOverlay(text: "", startTime: start, duration: duration), isNew: true)
    }

    func saveOverlay(_ overlay: TextOverlay) {
        mutateSelectedEpisode(reloadPreview: false) { episode in
            if let index = episode.textOverlays.firstIndex(where: { $0.id == overlay.id }) {
                episode.textOverlays[index] = overlay
            } else {
                episode.textOverlays.append(overlay)
            }
        }
        selectedSegmentID = overlay.id
    }

    func removeOverlay(_ id: UUID) {
        if selectedSegmentID == id { selectedSegmentID = nil }
        mutateSelectedEpisode(reloadPreview: false) { episode in
            episode.textOverlays.removeAll { $0.id == id }
        }
    }

    func moveOverlay(_ id: UUID, x: Double, y: Double, finished: Bool) {
        guard let episodeIndex = selectedEpisodeIndex,
              let index = episodes[episodeIndex].textOverlays.firstIndex(where: { $0.id == id }) else { return }
        if !isDraggingOverlay {
            isDraggingOverlay = true
            checkpoint()
        }
        selectedSegmentID = id
        episodes[episodeIndex].textOverlays[index].positionX = x
        episodes[episodeIndex].textOverlays[index].positionY = y
        selectedEpisode = episodes[episodeIndex]
        if finished {
            isDraggingOverlay = false
            Task { await persistProjectChanges(reloadPreview: false) }
        }
    }

    // MARK: Audio

    var selectedAudioClip: AudioClip? {
        guard let selectedSegmentID else { return nil }
        return selectedEpisode?.audioClips.first { $0.id == selectedSegmentID }
    }

    func addAudio(_ asset: MediaAsset, kind: AudioClipKind, allEpisodes: Bool, atPlayhead: Bool) {
        guard asset.duration > 0 else {
            errorMessage = "Esse arquivo de áudio não tem duração válida."
            return
        }
        let start = atPlayhead ? currentTime : 0
        func makeClip() -> AudioClip {
            AudioClip(
                assetID: asset.id,
                name: asset.name,
                kind: kind,
                timelineStart: start,
                sourceStart: 0,
                sourceEnd: asset.duration,
                volume: kind == .music ? 0.5 : 1,
                fadeIn: 0,
                fadeOut: kind == .music && asset.duration > 6 ? 2 : 0
            )
        }
        if allEpisodes {
            checkpoint()
            for index in episodes.indices {
                episodes[index].audioClips.append(makeClip())
            }
            Task { await persistProjectChanges() }
        } else {
            let clip = makeClip()
            mutateSelectedEpisode { $0.audioClips.append(clip) }
            selectedSegmentID = clip.id
        }
    }

    func updateAudioClip(_ clip: AudioClip) {
        mutateSelectedEpisode { episode in
            if let index = episode.audioClips.firstIndex(where: { $0.id == clip.id }) {
                episode.audioClips[index] = clip
            }
        }
    }

    func removeAudioClip(_ id: UUID) {
        if selectedSegmentID == id { selectedSegmentID = nil }
        mutateSelectedEpisode { $0.audioClips.removeAll { $0.id == id } }
    }

    func moveAudioClipToPlayhead(_ id: UUID) {
        let time = currentTime
        mutateSelectedEpisode { episode in
            if let index = episode.audioClips.firstIndex(where: { $0.id == id }) {
                episode.audioClips[index].timelineStart = time
            }
        }
    }

    // MARK: Narration

    func narrationRecordingChanged(_ recording: Bool, segment: TimelineSegment?) {
        guard let player = previewPlayer else { return }
        if recording {
            if let segment {
                seek(to: segment.startTime)
            }
            narrationStartTime = currentTime
            player.isMuted = true
            player.play()
            isPlaying = true
        } else {
            player.pause()
            player.isMuted = false
            isPlaying = false
            if let narrationStartTime { seek(to: narrationStartTime) }
        }
    }

    func addTimelineNarration(_ asset: MediaAsset) {
        let start = narrationStartTime ?? currentTime
        narrationStartTime = nil
        mediaAssets.append(asset)
        let clip = AudioClip(
            assetID: asset.id,
            name: asset.name,
            kind: .narration,
            timelineStart: start,
            sourceStart: 0,
            sourceEnd: max(asset.duration, 0.1),
            volume: 1
        )
        mutateSelectedEpisode { $0.audioClips.append(clip) }
        selectedSegmentID = clip.id
    }

    /// Links a narration to a clip. Intro/outro narrations follow the global template into every episode.
    func attachNarration(_ asset: MediaAsset, to segment: TimelineSegment) {
        narrationStartTime = nil
        mediaAssets.append(asset)
        switch segment.trackType {
        case .intro, .outro:
            checkpoint()
            if segment.trackType == .intro {
                project.introTemplate?.narrationAssetID = asset.id
            } else {
                project.outroTemplate?.narrationAssetID = asset.id
            }
            for index in episodes.indices {
                episodes[index].normalizeCustomTemplates()
                if segment.trackType == .intro {
                    episodes[index].introSegment?.narrationAssetID = asset.id
                } else {
                    episodes[index].outroSegment?.narrationAssetID = asset.id
                }
            }
            Task { await persistProjectChanges() }
        case .recap:
            checkpoint()
            for index in episodes.indices {
                episodes[index].modifySegment(id: segment.id) { $0.narrationAssetID = asset.id }
            }
            if let manual = project.recapSettings.manualSegments.firstIndex(where: { $0.id == segment.id }) {
                project.recapSettings.manualSegments[manual].narrationAssetID = asset.id
            }
            Task { await persistProjectChanges() }
        default:
            mutateSelectedEpisode { episode in
                episode.modifySegment(id: segment.id) { $0.narrationAssetID = asset.id }
            }
        }
    }

    private var selectedEpisodeIndex: Int? {
        guard let selectedEpisode else { return nil }
        return episodes.firstIndex { $0.id == selectedEpisode.id }
    }

    private func persistProjectChanges(reloadPreview: Bool = true) async {
        for index in episodes.indices {
            episodes[index].normalizeCustomTemplates()
        }
        project.episodes = episodes
        project.mediaAssets = mediaAssets
        do {
            try await storage.saveProject(project)
        } catch {
            errorMessage = "Erro ao salvar projeto: \(Self.describe(error))"
        }
        refreshSelectedEpisode(reloadPreview: reloadPreview)
    }

    private func refreshSelectedEpisode(reloadPreview: Bool = true) {
        guard let selectedEpisode else {
            if let first = episodes.first { selectEpisode(first) }
            return
        }
        guard let updatedEpisode = episodes.first(where: { $0.id == selectedEpisode.id }) ?? episodes.first else { return }
        self.selectedEpisode = updatedEpisode
        updateTimelineForEpisode(updatedEpisode)
        if reloadPreview {
            loadPreview(for: updatedEpisode, keepTime: true)
        }
    }

    private func updateTimelineForEpisode(_ episode: Episode) {
        var tracks: [TrackType: [TimelineSegment]] = [:]
        for track in timelineEngine.computeTrackSegments(for: episode, project: project) {
            tracks[track.trackType] = track.segments
        }
        timelineTracks = tracks
        if let selectedSegmentID,
           !orderedSegments.contains(where: { $0.id == selectedSegmentID }),
           !episode.textOverlays.contains(where: { $0.id == selectedSegmentID }),
           !episode.audioClips.contains(where: { $0.id == selectedSegmentID }) {
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
