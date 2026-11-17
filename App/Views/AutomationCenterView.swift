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
    let onOpenTranscriptEditor: (ProjectOperation) -> Void
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
    @State private var lastStage: AnalysisStage = .preparing
    @State private var analysisStart: Date?
    @State private var episodeCuts: [EpisodeCut] = []
    @State private var computingPlan = false

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
        onOpenTranscriptEditor: @escaping (ProjectOperation) -> Void,
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
                    if operation == .episodes {
                        episodePlanSection
                    } else if let analysis = analysis {
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
            .task(id: episodePlanKey) {
                await computeEpisodePlan()
            }
            .onChange(of: operation) { newOperation in
                let locale = request.localeIdentifier
                let allowServer = request.allowServerTranscription
                let analyzeScenes = request.analyzeScenes
                request = AutomationRequest.default(for: newOperation)
                request.localeIdentifier = locale
                request.allowServerTranscription = allowServer
                request.analyzeScenes = newOperation == .speechEdit ? false : analyzeScenes
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
            .onChange(of: request.momentLength) { _ in refreshSuggestions() }
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

    private var heroTitle: String {
        switch operation {
        case .speechEdit: return "Edite o clipe inteiro pelo texto."
        case .episodes: return "Transforme um vídeo longo em uma série."
        default: return "Um vídeo entra. Uma biblioteca sai."
        }
    }

    private var heroSubtitle: String {
        switch operation {
        case .speechEdit:
            return "A análise roda localmente uma vez. Você revisa a fala e aplica cortes no clipe inteiro, sem criar saídas."
        case .episodes:
            return "Divide em ordem, sem pular trechos, com abertura, resumo e fechamento."
        default:
            return "A análise roda localmente no iPad e é reutilizada pelas próximas saídas. As decisões automáticas continuam editáveis na timeline."
        }
    }

    private var heroIcon: String {
        switch operation {
        case .speechEdit: return "text.badge.minus"
        case .episodes: return "film.stack"
        default: return "sparkles.rectangle.stack"
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(heroTitle, systemImage: heroIcon)
                .font(.title3.bold())
            Text(heroSubtitle)
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
            Label(operation == .speechEdit ? "Configurar autoedição" : "Configurar produção", systemImage: "slider.horizontal.3")
                .font(.headline)

            Picker("Idioma da fala", selection: $request.localeIdentifier) {
                ForEach(languages, id: \.id) { language in
                    Text(language.name).tag(language.id)
                }
            }

            if operation != .speechEdit {
                Toggle("Analisar cortes visuais", isOn: $request.analyzeScenes)
            }
            Toggle("Usar servidor da Apple se o offline falhar", isOn: $request.allowServerTranscription)
                .font(.footnote)

            if operation == .multiply {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Duração dos momentos")
                        .font(.footnote.weight(.medium))
                    Picker("Duração dos momentos", selection: $request.momentLength) {
                        ForEach(MomentLength.allCases) { length in
                            Text(length.rawValue).tag(length)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Stepper("Até \(request.resultCount) momentos", value: $request.resultCount, in: 1...12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Plataformas")
                        .font(.footnote.weight(.medium))
                    HStack(spacing: 8) {
                        ForEach(PublishPlatform.allCases) { platform in
                            Button {
                                togglePlatform(platform)
                            } label: {
                                Label(platform.shortName, systemImage: platform.icon)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(request.platforms.contains(platform) ? Color.accentColor.opacity(0.2) : Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                                    .foregroundStyle(request.platforms.contains(platform) ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Toggle("Legendas nos clipes", isOn: $request.captions.enabled)
                if request.captions.enabled {
                    Toggle("Legendas dinâmicas", isOn: $request.captions.dynamic)
                }
                Toggle("Seguir pessoa (formatos verticais)", isOn: $request.autoFraming)
                Toggle("Gerar capas", isOn: $request.generateCovers)
            } else if operation == .podcast || operation == .speechEdit {
                Toggle(operation == .speechEdit ? "Cortar pausas de fala automaticamente" : "Remover pausas longas", isOn: $request.removeSilences)
                Toggle("Remover vícios de linguagem", isOn: $request.removeFillers)
                Toggle(operation == .speechEdit ? "Atualizar legendas do clipe" : "Legendas na saída", isOn: $request.captions.enabled)
            } else {
                episodeConfiguration
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .disabled(isAnalyzing)
    }

    private var sourceIsPortrait: Bool {
        let size = project.sourceVideoNaturalSize.cgSize.applying(project.sourceVideoTransform.cgAffineTransform)
        return abs(size.height) > abs(size.width)
    }

    private var videoAssets: [MediaAsset] {
        project.mediaAssets.filter { $0.type == .video }
    }

    private var hasTranscriptWords: Bool {
        !(analysis?.transcriptWords ?? project.transcriptWords ?? []).isEmpty
    }

    private var episodeTargetLength: Double {
        let total = project.sequenceSourceDuration
        if request.episodePlan.targetLength > 0 { return request.episodePlan.targetLength }
        return EpisodePlanner.suggestedLength(
            totalDuration: total,
            format: request.formats.first ?? .original,
            sourceIsPortrait: sourceIsPortrait
        )
    }

    private var plannedEpisodeCount: Int {
        EpisodePlanner.episodeCount(
            totalDuration: project.sequenceSourceDuration,
            targetLength: episodeTargetLength
        )
    }

    private func durationChipLabel(_ seconds: Double) -> String {
        seconds < 60 ? "30 s" : "\(Int(seconds / 60)) min"
    }

    private var episodeConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Título da série", text: $request.episodePlan.seriesTitle)

            VStack(alignment: .leading, spacing: 8) {
                Text("Formato de saída")
                    .font(.footnote.weight(.medium))
                HStack(spacing: 8) {
                    ForEach([AspectRatio.portrait9_16, .landscape16_9, .square1_1, .original]) { ratio in
                        Button {
                            request.formats = [ratio]
                        } label: {
                            Text(ratio.rawValue)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(request.formats.first == ratio ? Color.accentColor.opacity(0.2) : Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                                .foregroundStyle(request.formats.first == ratio ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Duração por episódio")
                    .font(.footnote.weight(.medium))
                let suggested = EpisodePlanner.suggestedLength(
                    totalDuration: project.sequenceSourceDuration,
                    format: request.formats.first ?? .original,
                    sourceIsPortrait: sourceIsPortrait
                )
                HStack(spacing: 8) {
                    ForEach([30.0, 60, 120, 180, 300, 600], id: \.self) { length in
                        Button {
                            request.episodePlan.targetLength = length
                        } label: {
                            VStack(spacing: 2) {
                                Text(durationChipLabel(length))
                                    .font(.caption.weight(.medium))
                                if abs(length - suggested) < 0.5 {
                                    Text("Sugerido")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                request.episodePlan.targetLength == length || (request.episodePlan.targetLength == 0 && abs(length - suggested) < 0.5)
                                    ? Color.accentColor.opacity(0.2)
                                    : Color(uiColor: .tertiarySystemGroupedBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(request.episodePlan.targetLength == length ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Stepper(
                "Quantidade de episódios: \(plannedEpisodeCount)",
                value: Binding(
                    get: { plannedEpisodeCount },
                    set: { newCount in
                        let total = project.sequenceSourceDuration
                        if total > 0 {
                            request.episodePlan.targetLength = total / Double(newCount)
                        }
                    }
                ),
                in: 1...30
            )

            Text("Duração total \(clock(project.sequenceSourceDuration)) → \(plannedEpisodeCount) episódios de ~\(clock(project.sequenceSourceDuration / Double(max(1, plannedEpisodeCount))))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Cartão de abertura (Parte N de M)", isOn: $request.episodePlan.introCard)

            Picker("Vinheta de abertura", selection: $request.episodePlan.introAssetID) {
                Text("Nenhuma").tag(UUID?.none)
                ForEach(videoAssets) { asset in
                    Text(asset.name).tag(UUID?.some(asset.id))
                }
            }
            .disabled(videoAssets.isEmpty)

            Toggle("Anteriormente (resumo do episódio anterior)", isOn: $request.episodePlan.recap)
            if request.episodePlan.recap {
                Picker("Duração do resumo", selection: $request.episodePlan.recapDuration) {
                    ForEach([4.0, 6, 8, 10], id: \.self) { seconds in
                        Text("\(Int(seconds)) s").tag(seconds)
                    }
                }
                .pickerStyle(.segmented)
            }

            Toggle("Cartão de fechamento (Continua na Parte N)", isOn: $request.episodePlan.outroCard)

            Picker("Vinheta de encerramento", selection: $request.episodePlan.outroAssetID) {
                Text("Nenhuma").tag(UUID?.none)
                ForEach(videoAssets) { asset in
                    Text(asset.name).tag(UUID?.some(asset.id))
                }
            }
            .disabled(videoAssets.isEmpty)

            Toggle("Gerar capas dos episódios", isOn: $request.generateCovers)

            Toggle("Legendas nos episódios", isOn: $request.captions.enabled)
                .disabled(!hasTranscriptWords)
            if !hasTranscriptWords {
                Text("Analise o vídeo para gerar legendas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
                    stepList(for: progress)
                    if isAnalyzing, let analysisStart = analysisStart {
                        TimelineView(.periodic(from: analysisStart, by: 1)) { context in
                            Text("Tempo decorrido: \(elapsedString(from: analysisStart, to: context.date))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if analysis == nil {
                Text("Transcrição, cenas, pausas, vícios e assuntos serão reunidos em um índice reutilizável.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if operation == .episodes {
                    Text("Opcional: analise para cortar no fim das frases e gerar legendas.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
            EmptyView()
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
                    let frame = project.sourceLocation(at: (suggestion.start + suggestion.end) / 2)
                    OutputCandidateCard(
                        suggestion: suggestion,
                        sourceURL: frame?.url ?? project.sourceVideoFileURL,
                        sourceTime: frame?.time ?? (suggestion.start + suggestion.end) / 2,
                        selected: selectedSuggestions.contains(suggestion.id),
                        onToggle: { toggleSuggestion(suggestion.id) },
                        onSeek: { onSeek(suggestion.start) },
                        canShorten: hasTranscriptWords && canAdjust(suggestion, extend: false),
                        canExtend: hasTranscriptWords && canAdjust(suggestion, extend: true),
                        onAdjust: hasTranscriptWords ? { extend in adjustSuggestion(suggestion, extend: extend) } : nil
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

            Text(speechCleanupSummary(analysis))
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Revisar texto") { openAfterDismiss(onOpenTranscript) }
                    .buttonStyle(.bordered)
                Button("Editar pelo texto") { openAfterDismiss { onOpenTranscriptEditor(operation) } }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var episodePlanSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Plano dos episódios", systemImage: "rectangle.split.3x1")
                .font(.headline)

            if computingPlan {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Calculando pontos de corte…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                let parts = episodeParts()
                ForEach(parts.indices, id: \.self) { index in
                    Button { onSeek(parts[index].0) } label: {
                        HStack {
                            Text("Parte \(index + 1)")
                                .font(.footnote.weight(.semibold))
                            Text("\(clock(parts[index].0))–\(clock(parts[index].1))")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(parts[index].2)
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

    /// (start, end, label of the cut that ends the part) for the current plan.
    private func episodeParts() -> [(Double, Double, String)] {
        let total = project.sequenceSourceDuration
        var parts: [(Double, Double, String)] = []
        var cursor = 0.0
        for cut in episodeCuts {
            parts.append((cursor, cut.time, cut.kind.rawValue))
            cursor = cut.time
        }
        parts.append((cursor, total, "fim do vídeo"))
        return parts
    }

    @MainActor
    private func computeEpisodePlan() async {
        let total = project.sequenceSourceDuration
        guard operation == .episodes, total > 0 else {
            episodeCuts = []
            return
        }
        computingPlan = true
        defer { if !Task.isCancelled { computingPlan = false } }
        let count = EpisodePlanner.episodeCount(totalDuration: total, targetLength: episodeTargetLength)
        let ideal = EpisodePlanner.idealCuts(totalDuration: total, count: count)
        let words = analysis?.transcriptWords ?? project.transcriptWords ?? []
        var quietPoints: [Double] = []
        if words.isEmpty {
            quietPoints = await AudioEnergyAnalyzer.quietPoints(project: project, near: ideal)
        }
        guard !Task.isCancelled else { return }
        let hardBoundaries = project.sourceClips.dropFirst().map { $0.sequenceStartTime + $0.startTime }
        episodeCuts = EpisodePlanner.snappedCuts(
            ideal: ideal,
            totalDuration: total,
            words: words,
            quietPoints: quietPoints,
            hardBoundaries: hardBoundaries
        )
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            if operation == .episodes {
                Button {
                    onCreateEpisodes(episodeCuts.map(\.time), request)
                    dismiss()
                } label: {
                    Label("Criar \(episodeCuts.count + 1) episódios", systemImage: "film.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(computingPlan || project.sequenceSourceDuration <= 0)
                if analysis == nil && !isAnalyzing {
                    Button { startAnalysis() } label: {
                        Label("Analisar vídeo (opcional)", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else if isAnalyzing {
                    Button { } label: {
                        Label("Analisando…", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                }
            } else if analysis == nil || isAnalyzing {
                Button { startAnalysis() } label: {
                    Label(isAnalyzing ? "Analisando…" : "Analisar vídeo", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAnalyzing)
            } else if operation == .multiply {
                let platformCount = max(1, request.platforms.count)
                Button {
                    let chosen = suggestions.filter { selectedSuggestions.contains($0.id) }
                    onCreateOutputs(chosen, request)
                    dismiss()
                } label: {
                    Label("Criar \(selectedSuggestions.count * platformCount) vídeos", systemImage: "rectangle.stack.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedSuggestions.isEmpty)
                Text("\(selectedSuggestions.count) momentos × \(platformCount) plataformas = \(selectedSuggestions.count * platformCount) vídeos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            }

            Text("Vídeo, fala e análise permanecem no dispositivo. O score indica qualidade editorial estimada, não viralização.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.bar)
    }

    private var analysisSteps: [AnalysisStage] {
        var steps: [AnalysisStage] = [.preparing, .transcribing]
        if request.analyzeScenes { steps.append(.detectingScenes) }
        steps.append(.indexing)
        return steps
    }

    private func stepList(for progress: AnalysisProgress) -> some View {
        let steps = analysisSteps
        let failed = progress.stage == .failed
        let effective = failed ? lastStage : progress.stage
        let currentIndex = steps.firstIndex(of: effective) ?? steps.count
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(steps.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    if failed && index == currentIndex {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    } else if index < currentIndex {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if index == currentIndex {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                    }
                    Text(steps[index].rawValue)
                        .font(.caption.weight(index == currentIndex && !failed ? .semibold : .regular))
                        .foregroundStyle(index <= currentIndex ? .primary : .secondary)
                }
            }
        }
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", total / 60, total % 60)
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
        lastStage = .preparing
        analysisStart = Date()
        progress = AnalysisProgress(stage: .preparing, message: "Preparando análise…", fraction: 0)
        let snapshot = project
        let currentRequest = request
        analysisTask = Task {
            let result = await coordinator.analyze(project: snapshot, request: currentRequest) { item in
                Task { @MainActor in
                    self.progress = item
                    if item.stage != .failed {
                        self.lastStage = item.stage
                    }
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
                maxResults: request.resultCount,
                momentLength: operation == .multiply ? request.momentLength : nil,
                energy: operation == .multiply ? analysis.audioEnergy : nil,
                energyInterval: 0.5
            ))
        }
        suggestions = generated.sorted { $0.score > $1.score }
        selectedSuggestions = Set(suggestions.map(\.id))
    }

    private func togglePlatform(_ platform: PublishPlatform) {
        if request.platforms.contains(platform), request.platforms.count > 1 {
            request.platforms.removeAll { $0 == platform }
        } else if !request.platforms.contains(platform) {
            request.platforms.append(platform)
        }
    }

    private var episodePlanKey: String {
        let words = analysis?.transcriptWords ?? project.transcriptWords ?? []
        return [
            operation.rawValue,
            "\(Int(project.sequenceSourceDuration))",
            "\(Int(episodeTargetLength * 10))",
            request.formats.first?.rawValue ?? "",
            "\(words.count)"
        ].joined(separator: "|")
    }

    private func adjustSuggestion(_ suggestion: ClipSuggestion, extend: Bool) {
        let words = analysis?.transcriptWords ?? []
        guard let updated = ClipSuggestionEngine.adjusted(
            suggestion,
            extend: extend,
            words: words,
            sourceDuration: analysis?.duration ?? project.sequenceSourceDuration
        ), let index = suggestions.firstIndex(where: { $0.id == suggestion.id }) else { return }
        suggestions[index] = updated
    }

    private func canAdjust(_ suggestion: ClipSuggestion, extend: Bool) -> Bool {
        let words = analysis?.transcriptWords ?? []
        return ClipSuggestionEngine.adjusted(
            suggestion,
            extend: extend,
            words: words,
            sourceDuration: analysis?.duration ?? project.sequenceSourceDuration
        ) != nil
    }

    private func toggleSuggestion(_ id: UUID) {
        if selectedSuggestions.contains(id) {
            selectedSuggestions.remove(id)
        } else {
            selectedSuggestions.insert(id)
        }
    }

    private func speechCleanupSummary(_ analysis: ContentAnalysis) -> String {
        let base = "Foram encontradas \(analysis.silenceRanges.count) pausas longas e \(analysis.fillerMatches.count) vícios de linguagem"
        if operation == .speechEdit {
            return base + " no clipe inteiro."
        }
        return base + ". Revise pelo texto ou aplique o corte automático sugerido."
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
    let sourceTime: Double
    let selected: Bool
    let onToggle: () -> Void
    let onSeek: () -> Void
    var canShorten = false
    var canExtend = false
    var onAdjust: ((Bool) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            SourceFrameView(sourceURL: sourceURL, time: sourceTime)
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
                if let onAdjust = onAdjust {
                    HStack(spacing: 8) {
                        Button("Encurtar") { onAdjust(false) }
                            .font(.caption.weight(.medium))
                            .disabled(!canShorten)
                        Button("Estender") { onAdjust(true) }
                            .font(.caption.weight(.medium))
                            .disabled(!canExtend)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
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
