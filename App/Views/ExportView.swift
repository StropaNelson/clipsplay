import SwiftUI

struct ExportView: View {
    let project: Project
    let episodes: [Episode]
    @Binding var settings: ExportSettings
    let onExport: (Set<Int>?) -> Void
    let onExportAll: () -> Void
    var onExportVariants: ([ExportSettings]) -> Void = { _ in }
    
    @State private var selectedEpisodes: Set<Int> = []
    @State private var showingExportOptions = false
    @State private var showingMultiply = false
    
    var body: some View {
        NavigationStack {
            List {
                Section("Formato do Vídeo") {
                    Picker("Proporção", selection: $settings.aspectRatio) {
                        ForEach(AspectRatio.allCases) { ratio in
                            Text(ratio.rawValue).tag(ratio)
                        }
                    }
                    
                    Picker("Resolução", selection: $settings.resolution) {
                        ForEach(ExportResolution.allCases) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }
                    
                    Picker("Enquadramento", selection: $settings.fitMode) {
                        ForEach(FitMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    
                    Picker("Qualidade", selection: $settings.quality) {
                        ForEach(ExportQuality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                }
                
                Section("Capas dos Episódios") {
                    Toggle("Fade preto nas pontas", isOn: $settings.fadeEdges)
                    Toggle("Gerar capas", isOn: $settings.includeCovers)
                    
                    if settings.includeCovers {
                        Picker("Tipo de capa", selection: $settings.coverMode) {
                            ForEach(CoverSettings.CoverMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        
                        if settings.coverMode == .captureFrame {
                            HStack {
                                Text("Tempo de captura")
                                Spacer()
                                Slider(value: $settings.coverCaptureTime, in: 0...project.sequenceSourceDuration, step: 1)
                                Text(formatTime(settings.coverCaptureTime))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 50)
                            }
                        }

                        if settings.coverMode == .customImage {
                            Picker("Imagem da capa", selection: $settings.coverImageAssetID) {
                                Text("Selecionar imagem").tag(nil as UUID?)
                                ForEach(project.mediaAssets.filter { $0.type == .image }) { asset in
                                    Text(asset.name).tag(asset.id as UUID?)
                                }
                            }
                            if project.mediaAssets.filter({ $0.type == .image }).isEmpty {
                                Text("Importe uma imagem em Mídia para usá-la como capa.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                Section("Nomenclatura") {
                    TextField("Prefixo do arquivo", text: $settings.fileNamePrefix)
                }
                
                Section("Episódios") {
                    if episodes.isEmpty {
                        Text("Nenhum episódio para exportar")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(episodes) { episode in
                            EpisodeExportRow(
                                episode: episode,
                                isSelected: selectedEpisodes.contains(episode.index + 1) || selectedEpisodes.isEmpty,
                                onToggle: { isSelected in
                                    if isSelected {
                                        selectedEpisodes.insert(episode.index + 1)
                                    } else {
                                        selectedEpisodes.remove(episode.index + 1)
                                    }
                                }
                            )
                        }
                    }
                }
                
                Section {
                    Button {
                        onExport(selectedEpisodes.isEmpty ? nil : selectedEpisodes)
                    } label: {
                        HStack {
                            Spacer()
                            Label(selectedEpisodes.isEmpty ? "Exportar Todos" : "Exportar Selecionados (\(selectedEpisodes.count))", systemImage: "square.and.arrow.up")
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(episodes.isEmpty)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                
                Section {
                    Button("Exportar Todos", systemImage: "square.and.arrow.up") {
                        onExportAll()
                    }
                    .buttonStyle(.bordered)
                    .disabled(episodes.isEmpty)
                }
                
                Section("Multiplicar conteúdo") {
                    Button {
                        showingMultiply = true
                    } label: {
                        Label("Gerar variações em lote", systemImage: "rectangle.stack.badge.plus")
                    }
                    .disabled(episodes.isEmpty)
                }
                
                Section("Estimativa") {
                    ExportEstimateView(project: project, episodes: episodes, settings: settings)
                }
            }
            .navigationTitle("Exportar")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingMultiply) {
                MultiplySheet(base: settings, episodeCount: episodes.count) { variants in
                    onExportVariants(variants)
                }
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct EpisodeExportRow: View {
    let episode: Episode
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    
    var body: some View {
        Button {
            onToggle(!isSelected)
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? Color.accentColor : Color.secondary)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Episódio \(episode.index + 1)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    
                    HStack(spacing: 12) {
                        if let intro = episode.effectiveIntro {
                            Text("Intro: \(formatDuration(intro.duration))")
                                .font(.caption)
                        }
                        if !episode.effectiveRecaps.isEmpty {
                            let total = episode.effectiveRecaps.reduce(0) { $0 + $1.duration }
                            Text("Recap: \(formatDuration(total))")
                                .font(.caption)
                        }
                        Text("Principal: \(formatDuration(episode.mainDuration))")
                            .font(.caption)
                        if let outro = episode.effectiveOutro {
                            Text("Outro: \(formatDuration(outro.duration))")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Text(formatDuration(episode.totalDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct ExportEstimateView: View {
    let project: Project
    let episodes: [Episode]
    let settings: ExportSettings
    
    private var totalDuration: Double {
        episodes.reduce(0) { $0 + $1.totalDuration }
    }
    
    private var estimatedTime: TimeInterval {
        let qualityMultiplier: Double
        switch settings.quality {
        case .low: qualityMultiplier = 0.3
        case .medium: qualityMultiplier = 0.5
        case .high: qualityMultiplier = 0.8
        case .maximum: qualityMultiplier = 1.2
        }
        return totalDuration * qualityMultiplier * Double(episodes.count)
    }
    
    private var estimatedSize: Int64 {
        let bitsPerPixel: Double
        switch settings.resolution {
        case .original: bitsPerPixel = 0.15
        case .p480: bitsPerPixel = 0.1
        case .p720: bitsPerPixel = 0.12
        case .p1080: bitsPerPixel = 0.15
        case .p1440: bitsPerPixel = 0.18
        case .p2160: bitsPerPixel = 0.2
        }
        
        let renderSize = calculateRenderSize()
        let pixelsPerFrame = renderSize.width * renderSize.height
        let frameRate = 30.0
        let bitsPerSecond = pixelsPerFrame * frameRate * bitsPerPixel
        let totalBits = bitsPerSecond * totalDuration
        return Int64(totalBits / 8)
    }
    
    private func calculateRenderSize() -> CGSize {
        let sourceRect = CGRect(origin: .zero, size: project.sourceVideoNaturalSize.cgSize)
            .applying(project.sourceVideoTransform.cgAffineTransform)
        let naturalSize = CGSize(width: abs(sourceRect.width), height: abs(sourceRect.height))
        
        guard let ratio = settings.aspectRatio.ratio else { return naturalSize }
        guard let longSide = settings.resolution.longSide else { return naturalSize }
        
        if ratio >= 1 { return CGSize(width: longSide, height: longSide/ratio) }
        return CGSize(width: longSide*ratio, height: longSide)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(episodes.count) episódios", systemImage: "film.stack")
                Spacer()
                Text(formatDuration(totalDuration))
                    .font(.subheadline.monospacedDigit().bold())
            }
            
            HStack {
                Label("Tempo estimado", systemImage: "clock")
                Spacer()
                Text(formatEstimatedTime(estimatedTime))
                    .font(.subheadline.monospacedDigit().bold())
            }
            
            HStack {
                Label("Tamanho estimado", systemImage: "doc")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: estimatedSize, countStyle: .file))
                    .font(.subheadline.monospacedDigit().bold())
            }
            
            HStack {
                Label("Resolução de saída", systemImage: "rectangle")
                Spacer()
                Text("\(Int(calculateRenderSize().width)) × \(Int(calculateRenderSize().height))")
                    .font(.subheadline.monospacedDigit().bold())
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
    
    private func formatEstimatedTime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        if m > 0 { return "\(m) min \(s) s" }
        return "\(s) s"
    }
}

struct ExportProgressView: View {
    @ObservedObject var viewModel: EditorViewModel
    
    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: ExportShareItem?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let progress = viewModel.exportProgress {
                    VStack(spacing: 16) {
                        ProgressView(value: progress.overallProgress)
                            .progressViewStyle(.linear)
                            .scaleEffect(y: 3)
                        
                        HStack {
                            Text("\(Int(progress.overallProgress * 100))%")
                                .font(.title.bold().monospacedDigit())
                            Spacer()
                            Text("\(progress.currentEpisode) / \(progress.totalEpisodes)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        
                        Text(progress.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        
                        if progress.currentStage == .completed || progress.currentStage == .failed {
                            if let zipURL = viewModel.lastExportZIPURL {
                                Button {
                                    shareItem = ExportShareItem(url: zipURL)
                                } label: {
                                    Label("Compartilhar ZIP", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                            }
                            Button("Fechar") { dismiss() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        }
                    }
                    .padding()
                } else {
                    ProgressView("Preparando exportação...")
                        .scaleEffect(1.5)
                }
            }
            .padding()
            .navigationTitle("Exportando")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.exportProgress?.currentStage == .completed || viewModel.exportProgress?.currentStage == .failed {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fechar") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.height(300)])
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }
}

private struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Generates several versions of the same episodes: formats × captions on/off, exported in batch.
struct MultiplySheet: View {
    let base: ExportSettings
    let episodeCount: Int
    let onExport: ([ExportSettings]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var formats: Set<AspectRatio> = [.portrait9_16, .square1_1]
    @State private var withCaptions = true
    @State private var withoutCaptions = false

    private static let offered: [AspectRatio] = [.portrait9_16, .portrait4_5, .square1_1, .landscape16_9, .original]

    private var variantCount: Int {
        formats.count * ((withCaptions ? 1 : 0) + (withoutCaptions ? 1 : 0)) * episodeCount
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Formatos") {
                    ForEach(Self.offered) { ratio in
                        Button {
                            if formats.contains(ratio) { formats.remove(ratio) } else { formats.insert(ratio) }
                        } label: {
                            HStack {
                                Image(systemName: formats.contains(ratio) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(formats.contains(ratio) ? Color.accentColor : Color.secondary)
                                Text(ratio.rawValue).foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Legendas") {
                    Toggle("Versão com legendas", isOn: $withCaptions)
                    Toggle("Versão sem legendas", isOn: $withoutCaptions)
                }
                Section {
                    Text("São gerados \(variantCount) vídeos, um por episódio e variação. Os arquivos levam o formato no nome.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Multiplicar conteúdo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Exportar \(variantCount)") {
                        onExport(variants())
                        dismiss()
                    }
                    .disabled(variantCount == 0)
                }
            }
        }
    }

    private func variants() -> [ExportSettings] {
        var list: [ExportSettings] = []
        let captionOptions: [(Bool, String)] =
            (withCaptions ? [(false, "")] : []) + (withoutCaptions ? [(true, "_semLegenda")] : [])
        for ratio in formats.sorted(by: { $0.rawValue < $1.rawValue }) {
            for (exclude, suffix) in captionOptions {
                var variant = base
                variant.aspectRatio = ratio
                variant.respectOutputFormats = false
                variant.excludeCaptions = exclude
                let tag = ratio == .original ? "orig" : ratio.rawValue.replacingOccurrences(of: ":", with: "x")
                variant.fileNamePrefix = "\(base.fileNamePrefix)_\(tag)\(suffix)"
                // Every exported variant gets a cover in its own output format.
                variant.includeCovers = base.includeCovers
                list.append(variant)
            }
        }
        return list
    }
}
