import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVKit

struct MediaLibraryView: View {
    @Binding var assets: [MediaAsset]
    let onAdd: () -> Void
    let onRemove: (MediaAsset) -> Void
    let onSelectForIntro: (MediaAsset, ClipSelection) -> Void
    let onSelectForOutro: (MediaAsset, ClipSelection) -> Void
    let onSelectForRecap: (MediaAsset, ClipSelection) -> Void
    
    @State private var showingImporter = false
    @State private var selectedFilter: AssetType? = nil
    @State private var showingActionSheet = false
    @State private var assetForAction: MediaAsset?
    @State private var trimRequest: AssetTrimRequest?
    
    var filteredAssets: [MediaAsset] {
        if let filter = selectedFilter {
            return assets.filter { $0.type == filter }
        }
        return assets
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                
                if assets.isEmpty {
                    emptyState
                } else {
                    assetGrid
                }
            }
            .navigationTitle("Biblioteca de Mídia")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        ForEach(AssetType.allCases) { type in
                            Button(type.rawValue) {
                                selectedFilter = selectedFilter == type ? nil : type
                            }
                        }
                        if selectedFilter != nil {
                            Divider()
                            Button("Todos") { selectedFilter = nil }
                        }
                    } label: {
                        Label(selectedFilter?.rawValue ?? "Todos", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Importar", systemImage: "plus") { onAdd() }
                }
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 8) {
                Text("Biblioteca vazia")
                    .font(.title2.bold())
                Text("Importe vídeos, áudios e imagens para usar como introduções, encerramentos, recapitulações e trilhas sonoras.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Button("Importar Mídia", systemImage: "plus.circle.fill") { onAdd() }
                .font(.headline)
                .frame(width: 200)
                .padding()
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var assetGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                ForEach(filteredAssets) { asset in
                    AssetCardView(
                        asset: asset,
                        onTap: { assetForAction = asset; showingActionSheet = true },
                        onDelete: { onRemove(asset) }
                    )
                    .onDrag { NSItemProvider(object: asset.id.uuidString as NSString) }
                }
            }
            .padding()
        }
        .confirmationDialog(
            assetForAction?.name ?? "",
            isPresented: $showingActionSheet,
            presenting: assetForAction
        ) { asset in
            if asset.type == .video {
                Button("Usar como Introdução") { beginTrimming(asset, for: .intro) }
                Button("Usar como Encerramento") { beginTrimming(asset, for: .outro) }
                Button("Usar como Recapitulação") { beginTrimming(asset, for: .recap) }
            }
            Button("Excluir", role: .destructive) { onRemove(asset) }
            Button("Cancelar", role: .cancel) {}
        } message: { asset in
            Text("Escolha como usar este \(asset.type.rawValue.lowercased())")
        }
        .sheet(item: $trimRequest) { request in
            AssetTrimSheet(asset: request.asset, track: request.track) { selection in
                switch request.track {
                case .intro: onSelectForIntro(request.asset, selection)
                case .outro: onSelectForOutro(request.asset, selection)
                case .recap: onSelectForRecap(request.asset, selection)
                default: break
                }
            }
        }
    }

    private func beginTrimming(_ asset: MediaAsset, for track: TrackType) {
        trimRequest = AssetTrimRequest(asset: asset, track: track)
    }
}

struct AssetTrimRequest: Identifiable {
    let id = UUID()
    let asset: MediaAsset
    let track: TrackType
}

struct AssetTrimSheet: View {
    let asset: MediaAsset
    let track: TrackType
    let vocabulary: [String]
    let onAssign: (ClipSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startTime = 0.0
    @State private var endTime: Double
    @State private var player: AVPlayer
    @State private var narration: MediaAsset?
    @State private var clipVolume: Float = 1
    @State private var showingNarration = false
    @State private var detectedWords: [TranscriptWord]?
    @State private var hookProgress: Double?
    @State private var hookError: String?
    @State private var hookTask: Task<Void, Never>?

    private let minimumDuration = 0.1

    /// Words already transcribed for an asset (in-memory only), keyed by asset id.
    static var hookWordCache: [UUID: [TranscriptWord]] = [:]

    var isVinheta: Bool {
        track == .intro || track == .outro || track == .recap
    }

    private var defaultEnd: Double {
        isVinheta ? min(asset.duration, track == .recap ? 6 : 5) : asset.duration
    }

    private var suggestions: [HookSuggestion] {
        guard isVinheta, let words = detectedWords else { return [] }
        let purpose: HookPurpose = track == .outro ? .closing : .opening
        return HookFinder.suggest(words: words, duration: asset.duration, purpose: purpose)
    }

    init(asset: MediaAsset, track: TrackType, words: [TranscriptWord]? = nil,
         vocabulary: [String] = [], onAssign: @escaping (ClipSelection) -> Void) {
        self.asset = asset
        self.track = track
        self.vocabulary = vocabulary
        self.onAssign = onAssign
        let vinheta = track == .intro || track == .outro || track == .recap
        let initial = words ?? AssetTrimSheet.hookWordCache[asset.id]
        var end = vinheta ? min(asset.duration, track == .recap ? 6 : 5) : asset.duration
        var start = 0.0
        if vinheta, let words = initial {
            let purpose: HookPurpose = track == .outro ? .closing : .opening
            if let top = HookFinder.suggest(words: words, duration: asset.duration, purpose: purpose).first {
                start = top.start
                end = top.end
            }
        }
        self._startTime = State(initialValue: start)
        self._endTime = State(initialValue: end)
        self._player = State(initialValue: AVPlayer(url: asset.url))
        self._detectedWords = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VideoPlayer(player: player)
                        .frame(height: 220)

                    if isVinheta {
                        Text("Trecho: \(String(format: "%.1f", endTime - startTime)) s (\(formatTime(startTime))–\(formatTime(endTime)))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach([3.0, 5, 8, 10, 15], id: \.self) { length in
                                Button {
                                    applyDuration(length)
                                } label: {
                                    Text("\(Int(length)) s")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        if endTime - startTime > 15 {
                            Text(track == .recap
                                 ? "Recaps curtos funcionam melhor."
                                 : "Aberturas e encerramentos curtos (3–10 s) funcionam melhor.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    TrimRangeView(
                        url: asset.url,
                        duration: asset.duration,
                        start: $startTime,
                        end: $endTime,
                        minimumDuration: minimumDuration
                    ) { time in
                        player.pause()
                        player.seek(
                            to: CMTime(seconds: time, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                    }
                    .padding(.vertical, 4)

                    Button {
                        player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
                        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: endTime, preferredTimescale: 600)
                        player.play()
                    } label: {
                        Label("Pré-visualizar trecho", systemImage: "play.fill")
                    }
                } header: {
                    Text(asset.name)
                } footer: {
                    Text("Selecione o trecho do vídeo que será usado como \(track.rawValue.lowercased()).")
                }

                if isVinheta {
                    Section {
                        if detectedWords != nil {
                            ForEach(suggestions) { suggestion in
                                Button {
                                    startTime = suggestion.start
                                    endTime = suggestion.end
                                    playSelection()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\"\(suggestion.text)\"")
                                                .font(.caption)
                                                .lineLimit(2)
                                            Text("\(formatTime(suggestion.start)) · \(String(format: "%.1f", suggestion.duration)) s")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                            if !suggestion.reasons.isEmpty {
                                                HStack(spacing: 4) {
                                                    ForEach(suggestion.reasons, id: \.self) { reason in
                                                        Text(reason)
                                                            .font(.caption2)
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 2)
                                                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                                                    }
                                                }
                                            }
                                        }
                                        Spacer()
                                        if abs(startTime - suggestion.start) < 0.05 && abs(endTime - suggestion.end) < 0.05 {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } else if hookProgress != nil {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Ouvindo o vídeo… \(Int((hookProgress ?? 0) * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button {
                                detectHooks()
                            } label: {
                                Label("Encontrar ganchos na fala", systemImage: "waveform")
                            }
                            if let hookError = hookError {
                                Text(hookError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    } header: {
                        Text(track == .outro ? "Sugestões de encerramento" : "Sugestões de gancho")
                    } footer: {
                        Text(track == .outro
                             ? "Dica: um convite curto para a próxima parte ou para seguir o canal."
                             : "Dica: uma pergunta ou frase forte nos primeiros segundos prende quem está assistindo.")
                    }
                }

                Section {
                    if let narration = narration {
                        HStack {
                            Image(systemName: "mic.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading) {
                                Text(narration.name)
                                Text(formatTime(narration.duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                self.narration = nil
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        Button { showingNarration = true } label: {
                            Label("Gravar de novo", systemImage: "mic.badge.plus")
                        }
                    } else {
                        Button {
                            player.pause()
                            showingNarration = true
                        } label: {
                            Label("Gravar narração para este trecho", systemImage: "mic.badge.plus")
                        }
                    }
                    HStack {
                        Image(systemName: "speaker.wave.2")
                        Text("Áudio do vídeo")
                        Slider(value: $clipVolume, in: 0...1)
                        Text("\(Int(clipVolume * 100))%")
                            .monospacedDigit()
                            .frame(width: 44)
                    }
                } header: {
                    Text("Narração")
                } footer: {
                    Text("A narração fica vinculada a este clipe e acompanha ele em todos os episódios. Abaixe o áudio do vídeo para a voz ficar em destaque.")
                }
            }
            .sheet(isPresented: $showingNarration) {
                NarrationRecorderSheet(
                    title: "Narração",
                    hint: "Grave até \(formatTime(endTime - startTime)); o excedente é cortado no fim do clipe.",
                    onRecordingChanged: { recording in
                        guard recording else {
                            player.pause()
                            player.isMuted = false
                            return
                        }
                        player.isMuted = true
                        player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
                        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: endTime, preferredTimescale: 600)
                        player.play()
                    },
                    onSave: { asset in
                        player.isMuted = false
                        narration = asset
                        if clipVolume > 0.3 { clipVolume = 0.3 }
                    }
                )
            }
            .navigationTitle("Aparar vídeo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        player.pause()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isVinheta ? "Usar trecho" : "Atribuir") {
                        player.pause()
                        onAssign(ClipSelection(
                            startTime: startTime,
                            endTime: endTime,
                            narration: narration,
                            clipVolume: clipVolume
                        ))
                        dismiss()
                    }
                    .disabled(asset.duration < minimumDuration || endTime <= startTime)
                }
            }
            .onDisappear {
                player.pause()
                hookTask?.cancel()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func applyDuration(_ length: Double) {
        endTime = min(asset.duration, startTime + length)
        if endTime - startTime < length {
            startTime = max(0, endTime - length)
        }
    }

    private func playSelection() {
        player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: endTime, preferredTimescale: 600)
        player.play()
    }

    private func detectHooks() {
        hookError = nil
        hookProgress = 0
        let url = asset.url
        let vocabulary = vocabulary
        hookTask = Task { @MainActor in
            do {
                let result = try await TranscriptionService.shared.transcribeVideo(
                    at: url,
                    localeIdentifier: "pt-BR",
                    contextualStrings: vocabulary,
                    onChunk: { seconds in
                        Task { @MainActor in
                            hookProgress = min(1, max(0, seconds / max(1, self.asset.duration)))
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                var words: [TranscriptWord] = []
                for cue in result.cues {
                    if !cue.words.isEmpty {
                        words.append(contentsOf: cue.words)
                    } else {
                        let tokens = cue.text.split(whereSeparator: { $0 == " " }).map(String.init)
                        let span = max(0.05, cue.endTime - cue.startTime)
                        let step = span / Double(max(1, tokens.count))
                        for (index, token) in tokens.enumerated() {
                            words.append(TranscriptWord(
                                text: token,
                                start: cue.startTime + step * Double(index),
                                end: cue.startTime + step * Double(index + 1)
                            ))
                        }
                    }
                }
                if words.isEmpty {
                    hookError = "Nenhuma fala encontrada neste vídeo. Ajuste o trecho manualmente."
                } else {
                    AssetTrimSheet.hookWordCache[asset.id] = words
                    detectedWords = words
                    if let top = suggestions.first {
                        startTime = top.start
                        endTime = top.end
                    }
                }
                hookProgress = nil
            } catch {
                guard !Task.isCancelled else { return }
                hookError = error.localizedDescription
                hookProgress = nil
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct AssetCardView: View {
    let asset: MediaAsset
    let onTap: () -> Void
    let onDelete: () -> Void
    
    @State private var thumbnail: UIImage?
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    thumbnailView
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    typeBadge
                        .padding(8)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    
                    HStack(spacing: 8) {
                        if asset.duration > 0 {
                            Label(formatDuration(asset.duration), systemImage: "clock")
                                .font(.caption)
                        }
                        Text(ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file))
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Excluir", systemImage: "trash", role: .destructive) { onDelete() }
        }
        .task {
            await loadThumbnail()
        }
    }
    
    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail = thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.2))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    Image(systemName: asset.type.icon)
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
        }
    }
    
    private var typeBadge: some View {
        Label(asset.type.rawValue, systemImage: asset.type.icon)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
    }
    
    private func loadThumbnail() async {
        if let thumbURL = asset.thumbnailFileURL, let image = UIImage(contentsOfFile: thumbURL.path) {
            await MainActor.run { self.thumbnail = image }
        } else if asset.type == .image, let image = UIImage(contentsOfFile: asset.url.path) {
            await MainActor.run { self.thumbnail = image }
        }
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

extension AssetType {
    var icon: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        }
    }
}

struct AssetImportSheet: View {
    let onComplete: (MediaAsset) -> Void

    init(initialType: AssetType = .video, onComplete: @escaping (MediaAsset) -> Void) {
        self.onComplete = onComplete
        self._selectedType = State(initialValue: initialType)
    }
    
    @Environment(\.dismiss) private var dismiss
    @State private var showingVideoImporter = false
    @State private var showingAudioImporter = false
    @State private var showingGalleryPicker = false
    @State private var selectedType: AssetType = .video
    @State private var isImporting = false
    @State private var errorMessage: String?
    
    private let importer = VideoImporter.shared
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Tipo de Mídia") {
                    Picker("Tipo", selection: $selectedType) {
                        ForEach(AssetType.allCases) { type in
                            Label(type.rawValue, systemImage: type.icon).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section {
                    Button {
                        fileImportType = selectedType
                        showingVideoImporter = true
                    } label: {
                        HStack {
                            Image(systemName: selectedType.icon)
                            Text("Selecionar \(selectedType.rawValue)")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isImporting)
                    if selectedType == .image || selectedType == .video {
                        Button {
                            showingGalleryPicker = true
                        } label: {
                            Label("Escolher da galeria de Fotos", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isImporting)
                    }
                    if isImporting {
                        ProgressView("Importando…")
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                
                Section {
                    Text("Dicas:")
                        .font(.footnote.bold())
                    Text("• Vídeos: use para introduções, encerramentos e recapitulações")
                    Text("• Áudios: use para trilhas sonoras e narrações")
                    Text("• Imagens: use para capas personalizadas e overlays")
                }
            }
            .navigationTitle("Importar Mídia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
            // A single file importer: SwiftUI only honours one `.fileImporter` per view.
            .fileImporter(
                isPresented: $showingVideoImporter,
                allowedContentTypes: allowedTypes(for: fileImportType),
                allowsMultipleSelection: false
            ) { result in
                handleImport(result, type: fileImportType)
            }
            .photosPicker(
                isPresented: $showingGalleryPicker,
                selection: $gallerySelection,
                matching: galleryPickerFilter
            )
            .onChange(of: gallerySelection) { item in
                guard let item = item else { return }
                importGalleryItem(item)
            }
        }
    }
    
    @State private var gallerySelection: PhotosPickerItem?
    @State private var fileImportType: AssetType = .video

    private var galleryPickerFilter: PHPickerFilter {
        if selectedType == .video { return .videos }
        return .images
    }

    private func allowedTypes(for type: AssetType) -> [UTType] {
        switch type {
        case .video: return VideoImporter.supportedVideoTypes
        case .audio: return VideoImporter.supportedAudioTypes
        case .image: return VideoImporter.supportedImageTypes
        }
    }

    private func importGalleryItem(_ item: PhotosPickerItem) {
        if selectedType == .video {
            importGalleryVideo(item)
        } else {
            importPhoto(item)
        }
    }

    private func importGalleryVideo(_ item: PhotosPickerItem) {
        Task {
            isImporting = true
            errorMessage = nil
            defer {
                isImporting = false
                gallerySelection = nil
            }
            do {
                guard let video = try await item.loadTransferable(type: GalleryVideo.self) else {
                    errorMessage = "Não foi possível ler o vídeo selecionado."
                    return
                }
                defer { try? FileManager.default.removeItem(at: video.url) }
                let asset = try await importer.importMediaAsset(from: video.url, type: .video)
                onComplete(asset)
                dismiss()
            } catch {
                errorMessage = "Erro ao importar vídeo da galeria: \(error.localizedDescription)"
            }
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        Task {
            isImporting = true
            errorMessage = nil
            defer {
                isImporting = false
                gallerySelection = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    errorMessage = "Não foi possível ler a imagem selecionada."
                    return
                }
                let alpha = image.cgImage?.alphaInfo ?? .none
                let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(alpha)
                guard let encoded = hasAlpha ? image.pngData() : image.jpegData(compressionQuality: 0.92) else {
                    errorMessage = "Não foi possível ler a imagem selecionada."
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("imagem_\(UUID().uuidString).\(hasAlpha ? "png" : "jpg")")
                try encoded.write(to: url, options: .atomic)
                defer { try? FileManager.default.removeItem(at: url) }
                let asset = try await importer.importMediaAsset(from: url, type: .image)
                onComplete(asset)
                dismiss()
            } catch {
                errorMessage = "Erro ao importar imagem: \(error.localizedDescription)"
            }
        }
    }
    
    private func handleImport(_ result: Result<[URL], Error>, type: AssetType) {
        Task {
            isImporting = true
            errorMessage = nil
            
            do {
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let asset = try await importer.importMediaAsset(from: url, type: type)
                    await MainActor.run {
                        onComplete(asset)
                        dismiss()
                    }
                case .failure(let error):
                    errorMessage = "Erro ao importar: \(error.localizedDescription)"
                }
            } catch {
                errorMessage = "Erro: \(error.localizedDescription)"
            }
            
            isImporting = false
        }
    }
}