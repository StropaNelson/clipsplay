import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionView: View {
    let project: Project
    let onTranscriptChange: (String) -> Void
    let onApplyCaptions: ([TranscriptCue], Bool) -> Void
    let onWords: ([TranscriptWord]) -> Void
    let onCorrected: (String, [TranscriptWord]) -> Void
    let currentWords: () -> [TranscriptWord]

    init(
        project: Project,
        onTranscriptChange: @escaping (String) -> Void,
        onApplyCaptions: @escaping ([TranscriptCue], Bool) -> Void,
        onWords: @escaping ([TranscriptWord]) -> Void = { _ in },
        onCorrected: @escaping (String, [TranscriptWord]) -> Void = { _, _ in },
        currentWords: @escaping () -> [TranscriptWord] = { [] }
    ) {
        self.project = project
        self.onTranscriptChange = onTranscriptChange
        self.onApplyCaptions = onApplyCaptions
        self.onWords = onWords
        self.onCorrected = onCorrected
        self.currentWords = currentWords
        self._transcript = State(initialValue: project.transcriptSRT ?? "")
    }

    @Environment(\.dismiss) private var dismiss
    @State private var transcript = ""
    @State private var isTranscribing = false
    @State private var showingSubtitleImporter = false
    @State private var shareItem: TranscriptShareItem?
    @State private var errorMessage: String?
    @State private var localeIdentifier = "pt-BR"
    @State private var allowServer = false
    @State private var dynamicCaptions = false
    @State private var isCorrecting = false
    @State private var correctionPreview: TranscriptCorrectionResult?
    @State private var correctionSummary: String?
    @State private var applyingCorrection = false

    private let languages: [(id: String, name: String)] = [
        ("pt-BR", "Português (Brasil)"),
        ("pt-PT", "Português (Portugal)"),
        ("en-US", "Inglês"),
        ("es-ES", "Espanhol")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Idioma da fala", selection: $localeIdentifier) {
                    ForEach(languages, id: \.id) { language in
                        Text(language.name).tag(language.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(isTranscribing)

                Toggle("Usar servidor da Apple se o offline falhar", isOn: $allowServer)
                    .font(.footnote)
                    .disabled(isTranscribing)

                Button {
                    Task { await prepareCorrection() }
                } label: {
                    Label("Corrigir ortografia e semântica", systemImage: "textformat.abc")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTranscribing || isCorrecting)

                if isCorrecting {
                    ProgressView("Corrigindo texto no dispositivo…")
                }

                if let correctionSummary = correctionSummary {
                    Text(correctionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isTranscribing {
                    ProgressView("Transcrevendo no dispositivo…")
                }

                TextEditor(text: $transcript)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .overlay {
                        if transcript.isEmpty && !isTranscribing {
                            Text("Gere uma transcrição em português ou importe um arquivo SRT/VTT.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                                .allowsHitTesting(false)
                        }
                    }

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !transcript.isEmpty && !isTranscribing {
                  VStack(spacing: 8) {
                    Toggle("Legendas dinâmicas (poucas palavras, destaca a palavra falada)", isOn: $dynamicCaptions)
                        .font(.footnote)
                        .padding(.horizontal)
                    Button {
                        applyCaptions()
                    } label: {
                        Label("Aplicar como legendas no vídeo", systemImage: "captions.bubble.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal)
                  }
                  .padding(.vertical)
                }
            }
            .padding()
            .onChange(of: transcript) { text in
                if !applyingCorrection { correctionSummary = nil }
                onTranscriptChange(text)
            }
            .navigationTitle("Transcrição")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button(allowServer ? "Transcrever" : "Transcrever no dispositivo", systemImage: "waveform") {
                            Task { await transcribe() }
                        }
                        Button("Importar SRT/VTT", systemImage: "doc.badge.plus") {
                            showingSubtitleImporter = true
                        }
                        Button("Compartilhar SRT", systemImage: "square.and.arrow.up") {
                            shareTranscript()
                        }
                        .disabled(transcript.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isTranscribing)
                }
            }
            .fileImporter(
                isPresented: $showingSubtitleImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                importSubtitle(result)
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .sheet(item: $correctionPreview) { result in
                TranscriptCorrectionSheet(result: result) { corrected in
                    applyingCorrection = true
                    transcript = corrected.srt
                    onCorrected(corrected.srt, corrected.words)
                    correctionSummary = "\(corrected.corrections.count) correções aplicadas."
                    DispatchQueue.main.async { applyingCorrection = false }
                }
            }
        }
    }

    @MainActor
    private func transcribe() async {
        isTranscribing = true
        errorMessage = nil
        defer { isTranscribing = false }

        do {
            let result = try await TranscriptionService.shared.transcribeVideoSequence(
                project.transcriptionSources,
                localeIdentifier: localeIdentifier,
                allowServer: allowServer
            )
            transcript = SubtitleFile.srt(from: result.cues)
            onWords(result.cues.flatMap(\.words))
            if !result.skippedClips.isEmpty {
                errorMessage = "Alguns clipes não tinham fala/áudio e foram pulados: \(result.skippedClips.joined(separator: "; "))"
            }
        } catch {
            errorMessage = "Falha na transcrição: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func prepareCorrection() async {
        isCorrecting = true
        errorMessage = nil
        correctionSummary = nil
        defer { isCorrecting = false }

        do {
            let cues = try SubtitleFile.parse(transcript)
            let storedWords = currentWords()
            let storedText = normalizedForComparison(storedWords.map(\.text).joined(separator: " "))
            let visibleText = normalizedForComparison(cues.map(\.text).joined(separator: " "))
            let words = !storedWords.isEmpty && storedText == visibleText ? storedWords : cues.flatMap {
                $0.words.isEmpty ? TranscriptWord.spread($0.text, from: $0.startTime, to: $0.endTime) : $0.words
            }
            let result = TranscriptCorrectionService.shared.correct(
                words: words,
                localeIdentifier: localeIdentifier
            )
            if result.changed {
                correctionPreview = result
            } else {
                correctionSummary = "Nenhuma correção necessária."
            }
        } catch {
            errorMessage = "Não foi possível corrigir o texto: \(error.localizedDescription)"
        }
    }

    private func normalizedForComparison(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func importSubtitle(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let ext = url.pathExtension.lowercased()
            guard ext == "srt" || ext == "vtt" else {
                throw TranscriptionService.TranscriptionError.invalidSubtitleFile
            }

            let accessGranted = url.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let contents = try String(contentsOf: url, encoding: .utf8)
            let cues = try SubtitleFile.parse(contents)
            transcript = SubtitleFile.srt(from: cues)
            onWords(cues.flatMap { TranscriptWord.spread($0.text, from: $0.startTime, to: $0.endTime) })
            errorMessage = nil
        } catch {
            if (error as NSError).code != NSUserCancelledError {
                errorMessage = "Falha ao importar legenda: \(error.localizedDescription)"
            }
        }
    }

    private func applyCaptions() {
        do {
            let cues = try SubtitleFile.parse(transcript)
            onApplyCaptions(cues, dynamicCaptions)
            dismiss()
        } catch {
            errorMessage = "Não foi possível ler as legendas: \(error.localizedDescription)"
        }
    }

    private func shareTranscript() {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(project.name.replacingOccurrences(of: "/", with: "-"))_transcricao.srt")
            guard let data = transcript.data(using: .utf8) else {
                throw TranscriptionService.TranscriptionError.invalidSubtitleFile
            }
            try data.write(to: url, options: .atomic)
            shareItem = TranscriptShareItem(url: url)
        } catch {
            errorMessage = "Falha ao preparar o SRT: \(error.localizedDescription)"
        }
    }
}

private struct TranscriptCorrectionSheet: View {
    let result: TranscriptCorrectionResult
    let onApply: (TranscriptCorrectionResult) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("\(result.corrections.count) alterações sugeridas") {
                    ForEach(result.corrections.prefix(120)) { correction in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: correction.kind == .spelling ? "checkmark.circle" : "text.bubble")
                                .foregroundStyle(correction.kind == .spelling ? Color.accentColor : Color.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(correction.original) → \(correction.replacement)")
                                    .font(.subheadline.weight(.medium))
                                Text("\(correction.kind.rawValue) • \(clock(correction.time))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if result.corrections.count > 120 {
                        Text("E mais \(result.corrections.count - 120) correções…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Prévia do texto corrigido") {
                    Text(result.srt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Corrigir texto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar") {
                        onApply(result)
                        dismiss()
                    }
                }
            }
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct TranscriptShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
