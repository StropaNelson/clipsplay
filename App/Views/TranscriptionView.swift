import SwiftUI
import UniformTypeIdentifiers

struct TranscriptionView: View {
    let project: Project

    @Environment(\.dismiss) private var dismiss
    @State private var transcript = ""
    @State private var isTranscribing = false
    @State private var showingSubtitleImporter = false
    @State private var shareItem: TranscriptShareItem?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
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

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .navigationTitle("Transcrição")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("Transcrever no dispositivo", systemImage: "waveform") {
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
            let cues = try await TranscriptionService.shared.transcribeVideo(at: project.sourceVideoFileURL)
            transcript = SubtitleFile.srt(from: cues)
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
            transcript = SubtitleFile.srt(from: try SubtitleFile.parse(contents))
            errorMessage = nil
        } catch {
            if (error as NSError).code != NSUserCancelledError {
                errorMessage = "Falha ao importar legenda: \(error.localizedDescription)"
            }
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
