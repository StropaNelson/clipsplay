import SwiftUI
import AVKit
import AVFoundation
import PhotosUI
import Photos
import UniformTypeIdentifiers

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
    case episodes = "Saídas"
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
    private let initialOperation: ProjectOperation?
    @StateObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingAutomationCenter = false
    @State private var showingTranscription = false
    @State private var showingTranscriptEditor = false
    @State private var showingClipSuggestions = false
    @State private var showingPauseRemoval = false
    @State private var sidePanel: EditorPanel? = .media
    @State private var sheetPanel: EditorPanel?
    @State private var clipPickRequest: ClipPickRequest?
    @State private var editingSegment: TimelineSegment?
    @State private var textEditRequest: TextEditRequest?
    @State private var transitionSegment: TimelineSegment?
    @State private var framingSegment: TimelineSegment?
    @State private var editingAudio: AudioClip?
    @State private var showingAddAudio = false
    @State private var narrationRequest: NarrationRequest?
    @State private var showingAddOverlay = false
    @State private var editingMediaOverlay: MediaOverlay?
    @State private var showingAddMotion = false
    @State private var editingMotionElement: MotionElement?
    @State private var didOpenInitialOperation = false

    init(project: Project, initialOperation: ProjectOperation? = nil) {
        self.project = project
        self.initialOperation = initialOperation
        self._viewModel = StateObject(wrappedValue: EditorViewModel(project: project))
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }
    private var projectOperation: ProjectOperation? { viewModel.currentProject.operation ?? initialOperation }

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
                    overlays: viewModel.resolvedOverlays,
                    audioClips: viewModel.resolvedAudioClips,
                    mediaOverlays: viewModel.selectedEpisode?.mediaOverlays ?? [],
                    motionElements: viewModel.selectedEpisode?.motionElements ?? [],
                    markers: viewModel.selectedEpisode?.markers.map(\.time) ?? [],
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
                    onAddMotion: { showingAddMotion = true },
                    onMoveMotion: { viewModel.retimeMotionElement($0, start: $1, duration: $2) },
                    onAddAudio: { showingAddAudio = true },
                    onTransitionTap: { transitionSegment = $0 },
                    maxSourceTime: { viewModel.maxSourceTime(for: $0) },
                    audioURL: { viewModel.audioAsset(for: $0)?.url },
                    audioDuration: { viewModel.audioAsset(for: $0)?.duration ?? $0.sourceEnd },
                    onTrimSegment: { viewModel.trimSegment($0, start: $1, end: $2) },
                    onMoveOverlay: { viewModel.retimeOverlay($0, start: $1, duration: $2) },
                    onMoveAudio: { viewModel.updateAudioClip($0) },
                    onAddOverlay: { showingAddOverlay = true },
                    onMoveMediaOverlay: { viewModel.retimeMediaOverlay($0, move: $1, left: $2, right: $3) },
                    onDropAsset: { viewModel.dropAsset($0, on: $1, at: $2) },
                    onReorderMain: { viewModel.reorderMainClip($0, toTime: $1) }
                )
                .frame(maxHeight: .infinity)
                Divider().overlay(EditorTheme.divider)
                featureSheets(on: toolBar)
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
        .sheet(isPresented: $showingAutomationCenter) {
            AutomationCenterView(
                project: viewModel.currentProject,
                operation: projectOperation,
                onAnalysisReady: { viewModel.applyContentAnalysis($0) },
                onCreateOutputs: { suggestions, request in
                    viewModel.setOperation(request.operation)
                    if request.operation == .multiply {
                        viewModel.createMomentOutputs(suggestions, request: request)
                    } else {
                        viewModel.createSuggestedEpisodes(
                            suggestions,
                            autoFraming: request.autoFraming,
                            captions: request.captions.enabled,
                            dynamicCaptions: request.captions.dynamic,
                            formats: request.formats,
                            generateCovers: request.generateCovers
                        )
                    }
                },
                onApplyCuts: { ranges, request in
                    viewModel.setOperation(request.operation)
                    viewModel.removeSourceRanges(
                        ranges,
                        captions: request.captions.enabled,
                        dynamicCaptions: request.captions.dynamic,
                        wholeClip: request.operation == .speechEdit
                    )
                },
                onCreateEpisodes: { times, request in
                    viewModel.setOperation(request.operation)
                    viewModel.createSequentialEpisodes(cuts: times, request: request)
                },
                onApplyPlan: { plan, brief in
                    viewModel.setOperation(.aiEdit)
                    viewModel.applyClipPlan(plan, brief: brief)
                },
                onOpenTranscript: { showingTranscription = true },
                onOpenTranscriptEditor: { operation in openTranscriptEditing(operation: operation) },
                onSeek: { viewModel.seekToSourceTime($0) },
                onImportAsset: { asset in
                    Task { await viewModel.addMediaAsset(asset) }
                }
            )
        }
        .sheet(isPresented: $showingTranscriptEditor) {
            TranscriptEditorView(
                words: viewModel.editableTranscriptWords.sorted { $0.start < $1.start },
                onRemove: { viewModel.removeSourceRanges($0, wholeClip: projectOperation == .speechEdit) },
                onSeekWord: { viewModel.seekToSourceTime($0) },
                onMarkTopics: { viewModel.markTimes($0) },
                onCreateEpisodes: { viewModel.createEpisodesAtTopics($0) }
            )
        }
        .sheet(isPresented: $showingTranscription) {
            TranscriptionView(
                project: viewModel.currentProject,
                onTranscriptChange: { viewModel.saveTranscript($0) },
                onApplyCaptions: { viewModel.applyCaptions($0, dynamic: $1) },
                onWords: { viewModel.saveTranscriptWords($0) },
                onCorrected: { viewModel.applyCorrectedTranscript($0, words: $1) },
                currentWords: { viewModel.editableTranscriptWords },
                onVocabularyChange: { viewModel.saveTranscriptionVocabulary($0) }
            )
        }
        .sheet(isPresented: $showingPauseRemoval) {
            PauseRemovalView(
                project: viewModel.currentProject,
                episodes: viewModel.episodes,
                selectedEpisodeID: viewModel.selectedEpisode?.id,
                coverage: { viewModel.sourceCoverage(of: $0) }
            ) { ranges, episodeIDs in
                viewModel.removeSourceRanges(ranges, episodeIDs: episodeIDs)
            }
        }
        .sheet(isPresented: $showingClipSuggestions) {
            ClipSuggestionsView(
                words: viewModel.editableTranscriptWords,
                sourceDuration: viewModel.currentProject.sequenceSourceDuration,
                sceneSources: viewModel.currentProject.transcriptionSources,
                storedSceneCuts: viewModel.currentProject.sceneCuts ?? [],
                onSceneCuts: { viewModel.saveSceneCuts($0) },
                onSeek: { viewModel.seekToSourceTime($0) },
                onCreate: { viewModel.createSuggestedEpisodes($0, autoFraming: $1) }
            )
        }
        .sheet(item: $sheetPanel) { panel in
            panelContent(panel)
        }
        .sheet(item: $clipPickRequest) { request in
            ClipAssetPickerSheet(
                track: request.track,
                assets: viewModel.mediaAssets.filter { $0.type == .video },
                project: viewModel.currentProject,
                canvasSize: pickerCanvasSize,
                onImportAsset: { asset in
                    Task { await viewModel.addMediaAsset(asset) }
                },
                onAssign: { asset, selection in
                    if request.track == .main {
                        viewModel.insertClip(asset, selection: selection)
                    } else {
                        Task { await viewModel.assign(asset, to: request.track, selection: selection) }
                    }
                }
            )
        }
        .sheet(item: $editingSegment) { segment in
            SegmentEditorView(
                segment: segment,
                trackType: segment.trackType,
                project: viewModel.currentProject,
                onSave: { viewModel.updateSegment($0, applyToAllEpisodes: $1) },
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
            openInitialOperationIfNeeded()
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

            Button {
                viewModel.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(EditorTheme.panelRaised, in: Circle())
            }
            .disabled(!viewModel.canRedo)
            .opacity(viewModel.canRedo ? 1 : 0.4)

            Menu {
                Button { Task { await viewModel.saveProject() } } label: {
                    Label("Salvar", systemImage: "square.and.arrow.down")
                }
                Button { viewModel.showDuplicateSheet = true } label: {
                    Label("Duplicar projeto", systemImage: "doc.on.doc")
                }
                Button { showingAutomationCenter = true } label: {
                    Label("Automatizar", systemImage: "sparkles.rectangle.stack")
                }
                Button { showingTranscription = true } label: {
                    Label("Texto e legendas", systemImage: "captions.bubble")
                }
                Button { showingPauseRemoval = true } label: {
                    Label("Remover pausas", systemImage: "speaker.slash")
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
                    operation: projectOperation,
                    onSelect: { episode in
                        viewModel.selectEpisode(episode)
                        sheetPanel = nil
                    },
                    onEdit: { episode in viewModel.updateEpisodeDetails(episode) },
                    onRegenerate: { length in Task { await viewModel.regenerateEpisodes(length: length) } }
                )
                .navigationTitle(projectOperation == .speechEdit ? "Clipe" : "Saídas")
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
                onExportAll: { afterDismissingPanelSheet { Task { await viewModel.exportAllEpisodes() } } },
                onExportVariants: { variants in
                    afterDismissingPanelSheet {
                        Task { await viewModel.exportVariants(variants) }
                    }
                }
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
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            action()
        }
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

    private func openInitialOperationIfNeeded() {
        guard !didOpenInitialOperation else { return }
        didOpenInitialOperation = true
        if initialOperation != nil {
            showingAutomationCenter = true
        }
    }

    private func openTranscriptEditing(operation: ProjectOperation? = nil) {
        guard !viewModel.editableTranscriptWords.isEmpty else {
            showingTranscription = true
            return
        }
        if let operation = operation {
            viewModel.setOperation(operation)
        }
        if (operation ?? projectOperation) == .speechEdit {
            viewModel.useWholeClipForSpeechEdit()
        }
        showingTranscriptEditor = true
    }

    private var viewer: some View {
        ZStack {
            EditorTheme.background
            ZStack {
                EditorTheme.stage
                if let player = viewModel.previewPlayer {
                    PlayerCanvasView(player: player)
                    MediaOverlayLayer(
                        overlays: viewModel.visibleMediaOverlays,
                        selectedID: viewModel.selectedSegmentID,
                        imageURL: { overlay in viewModel.mediaAssets.first { $0.id == overlay.assetID }?.url },
                        aspect: { viewModel.mediaAspect(for: $0) },
                        onSelect: { viewModel.selectedSegmentID = $0 },
                        onMove: { id, x, y, finished in viewModel.moveMediaOverlay(id, x: x, y: y, finished: finished) }
                    )
                    MotionLayer(
                        elements: viewModel.visibleMotionElements,
                        currentTime: viewModel.currentTime,
                        selectedID: viewModel.selectedSegmentID,
                        onSelect: { viewModel.selectedSegmentID = $0 },
                        onMove: { id, x, y, finished in viewModel.moveMotionElement(id, x: x, y: y, finished: finished) }
                    )
                    TextOverlayLayer(
                        overlays: viewModel.visibleOverlays,
                        currentTime: viewModel.currentTime,
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
                if viewModel.previewPlayer != nil && !viewModel.isPreviewLoading && viewModel.previewError == nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            previewAudioControls
                        }
                    }
                    .padding(10)
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

    private var previewAudioControls: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.togglePreviewMute()
            } label: {
                Image(systemName: viewModel.previewMuted || viewModel.previewVolume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            Slider(
                value: Binding(
                    get: { Double(viewModel.previewVolume) },
                    set: { viewModel.setPreviewVolume(Float($0)) }
                ),
                in: 0...1
            )
            .frame(width: isRegular ? 120 : 88)
            .tint(EditorTheme.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.65), in: Capsule())
        .contentShape(Capsule())
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
            Divider().frame(height: 20).overlay(EditorTheme.divider)
            Button { viewModel.jumpToMarker(forward: false) } label: {
                Image(systemName: "arrow.left.to.line")
            }
            Button { viewModel.toggleMarker() } label: {
                Image(systemName: viewModel.isOnMarker ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(viewModel.isOnMarker ? Color.orange : Color.white)
            }
            Button { viewModel.jumpToMarker(forward: true) } label: {
                Image(systemName: "arrow.right.to.line")
            }
            Button { viewModel.rippleDeleteBetweenMarkers() } label: {
                Image(systemName: "scissors.badge.ellipsis")
                    .foregroundStyle(viewModel.rippleRange == nil ? Color.white.opacity(0.3) : Color.red)
            }
            .disabled(viewModel.rippleRange == nil)
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
                        toolButton("Congelar", icon: "snowflake") { viewModel.freezeFrame() }
                        toolButton("Áudio", icon: "waveform") { Task { @MainActor in await viewModel.detachAudio() } }
                    }
                    Menu {
                        ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { value in
                            Button {
                                viewModel.setSpeed(value)
                            } label: {
                                if abs(segment.speed - value) < 0.001 {
                                    Label(Self.speedLabel(value), systemImage: "checkmark")
                                } else {
                                    Text(Self.speedLabel(value))
                                }
                            }
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 19))
                            Text(segment.isFreeze ? "Congelado" : Self.speedLabel(segment.speed))
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(minWidth: 64, minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    toolButton("Editar", icon: "slider.horizontal.3") { editingSegment = segment }
                    toolButton("Transição", icon: "square.on.square") { transitionSegment = segment }
                    toolButton("Ajustar", icon: "crop.rotate") { framingSegment = segment }
                    toolButton("Narração", icon: "mic.badge.plus") { narrationRequest = NarrationRequest(segment: segment) }
                    if segment.trackType == .main {
                        if viewModel.canMoveMainClip(segment.id, by: -1) {
                            toolButton("Mover ◀︎", icon: "arrow.left.square") { viewModel.moveMainClip(segment.id, by: -1) }
                        }
                        if viewModel.canMoveMainClip(segment.id, by: 1) {
                            toolButton("Mover ▶︎", icon: "arrow.right.square") { viewModel.moveMainClip(segment.id, by: 1) }
                        }
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
                } else if let motion = viewModel.selectedMotionElement {
                    toolButton("Fechar", icon: "xmark") { viewModel.selectedSegmentID = nil }
                    Divider().frame(height: 30).overlay(EditorTheme.divider)
                    toolButton("Editar", icon: "slider.horizontal.3") { editingMotionElement = motion }
                    toolButton("Duplicar", icon: "plus.square.on.square") { viewModel.duplicateSelected() }
                    toolButton("Excluir", icon: "trash", role: .destructive) { viewModel.removeMotionElement(motion.id) }
                } else if let media = viewModel.selectedMediaOverlay {
                    toolButton("Fechar", icon: "xmark") { viewModel.selectedSegmentID = nil }
                    Divider().frame(height: 30).overlay(EditorTheme.divider)
                    toolButton("Editar", icon: "slider.horizontal.3") { editingMediaOverlay = media }
                    toolButton("Excluir", icon: "trash", role: .destructive) { viewModel.removeMediaOverlay(media.id) }
                } else if let clip = viewModel.selectedAudioClip {
                    toolButton("Fechar", icon: "xmark") { viewModel.selectedSegmentID = nil }
                    Divider().frame(height: 30).overlay(EditorTheme.divider)
                    toolButton("Editar", icon: "slider.horizontal.3") { editingAudio = clip }
                    toolButton("Dividir", icon: "scissors") { viewModel.splitAudioClip(clip.id) }
                    toolButton("Cursor", icon: "arrow.right.to.line") { viewModel.moveAudioClipToPlayhead(clip.id) }
                    toolButton("Excluir", icon: "trash", role: .destructive) { viewModel.removeAudioClip(clip.id) }
                } else {
                    toolButton("Mídia", icon: "photo.on.rectangle.angled") { open(.media) }
                    toolButton(projectOperation == .speechEdit ? "Clipe" : "Episódios", icon: "film.stack") { open(.episodes) }
                    Divider().frame(height: 30).overlay(EditorTheme.divider)
                    toolButton("Dividir", icon: "scissors") { viewModel.splitAtPlayhead() }
                    toolButton("Pausas", icon: "speaker.slash") { showingPauseRemoval = true }
                    toolButton("Clipe", icon: "plus.rectangle.on.rectangle") { clipPickRequest = ClipPickRequest(track: .main) }
                    toolButton("Sobrepor", icon: "rectangle.on.rectangle") { showingAddOverlay = true }
                    toolButton("Texto", icon: "textformat") { textEditRequest = viewModel.newTextRequest() }
                    toolButton("Motion", icon: "sparkles") { showingAddMotion = true }
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
                    toolButton("Automatizar", icon: "sparkles.rectangle.stack") { showingAutomationCenter = true }
                    toolButton("Texto", icon: "captions.bubble") { showingTranscription = true }
                    toolButton("Sugerir", icon: "wand.and.stars") { showingClipSuggestions = true }
                    toolButton("Autoedição", icon: "text.badge.minus") { openTranscriptEditing() }
                    toolButton("Importar", icon: "plus.rectangle.on.folder") { viewModel.showImportAsset = true }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 64)
        .background(EditorTheme.panel)
    }

    /// Sheets hang off a real, visible view: presenting from a zero-size host can leave text
    /// fields in the sheet unable to become first responder.
    private func featureSheets<Content: View>(on content: Content) -> some View {
        content
            .sheet(item: $textEditRequest) { request in
                TextOverlayEditorSheet(
                    request: request,
                    episodeDuration: viewModel.timelineDuration,
                    onSave: { viewModel.saveOverlay($0) },
                    onDelete: { viewModel.removeOverlay(request.overlay.id) },
                    templates: viewModel.currentProject.textTemplates ?? [],
                    onSaveTemplate: { _, template in viewModel.saveTextTemplate(template) }
                )
            }
            .sheet(item: $framingSegment) { segment in
                ClipTransformSheet(transform: segment.transform, adjustments: segment.adjustments ?? .identity) { transform, adjustments in
                    var updated = segment
                    updated.transform = transform
                    updated.adjustments = adjustments.isIdentity ? nil : adjustments
                    viewModel.updateSegment(updated)
                }
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
                    onAdd: { asset, anchor, atPlayhead in
                        viewModel.addAudio(asset, kind: .music, anchor: anchor, atPlayhead: atPlayhead)
                    }
                )
            }
            .sheet(item: $editingAudio) { clip in
                AudioClipEditorSheet(
                    clip: clip,
                    assetURL: viewModel.mediaAssets.first { $0.id == clip.assetID }?.url,
                    assetDuration: viewModel.mediaAssets.first { $0.id == clip.assetID }?.duration ?? clip.sourceEnd,
                    episodeDuration: viewModel.timelineDuration,
                    onSave: { viewModel.updateAudioClip($0) },
                    onDelete: { viewModel.removeAudioClip(clip.id) }
                )
            }
            .sheet(isPresented: $showingAddOverlay) {
                AddOverlaySheet(
                    assets: viewModel.mediaAssets.filter { $0.type == .image || $0.type == .video },
                    onImportAsset: { asset in Task { await viewModel.addMediaAsset(asset) } },
                    onAdd: { viewModel.addMediaOverlay($0) }
                )
            }
            .sheet(item: $editingMediaOverlay) { overlay in
                MediaOverlayEditorSheet(
                    overlay: overlay,
                    episodeDuration: viewModel.timelineDuration,
                    assetDuration: viewModel.mediaAssets.first { $0.id == overlay.assetID }?.duration ?? overlay.duration,
                    onSave: { viewModel.updateMediaOverlay($0) },
                    onDelete: { viewModel.removeMediaOverlay(overlay.id) }
                )
            }
            .sheet(isPresented: $showingAddMotion) {
                AddMotionSheet(
                    currentTime: viewModel.currentTime,
                    timelineDuration: viewModel.timelineDuration,
                    onAdd: { viewModel.addMotionElement($0) }
                )
            }
            .sheet(item: $editingMotionElement) { element in
                MotionElementEditorSheet(
                    element: element,
                    episodeDuration: viewModel.timelineDuration,
                    onSave: { viewModel.updateMotionElement($0) },
                    onDelete: { viewModel.removeMotionElement(element.id) }
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

    static func speedLabel(_ value: Double) -> String {
        let text = value == value.rounded() ? String(format: "%.0f", value) : String(format: "%g", value)
        return text.replacingOccurrences(of: ".", with: ",") + "×"
    }

    private var pickerCanvasSize: CGSize {
        let format = viewModel.selectedEpisode?.outputAspectRatio ?? viewModel.currentProject.aspectRatio
        if let size = ClipAssetPickerSheet.canvasSize(for: format) { return size }
        let oriented = viewModel.currentProject.sourceVideoNaturalSize.cgSize
            .applying(viewModel.currentProject.sourceVideoTransform.cgAffineTransform)
        var width = abs(oriented.width)
        var height = abs(oriented.height)
        if width <= 0 || height <= 0 {
            width = 1920
            height = 1080
        }
        let scale = min(1, 1920 / max(width, height))
        return CGSize(
            width: (width * scale / 2).rounded() * 2,
            height: (height * scale / 2).rounded() * 2
        )
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
    let project: Project
    let canvasSize: CGSize
    let onImportAsset: (MediaAsset) -> Void
    let onAssign: (MediaAsset, ClipSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trimRequest: AssetTrimRequest?
    @State private var showingImport = false
    @State private var gallerySelection: PhotosPickerItem?
    @State private var galleryKind: PickerFileKind = .video
    @State private var showingGallery = false
    @State private var fileImportKind: PickerFileKind?
    @State private var showingImageSourceDialog = false
    @State private var showingCamera = false
    @State private var imageClipRequest: ImageClipRequest?
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var importedAssets: [MediaAsset] = []

    private let importer = VideoImporter.shared

    private var displayAssets: [MediaAsset] {
        var merged = assets
        for asset in importedAssets where !merged.contains(where: { $0.id == asset.id }) {
            merged.append(asset)
        }
        return merged
    }

    enum PickerFileKind: String, Identifiable {
        case video, image
        var id: String { rawValue }
        var allowedTypes: [UTType] {
            switch self {
            case .video: return VideoImporter.supportedVideoTypes
            case .image: return VideoImporter.supportedImageTypes
            }
        }
    }

    struct ImageClipRequest: Identifiable {
        let id = UUID()
        let image: UIImage
        let name: String
    }

    private func onImport() { showingImport = true }

    private var title: String {
        switch track {
        case .intro: return "Escolher abertura"
        case .outro: return "Escolher encerramento"
        case .recap: return "Escolher recapitulação"
        default: return "Escolher vídeo"
        }
    }

    static func canvasSize(for format: AspectRatio) -> CGSize? {
        switch format {
        case .portrait9_16: return CGSize(width: 1080, height: 1920)
        case .portrait4_5: return CGSize(width: 1080, height: 1350)
        case .portrait3_4: return CGSize(width: 1080, height: 1440)
        case .square1_1: return CGSize(width: 1080, height: 1080)
        case .landscape16_9: return CGSize(width: 1920, height: 1080)
        case .original: return nil
        }
    }

    private var projectSourceAssetIDs: Set<UUID> {
        Set(project.sourceClips.compactMap(\.assetID))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        actionTiles
                        if let message = errorMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Vídeos do projeto e da biblioteca")
                                .font(.subheadline.weight(.semibold))
                            if displayAssets.isEmpty {
                                Text("Nenhum vídeo disponível. Use as opções acima para trazer um vídeo da galeria, de arquivos, transformar uma imagem em clipe ou gravar uma vinheta.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding()
                                    .frame(maxWidth: .infinity)
                                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                                    ForEach(displayAssets) { asset in
                                        Button {
                                            trimRequest = AssetTrimRequest(asset: asset, track: track)
                                        } label: {
                                            assetTile(asset)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
                if let message = busyMessage {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(message)
                                .font(.caption.weight(.medium))
                        }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .sheet(item: $trimRequest) { request in
                AssetTrimSheet(
                    asset: request.asset,
                    track: request.track,
                    words: assetLocalWords(for: request.asset),
                    vocabulary: project.transcriptionVocabulary ?? []
                ) { selection in
                    onAssign(request.asset, selection)
                    dismiss()
                }
            }
            .sheet(isPresented: $showingImport) {
                AssetImportSheet { asset in
                    importedAssets.append(asset)
                    onImportAsset(asset)
                }
            }
            .sheet(item: $imageClipRequest) { request in
                ImageClipSheet(image: request.image, name: request.name, canvasSize: canvasSize) { url in
                    makeImageAsset(from: url, name: request.name)
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraVideoPicker { url in
                    importRecordedVideo(url)
                }
            }
            .confirmationDialog("Imagem para o clipe", isPresented: $showingImageSourceDialog) {
                Button("Escolher na galeria") {
                    galleryKind = .image
                    showingGallery = true
                }
                Button("Escolher em arquivos") {
                    fileImportKind = .image
                }
            }
            .fileImporter(
                isPresented: Binding(
                    get: { fileImportKind != nil },
                    set: { if !$0 { fileImportKind = nil } }
                ),
                allowedContentTypes: fileImportKind?.allowedTypes ?? VideoImporter.supportedVideoTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .photosPicker(
                isPresented: $showingGallery,
                selection: $gallerySelection,
                matching: galleryKind == .video ? .videos : .images
            )
            .onChange(of: gallerySelection) { item in
                guard let item = item else { return }
                if galleryKind == .image {
                    importGalleryImage(item)
                } else {
                    importGalleryVideo(item)
                }
            }
        }
    }

    private var actionTiles: some View {
        HStack(spacing: 10) {
            actionTile("Galeria", icon: "photo.on.rectangle") {
                galleryKind = .video
                showingGallery = true
            }
            actionTile("Arquivos", icon: "folder") {
                fileImportKind = .video
            }
            actionTile("Imagem", icon: "photo") {
                showingImageSourceDialog = true
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                actionTile("Gravar", icon: "video") {
                    showingCamera = true
                }
            }
        }
    }

    private func actionTile(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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
                if projectSourceAssetIDs.contains(asset.id) {
                    Text("Vídeo do projeto")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.9), in: Capsule())
                        .foregroundStyle(.black)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(asset.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
    }

    /// Project-transcript words that fall inside this asset's source range, shifted to
    /// asset-local time. Nil when the asset isn't a project source or the transcript is stale.
    private func assetLocalWords(for asset: MediaAsset) -> [TranscriptWord]? {
        guard let words = project.transcriptWords, !words.isEmpty,
              let transcriptDuration = project.transcriptSequenceDuration,
              abs(transcriptDuration - project.sequenceSourceDuration) <= 0.5 else { return nil }
        guard let clip = project.sourceClips.first(where: {
            $0.assetID == asset.id
        }) else { return nil }
        let lower = clip.sequenceStartTime + clip.startTime
        let upper = clip.sequenceStartTime + clip.endTime
        let local = words
            .filter { $0.start >= lower && $0.end <= upper }
            .map { TranscriptWord(text: $0.text, start: $0.start - clip.sequenceStartTime, end: $0.end - clip.sequenceStartTime) }
        return local.isEmpty ? nil : local
    }

    private func importGalleryVideo(_ item: PhotosPickerItem) {
        Task {
            busyMessage = "Importando…"
            errorMessage = nil
            defer {
                busyMessage = nil
                gallerySelection = nil
            }
            do {
                guard let video = try await item.loadTransferable(type: GalleryVideo.self) else {
                    errorMessage = "Não foi possível ler o vídeo selecionado."
                    return
                }
                defer { try? FileManager.default.removeItem(at: video.url) }
                let asset = try await importer.importMediaAsset(from: video.url, type: .video)
                importedAssets.append(asset)
                onImportAsset(asset)
                trimRequest = AssetTrimRequest(asset: asset, track: track)
            } catch {
                errorMessage = "Erro ao importar vídeo da galeria: \(error.localizedDescription)"
            }
        }
    }

    private func importGalleryImage(_ item: PhotosPickerItem) {
        Task {
            busyMessage = "Importando…"
            errorMessage = nil
            defer {
                busyMessage = nil
                gallerySelection = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    errorMessage = "Não foi possível ler a imagem selecionada."
                    return
                }
                imageClipRequest = ImageClipRequest(image: image, name: "Imagem da galeria")
            } catch {
                errorMessage = "Erro ao importar imagem: \(error.localizedDescription)"
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        let kind = fileImportKind
        fileImportKind = nil
        switch result {
        case .failure(let error):
            errorMessage = "Erro ao importar: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            if kind == .image {
                guard let data = try? Data(contentsOf: url),
                      let image = UIImage(data: data) else {
                    errorMessage = "Não foi possível ler a imagem selecionada."
                    return
                }
                imageClipRequest = ImageClipRequest(image: image, name: url.deletingPathExtension().lastPathComponent)
            } else {
                importFileVideo(url)
            }
        }
    }

    private func importFileVideo(_ url: URL) {
        Task {
            busyMessage = "Importando…"
            errorMessage = nil
            defer { busyMessage = nil }
            do {
                let asset = try await importer.importMediaAsset(from: url, type: .video)
                importedAssets.append(asset)
                onImportAsset(asset)
                trimRequest = AssetTrimRequest(asset: asset, track: track)
            } catch {
                errorMessage = "Erro ao importar vídeo: \(error.localizedDescription)"
            }
        }
    }

    private func importRecordedVideo(_ url: URL) {
        Task {
            busyMessage = "Importando…"
            errorMessage = nil
            defer { busyMessage = nil }
            do {
                let asset = try await importer.importMediaAsset(from: url, type: .video)
                try? FileManager.default.removeItem(at: url)
                importedAssets.append(asset)
                onImportAsset(asset)
                trimRequest = AssetTrimRequest(asset: asset, track: track)
            } catch {
                errorMessage = "Erro ao importar gravação: \(error.localizedDescription)"
            }
        }
    }

    private func makeImageAsset(from url: URL, name: String) {
        Task {
            busyMessage = "Importando…"
            errorMessage = nil
            defer { busyMessage = nil }
            do {
                var asset = try await importer.importMediaAsset(from: url, type: .video)
                try? FileManager.default.removeItem(at: url)
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = trimmed.isEmpty ? "Logo" : trimmed
                asset.name = "Imagem • \(label)"
                importedAssets.append(asset)
                onImportAsset(asset)
                onAssign(asset, ClipSelection(startTime: 0, endTime: asset.duration, narration: nil, clipVolume: 1))
                dismiss()
            } catch {
                errorMessage = "Erro ao criar clipe da imagem: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Image clip sheet

/// Picks a still image and a duration, then renders it into a video clip.
struct ImageClipSheet: View {
    let image: UIImage
    let name: String
    let canvasSize: CGSize
    let onCreate: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var duration = 3.0
    @State private var isCreating = false
    @State private var errorMessage: String?

    private let durations: [Double] = [2, 3, 5, 8]

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.top)

                Text("Duração do clipe")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach(durations, id: \.self) { seconds in
                        Button {
                            duration = seconds
                        } label: {
                            Text("\(Int(seconds)) s")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    duration == seconds ? Color.accentColor.opacity(0.2) : Color(uiColor: .tertiarySystemGroupedBackground),
                                    in: Capsule()
                                )
                                .foregroundStyle(duration == seconds ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let message = errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding(.horizontal)
            .navigationTitle("Imagem em clipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        create()
                    } label: {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Criar")
                        }
                    }
                    .disabled(isCreating)
                }
            }
        }
    }

    private func create() {
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let url = try await ImageClipWriter.makeClip(image: image, duration: duration, canvasSize: canvasSize)
                await MainActor.run {
                    onCreate(url)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isCreating = false
                }
            }
        }
    }
}

// MARK: - Camera picker

/// Minimal UIImagePickerController wrapper for recording short vinheta videos.
struct CameraVideoPicker: UIViewControllerRepresentable {
    let onRecorded: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.cameraCaptureMode = .video
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraVideoPicker

        init(_ parent: CameraVideoPicker) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.dismiss()
            guard let url = info[.mediaURL] as? URL else { return }
            parent.onRecorded(url)
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
    @Published var previewMuted = false
    @Published var previewVolume: Float = 1
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
    @Published var lastExportZIPURL: URL?
    @Published var lastExportedFiles: [URL] = []
    @Published var photoSaveStatus: String?
    @Published var isPreparingZIP = false
    private var exportFinalized = false

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
    private var redoStack: [UndoState] = []
    private var isDraggingOverlay = false
    private var narrationStartTime: Double?
    private var transcriptSaveTask: Task<Void, Never>?
    @Published var canUndo = false
    @Published var canRedo = false

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
            coverImageAssetID: project.coverSettings.customImageAssetID,
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

    func setOperation(_ operation: ProjectOperation) {
        guard project.operation != operation else { return }
        objectWillChange.send()
        project.operation = operation
        Task { await persistProjectChanges(reloadPreview: false) }
    }

    var orderedSegments: [TimelineSegment] {
        timelineTracks.values.flatMap { $0 }.sorted { $0.startTime < $1.startTime }
    }

    var timelineDuration: Double {
        orderedSegments.map(\.endTime).max() ?? 0
    }

    var selectedSegment: TimelineSegment? {
        guard let selectedSegmentID = selectedSegmentID else { return nil }
        return orderedSegments.first { $0.id == selectedSegmentID }
    }

    var canvasAspectRatio: CGFloat {
        if let ratio = selectedEpisode?.outputAspectRatio?.ratio ?? exportSettings.aspectRatio.ratio { return ratio }
        let rect = CGRect(origin: .zero, size: project.sourceVideoNaturalSize.cgSize)
            .applying(project.sourceVideoTransform.cgAffineTransform)
        guard abs(rect.width) > 1, abs(rect.height) > 1 else { return 16 / 9 }
        return abs(rect.width) / abs(rect.height)
    }

    var canvasLabel: String {
        let ratio = selectedEpisode?.outputAspectRatio ?? exportSettings.aspectRatio
        return ratio == .original ? "Original" : ratio.rawValue
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
            customImageAssetID: exportSettings.coverImageAssetID
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

    func updateEpisodeDetails(_ episode: Episode) {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }) else { return }
        checkpoint()
        episodes[index] = episode
        selectedEpisode = episode
        updateTimelineForEpisode(episode)
        Task { await persistProjectChanges() }
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
                episodes[index].usesCustomRecapSegments = nil
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
        let globalOverlays: [TextOverlay]
        let globalAudioClips: [AudioClip]
        let sourceClips: [VideoSegment]?
        let transcriptSequenceDuration: Double?
    }

    private func currentUndoState() -> UndoState {
        UndoState(
            episodes: episodes,
            mediaAssets: mediaAssets,
            introTemplate: project.introTemplate,
            outroTemplate: project.outroTemplate,
            recapSettings: project.recapSettings,
            globalOverlays: project.globalOverlays,
            globalAudioClips: project.globalAudioClips,
            sourceClips: project.storedSourceClips,
            transcriptSequenceDuration: project.transcriptSequenceDuration
        )
    }

    func checkpoint() {
        undoStack.append(currentUndoState())
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let state = undoStack.popLast() else { return }
        redoStack.append(currentUndoState())
        restore(state)
    }

    func redo() {
        guard let state = redoStack.popLast() else { return }
        undoStack.append(currentUndoState())
        restore(state)
    }

    private func restore(_ state: UndoState) {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        episodes = state.episodes
        mediaAssets = state.mediaAssets
        project.introTemplate = state.introTemplate
        project.outroTemplate = state.outroTemplate
        project.recapSettings = state.recapSettings
        project.globalOverlays = state.globalOverlays
        project.globalAudioClips = state.globalAudioClips
        project.storedSourceClips = state.sourceClips
        project.transcriptSequenceDuration = state.transcriptSequenceDuration
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

    func maxSourceTime(for segment: TimelineSegment) -> Double {
        if segment.sourceType == .mainVideo { return project.sourceVideoDuration }
        return mediaAssets.first { $0.id == segment.assetID }?.duration ?? segment.sourceEndTime
    }

    func trimSegment(_ segment: TimelineSegment, start: Double, end: Double) {
        var updated = segment
        updated.sourceStartTime = start
        updated.sourceEndTime = end
        updated.duration = (end - start) / segment.speed
        updateSegment(updated)
    }

    /// Intro/outro/recap edits repeat in every episode by default, like their global templates.
    func updateSegment(_ segment: TimelineSegment, applyToAllEpisodes: Bool? = nil) {
        let apply: (inout VideoSegment) -> Void = { video in
            video.startTime = segment.sourceStartTime
            video.endTime = segment.sourceEndTime
            video.sourceType = segment.sourceType
            video.assetID = segment.assetID
            video.isEnabled = true
            video.transition = segment.transition
            video.transitionDuration = segment.transitionDuration
            video.clipVolume = segment.clipVolume
            video.audioFadeIn = segment.audioFadeIn > 0.001 ? segment.audioFadeIn : nil
            video.audioFadeOut = segment.audioFadeOut > 0.001 ? segment.audioFadeOut : nil
            video.narrationAssetID = segment.narrationAssetID
            video.narrationLevel = segment.narrationVolume
            video.playbackSpeed = segment.speed
            video.clipTransform = segment.transform
            video.adjustments = segment.adjustments
        }
        let global = applyToAllEpisodes ?? (segment.trackType != .main)
        guard global, segment.trackType != .main else {
            mutateSelectedEpisode { $0.modifySegment(id: segment.id, apply) }
            return
        }

        checkpoint()
        func updateTemplate(_ template: inout SegmentTemplate?) {
            guard var value = template else { return }
            value.startTime = segment.sourceStartTime
            value.endTime = segment.sourceEndTime
            value.sourceType = segment.sourceType
            value.assetID = segment.assetID
            value.narrationAssetID = segment.narrationAssetID
            value.clipVolume = segment.clipVolume < 0.999 ? segment.clipVolume : nil
            template = value
        }
        switch segment.trackType {
        case .intro: updateTemplate(&project.introTemplate)
        case .outro: updateTemplate(&project.outroTemplate)
        default: break
        }
        if let index = project.recapSettings.manualSegments.firstIndex(where: { $0.id == segment.id }) {
            apply(&project.recapSettings.manualSegments[index])
        }
        for index in episodes.indices {
            episodes[index].normalizeCustomTemplates()
            switch segment.trackType {
            case .intro:
                if var video = episodes[index].introSegment {
                    apply(&video)
                    episodes[index].introSegment = video
                }
            case .outro:
                if var video = episodes[index].outroSegment {
                    apply(&video)
                    episodes[index].outroSegment = video
                }
            default:
                episodes[index].modifySegment(id: segment.id, apply)
            }
            episodes[index].clearTimelinePins()
        }
        Task { await persistProjectChanges() }
    }

    func moveMainClip(_ id: UUID, by offset: Int) {
        mutateSelectedEpisode { episode in
            var clips = episode.mainClips
            guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
            let target = index + offset
            guard clips.indices.contains(target) else { return }
            clips.swapAt(index, target)
            episode.mainClips = clips
        }
    }

    /// Places a main piece among the others according to where it was dropped on the timeline.
    func reorderMainClip(_ id: UUID, toTime time: Double) {
        let midpoints = Dictionary(orderedSegments.map { ($0.id, $0.startTime + $0.duration / 2) }, uniquingKeysWith: { first, _ in first })
        guard let clips = selectedEpisode?.mainClips, let index = clips.firstIndex(where: { $0.id == id }) else { return }
        var others = clips
        let clip = others.remove(at: index)
        let target = others.filter { (midpoints[$0.id] ?? 0) < time }.count
        guard target != index else { return }
        others.insert(clip, at: target)
        mutateSelectedEpisode { $0.mainClips = others }
    }

    func canMoveMainClip(_ id: UUID, by offset: Int) -> Bool {
        guard let clips = selectedEpisode?.mainClips,
              let index = clips.firstIndex(where: { $0.id == id }) else { return false }
        return clips.indices.contains(index + offset)
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
        let cut = item.segment.startTime + (time - item.start) * item.segment.playbackSpeed
        var newID = UUID()
        mutateSelectedEpisode { episode in
            var clips = episode.mainClips
            guard let index = clips.firstIndex(where: { $0.id == item.segment.id }) else { return }
            var first = clips[index]
            first.endTime = cut
            // The second half keeps playing the narration from where the first half stops.
            let second = clips[index].continuation(from: cut)
            newID = second.id
            clips.replaceSubrange(index...index, with: [first, second])
            episode.mainClips = clips
        }
        selectedSegmentID = newID
    }

    func setSpeed(_ speed: Double) {
        guard var segment = selectedSegment else { return }
        segment.speed = speed
        segment.duration = segment.sourceDuration / speed
        updateSegment(segment)
    }

    /// Splits the main clip at the playhead and inserts the current frame held for `seconds`.
    func freezeFrame(seconds: Double = 2) {
        guard let episode = selectedEpisode else { return }
        let time = currentTime
        guard let item = episode.storyline().first(where: {
            $0.track == .main && time >= $0.start && time < $0.end
        }) else {
            errorMessage = "Posicione o cursor sobre o conteúdo principal para congelar o quadro."
            return
        }
        // Shorter than one frame even at 120 fps, so exactly one image is held.
        let frame = 1.0 / 150
        let cut = min(item.segment.endTime - frame, item.segment.startTime + (time - item.start) * item.segment.playbackSpeed)
        var freezeID = UUID()
        mutateSelectedEpisode { episode in
            var clips = episode.mainClips
            guard let index = clips.firstIndex(where: { $0.id == item.segment.id }) else { return }
            let original = clips[index]
            var freeze = VideoSegment(
                startTime: cut,
                endTime: cut + frame,
                sourceType: original.sourceType,
                assetID: original.assetID,
                transitionStyle: TransitionStyle.none
            )
            freeze.playbackSpeed = frame / seconds
            freeze.adjustments = original.adjustments
            freeze.clipTransform = original.clipTransform
            freeze.sequenceStart = original.sequenceStart
            freezeID = freeze.id
            var replacement: [VideoSegment] = []
            if cut - original.startTime > 0.05 {
                var first = original
                first.endTime = cut
                replacement.append(first)
            }
            replacement.append(freeze)
            if original.endTime - cut > 0.05 {
                replacement.append(original.continuation(from: cut))
            }
            clips.replaceSubrange(index...index, with: replacement)
            episode.mainClips = clips
        }
        selectedSegmentID = freezeID
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
                copy.speed = original.speed
                copy.clipTransform = original.clipTransform
                copy.adjustments = original.adjustments
                copy.sequenceStart = original.sequenceStart
                clips.insert(copy, at: index + 1)
                episode.mainClips = clips
            }
        } else if let overlay = selectedOverlay {
            var copy = overlay
            copy.id = UUID()
            copy.startTime = min(overlay.endTime, max(0, timelineDuration - copy.duration))
            saveOverlay(copy)
        } else if let element = selectedMotionElement {
            var copy = element
            copy.id = UUID()
            let latestStart: Double = max(0, timelineDuration - copy.duration)
            copy.startTime = min(element.endTime, latestStart)
            mutateSelectedEpisode(reloadPreview: false) { $0.motionElements.append(copy) }
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

    /// Episode overlays plus project-wide (repeated) ones, in this episode's timeline time.
    var resolvedOverlays: [TextOverlay] {
        selectedEpisode?.resolvedOverlays(global: project.globalOverlays) ?? []
    }

    var resolvedAudioClips: [AudioClip] {
        selectedEpisode?.resolvedAudioClips(global: project.globalAudioClips) ?? []
    }

    var selectedOverlay: TextOverlay? {
        guard let selectedSegmentID = selectedSegmentID else { return nil }
        return resolvedOverlays.first { $0.id == selectedSegmentID }
    }

    var visibleOverlays: [TextOverlay] {
        resolvedOverlays.filter {
            $0.isVisible(at: currentTime) || (!isPlaying && $0.id == selectedSegmentID)
        }
    }

    func newTextRequest() -> TextEditRequest {
        let start = min(currentTime, max(0, timelineDuration - 1))
        let duration = max(0.5, min(3, timelineDuration - start))
        return TextEditRequest(overlay: TextOverlay(text: "", startTime: start, duration: duration), isNew: true)
    }

    /// Stores an overlay given in timeline time, either in the episode or (when anchored) project-wide.
    private func store(_ overlay: TextOverlay, persist: Bool) {
        guard let episodeIndex = selectedEpisodeIndex else { return }
        episodes[episodeIndex].textOverlays.removeAll { $0.id == overlay.id }
        project.globalOverlays.removeAll { $0.id == overlay.id }
        var item = overlay
        if let anchor = overlay.anchor, let base = episodes[episodeIndex].anchorStart(anchor) {
            item.startTime = max(0, overlay.startTime - base)
            project.globalOverlays.append(item)
        } else {
            if overlay.anchor != nil {
                errorMessage = "Este episódio não tem esse clipe; o texto ficou só neste episódio."
            }
            item.anchor = nil
            episodes[episodeIndex].textOverlays.append(item)
        }
        selectedEpisode = episodes[episodeIndex]
        if persist {
            Task { await persistProjectChanges(reloadPreview: false) }
        }
    }

    func saveOverlay(_ overlay: TextOverlay) {
        checkpoint()
        store(overlay, persist: true)
        selectedSegmentID = overlay.id
    }

    func removeOverlay(_ id: UUID) {
        guard let episodeIndex = selectedEpisodeIndex else { return }
        checkpoint()
        if selectedSegmentID == id { selectedSegmentID = nil }
        episodes[episodeIndex].textOverlays.removeAll { $0.id == id }
        project.globalOverlays.removeAll { $0.id == id }
        selectedEpisode = episodes[episodeIndex]
        Task { await persistProjectChanges(reloadPreview: false) }
    }

    func moveOverlay(_ id: UUID, x: Double, y: Double, finished: Bool) {
        guard var overlay = resolvedOverlays.first(where: { $0.id == id }) else { return }
        if !isDraggingOverlay {
            isDraggingOverlay = true
            checkpoint()
        }
        selectedSegmentID = id
        overlay.positionX = x
        overlay.positionY = y
        store(overlay, persist: finished)
        if finished { isDraggingOverlay = false }
    }

    func retimeOverlay(_ id: UUID, start: Double, duration: Double) {
        guard var overlay = resolvedOverlays.first(where: { $0.id == id }) else { return }
        checkpoint()
        overlay.startTime = min(start, max(0, timelineDuration - 0.3))
        overlay.duration = max(0.3, duration)
        store(overlay, persist: true)
    }

    // MARK: Captions

    /// Word timings for text-based editing; estimated from the subtitle text when none were recognized.
    var editableTranscriptWords: [TranscriptWord] {
        let stored = project.transcriptWords ?? []
        guard let srt = project.transcriptSRT,
              let cues = try? SubtitleFile.parse(srt) else { return stored }
        let cueWords = cues.flatMap {
            $0.words.isEmpty ? TranscriptWord.spread($0.text, from: $0.startTime, to: $0.endTime) : $0.words
        }
        let cueText = normalizedTranscriptText(cues.map(\.text).joined(separator: " "))
        let storedText = normalizedTranscriptText(stored.map(\.text).joined(separator: " "))
        return stored.isEmpty || storedText != cueText ? cueWords : stored
    }

    private func normalizedTranscriptText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func saveTranscriptWords(_ words: [TranscriptWord]) {
        project.transcriptWords = words
        project.transcriptSequenceDuration = project.sequenceSourceDuration
        Task { await persistProjectChanges(reloadPreview: false) }
    }

    func saveTranscript(_ text: String) {
        project.transcriptSRT = text
        project.transcriptSequenceDuration = project.sequenceSourceDuration
        transcriptSaveTask?.cancel()
        transcriptSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self = self, !Task.isCancelled else { return }
            await self.persistProjectChanges(reloadPreview: false)
        }
    }

    func saveTranscriptionVocabulary(_ terms: [String]) {
        project.transcriptionVocabulary = terms.isEmpty ? nil : terms
        transcriptSaveTask?.cancel()
        transcriptSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self = self, !Task.isCancelled else { return }
            await self.persistProjectChanges(reloadPreview: false)
        }
    }

    /// Applies a reviewed transcript correction and refreshes caption overlays in place.
    func applyCorrectedTranscript(_ srt: String, words: [TranscriptWord]) {
        project.transcriptSRT = srt
        project.transcriptWords = words
        project.transcriptSequenceDuration = project.sequenceSourceDuration
        transcriptSaveTask?.cancel()
        let hasCaptions = episodes.contains {
            $0.textOverlays.contains { $0.isCaption == true }
        }
        guard hasCaptions, let cues = try? SubtitleFile.parse(srt) else {
            Task { await persistProjectChanges(reloadPreview: false) }
            return
        }
        let dynamic = episodes.contains {
            $0.textOverlays.contains { $0.isCaption == true && !($0.words?.isEmpty ?? true) }
        }
        checkpoint()
        applyCaptions(cues, dynamic: dynamic, recordUndo: false)
    }

    /// Converts transcript cues (timed in the concatenated source sequence) into caption
    /// overlays in every episode, following each main clip's position on that timeline.
    func applyCaptions(_ cues: [TranscriptCue], dynamic: Bool = false, recordUndo: Bool = true, episodeIDs: Set<UUID>? = nil) {
        if recordUndo { checkpoint() }
        let words = project.transcriptWords ?? []
        var total = 0
        for index in episodes.indices {
            if let episodeIDs = episodeIDs, !episodeIDs.contains(episodes[index].id) { continue }
            var overlays = episodes[index].textOverlays.filter { $0.isCaption != true }
            for item in episodes[index].storyline() where item.track == .main {
                let clip = item.segment
                guard !clip.isFreezeFrame else { continue }
                let sourceStart = clip.sequenceStartTime + clip.startTime
                let sourceEnd = clip.sequenceStartTime + clip.endTime
                let speed = clip.playbackSpeed
                func timeline(_ source: Double) -> Double { item.start + (source - sourceStart) / speed }
                for cue in cues where cue.endTime > sourceStart && cue.startTime < sourceEnd {
                    let start = max(cue.startTime, sourceStart)
                    let end = min(cue.endTime, sourceEnd)
                    guard end - start >= 0.2 else { continue }
                    // Keep words with a meaningful part inside the clip (cuts remove whole words plus padding).
                    let cueWords = Self.words(for: cue, recognized: words).filter { word in
                        let overlap = min(word.end, sourceEnd) - max(word.start, sourceStart)
                        return overlap > min(0.08, (word.end - word.start) / 2)
                    }
                    if dynamic {
                        for group in Self.captionGroups(cueWords) {
                            let groupStart = max(group[0].start, sourceStart)
                            let groupEnd = min(group[group.count - 1].end, sourceEnd)
                            guard groupEnd > groupStart else { continue }
                            var overlay = Self.captionOverlay(
                                text: group.map(\.text).joined(separator: " "),
                                start: timeline(groupStart),
                                duration: max(0.2, (groupEnd - groupStart) / speed)
                            )
                            overlay.words = group.map { word in
                                TranscriptWord(
                                    text: word.text,
                                    start: (max(word.start, groupStart) - groupStart) / speed,
                                    end: (min(word.end, groupEnd) - groupStart) / speed
                                )
                            }
                            overlays.append(overlay)
                            total += 1
                        }
                    } else {
                        // A cue split by a cut only shows the words that remain in this clip.
                        let isWhole = cue.startTime >= sourceStart && cue.endTime <= sourceEnd
                        let text = isWhole ? cue.text : cueWords.map(\.text).joined(separator: " ")
                        guard !text.isEmpty else { continue }
                        overlays.append(Self.captionOverlay(text: text, start: timeline(start), duration: (end - start) / speed))
                        total += 1
                    }
                }
            }
            episodes[index].textOverlays = overlays
        }
        if let index = selectedEpisodeIndex { selectedEpisode = episodes[index] }
        if total == 0 {
            errorMessage = "Nenhuma legenda caiu dentro do conteúdo principal dos episódios."
        }
        Task { await persistProjectChanges(reloadPreview: false) }
    }

    /// Recognized words of a cue, or estimated ones when the cue text was edited after transcribing.
    static func words(for cue: TranscriptCue, recognized: [TranscriptWord]) -> [TranscriptWord] {
        let inside = recognized.filter { word in
            let middle = (word.start + word.end) / 2
            return middle >= cue.startTime && middle < cue.endTime
        }
        func normalized(_ text: String) -> String {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        if !inside.isEmpty, normalized(inside.map(\.text).joined(separator: " ")) == normalized(cue.text) {
            return inside
        }
        return TranscriptWord.spread(cue.text, from: cue.startTime, to: cue.endTime)
    }

    /// Short punchy groups for dynamic captions: up to 3 words, split on pauses and sentence ends.
    static func captionGroups(_ words: [TranscriptWord]) -> [[TranscriptWord]] {
        var groups: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []
        for word in words {
            if let last = current.last,
               current.count >= 3 || word.start - last.end > 0.5
                || last.text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?,")) != nil {
                groups.append(current)
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private static func captionOverlay(text: String, start: Double, duration: Double) -> TextOverlay {
        TextOverlay(
            text: text,
            startTime: start,
            duration: duration,
            positionX: 0.5,
            positionY: 0.86,
            fontScale: 0.05,
            color: .white,
            style: .box,
            isBold: false,
            isCaption: true
        )
    }

    // MARK: Audio

    var selectedAudioClip: AudioClip? {
        guard let selectedSegmentID = selectedSegmentID else { return nil }
        return resolvedAudioClips.first { $0.id == selectedSegmentID }
    }

    func audioAsset(for clip: AudioClip) -> MediaAsset? {
        mediaAssets.first { $0.id == clip.assetID }
    }

    /// Stores a clip given in timeline time, either in the episode or (when anchored) project-wide.
    private func store(_ clip: AudioClip) {
        guard let episodeIndex = selectedEpisodeIndex else { return }
        episodes[episodeIndex].audioClips.removeAll { $0.id == clip.id }
        project.globalAudioClips.removeAll { $0.id == clip.id }
        var item = clip
        if let anchor = clip.anchor, let base = episodes[episodeIndex].anchorStart(anchor) {
            item.timelineStart = max(0, clip.timelineStart - base)
            project.globalAudioClips.append(item)
        } else {
            if clip.anchor != nil {
                errorMessage = "Este episódio não tem esse clipe; o áudio ficou só neste episódio."
            }
            item.anchor = nil
            episodes[episodeIndex].audioClips.append(item)
        }
        selectedEpisode = episodes[episodeIndex]
        Task { await persistProjectChanges() }
    }

    func addAudio(_ asset: MediaAsset, kind: AudioClipKind, anchor: ClipAnchor?, atPlayhead: Bool) {
        guard asset.duration > 0 else {
            errorMessage = "Esse arquivo de áudio não tem duração válida."
            return
        }
        var start = atPlayhead ? currentTime : 0
        if !atPlayhead, let anchor = anchor, let base = selectedEpisode?.anchorStart(anchor) {
            start = base
        }
        let clip = AudioClip(
            assetID: asset.id,
            name: asset.name,
            kind: kind,
            timelineStart: start,
            sourceStart: 0,
            sourceEnd: asset.duration,
            volume: kind == .music ? 0.5 : 1,
            fadeIn: 0,
            fadeOut: kind == .music && asset.duration > 6 ? 2 : 0,
            anchor: anchor
        )
        checkpoint()
        store(clip)
        selectedSegmentID = clip.id
    }

    func updateAudioClip(_ clip: AudioClip) {
        checkpoint()
        store(clip)
    }

    func removeAudioClip(_ id: UUID) {
        guard let episodeIndex = selectedEpisodeIndex else { return }
        checkpoint()
        if selectedSegmentID == id { selectedSegmentID = nil }
        episodes[episodeIndex].audioClips.removeAll { $0.id == id }
        project.globalAudioClips.removeAll { $0.id == id }
        selectedEpisode = episodes[episodeIndex]
        Task { await persistProjectChanges() }
    }

    func splitAudioClip(_ id: UUID) {
        guard var clip = resolvedAudioClips.first(where: { $0.id == id }) else { return }
        let offset = currentTime - clip.timelineStart
        guard offset > 0.1, offset < clip.duration - 0.1 else {
            errorMessage = "Posicione o cursor dentro do áudio (a pelo menos 0,1s das bordas) para dividir."
            return
        }
        var second = clip
        second.id = UUID()
        clip.sourceEnd = clip.sourceStart + offset
        clip.fadeOut = 0
        second.sourceStart = clip.sourceEnd
        second.fadeIn = 0
        second.timelineStart = clip.timelineStart + offset
        updateAudioClip(clip)
        store(second)
        selectedSegmentID = second.id
    }

    func moveAudioClipToPlayhead(_ id: UUID) {
        guard var clip = resolvedAudioClips.first(where: { $0.id == id }) else { return }
        clip.timelineStart = currentTime
        updateAudioClip(clip)
    }

    // MARK: Media overlays (picture-in-picture)

    var selectedMediaOverlay: MediaOverlay? {
        guard let selectedSegmentID = selectedSegmentID else { return nil }
        return selectedEpisode?.mediaOverlays.first { $0.id == selectedSegmentID }
    }

    var visibleMediaOverlays: [MediaOverlay] {
        (selectedEpisode?.mediaOverlays ?? []).filter {
            $0.isVisible(at: currentTime) || (!isPlaying && $0.id == selectedSegmentID)
        }
    }

    func mediaAspect(for overlay: MediaOverlay) -> CGFloat {
        guard let size = mediaAssets.first(where: { $0.id == overlay.assetID })?.naturalSize.cgSize,
              size.width > 0, size.height > 0 else { return 16 / 9 }
        return size.width / size.height
    }

    func addMediaOverlay(_ asset: MediaAsset) {
        guard asset.type == .video || asset.type == .image else { return }
        let isVideo = asset.type == .video
        let start = min(currentTime, max(0, timelineDuration - 0.5))
        let remaining = max(0.5, timelineDuration - start)
        let overlay = MediaOverlay(
            assetID: asset.id,
            name: asset.name,
            isVideo: isVideo,
            startTime: start,
            duration: isVideo ? min(max(asset.duration, 0.5), remaining) : min(3, remaining)
        )
        mutateSelectedEpisode(reloadPreview: isVideo) { $0.mediaOverlays.append(overlay) }
        selectedSegmentID = overlay.id
    }

    func updateMediaOverlay(_ overlay: MediaOverlay) {
        mutateSelectedEpisode(reloadPreview: overlay.isVideo) { episode in
            if let index = episode.mediaOverlays.firstIndex(where: { $0.id == overlay.id }) {
                episode.mediaOverlays[index] = overlay
            }
        }
    }

    func removeMediaOverlay(_ id: UUID) {
        let isVideo = selectedEpisode?.mediaOverlays.first { $0.id == id }?.isVideo ?? false
        if selectedSegmentID == id { selectedSegmentID = nil }
        mutateSelectedEpisode(reloadPreview: isVideo) { $0.mediaOverlays.removeAll { $0.id == id } }
    }

    func moveMediaOverlay(_ id: UUID, x: Double, y: Double, finished: Bool) {
        guard let episodeIndex = selectedEpisodeIndex,
              let index = episodes[episodeIndex].mediaOverlays.firstIndex(where: { $0.id == id }) else { return }
        if !isDraggingOverlay {
            isDraggingOverlay = true
            checkpoint()
        }
        selectedSegmentID = id
        episodes[episodeIndex].mediaOverlays[index].centerX = x
        episodes[episodeIndex].mediaOverlays[index].centerY = y
        selectedEpisode = episodes[episodeIndex]
        if finished {
            isDraggingOverlay = false
            let isVideo = episodes[episodeIndex].mediaOverlays[index].isVideo
            Task { await persistProjectChanges(reloadPreview: isVideo) }
        }
    }

    func retimeMediaOverlay(_ id: UUID, move: Double, left: Double, right: Double) {
        guard var overlay = selectedEpisode?.mediaOverlays.first(where: { $0.id == id }) else { return }
        let assetDuration = mediaAssets.first { $0.id == overlay.assetID }?.duration ?? overlay.duration
        var trim = min(left, overlay.duration - 0.3)
        if overlay.isVideo { trim = max(trim, -overlay.sourceStart) }
        overlay.startTime = max(0, overlay.startTime + move + trim)
        if overlay.isVideo { overlay.sourceStart += trim }
        var duration = max(0.3, overlay.duration - trim + right)
        if overlay.isVideo { duration = min(duration, max(0.3, assetDuration - overlay.sourceStart)) }
        overlay.duration = duration
        updateMediaOverlay(overlay)
    }

    // MARK: Motion elements

    var selectedMotionElement: MotionElement? {
        guard let selectedSegmentID = selectedSegmentID else { return nil }
        return selectedEpisode?.motionElements.first { $0.id == selectedSegmentID }
    }

    var visibleMotionElements: [MotionElement] {
        (selectedEpisode?.motionElements ?? []).filter {
            $0.isVisible(at: currentTime) || (!isPlaying && $0.id == selectedSegmentID)
        }
    }

    func addMotionElement(_ element: MotionElement) {
        var item = element
        let latestStart: Double = max(0, timelineDuration - 0.3)
        item.startTime = min(currentTime, latestStart)
        let availableDuration: Double = max(0.3, timelineDuration - item.startTime)
        item.duration = max(0.3, min(item.duration, availableDuration))
        mutateSelectedEpisode(reloadPreview: false) { $0.motionElements.append(item) }
        selectedSegmentID = item.id
    }

    func updateMotionElement(_ element: MotionElement) {
        mutateSelectedEpisode(reloadPreview: false) { episode in
            if let index = episode.motionElements.firstIndex(where: { $0.id == element.id }) {
                episode.motionElements[index] = element
            }
        }
    }

    func removeMotionElement(_ id: UUID) {
        if selectedSegmentID == id { selectedSegmentID = nil }
        mutateSelectedEpisode(reloadPreview: false) { $0.motionElements.removeAll { $0.id == id } }
    }

    func moveMotionElement(_ id: UUID, x: Double, y: Double, finished: Bool) {
        guard let episodeIndex = selectedEpisodeIndex,
              let index = episodes[episodeIndex].motionElements.firstIndex(where: { $0.id == id }) else { return }
        if !isDraggingOverlay {
            isDraggingOverlay = true
            checkpoint()
        }
        selectedSegmentID = id
        episodes[episodeIndex].motionElements[index].centerX = x
        episodes[episodeIndex].motionElements[index].centerY = y
        selectedEpisode = episodes[episodeIndex]
        if finished {
            isDraggingOverlay = false
            Task { await persistProjectChanges(reloadPreview: false) }
        }
    }

    func retimeMotionElement(_ id: UUID, start: Double, duration: Double) {
        guard var element = selectedEpisode?.motionElements.first(where: { $0.id == id }) else { return }
        let durationDifference: Double = abs(duration - element.duration)
        let moveTolerance: Double = 0.001
        if durationDifference < moveTolerance {
            let latestMoveStart: Double = max(0, timelineDuration - element.duration)
            element.startTime = min(max(0, start), latestMoveStart)
        } else {
            let latestTrimStart: Double = max(0, timelineDuration - 0.3)
            element.startTime = min(max(0, start), latestTrimStart)
            let availableDuration: Double = max(0.3, timelineDuration - element.startTime)
            element.duration = max(0.3, min(duration, availableDuration))
        }
        updateMotionElement(element)
    }

    func dropAsset(_ id: UUID, on track: TrackType, at time: Double) {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        seek(to: time)
        switch asset.type {
        case .audio:
            addAudio(asset, kind: .music, anchor: nil, atPlayhead: true)
        case .image:
            addMediaOverlay(asset)
        case .video:
            if track == .overlay {
                addMediaOverlay(asset)
            } else if track == .main {
                insertClip(asset, selection: ClipSelection(startTime: 0, endTime: asset.duration))
            } else {
                errorMessage = "Solte vídeos na faixa de vídeo ou na faixa PiP."
            }
        }
    }

    /// Inserts a library video into the main sequence, after the clip under the playhead.
    func insertClip(_ asset: MediaAsset, selection: ClipSelection) {
        guard asset.type == .video else { return }
        let start = max(0, min(selection.startTime, asset.duration))
        let end = max(start, min(selection.endTime, asset.duration))
        guard end - start >= 0.1 else {
            errorMessage = "O trecho escolhido é curto demais."
            return
        }
        if let narration = selection.narration, !mediaAssets.contains(where: { $0.id == narration.id }) {
            mediaAssets.append(narration)
        }
        let time = currentTime
        var clip = VideoSegment(
            startTime: start,
            endTime: end,
            sourceType: .clipAsset,
            assetID: asset.id,
            narrationAssetID: selection.narration?.id,
            volume: selection.clipVolume < 0.999 ? selection.clipVolume : nil
        )
        mutateSelectedEpisode { episode in
            clip.sequenceStart = project.registerSourceClip(for: asset)
            var clips = episode.mainClips
            let current = episode.storyline().last { $0.track == .main && $0.start <= time }
            let index = current.flatMap { item in clips.firstIndex { $0.id == item.segment.id } }.map { $0 + 1 } ?? clips.count
            clips.insert(clip, at: min(index, clips.count))
            episode.mainClips = clips
        }
        selectedSegmentID = clip.id
    }

    // MARK: Narration

    func narrationRecordingChanged(_ recording: Bool, segment: TimelineSegment?) {
        guard let player = previewPlayer else { return }
        if recording {
            if let segment = segment {
                seek(to: segment.startTime)
            }
            narrationStartTime = currentTime
            player.isMuted = true
            player.play()
            isPlaying = true
        } else {
            player.pause()
            player.isMuted = previewMuted
            isPlaying = false
            if let narrationStartTime = narrationStartTime { seek(to: narrationStartTime) }
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
                episode.modifySegment(id: segment.id) { video in
                    video.narrationAssetID = asset.id
                    video.narrationOffset = nil
                }
            }
        }
    }

    private var selectedEpisodeIndex: Int? {
        guard let selectedEpisode = selectedEpisode else { return nil }
        return episodes.firstIndex { $0.id == selectedEpisode.id }
    }

    private func persistProjectChanges(reloadPreview: Bool = true) async {
        for index in episodes.indices {
            episodes[index].normalizeCustomTemplates()
        }
        project.episodes = episodes
        project.mediaAssets = mediaAssets
        project.aspectRatio = exportSettings.aspectRatio
        project.resolution = exportSettings.resolution
        project.fitMode = exportSettings.fitMode
        project.coverSettings = CoverSettings(
            enabled: exportSettings.includeCovers,
            mode: exportSettings.coverMode,
            templateName: "Padrão",
            captureTime: exportSettings.coverCaptureTime,
            customImageAssetID: exportSettings.coverImageAssetID
        )
        do {
            try await storage.saveProject(project)
        } catch {
            errorMessage = "Erro ao salvar projeto: \(Self.describe(error))"
        }
        refreshSelectedEpisode(reloadPreview: reloadPreview)
    }

    private func refreshSelectedEpisode(reloadPreview: Bool = true) {
        guard let selectedEpisode = selectedEpisode else {
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
        if let selectedSegmentID = selectedSegmentID,
           !orderedSegments.contains(where: { $0.id == selectedSegmentID }),
           !episode.resolvedOverlays(global: project.globalOverlays).contains(where: { $0.id == selectedSegmentID }),
           !episode.resolvedAudioClips(global: project.globalAudioClips).contains(where: { $0.id == selectedSegmentID }),
           !episode.mediaOverlays.contains(where: { $0.id == selectedSegmentID }),
           !episode.motionElements.contains(where: { $0.id == selectedSegmentID }) {
            self.selectedSegmentID = nil
        }
        durationString = timeString(timelineDuration)
    }

    // MARK: Preview

    func reloadPreview() {
        guard let selectedEpisode = selectedEpisode else { return }
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
            guard let self = self else { return }
            do {
                let output = try await self.timelineEngine.buildPreviewComposition(
                    project: projectSnapshot,
                    episode: episode,
                    additionalAssets: assetURLs
                )
                guard generation == self.previewGeneration, !Task.isCancelled else { return }
                let playerItem = AVPlayerItem(asset: output.composition)
                playerItem.audioTimePitchAlgorithm = .spectral
                playerItem.videoComposition = output.videoComposition
                playerItem.audioMix = output.audioMix
                let player = AVPlayer(playerItem: playerItem)
                self.configurePreviewAudioSession()
                self.applyPreviewAudioSettings(to: player)
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

    private func configurePreviewAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    private func applyPreviewAudioSettings(to player: AVPlayer) {
        player.volume = max(0, min(1, previewVolume))
        player.isMuted = previewMuted
    }

    func togglePreviewMute() {
        previewMuted.toggle()
        previewPlayer?.isMuted = previewMuted
    }

    func setPreviewVolume(_ value: Float) {
        previewVolume = max(0, min(1, value))
        if previewVolume > 0.001 {
            previewMuted = false
            previewPlayer?.isMuted = false
        }
        previewPlayer?.volume = previewVolume
    }

    private func setupTimeObserver(for player: AVPlayer) {
        if let timeObserver = timeObserver, let timeObserverPlayer = timeObserverPlayer {
            timeObserverPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self, weak player] time in
            Task { @MainActor [weak self, weak player] in
                guard let self = self, let player = player, player === self.previewPlayer else { return }
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

    // MARK: Markers

    private var markerAtPlayhead: TimelineMarker? {
        selectedEpisode?.markers.first { abs($0.time - currentTime) < 0.25 }
    }

    var isOnMarker: Bool { markerAtPlayhead != nil }

    func toggleMarker() {
        let time = currentTime
        if let marker = markerAtPlayhead {
            mutateSelectedEpisode(reloadPreview: false) { $0.markers.removeAll { $0.id == marker.id } }
        } else {
            mutateSelectedEpisode(reloadPreview: false) { $0.markers.append(TimelineMarker(time: time)) }
        }
    }

    func jumpToMarker(forward: Bool) {
        let times = selectedEpisode?.markers.map(\.time) ?? []
        let target: Double?
        if forward {
            target = times.first { $0 > currentTime + 0.05 }
        } else {
            target = times.last { $0 < currentTime - 0.05 }
        }
        if let target = target { seek(to: target) }
    }

    /// Markers surrounding the playhead; the main content between them can be ripple-deleted.
    var rippleRange: ClosedRange<Double>? {
        let times = selectedEpisode?.markers.map(\.time) ?? []
        guard let lower = times.last(where: { $0 <= currentTime + 0.05 }),
              let upper = times.first(where: { $0 > currentTime + 0.05 }),
              upper - lower > 0.1 else { return nil }
        return lower...upper
    }

    /// Removes the main content between the markers around the playhead and closes the gap.
    func rippleDeleteBetweenMarkers() {
        guard let range = rippleRange, let episode = selectedEpisode else { return }
        let items = episode.storyline().filter { $0.track == .main }
        var touched = false
        var emptied = false
        mutateSelectedEpisode { episode in
            var result: [VideoSegment] = []
            for clip in episode.mainClips {
                guard let item = items.first(where: { $0.segment.id == clip.id }),
                      item.end > range.lowerBound, item.start < range.upperBound else {
                    result.append(clip)
                    continue
                }
                touched = true
                let speed = clip.playbackSpeed
                if range.lowerBound - item.start > 0.05 {
                    var left = clip
                    left.endTime = clip.startTime + (range.lowerBound - item.start) * speed
                    result.append(left)
                }
                if item.end - range.upperBound > 0.05 {
                    result.append(clip.continuation(from: clip.startTime + (range.upperBound - item.start) * speed))
                }
            }
            guard touched else { return }
            guard !result.isEmpty else {
                emptied = true
                return
            }
            episode.mainClips = result
            Self.closeGaps(in: &episode, removing: [range])
        }
        if !touched {
            errorMessage = "Não há conteúdo principal entre os marcadores."
        } else if emptied {
            errorMessage = "Não é possível remover todo o conteúdo principal do episódio."
        } else {
            seek(to: range.lowerBound)
        }
    }

    /// Shifts episode text, audio, PiP and markers left over removed timeline intervals,
    /// dropping the items that fell inside them.
    static func closeGaps(in episode: inout Episode, removing intervals: [ClosedRange<Double>]) {
        for range in intervals.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            let removed = range.upperBound - range.lowerBound
            func shifted(_ start: Double, _ duration: Double) -> Double? {
                if start + duration <= range.lowerBound + 0.001 { return start }
                if start >= range.upperBound - 0.001 { return start - removed }
                return nil
            }
            episode.textOverlays = episode.textOverlays.compactMap { item in
                guard let start = shifted(item.startTime, item.duration) else { return nil }
                var moved = item
                moved.startTime = start
                return moved
            }
            episode.audioClips = episode.audioClips.compactMap { item in
                guard let start = shifted(item.timelineStart, item.duration) else { return nil }
                var moved = item
                moved.timelineStart = start
                return moved
            }
            episode.mediaOverlays = episode.mediaOverlays.compactMap { item in
                guard let start = shifted(item.startTime, item.duration) else { return nil }
                var moved = item
                moved.startTime = start
                return moved
            }
            episode.motionElements = episode.motionElements.compactMap { item in
                guard let start = shifted(item.startTime, item.duration) else { return nil }
                var moved = item
                moved.startTime = start
                return moved
            }
            episode.markers = episode.markers.compactMap { marker in
                guard let time = shifted(marker.time, 0) else { return nil }
                var moved = marker
                moved.time = time
                return moved
            }
        }
    }

    /// Adds markers at topic boundaries (already timeline-relative times are not needed here:
    /// Editar fala reports source times, so convert through the episode layout).
    func markTimes(_ sourceTimes: [Double]) {
        guard let episode = selectedEpisode else { return }
        var times: [Double] = []
        for item in episode.storyline() where item.track == .main {
            let clip = item.segment
            let sourceStart = clip.sequenceStartTime + clip.startTime
            let sourceEnd = clip.sequenceStartTime + clip.endTime
            for source in sourceTimes where sourceStart <= source && source < sourceEnd {
                times.append(item.start + (source - sourceStart) / clip.playbackSpeed)
            }
        }
        guard !times.isEmpty else {
            errorMessage = "Os limites detectados não caem no conteúdo principal deste episódio."
            return
        }
        mutateSelectedEpisode(reloadPreview: false) { ep in
            for time in times { ep.markers.append(TimelineMarker(time: time)) }
        }
    }

    /// "Criar episódios": sequential series covering the whole video, with optional
    /// part cards, intro/outro vinhetas and "Anteriormente" recaps.
    func createSequentialEpisodes(cuts: [Double], request: AutomationRequest) {
        checkpoint()
        let plan = request.episodePlan
        let seriesInput = plan.seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seriesInput.isEmpty {
            project.seriesTitle = seriesInput
        }
        project.recapSettings = RecapSettings(enabled: plan.recap, mode: .automatic, duration: plan.recapDuration)
        project.introTemplate = vinhetaTemplate(for: plan.intro, track: .intro)
        project.outroTemplate = vinhetaTemplate(for: plan.outro, track: .outro)
        project.createSequentialEpisodes(at: cuts)
        episodes = project.episodes
        let format = request.formats.first ?? .original
        if format != .original {
            for index in episodes.indices {
                episodes[index].outputAspectRatio = format
            }
        }
        exportSettings.includeCovers = request.generateCovers
        project.coverSettings.enabled = request.generateCovers

        let series = !seriesInput.isEmpty
            ? seriesInput
            : (project.seriesTitle != "Minha Série" ? project.seriesTitle : project.name)
        let count = episodes.count
        for index in episodes.indices {
            let storyline = episodes[index].storyline()
            guard let mainStart = storyline.first(where: { $0.track == .main })?.start,
                  let mainEnd = storyline.last(where: { $0.track == .main })?.end else { continue }
            let mainLength = max(0.1, mainEnd - mainStart)
            var overlays = episodes[index].textOverlays
            if plan.introCard {
                let text = EpisodePlanSettings.cardText(plan.introCardText, index: index, count: count, series: series, prependSeries: plan.showSeriesTitle)
                if let introItem = storyline.first(where: { $0.track == .intro }) {
                    overlays.append(partCard(plan: plan, text: text, start: introItem.start, duration: max(1.5, introItem.end - introItem.start)))
                } else {
                    overlays.append(partCard(plan: plan, text: text, start: mainStart, duration: min(3, mainLength / 3)))
                }
            }
            if plan.recap, index > 0, let recapItem = storyline.first(where: { $0.track == .recap }) {
                overlays.append(partCard(plan: plan, text: "Anteriormente…", start: recapItem.start, duration: max(0.5, recapItem.end - recapItem.start), positionY: 0.12))
            }
            if plan.outroCard {
                let isLast = index == count - 1
                if !isLast || plan.finalCard {
                    let text = EpisodePlanSettings.cardText(
                        isLast ? plan.finalCardText : plan.outroCardText,
                        index: index,
                        count: count,
                        series: series,
                        prependSeries: false
                    )
                    if let outroItem = storyline.first(where: { $0.track == .outro }) {
                        overlays.append(partCard(plan: plan, text: text, start: outroItem.start, duration: max(1.5, outroItem.end - outroItem.start)))
                    } else {
                        let cardLength = min(3, mainLength / 3)
                        overlays.append(partCard(plan: plan, text: text, start: mainEnd - cardLength, duration: cardLength))
                    }
                }
            }
            episodes[index].textOverlays = overlays
        }
        if request.captions.enabled, let srt = project.transcriptSRT, let cues = try? SubtitleFile.parse(srt) {
            applyCaptions(cues, dynamic: request.captions.dynamic, recordUndo: false)
        }
        if let first = episodes.first { selectedEpisode = first }
        Task { await persistProjectChanges() }
    }

    private func vinhetaTemplate(for choice: VinhetaChoice?, track: TrackType) -> SegmentTemplate? {
        guard let choice = choice,
              let asset = mediaAssets.first(where: { $0.id == choice.assetID && $0.type == .video }) else { return nil }
        var template = SegmentTemplate(
            name: asset.name,
            sourceType: track == .intro ? .introAsset : .outroAsset,
            assetID: asset.id,
            startTime: max(0, min(choice.start, asset.duration)),
            endTime: max(0, min(choice.end, asset.duration)),
            targetTrack: track
        )
        template.clipVolume = choice.clipVolume
        return template
    }

    private func partCard(plan: EpisodePlanSettings, text: String, start: Double, duration: Double,
                          positionY: Double? = nil) -> TextOverlay {
        var overlay = TextOverlay(text: text, startTime: start, duration: max(0.5, duration))
        overlay.positionY = positionY ?? plan.cardPosition.positionY
        overlay.fontScale = plan.cardSize.fontScale
        overlay.style = plan.cardStyle
        overlay.color = plan.cardColor.rgba
        overlay.animation = .fade
        overlay.exitAnimation = .fade
        return overlay
    }

    /// "Multiplicar conteúdo": one output per (moment, platform), titled "Momento N • Plataforma".
    func createMomentOutputs(_ suggestions: [ClipSuggestion], request: AutomationRequest) {
        guard !suggestions.isEmpty else { return }
        let platforms = request.platforms.isEmpty ? [PublishPlatform.vertical] : request.platforms
        checkpoint()
        var selected: Episode?
        var nextIndex = (episodes.map(\.index).max() ?? -1) + 1
        var momentCount = 0
        for episode in episodes where episode.displayTitle?.hasPrefix("Momento") == true {
            let suffix = episode.displayTitle?.dropFirst("Momento".count).trimmingCharacters(in: .whitespaces) ?? ""
            let number = Int(suffix.prefix { $0.isNumber }) ?? 0
            momentCount = max(momentCount, number)
        }
        exportSettings.includeCovers = request.generateCovers
        project.coverSettings.enabled = request.generateCovers
        let sequenceDuration = project.sequenceSourceDuration
        var newEpisodeIDs = Set<UUID>()
        var framedIDs = Set<UUID>()
        for suggestion in suggestions.sorted(by: { $0.start < $1.start }) {
            let start = max(0, min(suggestion.start, sequenceDuration))
            let end = max(start, min(suggestion.end, sequenceDuration))
            guard end - start > 0.2 else { continue }
            momentCount += 1
            for platform in platforms {
                var mainPieces = project.sourceSegments(in: start...end)
                guard !mainPieces.isEmpty else { continue }
                if request.autoFraming && platform != .youtube {
                    for index in mainPieces.indices {
                        var adjustments = mainPieces[index].clipAdjustments
                        adjustments.autoFraming = true
                        mainPieces[index].clipAdjustments = adjustments
                    }
                }
                for index in mainPieces.indices {
                    mainPieces[index].transition = .none
                }
                var episode = Episode(
                    index: nextIndex,
                    mainStart: start,
                    mainEnd: end,
                    introTemplate: nil,
                    outroTemplate: nil,
                    recapSettings: RecapSettings(enabled: false)
                )
                episode.mainClips = mainPieces
                episode.outputAspectRatio = platform.aspectRatio
                episode.displayTitle = "Momento \(momentCount) • \(platform.shortName)"
                episode.useGlobalIntro = false
                episode.useGlobalOutro = false
                episode.useGlobalRecap = false
                episodes.append(episode)
                newEpisodeIDs.insert(episode.id)
                if platform != .youtube { framedIDs.insert(episode.id) }
                selected = episode
                nextIndex += 1
            }
        }
        guard let selected = selected else { return }
        selectedEpisode = selected
        if request.captions.enabled, let srt = project.transcriptSRT, let cues = try? SubtitleFile.parse(srt) {
            let landscapeIDs = newEpisodeIDs.subtracting(framedIDs)
            if !framedIDs.isEmpty {
                applyCaptions(cues, dynamic: request.captions.dynamic, recordUndo: false, episodeIDs: framedIDs)
            }
            if !landscapeIDs.isEmpty {
                applyCaptions(cues, dynamic: false, recordUndo: false, episodeIDs: landscapeIDs)
            }
        }
        Task { await persistProjectChanges() }
    }

    /// "Editar com IA": one new episode per validated output (segments of the source
    /// sequence, optional vinhetas/cards/captions). `operations` plans are applied
    /// in place over the existing episodes by `applyClipPlanOperations`.
    /// Returns the number of episodes created / operations applied.
    @discardableResult
    func applyClipPlan(_ plan: ClipPlan, brief: ClipBrief?) -> Int {
        if let outputs = plan.normalized().outputs, !outputs.isEmpty {
            let errors = ClipPlanValidator.validate(plan.normalized(), project: currentProject)
            guard errors.isEmpty else {
                errorMessage = ClipPlanExecutor.validationFailed(errors)
                return 0
            }
            checkpoint()
            var selected: Episode?
            var nextIndex = (episodes.map(\.index).max() ?? -1) + 1
            var aiCount = 0
            for episode in episodes where episode.displayTitle?.hasPrefix("IA ") == true {
                let suffix = episode.displayTitle?.dropFirst("IA ".count).trimmingCharacters(in: .whitespaces) ?? ""
                aiCount = max(aiCount, Int(suffix.prefix { $0.isNumber }) ?? 0)
            }
            let sequenceDuration = project.sequenceSourceDuration
            var newEpisodeIDs = Set<UUID>()
            var dynamicCaptionIDs = Set<UUID>()
            var staticCaptionIDs = Set<UUID>()
            for output in outputs {
                let merged = ClipPlanExecutor.mergedSourceRanges(of: output, sequenceDuration: sequenceDuration)
                guard !merged.isEmpty else { continue }
                var mainPieces: [VideoSegment] = []
                for range in merged {
                    mainPieces.append(contentsOf: project.sourceSegments(in: range))
                }
                guard !mainPieces.isEmpty else { continue }
                let format = Self.planAspectRatio(output.format)
                if output.auto_framing == true && format != .landscape16_9 {
                    for index in mainPieces.indices {
                        var adjustments = mainPieces[index].clipAdjustments
                        adjustments.autoFraming = true
                        mainPieces[index].clipAdjustments = adjustments
                    }
                }
                for index in mainPieces.indices {
                    mainPieces[index].transition = .none
                }
                var episode = Episode(
                    index: nextIndex,
                    mainStart: merged.first?.lowerBound ?? 0,
                    mainEnd: merged.last?.upperBound ?? 0,
                    introTemplate: nil,
                    outroTemplate: nil,
                    recapSettings: RecapSettings(enabled: false)
                )
                episode.mainClips = mainPieces
                episode.outputAspectRatio = format == .original ? nil : format
                aiCount += 1
                let trimmedTitle = (output.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                episode.displayTitle = trimmedTitle.isEmpty ? "IA \(aiCount)" : String(trimmedTitle.prefix(80))
                episode.useGlobalIntro = false
                episode.useGlobalOutro = false
                episode.useGlobalRecap = false
                if let intro = output.intro,
                   let assetID = UUID(uuidString: intro.asset_id),
                   let template = vinhetaTemplate(
                       for: VinhetaChoice(
                           assetID: assetID,
                           start: Double(intro.in_ms) / 1000,
                           end: Double(intro.out_ms) / 1000
                       ),
                       track: .intro
                   ) {
                    episode.customIntroTemplate = template
                }
                if let outro = output.outro,
                   let assetID = UUID(uuidString: outro.asset_id),
                   let template = vinhetaTemplate(
                       for: VinhetaChoice(
                           assetID: assetID,
                           start: Double(outro.in_ms) / 1000,
                           end: Double(outro.out_ms) / 1000
                       ),
                       track: .outro
                   ) {
                    episode.customOutroTemplate = template
                }
                var overlays: [TextOverlay] = []
                let anchorRanges = ClipPlanExecutor.cumulativeRanges(of: merged)
                let outputDuration = ClipPlanExecutor.outputDuration(output, sequenceDuration: sequenceDuration)
                for spec in output.texts ?? [] {
                    let start = ClipPlanExecutor.resolveStart(
                        startMs: spec.start_ms,
                        atSegment: spec.at_segment,
                        at: spec.at,
                        anchorRanges: anchorRanges,
                        timelineDuration: outputDuration
                    )
                    overlays.append(Self.planTextOverlay(spec, start: start))
                }
                episode.textOverlays = overlays
                episodes.append(episode)
                newEpisodeIDs.insert(episode.id)
                if output.captions?.enabled == true {
                    if (output.captions?.style ?? "static") == "dynamic" {
                        dynamicCaptionIDs.insert(episode.id)
                    } else {
                        staticCaptionIDs.insert(episode.id)
                    }
                }
                selected = episode
                nextIndex += 1
            }
            guard let selected = selected else { return 0 }
            selectedEpisode = selected
            if let srt = project.transcriptSRT, let cues = try? SubtitleFile.parse(srt) {
                if !dynamicCaptionIDs.isEmpty {
                    applyCaptions(cues, dynamic: true, recordUndo: false, episodeIDs: dynamicCaptionIDs)
                }
                if !staticCaptionIDs.isEmpty {
                    applyCaptions(cues, dynamic: false, recordUndo: false, episodeIDs: staticCaptionIDs)
                }
            }
            Task { await persistProjectChanges() }
            return newEpisodeIDs.count
        }
        if let operations = plan.normalized().operations, !operations.isEmpty {
            let errors = ClipPlanValidator.validate(plan.normalized(), project: currentProject)
            guard errors.isEmpty else {
                errorMessage = ClipPlanExecutor.validationFailed(errors)
                return 0
            }
            return applyClipPlanOperations(operations, brief: brief)
        }
        errorMessage = ClipPlanExecutor.emptyPlan
        return 0
    }

    // MARK: - ClipPlan operations

    /// Where a "seg_N" id pointed when the plan started, so a piece removed by
    /// an earlier cut simply fails to resolve instead of hitting the wrong clip.
    private enum PlanSegmentSlot {
        case intro
        case recap(Int)         // ordinal inside the episode's effective recaps
        case main(UUID)         // mainClips element id
        case outro

        var isMain: Bool {
            if case .main = self { return true }
            return false
        }
    }

    /// Ids of one episode's pieces as the plan saw them (same numbering
    /// ClipBriefBuilder.episodeStates uses: storyline order, textOverlays order,
    /// resolvedAudioClips order, mediaOverlays order).
    private struct PlanTargetMaps {
        var segments: [String: PlanSegmentSlot] = [:]
        var texts: [String: UUID] = [:]
        var audio: [String: UUID] = [:]
        var overlays: [String: UUID] = [:]
        /// Storyline time ranges of seg_1...seg_N (for at_segment anchors).
        var segmentRanges: [ClosedRange<Double>] = []
        /// Storyline end of the episode (for negative start_ms resolution).
        var timelineDuration: Double = 0
        var coverage: [ClosedRange<Double>] = []
        var hadCaptions = false
        var hadDynamicCaptions = false
    }

    /// Applies an `operations` plan in place over the existing episodes.
    /// One checkpoint covers the whole plan; ops whose targets disappeared
    /// (e.g. a segment removed by a cut in the same plan) are skipped.
    /// Returns the number of operations applied.
    @discardableResult
    func applyClipPlanOperations(_ ops: [ClipPlanOperation], brief: ClipBrief?) -> Int {
        // Rebuild a minimal plan so the validator stays the single entry point.
        let plan = ClipPlan(clipplan_version: ClipPlanContract.planVersion, outputs: nil, operations: ops)
        let errors = ClipPlanValidator.validate(plan, project: currentProject)
        guard errors.isEmpty else {
            errorMessage = ClipPlanExecutor.validationFailed(errors)
            return 0
        }
        guard !ops.isEmpty else {
            errorMessage = ClipPlanExecutor.emptyPlan
            return 0
        }
        checkpoint()

        // Resolve every id against the ORIGINAL episodes: ep_N is the array
        // index at plan time; seg_N/txt_N/aud_N index into each episode's own
        // snapshot (storyline / textOverlays / resolvedAudioClips order).
        var targetMaps: [Int: PlanTargetMaps] = [:]
        for operation in ops {
            guard let episodeIndex = ClipPlanExecutor.planIndex(operation.target, prefix: "ep"),
                  episodes.indices.contains(episodeIndex),
                  targetMaps[episodeIndex] == nil else { continue }
            targetMaps[episodeIndex] = planTargetMaps(for: episodes[episodeIndex])
        }

        // Cuts are grouped per episode and applied once after all other ops:
        // the AI authored the plan against the original episodes, so ids and
        // timeline positions must keep resolving to the pre-edit state.
        var pendingCuts: [Int: [ClosedRange<Double>]] = [:]
        var cutOpIndices: [Int: [Int]] = [:]
        /// ep indices a delete_episode op claimed — later ops on them skip,
        /// and the episodes are actually removed after everything else.
        var deletedTargets: Set<Int> = []
        var applied = 0
        var skipped = 0

        for (opIndex, operation) in ops.enumerated() {
            guard let episodeIndex = ClipPlanExecutor.planIndex(operation.target, prefix: "ep"),
                  episodes.indices.contains(episodeIndex),
                  let maps = targetMaps[episodeIndex] else {
                skipped += 1
                continue
            }
            guard !deletedTargets.contains(episodeIndex) else {
                skipped += 1
                continue
            }
            var episode = episodes[episodeIndex]

            switch operation.op {
            case "cut_range":
                guard let inMs = operation.in_ms, let outMs = operation.out_ms, outMs > inMs else {
                    skipped += 1
                    continue
                }
                let start = max(0, min(Double(inMs) / 1000, project.sequenceSourceDuration))
                let end = max(start, min(Double(outMs) / 1000, project.sequenceSourceDuration))
                guard end - start > 0.05 else {
                    skipped += 1
                    continue
                }
                pendingCuts[episodeIndex, default: []].append(start...end)
                cutOpIndices[episodeIndex, default: []].append(opIndex)
                applied += 1
            case "remove_silences":
                let ranges = planSilenceRanges(
                    coverage: maps.coverage,
                    minPause: ClipPlanExecutor.minPauseSeconds(operation)
                )
                guard !ranges.isEmpty else {
                    skipped += 1
                    continue
                }
                pendingCuts[episodeIndex, default: []].append(contentsOf: ranges)
                cutOpIndices[episodeIndex, default: []].append(opIndex)
                applied += 1
            case "set_volume":
                var changed = false
                if let segmentID = operation.segment_id,
                   let slot = maps.segments[segmentID],
                   let volume = operation.volume,
                   mutatePlanSegment(slot, in: &episode, { $0.clipVolume = Float(volume) }) {
                    changed = true
                }
                if let audioID = operation.audio_id,
                   let uuid = maps.audio[audioID],
                   let volume = operation.volume,
                   setPlanAudioVolume(uuid, in: &episode, volume: Float(volume)) {
                    changed = true
                }
                if changed { applied += 1 } else { skipped += 1 }
            case "move_text":
                if let textID = operation.text_id,
                   let uuid = maps.texts[textID],
                   let index = episode.textOverlays.firstIndex(where: { $0.id == uuid }) {
                    episode.textOverlays[index].positionY = Self.planPositionY(operation.position)
                    applied += 1
                } else {
                    skipped += 1
                }
            case "set_text_style":
                if let textID = operation.text_id,
                   let uuid = maps.texts[textID],
                   let index = episode.textOverlays.firstIndex(where: { $0.id == uuid }) {
                    var overlay = episode.textOverlays[index]
                    if let style = operation.style { overlay.style = Self.planOverlayStyle(style) }
                    if let color = operation.color { overlay.color = Self.planOverlayColor(color) }
                    if let size = operation.size { overlay.fontScale = ClipPlanExecutor.textFontScale(size) }
                    episode.textOverlays[index] = overlay
                    applied += 1
                } else {
                    skipped += 1
                }
            case "set_aspect":
                guard let format = operation.format else {
                    skipped += 1
                    continue
                }
                let ratio = Self.planAspectRatio(format)
                episode.outputAspectRatio = ratio == .original ? nil : ratio
                applied += 1
            case "set_transition":
                if let segmentID = operation.segment_id,
                   let slot = maps.segments[segmentID],
                   let style = operation.style {
                    if mutatePlanSegment(slot, in: &episode, { $0.transition = Self.planTransition(style) }) {
                        applied += 1
                    } else {
                        skipped += 1
                    }
                } else {
                    skipped += 1
                }
            case "add_text":
                guard let text = operation.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let durationMs = operation.duration_ms,
                      operation.start_ms != nil || operation.at_segment != nil else {
                    skipped += 1
                    continue
                }
                let start = ClipPlanExecutor.resolveStart(
                    startMs: operation.start_ms,
                    atSegment: operation.at_segment,
                    at: operation.at,
                    anchorRanges: maps.segmentRanges,
                    timelineDuration: maps.timelineDuration
                )
                let spec = ClipPlanText(
                    text: text,
                    start_ms: nil,
                    duration_ms: durationMs,
                    position: operation.position,
                    style: operation.style,
                    color: operation.color
                )
                episode.textOverlays.append(Self.planTextOverlay(spec, start: start))
                applied += 1
            case "set_captions":
                if operation.enabled == false {
                    episode.textOverlays = episode.textOverlays.filter { $0.isCaption != true }
                    applied += 1
                } else if operation.enabled == true,
                          let srt = project.transcriptSRT,
                          let cues = try? SubtitleFile.parse(srt), !cues.isEmpty {
                    // applyCaptions reads the episodes array — write pending edits back first.
                    episodes[episodeIndex] = episode
                    applyCaptions(cues, dynamic: operation.style == "dynamic", recordUndo: false, episodeIDs: [episode.id])
                    episode = episodes[episodeIndex]
                    applied += 1
                } else {
                    skipped += 1
                }
            case "auto_framing":
                guard let enabled = operation.enabled else {
                    skipped += 1
                    continue
                }
                var clips = episode.mainClips
                for index in clips.indices {
                    var adjustments = clips[index].clipAdjustments
                    adjustments.autoFraming = enabled
                    clips[index].clipAdjustments = adjustments
                }
                episode.mainClips = clips
                applied += 1
            case "set_vinheta":
                guard let track = operation.track,
                      let assetString = operation.asset_id,
                      let assetID = UUID(uuidString: assetString),
                      let inMs = operation.in_ms, let outMs = operation.out_ms,
                      let template = vinhetaTemplate(
                          for: VinhetaChoice(assetID: assetID, start: Double(inMs) / 1000, end: Double(outMs) / 1000),
                          track: track == "intro" ? .intro : .outro
                      ) else {
                    skipped += 1
                    continue
                }
                // A custom template wins over the global one in storyline(); the
                // flag stays false so dropping the custom never falls back silently.
                if track == "intro" {
                    episode.customIntroTemplate = template
                    episode.useGlobalIntro = false
                } else {
                    episode.customOutroTemplate = template
                    episode.useGlobalOutro = false
                }
                applied += 1
            case "set_speed":
                guard let segmentID = operation.segment_id,
                      let slot = maps.segments[segmentID],
                      let speed = operation.speed,
                      mutatePlanSegment(slot, in: &episode, { $0.playbackSpeed = speed }) else {
                    skipped += 1
                    continue
                }
                episode.clearTimelinePins()
                applied += 1
            case "set_adjustments":
                guard let segmentID = operation.segment_id,
                      let slot = maps.segments[segmentID],
                      mutatePlanSegment(slot, in: &episode, { segment in
                          var adjustments = segment.clipAdjustments
                          if let brightness = operation.brightness { adjustments.brightness = brightness }
                          if let contrast = operation.contrast { adjustments.contrast = contrast }
                          if let saturation = operation.saturation { adjustments.saturation = saturation }
                          if let warmth = operation.warmth { adjustments.warmth = warmth }
                          if let vignette = operation.vignette { adjustments.vignette = vignette }
                          if let removeBackground = operation.remove_background { adjustments.removeBackground = removeBackground }
                          segment.clipAdjustments = adjustments
                      }) else {
                    skipped += 1
                    continue
                }
                applied += 1
            case "set_transform":
                guard let segmentID = operation.segment_id,
                      let slot = maps.segments[segmentID],
                      mutatePlanSegment(slot, in: &episode, { segment in
                          var transform = segment.clipTransform
                          if let scale = operation.scale { transform.scale = scale }
                          if let rotation = operation.rotation { transform.rotation = rotation }
                          if let offsetX = operation.offset_x { transform.offsetX = offsetX }
                          if let offsetY = operation.offset_y { transform.offsetY = offsetY }
                          segment.clipTransform = transform
                      }) else {
                    skipped += 1
                    continue
                }
                applied += 1
            case "trim_segment":
                guard let segmentID = operation.segment_id,
                      let slot = maps.segments[segmentID],
                      operation.in_ms != nil || operation.out_ms != nil else {
                    skipped += 1
                    continue
                }
                var trimmed = false
                let resolved = mutatePlanSegment(slot, in: &episode) { segment in
                    // Main slots trim in source-sequence ms; vinheta slots in
                    // asset-local ms (same convention as the brief).
                    let seqOffset = slot.isMain ? segment.sequenceStartTime : 0
                    let limit = planSourceLimit(for: segment, slot: slot)
                    if let inMs = operation.in_ms {
                        segment.startTime = min(limit, max(0, Double(inMs) / 1000 - seqOffset))
                    }
                    if let outMs = operation.out_ms {
                        segment.endTime = min(limit, max(0, Double(outMs) / 1000 - seqOffset))
                    }
                    if segment.endTime - segment.startTime <= 0.05 {
                        segment.endTime = min(limit, segment.startTime + 0.051)
                    }
                    if segment.endTime - segment.startTime <= 0.05 {
                        segment.startTime = max(0, segment.endTime - 0.051)
                    }
                    trimmed = segment.endTime - segment.startTime > 0.05
                }
                if resolved && trimmed {
                    episode.clearTimelinePins()
                    applied += 1
                } else {
                    skipped += 1
                }
            case "split":
                guard let segmentID = operation.segment_id,
                      let slot = maps.segments[segmentID],
                      case .main(let uuid) = slot,
                      let atMs = operation.at_ms else {
                    skipped += 1
                    continue
                }
                var clips = episode.mainClips
                guard let clipIndex = clips.firstIndex(where: { $0.id == uuid }) else {
                    skipped += 1
                    continue
                }
                let clip = clips[clipIndex]
                let localSplit = Double(atMs) / 1000 - clip.sequenceStartTime
                guard localSplit - clip.startTime > 0.05, clip.endTime - localSplit > 0.05 else {
                    skipped += 1
                    continue
                }
                var first = clip
                first.endTime = localSplit
                // The transition moves to the second piece: it plays at the
                // split point (the first piece keeps the clip's entrance cut).
                var second = clip.continuation(from: localSplit)
                second.transitionStyle = clip.transitionStyle
                first.transitionStyle = TransitionStyle.none
                clips.replaceSubrange(clipIndex...clipIndex, with: [first, second])
                episode.mainClips = clips
                applied += 1
            case "remove_segment":
                guard let segmentID = operation.segment_id,
                      let slot = maps.segments[segmentID] else {
                    skipped += 1
                    continue
                }
                switch slot {
                case .main(let uuid):
                    guard let clip = episode.mainClips.first(where: { $0.id == uuid }) else {
                        skipped += 1
                        continue
                    }
                    // Removing a main clip = cutting its source coverage; the
                    // grouped pass below closes the timeline gap.
                    let range = (clip.sequenceStartTime + clip.startTime)...(clip.sequenceStartTime + clip.endTime)
                    pendingCuts[episodeIndex, default: []].append(range)
                    cutOpIndices[episodeIndex, default: []].append(opIndex)
                    applied += 1
                case .intro:
                    episode.normalizeCustomTemplates()
                    episode.introSegment = nil
                    episode.useGlobalIntro = false
                    applied += 1
                case .outro:
                    episode.normalizeCustomTemplates()
                    episode.outroSegment = nil
                    episode.useGlobalOutro = false
                    applied += 1
                case .recap(let ordinal):
                    if !episode.customRecapSegments.isEmpty {
                        guard ordinal < episode.customRecapSegments.count else {
                            skipped += 1
                            continue
                        }
                        episode.customRecapSegments.remove(at: ordinal)
                    } else {
                        guard ordinal < episode.recapSegments.count else {
                            skipped += 1
                            continue
                        }
                        episode.recapSegments.remove(at: ordinal)
                        episode.useGlobalRecap = !episode.recapSegments.isEmpty
                    }
                    episode.usesCustomRecapSegments = true
                    applied += 1
                }
            case "reorder":
                guard let ids = operation.order, !ids.isEmpty else {
                    skipped += 1
                    continue
                }
                var uuids: [UUID] = []
                var badID = false
                for segmentID in ids {
                    guard let slot = maps.segments[segmentID], case .main(let uuid) = slot else {
                        badID = true
                        break
                    }
                    uuids.append(uuid)
                }
                let current = episode.mainClips
                guard !badID,
                      uuids.count == current.count,
                      Set(uuids) == Set(current.map(\.id)) else {
                    skipped += 1
                    continue
                }
                episode.mainClips = uuids.compactMap { uuid in current.first(where: { $0.id == uuid }) }
                episode.clearTimelinePins()
                applied += 1
            case "rename":
                guard let title = operation.title,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    skipped += 1
                    continue
                }
                episode.displayTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                applied += 1
            case "delete_episode":
                deletedTargets.insert(episodeIndex)
                applied += 1
            case "set_audio":
                guard let audioID = operation.audio_id,
                      let uuid = maps.audio[audioID],
                      mutatePlanAudio(uuid, in: &episode, { clip in
                          if let volume = operation.volume { clip.volume = Float(volume) }
                          if let fadeIn = operation.fade_in_ms { clip.fadeIn = Double(fadeIn) / 1000 }
                          if let fadeOut = operation.fade_out_ms { clip.fadeOut = Double(fadeOut) / 1000 }
                          if let duckLevel = operation.duck_level { clip.duckLevel = Float(duckLevel) }
                      }) else {
                    skipped += 1
                    continue
                }
                applied += 1
            case "remove_audio":
                guard let audioID = operation.audio_id,
                      let uuid = maps.audio[audioID] else {
                    skipped += 1
                    continue
                }
                if let index = episode.audioClips.firstIndex(where: { $0.id == uuid }) {
                    var clips = episode.audioClips
                    clips.remove(at: index)
                    episode.audioClips = clips
                    applied += 1
                } else if let index = project.globalAudioClips.firstIndex(where: { $0.id == uuid }) {
                    project.globalAudioClips.remove(at: index)
                    applied += 1
                } else {
                    skipped += 1
                }
            case "add_audio":
                guard let assetString = operation.asset_id,
                      let assetID = UUID(uuidString: assetString),
                      let asset = mediaAssets.first(where: { $0.id == assetID }),
                      asset.type != .image else {
                    skipped += 1
                    continue
                }
                let sourceStart = max(0, min(Double(operation.source_in_ms ?? 0) / 1000, asset.duration))
                let sourceEnd = operation.source_out_ms
                    .map { max(0, min(Double($0) / 1000, asset.duration)) } ?? asset.duration
                guard sourceEnd - sourceStart > 0.05 else {
                    skipped += 1
                    continue
                }
                var clip = AudioClip(
                    assetID: asset.id,
                    name: asset.name,
                    kind: Self.planAudioKind(operation.kind),
                    timelineStart: ClipPlanExecutor.resolveStart(
                        startMs: operation.start_ms,
                        atSegment: nil,
                        at: nil,
                        anchorRanges: [],
                        timelineDuration: maps.timelineDuration
                    ),
                    sourceStart: sourceStart,
                    sourceEnd: sourceEnd,
                    volume: Float(operation.volume ?? 0.5)
                )
                if let fadeIn = operation.fade_in_ms { clip.fadeIn = Double(fadeIn) / 1000 }
                if let fadeOut = operation.fade_out_ms { clip.fadeOut = Double(fadeOut) / 1000 }
                if let duckLevel = operation.duck_level { clip.duckLevel = Float(duckLevel) }
                episode.audioClips.append(clip)
                applied += 1
            case "add_overlay":
                guard let assetString = operation.asset_id,
                      let assetID = UUID(uuidString: assetString),
                      let asset = mediaAssets.first(where: { $0.id == assetID }),
                      asset.type != .audio else {
                    skipped += 1
                    continue
                }
                let isVideo = asset.type == .video
                let duration = operation.duration_ms
                    .map { Double($0) / 1000 } ?? (isVideo ? asset.duration : 4)
                guard duration > 0.05 else {
                    skipped += 1
                    continue
                }
                var overlay = MediaOverlay(
                    assetID: asset.id,
                    name: asset.name,
                    isVideo: isVideo,
                    startTime: ClipPlanExecutor.resolveStart(
                        startMs: operation.start_ms,
                        atSegment: nil,
                        at: nil,
                        anchorRanges: [],
                        timelineDuration: maps.timelineDuration
                    ),
                    duration: duration,
                    sourceStart: 0
                )
                if let centerX = operation.center_x { overlay.centerX = centerX }
                if let centerY = operation.center_y { overlay.centerY = centerY }
                if let width = operation.width_fraction { overlay.widthFraction = width }
                if let volume = operation.volume { overlay.volume = Float(volume) }
                if let opacity = operation.opacity { overlay.opacity = opacity }
                if let rotation = operation.rotation { overlay.rotation = rotation }
                if operation.chroma_enabled == true {
                    overlay.chromaKey = ChromaKeySettings(enabled: true)
                }
                episode.mediaOverlays.append(overlay)
                applied += 1
            case "set_overlay":
                guard let overlayID = operation.overlay_id,
                      let uuid = maps.overlays[overlayID],
                      let overlayIndex = episode.mediaOverlays.firstIndex(where: { $0.id == uuid }) else {
                    skipped += 1
                    continue
                }
                var overlay = episode.mediaOverlays[overlayIndex]
                if let centerX = operation.center_x { overlay.centerX = centerX }
                if let centerY = operation.center_y { overlay.centerY = centerY }
                if let width = operation.width_fraction { overlay.widthFraction = width }
                if operation.start_ms != nil {
                    overlay.startTime = ClipPlanExecutor.resolveStart(
                        startMs: operation.start_ms,
                        atSegment: nil,
                        at: nil,
                        anchorRanges: [],
                        timelineDuration: maps.timelineDuration
                    )
                }
                if let duration = operation.duration_ms { overlay.duration = Double(duration) / 1000 }
                if let sourceStart = operation.source_start_ms {
                    overlay.sourceStart = max(0, Double(sourceStart) / 1000)
                }
                if let opacity = operation.opacity { overlay.opacity = opacity }
                if let rotation = operation.rotation { overlay.rotation = rotation }
                if let volume = operation.volume { overlay.volume = Float(volume) }
                let hasChroma = operation.chroma_enabled != nil || operation.chroma_r != nil
                    || operation.chroma_g != nil || operation.chroma_b != nil
                    || operation.chroma_tolerance != nil
                if hasChroma {
                    var chroma = overlay.chromaKey ?? ChromaKeySettings()
                    if let enabled = operation.chroma_enabled { chroma.enabled = enabled }
                    if operation.chroma_r != nil || operation.chroma_g != nil || operation.chroma_b != nil {
                        chroma.color = RGBAColor(
                            red: operation.chroma_r ?? chroma.color.red,
                            green: operation.chroma_g ?? chroma.color.green,
                            blue: operation.chroma_b ?? chroma.color.blue,
                            alpha: 1
                        )
                    }
                    if let tolerance = operation.chroma_tolerance { chroma.tolerance = tolerance }
                    overlay.chromaKey = chroma
                }
                episode.mediaOverlays[overlayIndex] = overlay
                applied += 1
            case "remove_overlay":
                guard let overlayID = operation.overlay_id,
                      let uuid = maps.overlays[overlayID],
                      let overlayIndex = episode.mediaOverlays.firstIndex(where: { $0.id == uuid }) else {
                    skipped += 1
                    continue
                }
                episode.mediaOverlays.remove(at: overlayIndex)
                applied += 1
            case "set_chroma":
                // Dedicated chroma op: only ovl_N targets resolve — a seg_N
                // target is rejected by the validator ("chroma só em overlays").
                guard let overlayID = operation.overlay_id,
                      let uuid = maps.overlays[overlayID],
                      let overlayIndex = episode.mediaOverlays.firstIndex(where: { $0.id == uuid }),
                      let enabled = operation.enabled else {
                    skipped += 1
                    continue
                }
                var overlay = episode.mediaOverlays[overlayIndex]
                var chroma = overlay.chromaKey ?? ChromaKeySettings()
                chroma.enabled = enabled
                if let color = operation.color, let parsed = Self.planHexColor(color) {
                    chroma.color = parsed
                }
                if let tolerance = operation.tolerance {
                    chroma.tolerance = min(1, max(0, tolerance))
                }
                overlay.chromaKey = chroma
                episode.mediaOverlays[overlayIndex] = overlay
                applied += 1
            case "add_marker":
                guard let timeMs = operation.time_ms else {
                    skipped += 1
                    continue
                }
                episode.markers.append(TimelineMarker(time: Double(timeMs) / 1000))
                applied += 1
            case "remove_marker":
                guard let timeMs = operation.time_ms else {
                    skipped += 1
                    continue
                }
                let time = Double(timeMs) / 1000
                guard let nearest = episode.markers
                    .filter({ abs($0.time - time) <= 0.5 })
                    .min(by: { abs($0.time - time) < abs($1.time - time) }) else {
                    skipped += 1
                    continue
                }
                episode.markers = episode.markers.filter { $0.id != nearest.id }
                applied += 1
            default:
                skipped += 1
            }
            episodes[episodeIndex] = episode
        }

        // Grouped cuts, once per episode, then captions regenerated where needed.
        // Episodes a delete_episode claimed are skipped here and removed below.
        var captionRefresh: [Int: Bool] = [:]
        for episodeIndex in pendingCuts.keys.sorted() where !deletedTargets.contains(episodeIndex) {
            guard let ranges = pendingCuts[episodeIndex] else { continue }
            let merged = Self.merge(ranges)
            guard !merged.isEmpty else { continue }
            if removeMergedRanges(merged, fromEpisodeAt: episodeIndex) {
                captionRefresh[episodeIndex] = true
            } else {
                // Nothing intersected (or the episode would empty out): the ops
                // that contributed these ranges count as skipped.
                let count = cutOpIndices[episodeIndex]?.count ?? 0
                applied -= count
                skipped += count
            }
        }

        // Episodes whose captions should still exist get them re-rendered on the
        // post-cut timeline (closeGaps only shifts overlays; it can't re-split cues).
        if let srt = project.transcriptSRT, let cues = try? SubtitleFile.parse(srt), !cues.isEmpty {
            for episodeIndex in captionRefresh.keys.sorted() where !deletedTargets.contains(episodeIndex) {
                guard let maps = targetMaps[episodeIndex] else { continue }
                let overlays = episodes[episodeIndex].textOverlays
                let hasCaptions = overlays.contains { $0.isCaption == true }
                guard hasCaptions || maps.hadCaptions else { continue }
                let dynamic = overlays.contains { $0.isCaption == true && !($0.words?.isEmpty ?? true) }
                    || maps.hadDynamicCaptions
                applyCaptions(cues, dynamic: dynamic, recordUndo: false, episodeIDs: [episodes[episodeIndex].id])
            }
        }

        // delete_episode ops land last: remove the claimed episodes now.
        if !deletedTargets.isEmpty {
            let selectedWasDeleted = selectedEpisodeIndex.map { deletedTargets.contains($0) } ?? false
            for index in deletedTargets.sorted(by: >) {
                episodes.remove(at: index)
            }
            if selectedWasDeleted { selectedEpisode = episodes.first }
        }

        if let index = selectedEpisodeIndex { selectedEpisode = episodes[index] }
        if applied > 0 {
            // Mid-plan helpers (e.g. applyCaptions on an episode with no cues)
            // may have surfaced a warning; the plan as a whole succeeded.
            errorMessage = nil
        } else {
            errorMessage = skipped > 0
                ? "Nenhuma das \(skipped) edições do plano pôde ser aplicada."
                : "Nenhuma edição do plano pôde ser aplicada."
        }
        Task { await persistProjectChanges() }
        return applied
    }

    /// Id maps of one episode at plan start (pre-mutation), matching
    /// ClipBriefBuilder.episodeStates numbering.
    private func planTargetMaps(for episode: Episode) -> PlanTargetMaps {
        var maps = PlanTargetMaps()
        var recapOrdinal = 0
        let items = episode.storyline()
        for (index, item) in items.enumerated() {
            maps.segmentRanges.append(item.start...item.end)
            switch item.track {
            case .intro:
                maps.segments["seg_\(index + 1)"] = .intro
            case .outro:
                maps.segments["seg_\(index + 1)"] = .outro
            case .recap:
                maps.segments["seg_\(index + 1)"] = .recap(recapOrdinal)
                recapOrdinal += 1
            default:
                maps.segments["seg_\(index + 1)"] = .main(item.segment.id)
            }
        }
        maps.timelineDuration = items.last?.end ?? 0
        for (index, overlay) in episode.textOverlays.enumerated() {
            maps.texts["txt_\(index + 1)"] = overlay.id
        }
        for (index, clip) in episode.resolvedAudioClips(global: project.globalAudioClips).enumerated() {
            maps.audio["aud_\(index + 1)"] = clip.id
        }
        for (index, overlay) in episode.mediaOverlays.enumerated() {
            maps.overlays["ovl_\(index + 1)"] = overlay.id
        }
        maps.coverage = sourceCoverage(of: episode)
        maps.hadCaptions = episode.textOverlays.contains { $0.isCaption == true }
        maps.hadDynamicCaptions = episode.textOverlays.contains { $0.isCaption == true && !($0.words?.isEmpty ?? true) }
        return maps
    }

    /// Mutates the segment a seg_N id pointed at in the original snapshot.
    /// Returns false when that piece no longer exists (e.g. removed by a cut).
    private func mutatePlanSegment(_ slot: PlanSegmentSlot, in episode: inout Episode, _ body: (inout VideoSegment) -> Void) -> Bool {
        switch slot {
        case .main(let id):
            var clips = episode.mainClips
            guard let index = clips.firstIndex(where: { $0.id == id }) else { return false }
            body(&clips[index])
            episode.mainClips = clips
            return true
        case .recap(let ordinal):
            if !episode.customRecapSegments.isEmpty {
                guard ordinal < episode.customRecapSegments.count else { return false }
                body(&episode.customRecapSegments[ordinal])
                episode.usesCustomRecapSegments = true
                return true
            }
            guard ordinal < episode.recapSegments.count else { return false }
            body(&episode.recapSegments[ordinal])
            episode.usesCustomRecapSegments = true
            return true
        case .intro:
            if episode.customIntroTemplate != nil { episode.normalizeCustomTemplates() }
            guard episode.useGlobalIntro, var intro = episode.introSegment else { return false }
            body(&intro)
            episode.introSegment = intro
            return true
        case .outro:
            if episode.customOutroTemplate != nil { episode.normalizeCustomTemplates() }
            guard episode.useGlobalOutro, var outro = episode.outroSegment else { return false }
            body(&outro)
            episode.outroSegment = outro
            return true
        }
    }

    /// Mutates an aud_N target: episode clips first, then project-wide ones
    /// (resolvedAudioClips merges both; the id tells which list owns it).
    private func mutatePlanAudio(_ uuid: UUID, in episode: inout Episode, _ body: (inout AudioClip) -> Void) -> Bool {
        if let index = episode.audioClips.firstIndex(where: { $0.id == uuid }) {
            var clips = episode.audioClips
            body(&clips[index])
            episode.audioClips = clips
            return true
        }
        if let index = project.globalAudioClips.firstIndex(where: { $0.id == uuid }) {
            var clips = project.globalAudioClips
            body(&clips[index])
            project.globalAudioClips = clips
            return true
        }
        return false
    }

    /// Volume on an aud_N target: episode clips first, then project-wide ones
    /// (resolvedAudioClips merges both; the id tells which list owns it).
    private func setPlanAudioVolume(_ uuid: UUID, in episode: inout Episode, volume: Float) -> Bool {
        mutatePlanAudio(uuid, in: &episode) { $0.volume = volume }
    }

    /// Clip-local trim ceiling (seconds): main slots trim inside their source
    /// clip of the sequence; vinheta slots inside the referenced asset.
    private func planSourceLimit(for segment: VideoSegment, slot: PlanSegmentSlot) -> Double {
        switch slot {
        case .main:
            return project.sourceClips
                .first(where: { abs($0.sequenceStartTime - segment.sequenceStartTime) < 0.001 })?
                .duration ?? project.sourceVideoDuration
        default:
            return mediaAssets.first(where: { $0.id == segment.assetID })?.duration ?? segment.endTime
        }
    }

    /// Pause ranges (source-sequence seconds) inside one episode's coverage,
    /// from the transcript alone — same word-gap detection as "Remover pausas",
    /// kept synchronous so the whole plan applies under a single checkpoint.
    private func planSilenceRanges(coverage: [ClosedRange<Double>], minPause: Double) -> [ClosedRange<Double>] {
        guard let words = project.transcriptWords, !words.isEmpty,
              let transcriptDuration = project.transcriptSequenceDuration,
              abs(transcriptDuration - project.sequenceSourceDuration) <= 0.5 else { return [] }
        return PauseDetector.detect(
            words: words,
            energy: [],
            interval: 0.5,
            totalDuration: project.sequenceSourceDuration,
            minPause: minPause,
            margin: 0.15,
            coverage: coverage
        ).map { $0.start...$0.end }
    }

    private static func planPositionY(_ position: String?) -> Double {
        switch position {
        case "top": return EpisodeCardPosition.top.positionY
        case "center": return EpisodeCardPosition.center.positionY
        default: return EpisodeCardPosition.bottom.positionY
        }
    }

    private static func planOverlayStyle(_ style: String?) -> TextOverlayStyle {
        switch style {
        case "plain": return .plain
        case "shadow": return .shadow
        default: return .box
        }
    }

    private static func planOverlayColor(_ color: String?) -> RGBAColor {
        switch color {
        case "yellow": return EpisodeCardColor.yellow.rgba
        case "black": return EpisodeCardColor.black.rgba
        default: return EpisodeCardColor.white.rgba
        }
    }

    /// Plan transition names are TransitionStyle case names, not display names.
    private static func planTransition(_ style: String) -> TransitionStyle {
        switch style {
        case "none": return .none
        case "fadeBlack": return .fadeBlack
        case "fadeWhite": return .fadeWhite
        case "slideLeft": return .slideLeft
        case "slideRight": return .slideRight
        case "slideUp": return .slideUp
        case "push": return .push
        case "zoom": return .zoom
        case "wipe": return .wipe
        case "iris": return .iris
        default: return .dissolve
        }
    }

    /// Parses a plan "#RRGGBB" hex string into an RGBAColor (set_chroma).
    private static func planHexColor(_ text: String) -> RGBAColor? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        func channel(_ range: Range<String.Index>) -> Double {
            Double(Int(hex[range], radix: 16) ?? 0) / 255
        }
        let r = channel(hex.startIndex..<hex.index(hex.startIndex, offsetBy: 2))
        let g = channel(hex.index(hex.startIndex, offsetBy: 2)..<hex.index(hex.startIndex, offsetBy: 4))
        let b = channel(hex.index(hex.startIndex, offsetBy: 4)..<hex.endIndex)
        return RGBAColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// Plan audio kinds map straight onto AudioClipKind case names.
    private static func planAudioKind(_ kind: String?) -> AudioClipKind {
        switch kind {
        case "narration": return .narration
        case "videoSound": return .videoSound
        default: return .music
        }
    }

    private static func planAspectRatio(_ format: String) -> AspectRatio {
        switch format {
        case "16:9": return .landscape16_9
        case "9:16": return .portrait9_16
        case "1:1": return .square1_1
        case "4:5": return .portrait4_5
        default: return .original
        }
    }

    /// Maps a plan text card to a timeline overlay (same look as the part
    /// cards) at an already-resolved timeline start in seconds.
    private static func planTextOverlay(_ spec: ClipPlanText, start: Double) -> TextOverlay {
        var overlay = TextOverlay(
            text: spec.text,
            startTime: max(0, start),
            duration: max(0.5, Double(spec.duration_ms) / 1000)
        )
        overlay.positionY = planPositionY(spec.position ?? "bottom")
        overlay.fontScale = EpisodeCardSize.medium.fontScale
        overlay.style = planOverlayStyle(spec.style ?? "box")
        overlay.color = planOverlayColor(spec.color ?? "white")
        overlay.animation = .fade
        overlay.exitAnimation = .fade
        return overlay
    }

    /// Rebuilds the project's episodes at detected topic boundaries (source times).
    func createEpisodesAtTopics(_ sourceTimes: [Double], request: AutomationRequest? = nil) {
        var workingProject = project
        guard workingProject.createEpisodes(at: sourceTimes) > 0 else {
            errorMessage = "Os limites detectados ficam perto demais das bordas (menos de 5s) para virar episódio."
            return
        }
        checkpoint()
        project = workingProject
        episodes = project.episodes
        if let request = request {
            exportSettings.includeCovers = request.generateCovers
            project.coverSettings.enabled = request.generateCovers
            let format = request.formats.first ?? .original
            if format != .original {
                for index in episodes.indices {
                    episodes[index].outputAspectRatio = format
                }
            }
        }
        if let first = episodes.first { selectedEpisode = first }
        Task { await persistProjectChanges() }
    }

    func saveSceneCuts(_ cuts: [Double]) {
        project.sceneCuts = cuts
        Task { await persistProjectChanges(reloadPreview: false) }
    }

    /// Reuses the generated analysis in the legacy views while keeping the
    /// complete index in AnalysisStore for future automation runs.
    func applyContentAnalysis(_ analysis: ContentAnalysis) {
        var changed = false
        let newWords = analysis.transcriptWords
        if project.transcriptSRT != analysis.transcriptSRT {
            project.transcriptSRT = analysis.transcriptSRT
            changed = true
        }
        if project.transcriptWords != newWords {
            project.transcriptWords = newWords
            changed = true
        }
        if project.transcriptSequenceDuration != analysis.duration {
            project.transcriptSequenceDuration = analysis.duration
            changed = true
        }
        let newSceneCuts = analysis.sceneCuts
        if project.sceneCuts != newSceneCuts {
            project.sceneCuts = newSceneCuts
            changed = true
        }
        guard changed else { return }
        Task { await persistProjectChanges(reloadPreview: false) }
    }

    func createSuggestedEpisodes(
        _ suggestions: [ClipSuggestion],
        autoFraming: Bool,
        captions: Bool = false,
        dynamicCaptions: Bool = false,
        formats: [AspectRatio] = [],
        generateCovers: Bool? = nil
    ) {
        guard !suggestions.isEmpty else { return }
        checkpoint()
        let shouldApplyCaptions = captions || episodes.contains { $0.textOverlays.contains { $0.isCaption == true } }
        var selected: Episode?
        var nextIndex = (episodes.map(\.index).max() ?? -1) + 1
        var outputCounts: [ClipSuggestionKind: Int] = [:]
        let outputFormats = formats.isEmpty ? [AspectRatio.original] : formats
        if let generateCovers = generateCovers {
            exportSettings.includeCovers = generateCovers
            project.coverSettings.enabled = generateCovers
        }
        for episode in episodes {
            for kind in ClipSuggestionKind.allCases where episode.displayTitle?.hasPrefix(kind.outputName) == true {
                let suffix = episode.displayTitle?.dropFirst(kind.outputName.count).trimmingCharacters(in: .whitespaces) ?? ""
                let numberText = suffix.prefix { $0.isNumber }
                let number = Int(numberText) ?? 0
                outputCounts[kind] = max(outputCounts[kind] ?? 0, number)
            }
        }
        let sequenceDuration = project.sequenceSourceDuration
        for suggestion in suggestions.sorted(by: { $0.start < $1.start }) {
            let start = max(0, min(suggestion.start, sequenceDuration))
            let end = max(start, min(suggestion.end, sequenceDuration))
            guard end - start > 0.2 else { continue }
            var mainPieces = project.sourceSegments(in: start...end)
            guard !mainPieces.isEmpty else { continue }
            if autoFraming {
                for index in mainPieces.indices {
                    var adjustments = mainPieces[index].clipAdjustments
                    adjustments.autoFraming = true
                    mainPieces[index].clipAdjustments = adjustments
                }
            }
            for index in mainPieces.indices {
                mainPieces[index].transition = .none
            }
            let outputNumber = (outputCounts[suggestion.kind] ?? 0) + 1
            outputCounts[suggestion.kind] = outputNumber
            for format in outputFormats {
                var episode = Episode(
                    index: nextIndex,
                    mainStart: start,
                    mainEnd: end,
                    introTemplate: nil,
                    outroTemplate: nil,
                    recapSettings: RecapSettings(enabled: false)
                )
                episode.mainClips = mainPieces
                episode.outputAspectRatio = format == .original ? nil : format
                let suffix = outputFormats.count > 1 ? " • \(format.rawValue)" : ""
                episode.displayTitle = "\(suggestion.kind.outputName) \(outputNumber)\(suffix)"
                episode.useGlobalIntro = false
                episode.useGlobalOutro = false
                episode.useGlobalRecap = false
                episodes.append(episode)
                selected = episode
                nextIndex += 1
            }
        }
        guard let selected = selected else { return }
        selectedEpisode = selected
        if shouldApplyCaptions, let srt = project.transcriptSRT, let cues = try? SubtitleFile.parse(srt) {
            applyCaptions(cues, dynamic: captions ? dynamicCaptions : captionsAreDynamic, recordUndo: false)
        }
        Task { await persistProjectChanges() }
    }

    func saveTextTemplate(_ template: TextStyleTemplate) {
        project.textTemplates = (project.textTemplates ?? []) + [template]
        Task { @MainActor in await persistProjectChanges() }
    }

    /// Detaches the selected main clip's audio into its own "Som" track and mutes the clip.
    func detachAudio() async {
        guard let segment = selectedSegment, segment.trackType == .main,
              segment.sourceType == .mainVideo, segment.sourceEndTime > segment.sourceStartTime else { return }
        guard abs(segment.speed - 1) < 0.001 else {
            errorMessage = "Separe o áudio antes de mudar a velocidade do clipe (ou volte a velocidade para 1x)."
            return
        }
        let fileURL = project.sourceVideoFileURL
        let audioTrack = try? await AVURLAsset(url: fileURL).loadTracks(withMediaType: .audio).first
        guard audioTrack != nil else {
            errorMessage = "Este vídeo não tem faixa de áudio para separar."
            return
        }
        // Reuse (or register) a media asset that points at the source video file.
        let asset: MediaAsset
        if let existing = mediaAssets.first(where: { $0.fileURL == fileURL.path || $0.name == "__source__" }) {
            asset = existing
        } else {
            asset = MediaAsset(
                name: "__source__",
                fileURL: fileURL,
                type: .video,
                duration: project.sourceVideoDuration,
                naturalSize: .zero,
                fileSize: 0,
                thumbnailURL: nil
            )
            mediaAssets.append(asset)
        }
        mutateSelectedEpisode { episode in
            var clips = episode.mainClips
            guard let index = clips.firstIndex(where: { $0.id == segment.id }) else { return }
            let clip = AudioClip(
                assetID: asset.id,
                name: "Som do vídeo",
                kind: .videoSound,
                timelineStart: segment.startTime,
                sourceStart: segment.sourceStartTime,
                sourceEnd: segment.sourceEndTime,
                volume: clips[index].clipVolume
            )
            clips[index].clipVolume = 0
            episode.mainClips = clips
            episode.audioClips.append(clip)
            selectedSegmentID = clip.id
        }
    }

    /// Positions the playhead where a source-video time lands, preferring the
    /// selected output and only switching when that range lives in another one.
    func seekToSourceTime(_ source: Double) {
        func target(in episode: Episode) -> Double? {
            for item in episode.storyline() where item.track == .main {
                let clip = item.segment
                let sourceStart = clip.sequenceStartTime + clip.startTime
                let sourceEnd = clip.sequenceStartTime + clip.endTime
                guard sourceStart <= source, source < sourceEnd else { continue }
                return item.start + (source - sourceStart) / clip.playbackSpeed
            }
            return nil
        }

        if let selectedEpisode = selectedEpisode, let target = target(in: selectedEpisode) {
            seek(to: target)
            return
        }
        for episode in episodes where episode.id != selectedEpisode?.id {
            guard let target = target(in: episode) else { continue }
            selectedEpisode = episode
            selectedSegmentID = nil
            updateTimelineForEpisode(episode)
            currentTime = target
            loadPreview(for: episode, keepTime: true)
            return
        }
    }

    /// Speech-edit mode works on one continuous clip instead of output slices.
    func useWholeClipForSpeechEdit() {
        guard project.sequenceSourceDuration > 0, !isWholeClipEpisode else { return }
        checkpoint()
        replaceWithWholeClipEpisode()
        Task { await persistProjectChanges() }
    }

    private var isWholeClipEpisode: Bool {
        guard episodes.count == 1, let episode = episodes.first else { return false }
        return abs(episode.mainStart) < 0.05 && abs(episode.mainEnd - project.sequenceSourceDuration) < 0.05
    }

    private func replaceWithWholeClipEpisode() {
        var episode = Episode(
            index: 0,
            mainStart: 0,
            mainEnd: project.sequenceSourceDuration,
            introTemplate: project.introTemplate,
            outroTemplate: project.outroTemplate,
            recapSettings: project.recapSettings
        )
        episode.displayTitle = "Clipe inteiro"
        episode.mainClips = project.sourceSegments(in: 0...project.sequenceSourceDuration)
        episodes = [episode]
        selectedEpisode = episode
        selectedSegmentID = nil
        updateTimelineForEpisode(episode)
    }

    /// Cuts source-video time ranges (from the transcript) out of every episode's main content.
    func removeSourceRanges(
        _ ranges: [ClosedRange<Double>],
        captions: Bool = false,
        dynamicCaptions: Bool = false,
        wholeClip: Bool = false,
        episodeIDs: Set<UUID>? = nil
    ) {
        let merged = Self.merge(ranges)
        guard !merged.isEmpty else { return }
        checkpoint()
        if wholeClip, !isWholeClipEpisode {
            replaceWithWholeClipEpisode()
        }
        let shouldApplyCaptions = captions || episodes.contains { $0.textOverlays.contains { $0.isCaption == true } }
        var changed = 0
        for index in episodes.indices {
            if let episodeIDs = episodeIDs, !episodeIDs.contains(episodes[index].id) { continue }
            if removeMergedRanges(merged, fromEpisodeAt: index) { changed += 1 }
        }
        guard changed > 0 else {
            errorMessage = "Os trechos escolhidos não estão no conteúdo principal dos episódios."
            return
        }
        if let index = selectedEpisodeIndex { selectedEpisode = episodes[index] }
        if shouldApplyCaptions, let srt = project.transcriptSRT, let cues = try? SubtitleFile.parse(srt) {
            applyCaptions(cues, dynamic: captions ? dynamicCaptions : captionsAreDynamic, recordUndo: false)
        }
        Task { await persistProjectChanges() }
    }

    /// Cuts merged source-sequence ranges out of one episode's main clips and
    /// closes the resulting timeline gaps (overlays/audio/markers shift too).
    /// Returns false when nothing would be removed or the episode would empty out.
    /// Mutates `episodes[index]` without checkpointing — the caller owns undo.
    @discardableResult
    private func removeMergedRanges(_ merged: [ClosedRange<Double>], fromEpisodeAt index: Int) -> Bool {
        var episode = episodes[index]
        let items = episode.storyline()
        var removedTimeline: [ClosedRange<Double>] = []
        var clips: [VideoSegment] = []
        for clip in episode.mainClips {
            guard !clip.isFreezeFrame,
                  let item = items.first(where: { $0.segment.id == clip.id }) else {
                clips.append(clip)
                continue
            }
            let sourceStart = clip.sequenceStartTime + clip.startTime
            let sourceEnd = clip.sequenceStartTime + clip.endTime
            let speed = clip.playbackSpeed
            var cursor = clip.startTime
            var touched = false
            var pieces: [VideoSegment] = []
            for range in merged where range.upperBound > sourceStart && range.lowerBound < sourceEnd {
                let lower = max(range.lowerBound, sourceStart) - clip.sequenceStartTime
                let upper = min(range.upperBound, sourceEnd) - clip.sequenceStartTime
                if lower - cursor > 0.05 {
                    var piece = cursor == clip.startTime ? clip : clip.continuation(from: cursor)
                    piece.endTime = lower
                    pieces.append(piece)
                }
                removedTimeline.append((item.start + (lower - clip.startTime) / speed)...(item.start + (upper - clip.startTime) / speed))
                cursor = upper
                touched = true
            }
            guard touched else {
                clips.append(clip)
                continue
            }
            if clip.endTime - cursor > 0.05 { pieces.append(clip.continuation(from: cursor)) }
            clips.append(contentsOf: pieces)
        }
        guard !removedTimeline.isEmpty, !clips.isEmpty else { return false }
        episode.mainClips = clips
        Self.closeGaps(in: &episode, removing: removedTimeline)
        episode.clearTimelinePins()
        episodes[index] = episode
        return true
    }

    /// Global source-sequence ranges covered by an episode's non-freeze main clips, merged.
    func sourceCoverage(of episode: Episode) -> [ClosedRange<Double>] {
        let ranges = episode.mainClips
            .filter { !$0.isFreezeFrame }
            .map { ($0.sequenceStartTime + $0.startTime)...($0.sequenceStartTime + $0.endTime) }
        return Self.merge(ranges)
    }

    static func merge(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.upperBound > range.lowerBound {
            if let last = result.last, range.lowerBound <= last.upperBound + 0.02 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private var captionsAreDynamic: Bool {
        episodes.contains { $0.textOverlays.contains { $0.isCaption == true && $0.words != nil } }
    }

    func stepFrame(by frames: Int) {
        previewPlayer?.pause()
        isPlaying = false
        seek(to: currentTime + Double(frames) / 30)
    }

    // MARK: Export

    private var exportTask: Task<Void, Never>?

    func cancelExport() {
        exportTask?.cancel()
    }

    private func isExportCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let processorError = error as? ProcessorError, case .exportCancelled = processorError { return true }
        return false
    }

    private func cancelledExportProgress() -> BatchExportProgress {
        BatchExportProgress(
            currentEpisode: 0,
            totalEpisodes: 0,
            overallProgress: 0,
            currentStage: .failed,
            message: "Exportação cancelada."
        )
    }

    func exportEpisodes(selection: Set<Int>?) async {
        let task = Task { await self.performExportEpisodes(selection: selection) }
        exportTask = task
        await task.value
        exportTask = nil
    }

    private func performExportEpisodes(selection: Set<Int>?) async {
        let seconds = currentProject.episodes
            .filter { selection?.contains($0.index + 1) ?? true }
            .map { $0.storyline().map(\.end).max() ?? 0 }
            .reduce(0, +)
        // Roughly 1.5 MB per second at 1080p, doubled for the temporary render.
        let needed = Int64(max(200, seconds * 3) * 1_000_000)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        if let available = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           available < needed {
            let formatter = ByteCountFormatter()
            errorMessage = "Espaço insuficiente para exportar: são necessários cerca de \(formatter.string(fromByteCount: needed)) e há \(formatter.string(fromByteCount: available)) livres."
            return
        }
        showExportProgress = true
        exportProgress = nil
        lastExportZIPURL = nil
        lastExportedFiles = []
        photoSaveStatus = nil
        isPreparingZIP = false
        exportFinalized = false

        do {
            let result = try await exportManager.exportAllEpisodes(
                project: currentProject,
                settings: exportSettings,
                selectedEpisodes: selection
            ) { progress in
                Task { @MainActor in
                    guard !self.exportFinalized else { return }
                    self.exportProgress = progress
                }
            }

            exportFinalized = true
            lastExportedFiles = result.results.map(\.videoURL) + result.results.compactMap(\.coverURL)
            let summary = result.errors.isEmpty
                ? "Exportação concluída: \(result.successCount) episódios"
                : "Exportação concluída: \(result.successCount) vídeo(s) · \(result.failureCount) com erro"
            exportProgress = BatchExportProgress(
                currentEpisode: 0,
                totalEpisodes: result.results.count,
                overallProgress: 1.0,
                currentStage: .completed,
                message: summary
            )
            if !result.errors.isEmpty {
                let details = result.errors.map { "Episódio \($0.episodeNumber): \($0.error)" }.joined(separator: "\n")
                errorMessage = "\(result.failureCount) episódio(s) não foram exportados.\n\(details)"
            }
            if exportSettings.includeCovers, !result.results.isEmpty {
                await prepareExportZIP(result.results, name: project.name)
            }
        } catch {
            if isExportCancellation(error) {
                exportFinalized = true
                exportProgress = cancelledExportProgress()
            } else {
                showExportProgress = false
                errorMessage = "Erro na exportação: \(Self.describe(error))"
            }
        }
    }

    func exportAllEpisodes() async {
        await exportEpisodes(selection: nil)
    }

    /// Multiplicar conteúdo: exports every episode once per variant setting, then zips everything.
    func exportVariants(_ variants: [ExportSettings]) async {
        guard !variants.isEmpty else { return }
        let task = Task { await self.performExportVariants(variants) }
        exportTask = task
        await task.value
        exportTask = nil
    }

    private func performExportVariants(_ variants: [ExportSettings]) async {
        showExportProgress = true
        exportProgress = nil
        lastExportZIPURL = nil
        lastExportedFiles = []
        photoSaveStatus = nil
        isPreparingZIP = false
        exportFinalized = false
        var allResults: [ExportResult] = []
        do {
            for (index, variant) in variants.enumerated() {
                let result = try await exportManager.exportAllEpisodes(
                    project: currentProject,
                    settings: variant,
                    selectedEpisodes: nil
                ) { progress in
                    Task { @MainActor in
                        guard !self.exportFinalized else { return }
                        self.exportProgress = BatchExportProgress(
                            currentEpisode: progress.currentEpisode,
                            totalEpisodes: progress.totalEpisodes,
                            overallProgress: (Double(index) + progress.overallProgress) / Double(variants.count),
                            currentStage: progress.currentStage,
                            message: "Variação \(index + 1)/\(variants.count) · \(progress.message)"
                        )
                    }
                }
                allResults.append(contentsOf: result.results)
            }
            exportFinalized = true
            lastExportedFiles = allResults.map(\.videoURL) + allResults.compactMap(\.coverURL)
            exportProgress = BatchExportProgress(
                currentEpisode: 0,
                totalEpisodes: allResults.count,
                overallProgress: 1.0,
                currentStage: .completed,
                message: "Multiplicação concluída: \(allResults.count) vídeos"
            )
            if allResults.count > 1 {
                await prepareExportZIP(allResults, name: "\(project.name)_multiplicar")
            }
        } catch {
            if isExportCancellation(error) {
                exportFinalized = true
                exportProgress = cancelledExportProgress()
            } else {
                showExportProgress = false
                errorMessage = "Erro na multiplicação: \(Self.describe(error))"
            }
        }
    }

    /// Builds the optional ZIP after the videos are already available to save/share.
    private func prepareExportZIP(_ results: [ExportResult], name: String) async {
        isPreparingZIP = true
        defer { isPreparingZIP = false }
        do {
            lastExportZIPURL = try await exportManager.createZIP(from: results, projectName: name)
        } catch {
            photoSaveStatus = "Vídeos prontos, mas o ZIP falhou: \(Self.describe(error))"
        }
    }

    /// Saves the videos from the last export to the user's photo library.
    func saveExportedVideosToPhotos() async {
        let videos = lastExportedFiles.filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
        guard !videos.isEmpty else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            photoSaveStatus = "Permita o acesso à Galeria nos Ajustes para salvar os vídeos."
            return
        }
        photoSaveStatus = "Salvando na Galeria…"
        var saved = 0
        var firstError: Error?
        for url in videos {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
                }
                saved += 1
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if saved == videos.count {
            photoSaveStatus = "\(saved) vídeo(s) salvos na Galeria."
        } else if saved > 0 {
            photoSaveStatus = "\(saved) vídeo(s) salvos; \(videos.count - saved) falharam."
        } else {
            photoSaveStatus = "Falha ao salvar na Galeria: \(Self.describe(firstError ?? ProcessorError.exportFailed))"
        }
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
