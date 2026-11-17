import SwiftUI

private func segment(_ segment: VideoSegment?, matchesTemplate template: SegmentTemplate?) -> Bool {
    guard let segment = segment, let template = template else { return false }
    let expected = template.toSegment()
    return segment.sourceType == expected.sourceType
        && segment.assetID == expected.assetID
        && abs(segment.startTime - expected.startTime) < 0.01
        && abs(segment.endTime - expected.endTime) < 0.01
        && segment.trackIndex == expected.trackIndex
        && segment.isEnabled == expected.isEnabled
        && segment.timelineStartTime == expected.timelineStartTime
        && segment.transition == expected.transition
        && abs(segment.transitionDuration - expected.transitionDuration) < 0.01
        && abs(segment.clipVolume - expected.clipVolume) < 0.001
        && segment.narrationAssetID == expected.narrationAssetID
        && abs(segment.narrationLevel - expected.narrationLevel) < 0.001
        && segment.narrationOffset == expected.narrationOffset
        && segment.audioFadeIn == expected.audioFadeIn
        && segment.audioFadeOut == expected.audioFadeOut
        && abs(segment.playbackSpeed - expected.playbackSpeed) < 0.001
        && segment.clipTransform == expected.clipTransform
        && segment.clipAdjustments == expected.clipAdjustments
}

struct EpisodeListView: View {
    @Binding var episodes: [Episode]
    let project: Project
    let operation: ProjectOperation?
    let onSelect: (Episode) -> Void
    let onEdit: (Episode) -> Void
    let onRegenerate: (Double) -> Void
    
    @State private var showingRegenerateAlert = false
    @State private var newEpisodeLength: Double = 60
    @State private var editingEpisode: Episode?

    private var allowsAutomaticSplit: Bool {
        operation != .multiply && operation != .podcast && operation != .speechEdit
    }

    private var outputsTitle: String {
        if operation == .speechEdit { return "Clipe" }
        return operation == .episodes ? "Episódios" : "Saídas"
    }

    private var outputsCountLabel: String {
        if operation == .speechEdit { return "clipe" }
        return operation == .episodes ? "episódios" : "saídas"
    }
    
    var body: some View {
        List {
            if allowsAutomaticSplit {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Divisão Automática", systemImage: "scissors")
                                .font(.headline)
                            Spacer()
                            Button("Regenerar") { showingRegenerateAlert = true }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }

                        HStack {
                            Text("Duração por episódio")
                            Spacer()
                            TextField("", value: $newEpisodeLength, format: .number)
                                .keyboardType(.numberPad)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                            Text("segundos").foregroundStyle(.secondary)
                        }

                        Text("\(episodes.count) \(outputsCountLabel) • \(formatDuration(project.sourceVideoDuration)) total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Section(outputsTitle) {
                ForEach(episodes) { episode in
                    EpisodeRowView(episode: episode, project: project)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(episode) }
                        .contextMenu {
                            Button("Editar", systemImage: "pencil") { editingEpisode = episode }
                            Button("Pré-visualizar", systemImage: "play.circle") { onSelect(episode) }
                            if episode.index > 0 {
                                Divider()
                                Button("Mover para cima") { moveEpisode(episode, direction: -1) }
                                Button("Mover para baixo") { moveEpisode(episode, direction: 1) }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteEpisode(episode)
                            } label: {
                                Label("Excluir", systemImage: "trash")
                            }
                        }
                }
                .onMove { indices, newOffset in
                    episodes.move(fromOffsets: indices, toOffset: newOffset)
                    reindexEpisodes()
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $editingEpisode) { episode in
            EpisodeDetailView(
                episode: Binding(
                    get: { editingEpisode ?? episode },
                    set: { editingEpisode = $0 }
                ),
                project: project,
                mediaAssets: project.mediaAssets,
                onSave: { onEdit(editingEpisode ?? episode) }
            )
        }
        .alert("Regenerar Episódios", isPresented: $showingRegenerateAlert) {
            TextField("Duração (segundos)", value: $newEpisodeLength, format: .number)
                .keyboardType(.numberPad)
            Button("Cancelar", role: .cancel) {}
            Button("Regenerar") {
                onRegenerate(newEpisodeLength)
            }
        } message: {
            Text("Isso recriará todos os episódios com a nova duração. Edições manuais serão perdidas.")
        }
    }
    
    private func reindexEpisodes() {
        for index in episodes.indices {
            episodes[index].index = index
        }
    }
    
    private func moveEpisode(_ episode: Episode, direction: Int) {
        guard let oldIndex = episodes.firstIndex(where: { $0.id == episode.id }) else { return }
        let newIndex = oldIndex + direction
        guard newIndex >= 0 && newIndex < episodes.count else { return }
        episodes.swapAt(oldIndex, newIndex)
        reindexEpisodes()
    }
    
    private func deleteEpisode(_ episode: Episode) {
        guard operation != .speechEdit || episodes.count > 1 else { return }
        episodes.removeAll { $0.id == episode.id }
        reindexEpisodes()
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

struct EpisodeRowView: View {
    let episode: Episode
    let project: Project

    private var hasCustomIntro: Bool {
        episode.customIntroTemplate != nil
            || (episode.useGlobalIntro
                && episode.introSegment != nil
                && !segment(episode.introSegment, matchesTemplate: project.introTemplate))
    }

    private var hasCustomOutro: Bool {
        episode.customOutroTemplate != nil
            || (episode.useGlobalOutro
                && episode.outroSegment != nil
                && !segment(episode.outroSegment, matchesTemplate: project.outroTemplate))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(episode.title)
                    .font(.headline)
                if let format = episode.outputAspectRatio {
                    Text(format.rawValue)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                Spacer()
                Text(formatDuration(episode.totalDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            
            HStack(spacing: 16) {
                if let intro = episode.effectiveIntro {
                    SegmentBadge(title: "Intro", duration: intro.duration, color: .purple)
                }
                
                if !episode.effectiveRecaps.isEmpty {
                    let totalRecap = episode.effectiveRecaps.reduce(0) { $0 + $1.duration }
                    SegmentBadge(title: "Recap", duration: totalRecap, color: .orange)
                }
                
                SegmentBadge(title: "Principal", duration: episode.mainDuration, color: .blue)
                
                if let outro = episode.effectiveOutro {
                    SegmentBadge(title: "Outro", duration: outro.duration, color: .green)
                }
                
                Spacer()
            }
            
            HStack {
                Text("Principal: \(formatTime(episode.mainStart)) – \(formatTime(episode.mainEnd))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if hasCustomIntro {
                    Label("Intro personalizada", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                if hasCustomOutro {
                    Label("Outro personalizado", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct SegmentBadge: View {
    let title: String
    let duration: Double
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.caption2.weight(.medium))
            Text(formatDuration(duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct EpisodeDetailView: View {
    @Binding var episode: Episode
    let project: Project
    let mediaAssets: [MediaAsset]
    let onSave: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var outputFormat: AspectRatio?
    @State private var mainStart: Double
    @State private var mainEnd: Double
    @State private var useCustomIntro = false
    @State private var customIntroAsset: MediaAsset?
    @State private var customIntroStart: Double = 0
    @State private var customIntroEnd: Double = 5
    @State private var useCustomOutro = false
    @State private var customOutroAsset: MediaAsset?
    @State private var customOutroStart: Double = 0
    @State private var customOutroEnd: Double = 5
    @State private var recapMode: RecapSettings.RecapMode = .manual
    @State private var recapSegments: [VideoSegment] = []
    private let initialRecapMode: RecapSettings.RecapMode
    private let initialHasIntro: Bool
    private let initialHasOutro: Bool
    private let initialCustomIntro: Bool
    private let initialCustomOutro: Bool
    
    init(episode: Binding<Episode>, project: Project, mediaAssets: [MediaAsset], onSave: @escaping () -> Void) {
        let currentEpisode = episode.wrappedValue
        self._episode = episode
        self.project = project
        self.mediaAssets = mediaAssets
        self.onSave = onSave
        self._title = State(initialValue: currentEpisode.displayTitle ?? "")
        self._outputFormat = State(initialValue: currentEpisode.outputAspectRatio)
        self._mainStart = State(initialValue: currentEpisode.mainStart)
        self._mainEnd = State(initialValue: currentEpisode.mainEnd)
        self.initialHasIntro = currentEpisode.effectiveIntro != nil
            || (currentEpisode.useGlobalIntro && project.introTemplate != nil)
        self.initialHasOutro = currentEpisode.effectiveOutro != nil
            || (currentEpisode.useGlobalOutro && project.outroTemplate != nil)
        let hasCustomIntro = currentEpisode.customIntroTemplate != nil
            || (currentEpisode.useGlobalIntro
                && currentEpisode.introSegment != nil
                && !segment(currentEpisode.introSegment, matchesTemplate: project.introTemplate))
        self.initialCustomIntro = hasCustomIntro
        self._useCustomIntro = State(initialValue: hasCustomIntro)
        self._customIntroAsset = State(initialValue: mediaAssets.first {
            $0.id == (currentEpisode.customIntroTemplate?.assetID ?? currentEpisode.introSegment?.assetID)
        })
        self._customIntroStart = State(initialValue: currentEpisode.customIntroTemplate?.startTime ?? currentEpisode.introSegment?.startTime ?? 0)
        self._customIntroEnd = State(initialValue: currentEpisode.customIntroTemplate?.endTime ?? currentEpisode.introSegment?.endTime ?? 5)
        let hasCustomOutro = currentEpisode.customOutroTemplate != nil
            || (currentEpisode.useGlobalOutro
                && currentEpisode.outroSegment != nil
                && !segment(currentEpisode.outroSegment, matchesTemplate: project.outroTemplate))
        self.initialCustomOutro = hasCustomOutro
        self._useCustomOutro = State(initialValue: hasCustomOutro)
        self._customOutroAsset = State(initialValue: mediaAssets.first {
            $0.id == (currentEpisode.customOutroTemplate?.assetID ?? currentEpisode.outroSegment?.assetID)
        })
        self._customOutroStart = State(initialValue: currentEpisode.customOutroTemplate?.startTime ?? currentEpisode.outroSegment?.startTime ?? 0)
        self._customOutroEnd = State(initialValue: currentEpisode.customOutroTemplate?.endTime ?? currentEpisode.outroSegment?.endTime ?? 5)
        let hadCustomRecap = currentEpisode.usesCustomRecapSegments == true || !currentEpisode.customRecapSegments.isEmpty
        let initialMode: RecapSettings.RecapMode
        if hadCustomRecap || !currentEpisode.useGlobalRecap {
            initialMode = .manual
        } else {
            initialMode = project.recapSettings.mode
        }
        self.initialRecapMode = initialMode
        self._recapMode = State(initialValue: initialMode)
        let initialRecaps = currentEpisode.customRecapSegments.isEmpty ? currentEpisode.effectiveRecaps : currentEpisode.customRecapSegments
        self._recapSegments = State(initialValue: initialRecaps)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Saída") {
                    TextField("Nome", text: $title)
                    Picker("Formato", selection: $outputFormat) {
                        Text("Seguir projeto").tag(nil as AspectRatio?)
                        ForEach(AspectRatio.allCases) { ratio in
                            Text(ratio.rawValue).tag(ratio as AspectRatio?)
                        }
                    }
                }

                Section("Conteúdo Principal") {
                    HStack {
                        Text("Início")
                        Spacer()
                        TextField("", value: $mainStart, format: .number)
                            .keyboardType(.decimalPad)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                        Text("s")
                    }
                    HStack {
                        Text("Fim")
                        Spacer()
                        TextField("", value: $mainEnd, format: .number)
                            .keyboardType(.decimalPad)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                        Text("s")
                    }
                    if mainEnd <= mainStart {
                        Text("O fim deve ser posterior ao início").font(.caption).foregroundStyle(.red)
                    }
                }
                
                Section("Introdução") {
                    Toggle("Usar introdução personalizada", isOn: $useCustomIntro)
                    if useCustomIntro {
                        Picker("Asset", selection: $customIntroAsset) {
                            Text("Nenhum").tag(nil as MediaAsset?)
                            ForEach(mediaAssets.filter { $0.type == .video }) { asset in
                                Text(asset.name).tag(asset as MediaAsset?)
                            }
                        }
                        
                        HStack {
                            Text("Início")
                            Spacer()
                            TextField("", value: $customIntroStart, format: .number)
                                .keyboardType(.decimalPad)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Fim")
                            Spacer()
                            TextField("", value: $customIntroEnd, format: .number)
                                .keyboardType(.decimalPad)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                
                Section("Recapitulação") {
                    Picker("Modo", selection: $recapMode) {
                        ForEach(RecapSettings.RecapMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    if recapMode == .manual {
                        ForEach(recapSegments.indices, id: \.self) { index in
                            HStack {
                                TextField("Início", value: $recapSegments[index].startTime, format: .number)
                                    .keyboardType(.decimalPad)
                                    .frame(width: 70)
                                    .textFieldStyle(.roundedBorder)
                                Text("–")
                                TextField("Fim", value: $recapSegments[index].endTime, format: .number)
                                    .keyboardType(.decimalPad)
                                    .frame(width: 70)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        Button("Adicionar trecho") {
                            recapSegments.append(VideoSegment(startTime: 0, endTime: 5, sourceType: .mainVideo))
                        }
                    }
                }
                
                Section("Encerramento") {
                    Toggle("Usar encerramento personalizado", isOn: $useCustomOutro)
                    if useCustomOutro {
                        Picker("Asset", selection: $customOutroAsset) {
                            Text("Nenhum").tag(nil as MediaAsset?)
                            ForEach(mediaAssets.filter { $0.type == .video }) { asset in
                                Text(asset.name).tag(asset as MediaAsset?)
                            }
                        }
                        
                        HStack {
                            Text("Início")
                            Spacer()
                            TextField("", value: $customOutroStart, format: .number)
                                .keyboardType(.decimalPad)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text("Fim")
                            Spacer()
                            TextField("", value: $customOutroEnd, format: .number)
                                .keyboardType(.decimalPad)
                                .frame(width: 80)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            .navigationTitle("Editar \(episode.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        saveChanges()
                        dismiss()
                    }
                    .disabled(mainEnd <= mainStart)
                }
            }
        }
    }
    

    private func saveChanges() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        episode.displayTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        episode.outputAspectRatio = outputFormat
        episode.mainStart = mainStart
        episode.mainEnd = mainEnd
        if episode.mainClips.count == 1 {
            var clips = episode.mainClips
            clips[0].startTime = mainStart
            clips[0].endTime = mainEnd
            episode.mainClips = clips
        }
        
        if useCustomIntro {
            if let asset = customIntroAsset {
                episode.customIntroTemplate = nil
                var segment = episode.introSegment ?? VideoSegment(
                    startTime: customIntroStart,
                    endTime: customIntroEnd,
                    sourceType: .introAsset,
                    assetID: asset.id
                )
                segment.startTime = customIntroStart
                segment.endTime = customIntroEnd
                segment.sourceType = .introAsset
                segment.assetID = asset.id
                episode.introSegment = segment
                episode.useGlobalIntro = true
            } else if initialCustomIntro {
                if var template = episode.customIntroTemplate {
                    template.startTime = customIntroStart
                    template.endTime = customIntroEnd
                    episode.customIntroTemplate = template
                } else if var existing = episode.introSegment {
                    existing.startTime = customIntroStart
                    existing.endTime = customIntroEnd
                    episode.introSegment = existing
                    episode.useGlobalIntro = true
                }
            } else {
                episode.customIntroTemplate = nil
                episode.introSegment = initialHasIntro ? project.introTemplate?.toSegment() : nil
                episode.useGlobalIntro = initialHasIntro && project.introTemplate != nil
            }
        } else {
            episode.customIntroTemplate = nil
            episode.introSegment = initialHasIntro ? project.introTemplate?.toSegment() : nil
            episode.useGlobalIntro = initialHasIntro && project.introTemplate != nil
        }
        
        if useCustomOutro {
            if let asset = customOutroAsset {
                episode.customOutroTemplate = nil
                var segment = episode.outroSegment ?? VideoSegment(
                    startTime: customOutroStart,
                    endTime: customOutroEnd,
                    sourceType: .outroAsset,
                    assetID: asset.id
                )
                segment.startTime = customOutroStart
                segment.endTime = customOutroEnd
                segment.sourceType = .outroAsset
                segment.assetID = asset.id
                episode.outroSegment = segment
                episode.useGlobalOutro = true
            } else if initialCustomOutro {
                if var template = episode.customOutroTemplate {
                    template.startTime = customOutroStart
                    template.endTime = customOutroEnd
                    episode.customOutroTemplate = template
                } else if var existing = episode.outroSegment {
                    existing.startTime = customOutroStart
                    existing.endTime = customOutroEnd
                    episode.outroSegment = existing
                    episode.useGlobalOutro = true
                }
            } else {
                episode.customOutroTemplate = nil
                episode.outroSegment = initialHasOutro ? project.outroTemplate?.toSegment() : nil
                episode.useGlobalOutro = initialHasOutro && project.outroTemplate != nil
            }
        } else {
            episode.customOutroTemplate = nil
            episode.outroSegment = initialHasOutro ? project.outroTemplate?.toSegment() : nil
            episode.useGlobalOutro = initialHasOutro && project.outroTemplate != nil
        }

        let wasCustom = episode.usesCustomRecapSegments == true || !episode.customRecapSegments.isEmpty
        episode.customRecapSegments = []
        if recapMode == .manual {
            let recapChanged = recapSegments != episode.effectiveRecaps
            episode.recapSegments = recapSegments
            episode.useGlobalRecap = !recapSegments.isEmpty
            episode.usesCustomRecapSegments = wasCustom || recapChanged || recapMode != initialRecapMode ? true : nil
        } else {
            var recapSettings = project.recapSettings
            recapSettings.enabled = true
            recapSettings.mode = .automatic
            let previousEpisode = project.episodes
                .filter { $0.index < episode.index }
                .max { $0.index < $1.index }
            if let previousEnd = previousEpisode?.mainEnd {
                episode.regenerateRecap(previousEpisodeEnd: previousEnd, settings: recapSettings)
            } else {
                episode.recapSegments = []
            }
            episode.useGlobalRecap = !episode.recapSegments.isEmpty
            episode.usesCustomRecapSegments = nil
        }
        
        onSave()
    }
}