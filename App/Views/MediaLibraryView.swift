import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MediaLibraryView: View {
    @Binding var assets: [MediaAsset]
    let onAdd: () -> Void
    let onRemove: (MediaAsset) -> Void
    let onSelectForIntro: (MediaAsset) -> Void
    let onSelectForOutro: (MediaAsset) -> Void
    let onSelectForRecap: (MediaAsset) -> Void
    
    @State private var showingImporter = false
    @State private var selectedFilter: AssetType? = nil
    @State private var showingActionSheet = false
    @State private var assetForAction: MediaAsset?
    
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
                Button("Usar como Introdução") { onSelectForIntro(asset) }
                Button("Usar como Encerramento") { onSelectForOutro(asset) }
                Button("Usar como Recapitulação") { onSelectForRecap(asset) }
            }
            Button("Excluir", role: .destructive) { onRemove(asset) }
            Button("Cancelar", role: .cancel) {}
        } message: { asset in
            Text("Escolha como usar este \(asset.type.rawValue.lowercased())")
        }
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
    
    @Environment(\.dismiss) private var dismiss
    @State private var showingVideoImporter = false
    @State private var showingAudioImporter = false
    @State private var showingImagePicker = false
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
                        switch selectedType {
                        case .video: showingVideoImporter = true
                        case .audio: showingAudioImporter = true
                        case .image: showingImagePicker = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: selectedType.icon)
                            Text("Selecionar \(selectedType.rawValue)")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isImporting)
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
            .fileImporter(
                isPresented: $showingVideoImporter,
                allowedContentTypes: VideoImporter.supportedVideoTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result, type: .video)
            }
            .fileImporter(
                isPresented: $showingAudioImporter,
                allowedContentTypes: VideoImporter.supportedAudioTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result, type: .audio)
            }
            .photosPicker(
                isPresented: $showingImagePicker,
                selection: $imageSelection,
                matching: .images
            )
        }
    }
    
    @State private var imageSelection: PhotosPickerItem?
    
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