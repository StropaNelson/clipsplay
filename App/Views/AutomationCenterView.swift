import SwiftUI
import AVFoundation
import UIKit

/// Guided automation layer: analyze once, review the found opportunities and
/// only then create editable outputs in the existing timeline model.
struct AutomationCenterView: View {
    let project: Project
    let onAnalysisReady: (ContentAnalysis) -> Void
    let onCreateOutputs: ([ClipSuggestion], AutomationRequest) -> Void
    let onApplyCuts: ([ClosedRange<Double>], AutomationRequest) -> Void
    let onCreateEpisodes: ([Double], AutomationRequest) -> Void
    let onOpenTranscript: () -> Void
    let onOpenTranscriptEditor: () -> Void
    let onSeek: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var operation: ProjectOperation
    @State private var request: AutomationRequest
    @State private var selectedKind: ClipSuggestionKind
    @State private var analysis: ContentAnalysis?
    @State private var progress: AnalysisProgress?
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var suggestions: [ClipSuggestion] = []
    @State private var selectedSuggestions: Set<UUID> = []
    @State private var analysisTask: Task<Void, Never>?

    private let coordinator = AnalysisCoordinator.shared
    private let languages: [AutomationLanguage] = [
        AutomationLanguage(id: "pt-BR", name: "Português (Brasil)"),
        AutomationLanguage(id: "pt-PT", name: "Português (Portugal)"),
        AutomationLanguage(id: "en-US", name: "Inglês"),
        AutomationLanguage(id: "es-ES", name: "Espanhol")
    ]

    init(
        project: Project,
        operation: ProjectOperation?,
        onAnalysisReady: @escaping (ContentAnalysis) -> Void,
        onCreateOutputs: @escaping ([ClipSuggestion], AutomationRequest) -> Void,
        onApplyCuts: @escaping ([ClosedRange<Double>], AutomationRequest) -> Void,
        onCreateEpisodes: @escaping ([Double], AutomationRequest) -> Void,
        onOpenTranscript: @escaping () -> Void,
        onOpenTranscriptEditor: @escaping () -> Void,
        onSeek: @escaping (Double) -> Void
    ) {
        let resolved = operation ?? project.operation ?? .multiply
        var initial = AutomationRequest.default(for: resolved)
        initial.clipKinds = [initial.clipKinds.first ?? .clips]
        self.project = project
        self.onAnalysisReady = onAnalysisReady
        self.onCreateOutputs = onCreateOutputs
        self.onApplyCuts = onApplyCuts
        self.onCreateEpisodes = onCreateEpisodes
        self.onOpenTranscript = onOpenTranscript
        self.onOpenTranscriptEditor = onOpenTranscriptEditor
        self.onSeek = onSeek
        _operation = State(initialValue: resolved)
        _request = State(initialValue: initial)
        _selectedKind = State(initialValue: initial.clipKinds.first ?? .clips)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    configurationCard
                    analysisCard
                    if let analysis = analysis {
                        resultSection(analysis)
                    }
                }
                .padding()
            }
            .navigationTitle("Automatizar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if analysis != nil && !isAnalyzing {
                        Button("Reanalisar") { startAnalysis() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .task { await loadCachedAnalysis() }
            .onChange(of: operation) { newOperation in
                let locale = request.localeIdentifier
                let allowServer = request.allowServerTranscription
                let analyzeScenes = request.analyzeScenes
                request = AutomationRequest.default(for: newOperation)
                request.localeIdentifier = locale
                request.allowServerTranscription = allowServer
                request.analyzeScenes = analyzeScenes
                selectedKind = request.clipKinds.first ?? .clips
                refreshSuggestions()
            }
            .onChange(of: selectedKind) { newKind in
                request.clipKinds = [newKind]
                request.resultCount = min(request.resultCount, 12)
                refreshSuggestions()
            }
            .onChange(of: request.resultCount) { _ in refreshSuggestions() }
            .onChange(of: request.analyzeScenes) { _ in refreshSuggestions() }
            .onChange(of: request.localeIdentifier) { locale in
                guard analysis?.transcriptionLocale != locale else { return }
                analysis = nil
                progress = nil
                suggestions = []
                selectedSuggestions = []
                Task { await loadCachedAnalysis() }
            }
            .onDisappear { analysisTask?.cancel() }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Um vídeo entra. Uma biblioteca sai.", systemImage: "sparkles.rectangle.stack")
                .font(.title3.bold())
            Text("A análise roda localmente no iPad e é reutilizada pelas próximas saídas. As decisões automáticas continuam editáveis na timeline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(ProjectOperation.allCases) { item in
                    Button {
                        operation = item
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(2)
                                Text(item.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.primary)
                        .padding(10)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        .background(
                            item == operation ? Color.accentColor.opacity(0.18) : Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(item == operation ? Color.accentColor : Color.clear, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(isAnalyzing)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EditorTheme.panelRaised.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Configurar produção", systemImage: "slider.horizontal.3")
                .font(.headline)

            Picker("Idioma da fala", selection: $request.localeIdentifier) {
                ForEach(languages, id: \.id) { language in
                    Text(language.name).tag(language.id)
                }
            }

            Toggle("Analisar cortes visuais", isOn: $request.analyzeScenes)
            Toggle("Usar servidor da Apple se o offline falhar", isOn: $request.allowServerTranscription)
                .font(.footnote)

            if operation == .multiply {
                Picker("Tipo de oportunidade", selection: $selectedKind) {
                    ForEach(ClipSuggestionKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                Stepper("Até \(request.resultCount) sugestões", value: $request.resultCount, in: 1...12)
                Toggle("Legendas nos clipes", isOn: $request.captions.enabled)
                if request.captions.enabled {
                    Toggle("Legendas dinâmicas", isOn: $request.captions.dynamic)
                }
                Toggle("Seguir pessoa", isOn: $request.autoFraming)
                Toggle("Gerar capas", isOn: $request.generateCovers)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Formatos")
                        .font(.footnote.weight(.medium))
                    HStack(spacing: 8) {
                        ForEach([AspectRatio.portrait9_16, .square1_1, .landscape16_9, .original]) { ratio in
                            Button {
                                toggleFormat(ratio)
                            } label: {
                                Text(ratio.rawValue)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(request.formats.contains(ratio) ? Color.accentColor.opacity(0.2) : Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                                    .foregroundStyle(request.formats.contains(ratio) ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if operation == .podcast || operation == .speechEdit {
                Toggle(operation == .speechEdit ? "Cortar pausas de fala automaticamente" : "Remover pausas longas", isOn: $request.removeSilences)
                Toggle("Remover vícios de linguagem", isOn: $request.removeFillers)
                Toggle("Legendas na saída", isOn: $request.captions.enabled)
            } else {
                Toggle("Gerar capas dos episódios", isOn: $request.generateCovers)
                Text("A divisão prefere limites de assunto; cortes visuais são usados como apoio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .disabled(isAnalyzing)
    }

    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Análise local", systemImage: "bolt.badge.checkmark")
                    .font(.headline)
                Spacer()
                if let analysis = analysis {
                    Text(analysis.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = progress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(progress.stage.rawValue)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(progress.fraction * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: progress.fraction)
                    Text(progress.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if analysis == nil {
                Text("Transcrição, cenas, pausas, vícios e assuntos serão reunidos em um índice reutilizável.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let analysis = analysis {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    metric("Palavras", "\(analysis.transcriptWords.count)", "text.bubble")
                    metric("Cenas", "\(analysis.sceneCuts.count)", "film")
                    metric("Pausas", "\(analysis.silenceRanges.count)", "speaker.slash")
                    metric("Assuntos", "\(analysis.topicBoundaries.count)", "bookmark")
                }
                if !analysis.warnings.isEmpty {
                    ForEach(analysis.warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func resultSection(_ analysis: ContentAnalysis) -> some View {
        switch operation {
        case .multiply:
            opportunitiesSection(analysis)
        case .podcast, .speechEdit:
            speechCleanupSection(analysis)
        case .episodes:
            episodesSection(analysis)
        }
    }

    private func opportunitiesSection(_ analysis: ContentAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Oportunidades encontradas", systemImage: "wand.and.stars")
                    .font(.headline)
                Spacer()
                if !suggestions.isEmpty {
                    Text("\(selectedSuggestions.count) selecionadas")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if suggestions.isEmpty {
                Text(analysis.transcriptWords.isEmpty ? "Sem transcrição, só cortes visuais podem gerar oportunidades." : "Nenhum trecho ficou dentro da duração escolhida.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(suggestions) { suggestion in
                    OutputCandidateCard(
                        suggestion: suggestion,
                        sourceURL: project.sourceVideoFileURL,
                        selected: selectedSuggestions.contains(suggestion.id),
                        onToggle: { toggleSuggestion(suggestion.id) },
                        onSeek: { onSeek(suggestion.start) }
                    )
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func speechCleanupSection(_ analysis: ContentAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(operation == .speechEdit ? "Autoedição por transcrição" : "Limpeza e edição por texto", systemImage: "text.badge.minus")
                .font(.headline)

            Text("Foram encontradas \(analysis.silenceRanges.count) pausas longas e \(analysis.fillerMatches.count) vícios de linguagem. Revise pelo texto ou aplique o corte automático sugerido.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Abrir transcrição") { openAfterDismiss(onOpenTranscript) }
                    .buttonStyle(.bordered)
                Button("Autoedição por fala") { openAfterDismiss(onOpenTranscriptEditor) }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func episodesSection(_ analysis: ContentAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Limites de episódio", systemImage: "rectangle.split.3x1")
                .font(.headline)

            if analysis.topicBoundaries.isEmpty {
                Text("Nenhuma mudança forte de assunto foi detectada. Você ainda pode usar divisão automática em Saídas.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(analysis.topicBoundaries.prefix(8), id: \.time) { boundary in
                    Button { onSeek(boundary.time) } label: {
                        HStack {
                            Image(systemName: "bookmark")
                            Text(clock(boundary.time))
                                .monospacedDigit()
                            Spacer()
                            Text("\(Int(boundary.score * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if analysis == nil || isAnalyzing {
                Button { startAnalysis() } label: {
                    Label(isAnalyzing ? "Analisando…" : "Analisar vídeo", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAnalyzing)
            } else if operation == .multiply {
                Button {
                    let chosen = suggestions.filter { selectedSuggestions.contains($0.id) }
                    onCreateOutputs(chosen, request)
                    dismiss()
                } label: {
                    Label("Criar \(selectedSuggestions.count * max(1, request.formats.count)) saídas editáveis", systemImage: "rectangle.stack.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedSuggestions.isEmpty)
            } else if operation == .podcast || operation == .speechEdit {
                Button {
                    guard let analysis = analysis else { return }
                    onApplyCuts(recommendedCuts(from: analysis), request)
                    dismiss()
                } label: {
                    Label(operation == .speechEdit ? "Aplicar autoedição" : "Aplicar limpeza sugerida", systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(analysis.map { recommendedCuts(from: $0).isEmpty } ?? true)
            } else if operation == .episodes {
                Button {
                    onCreateEpisodes(analysis?.topicBoundaries.map(\.time) ?? [], request)
                    dismiss()
                } label: {
                    Label("Criar episódios por assunto", systemImage: "rectangle.split.3x1")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(analysis?.topicBoundaries.isEmpty ?? true)
            }

            Text("Vídeo, fala e análise permanecem no dispositivo. O score indica qualidade editorial estimada, não viralização.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.bar)
    }

    private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold().monospacedDigit())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func startAnalysis() {
        analysisTask?.cancel()
        isAnalyzing = true
        errorMessage = nil
        progress = AnalysisProgress(stage: .preparing, message: "Preparando análise…", fraction: 0)
        let snapshot = project
        let currentRequest = request
        analysisTask = Task {
            let result = await coordinator.analyze(project: snapshot, request: currentRequest) { item in
                Task { @MainActor in
                    self.progress = item
                }
            }
            await MainActor.run {
                self.analysis = result
                self.isAnalyzing = false
                self.onAnalysisReady(result)
                self.refreshSuggestions()
            }
        }
    }

    private func loadCachedAnalysis() async {
        if let cached = await coordinator.cachedAnalysis(for: project, localeIdentifier: request.localeIdentifier) {
            analysis = cached
            progress = nil
            onAnalysisReady(cached)
            refreshSuggestions()
        }
    }

    private func refreshSuggestions() {
        guard let analysis = analysis else {
            suggestions = []
            selectedSuggestions = []
            return
        }
        var generated: [ClipSuggestion] = []
        for kind in request.clipKinds {
            generated.append(contentsOf: ClipSuggestionEngine.suggest(
                words: analysis.transcriptWords,
                sourceDuration: analysis.duration,
                kind: kind,
                sceneCuts: request.analyzeScenes ? analysis.sceneCuts : [],
                maxResults: request.resultCount
            ))
        }
        suggestions = generated.sorted { $0.score > $1.score }
        selectedSuggestions = Set(suggestions.map(\.id))
    }

    private func toggleFormat(_ ratio: AspectRatio) {
        if request.formats.contains(ratio), request.formats.count > 1 {
            request.formats.removeAll { $0 == ratio }
        } else if !request.formats.contains(ratio) {
            request.formats.append(ratio)
        }
    }

    private func toggleSuggestion(_ id: UUID) {
        if selectedSuggestions.contains(id) {
            selectedSuggestions.remove(id)
        } else {
            selectedSuggestions.insert(id)
        }
    }

    private func recommendedCuts(from analysis: ContentAnalysis) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        if request.removeSilences {
            ranges.append(contentsOf: analysis.silenceRanges.compactMap { range in
                let start = range.start + 0.12
                let end = range.end - 0.12
                return end > start ? start...end : nil
            })
        }
        if request.removeFillers {
            ranges.append(contentsOf: analysis.fillerMatches.map { max(0, $0.start - 0.04)...($0.end + 0.08) })
        }
        return ranges
    }

    private func openAfterDismiss(_ action: @escaping () -> Void) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 550_000_000)
            action()
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct OutputCandidateCard: View {
    let suggestion: ClipSuggestion
    let sourceURL: URL
    let selected: Bool
    let onToggle: () -> Void
    let onSeek: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            SourceFrameView(sourceURL: sourceURL, time: (suggestion.start + suggestion.end) / 2)
                .frame(width: 96, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(suggestion.kind.outputName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(suggestion.score.rounded()))")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(scoreColor, in: Capsule())
                }
                Text("\(clock(suggestion.start)) • \(Int(suggestion.duration.rounded()))s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(suggestion.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    ForEach(suggestion.reasons.prefix(2), id: \.self) { reason in
                        Text(reason)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                    }
                }
            }

            Button(action: onSeek) {
                Image(systemName: "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var scoreColor: Color {
        switch suggestion.score {
        case 75...: return .green
        case 55...: return .orange
        default: return .gray
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Lightweight frame thumbnail for review cards; generated locally from the source.
private struct SourceFrameView: View {
    let sourceURL: URL
    let time: Double
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .task { await load() }
    }

    private func load() async {
        let url = sourceURL
        let sampleTime = time
        let data = await Task.detached(priority: .utility) { () -> Data? in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 192, height: 112)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(
                at: CMTime(seconds: sampleTime, preferredTimescale: 600),
                actualTime: nil
            ) else { return nil }
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.72)
        }.value
        let image = data.flatMap { UIImage(data: $0) }
        await MainActor.run { self.image = image }
    }
}

private struct AutomationLanguage: Identifiable {
    let id: String
    let name: String
}
