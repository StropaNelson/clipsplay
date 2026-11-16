import SwiftUI

struct ClipSuggestionsView: View {
    let words: [TranscriptWord]
    let sourceDuration: Double
    let sourceURL: URL
    let onSceneCuts: ([Double]) -> Void
    let onSeek: (Double) -> Void
    let onCreate: ([ClipSuggestion], Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ClipSuggestionKind = .clips
    @State private var suggestions: [ClipSuggestion] = []
    @State private var selected: Set<UUID> = []
    @State private var sceneCuts: [Double]
    @State private var useSceneCuts = true
    @State private var autoFraming = false
    @State private var maxResults = 8
    @State private var isAnalyzingScenes = false
    @State private var errorMessage: String?

    init(
        words: [TranscriptWord],
        sourceDuration: Double,
        sourceURL: URL,
        storedSceneCuts: [Double],
        onSceneCuts: @escaping ([Double]) -> Void,
        onSeek: @escaping (Double) -> Void,
        onCreate: @escaping ([ClipSuggestion], Bool) -> Void
    ) {
        self.words = words
        self.sourceDuration = sourceDuration
        self.sourceURL = sourceURL
        self.onSceneCuts = onSceneCuts
        self.onSeek = onSeek
        self.onCreate = onCreate
        _sceneCuts = State(initialValue: storedSceneCuts)
        _maxResults = State(initialValue: ClipSuggestionKind.clips.defaultCount)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                content
            }
            .navigationTitle("Sugerir clipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { applyBar }
            .onAppear { refreshSuggestions() }
            .onChange(of: kind) { newKind in
                maxResults = newKind.defaultCount
                refreshSuggestions()
            }
            .onChange(of: useSceneCuts) { _ in refreshSuggestions() }
            .onChange(of: maxResults) { _ in refreshSuggestions() }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Tipo", selection: $kind) {
                ForEach(ClipSuggestionKind.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Toggle("Cenas", isOn: $useSceneCuts)
                    .font(.footnote)
                Toggle("Seguir pessoa", isOn: $autoFraming)
                    .font(.footnote)
                Stepper("\(maxResults)", value: $maxResults, in: 1...12)
                    .font(.footnote)
                    .frame(maxWidth: 120)
            }
            .padding(.horizontal)

            if useSceneCuts {
                HStack {
                    if isAnalyzingScenes {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Analisando cenas…")
                            .font(.caption)
                    } else {
                        Button {
                            Task { await analyzeScenes() }
                        } label: {
                            Label(sceneCuts.isEmpty ? "Analisar cenas" : "\(sceneCuts.count) cenas detectadas", systemImage: "film.badge.plus")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                    if !sceneCuts.isEmpty {
                        Button("Limpar") {
                            sceneCuts = []
                            onSceneCuts([])
                            refreshSuggestions()
                        }
                        .font(.caption)
                    }
                }
                .padding(.horizontal)
            }

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
        }
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    @ViewBuilder
    private var content: some View {
        if suggestions.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(words.isEmpty ? "Nenhuma sugestão ainda" : "Nenhum trecho com esse formato")
                    .font(.headline)
                Text(emptyMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(suggestions) { suggestion in
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        if selected.contains(suggestion.id) {
                            selected.remove(suggestion.id)
                        } else {
                            selected.insert(suggestion.id)
                        }
                    } label: {
                        Image(systemName: selected.contains(suggestion.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selected.contains(suggestion.id) ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(clock(suggestion.start))
                                .monospacedDigit()
                            Text("•")
                            Text("\(Int(suggestion.duration.rounded()))s")
                            Spacer()
                            Text("\(Int(suggestion.score.rounded()))")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(scoreColor(suggestion.score), in: Capsule())
                        }
                        .font(.subheadline.weight(.semibold))

                        Text(suggestion.snippet)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)

                        HStack(spacing: 6) {
                            ForEach(suggestion.reasons, id: \.self) { reason in
                                Text(reason)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                            }
                        }
                    }

                    Button {
                        onSeek(suggestion.start)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
        }
    }

    private var emptyMessage: String {
        if words.isEmpty && sceneCuts.isEmpty {
            return "Gere a transcrição para sugestões pela fala, ou toque em “Analisar cenas” para sugerir cortes visuais."
        }
        if words.isEmpty {
            return "As cenas foram analisadas, mas nenhum trecho ficou dentro da duração escolhida."
        }
        return "Tente outro tipo de sugestão, mais resultados ou desative a análise de cenas."
    }

    private var applyBar: some View {
        VStack(spacing: 8) {
            Button {
                let chosen = suggestions.filter { selected.contains($0.id) }
                onCreate(chosen, autoFraming)
                dismiss()
            } label: {
                Label("Criar \(selected.count) item(ns) editáveis", systemImage: "rectangle.stack.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selected.isEmpty)

            Text("A pontuação mede potencial editorial com sinais locais; ela não promete desempenho nas redes.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.bar)
    }

    private func refreshSuggestions() {
        suggestions = ClipSuggestionEngine.suggest(
            words: words,
            sourceDuration: sourceDuration,
            kind: kind,
            sceneCuts: useSceneCuts ? sceneCuts : [],
            maxResults: maxResults
        )
        selected = Set(suggestions.map(\.id))
    }

    @MainActor
    private func analyzeScenes() async {
        isAnalyzingScenes = true
        errorMessage = nil
        defer { isAnalyzingScenes = false }
        let cuts = await VisualAnalysisService.shared.detectSceneCuts(
            in: sourceURL,
            duration: sourceDuration
        )
        sceneCuts = cuts
        onSceneCuts(cuts)
        if cuts.isEmpty {
            errorMessage = "Nenhuma mudança visual forte encontrada. A análise ainda pode ser usada com a transcrição."
        }
        refreshSuggestions()
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func scoreColor(_ score: Double) -> Color {
        switch score {
        case 75...: return .green
        case 55...: return .orange
        default: return .gray
        }
    }
}
