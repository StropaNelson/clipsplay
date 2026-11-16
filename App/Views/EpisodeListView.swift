import SwiftUI

struct EpisodeListView: View {
    @Binding var episodes: [Episode]
    let project: Project
    let onSelect: (Episode) -> Void
    let onEdit: (Episode) -> Void
    let onRegenerate: (Double) -> Void
    
    @State private var showingRegenerateAlert = false
    @State private var newEpisodeLength: Double = 60
    
    var body: some View {
        List {
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
                    
                    Text("\(episodes.count) episódios • \(formatDuration(project.sourceVideoDuration)) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            Section("Episódios") {
                ForEach(episodes) { episode in
                    EpisodeRowView(episode: episode, project: project)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(episode) }
                        .contextMenu {
                            Button("Editar", systemImage: "pencil") { onEdit(episode) }
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
        let newIndex = episode.index + direction
        guard newIndex >= 0 && newIndex < episodes.count else { return }
        episodes.swapAt(episode.index, newIndex)
        reindexEpisodes()
    }
    
    private func deleteEpisode(_ episode: Episode) {
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Episódio \(episode.index + 1)")
                    .font(.headline)
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
                if episode.customIntroTemplate != nil {
                    Label("Intro personalizada", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                if episode.customOutroTemplate != nil {
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
    
    init(episode: Binding<Episode>, project: Project, mediaAssets: [MediaAsset], onSave: @escaping () -> Void) {
        let currentEpisode = episode.wrappedValue
        self._episode = episode
        self.project = project
        self.mediaAssets = mediaAssets
        self.onSave = onSave
        self._mainStart = State(initialValue: currentEpisode.mainStart)
        self._mainEnd = State(initialValue: currentEpisode.mainEnd)
        self._useCustomIntro = State(initialValue: currentEpisode.customIntroTemplate != nil)
        self._customIntroStart = State(initialValue: currentEpisode.customIntroTemplate?.startTime ?? 0)
        self._customIntroEnd = State(initialValue: currentEpisode.customIntroTemplate?.endTime ?? 5)
        self._useCustomOutro = State(initialValue: currentEpisode.customOutroTemplate != nil)
        self._customOutroStart = State(initialValue: currentEpisode.customOutroTemplate?.startTime ?? 0)
        self._customOutroEnd = State(initialValue: currentEpisode.customOutroTemplate?.endTime ?? 5)
        self._recapMode = State(initialValue: project.recapSettings.mode)
        self._recapSegments = State(initialValue: currentEpisode.customRecapSegments)
    }
    
    var body: some View {
        NavigationStack {
            Form {
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
            .navigationTitle("Editar Episódio \(episode.index + 1)")
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
        episode.mainStart = mainStart
        episode.mainEnd = mainEnd
        
        if useCustomIntro, let asset = customIntroAsset {
            episode.customIntroTemplate = SegmentTemplate(
                name: asset.name,
                sourceType: .introAsset,
                assetID: asset.id,
                startTime: customIntroStart,
                endTime: customIntroEnd,
                targetTrack: .intro
            )
        } else {
            episode.customIntroTemplate = nil
        }
        
        if useCustomOutro, let asset = customOutroAsset {
            episode.customOutroTemplate = SegmentTemplate(
                name: asset.name,
                sourceType: .outroAsset,
                assetID: asset.id,
                startTime: customOutroStart,
                endTime: customOutroEnd,
                targetTrack: .outro
            )
        } else {
            episode.customOutroTemplate = nil
        }
        
        if recapMode == .manual {
            episode.customRecapSegments = recapSegments
        }
        
        onSave()
    }
}