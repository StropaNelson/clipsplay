import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionView: View {
    let project: Project
    let onTranscriptChange: (String) -> Void
    let onApplyCaptions: ([TranscriptCue], Bool) -> Void
    let onWords: ([TranscriptWord]) -> Void

    init(
        project: Project,
        onTranscriptChange: @escaping (String) -> Void,
        onApplyCaptions: @escaping ([TranscriptCue], Bool) -> Void,
        onWords: @escaping ([TranscriptWord]) -> Void = { _ in }
    ) {
        self.project = project
        self.onTranscriptChange = onTranscriptChange
        self.onApplyCaptions = onApplyCaptions
        self.onWords = onWords
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
            .onChange(of: transcript) { onTranscriptChange($0) }
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
        }
    }

    @MainActor
    private func transcribe() async {
        isTranscribing = true
        errorMessage = nil
        defer { isTranscribing = false }

        do {
            let cues = try await TranscriptionService.shared.transcribeVideo(
                at: project.sourceVideoFileURL,
                localeIdentifier: localeIdentifier,
                allowServer: allowServer
            )
            transcript = SubtitleFile.srt(from: cues)
            onWords(cues.flatMap(\.words))
        } catch {
            errorMessage = "Falha na transcrição: \(error.localizedDescription)"
        }
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

private struct TranscriptShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
