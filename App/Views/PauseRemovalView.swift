import SwiftUI
import AVFoundation

/// Reviews detected silences over the editable source and removes the selected
/// ones from the chosen episode (or all outputs).
struct PauseRemovalView: View {
    let project: Project
    let episodes: [Episode]
    let selectedEpisodeID: UUID?
    let coverage: (Episode) -> [ClosedRange<Double>]
    let onApply: ([ClosedRange<Double>], Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var energy: [Float] = []
    @State private var measuring = true
    @State private var intensity = 1
    @State private var minPause = 0.7
    @State private var margin = 0.15
    @State private var allOutputs = false
    @State private var pauses: [DetectedPause] = []
    @State private var unchecked: Set<Int> = []
    @State private var previewPlayer: AVPlayer?

    private let energyInterval = 0.1
    private let intensities: [(label: String, minPause: Double, margin: Double)] = [
        ("Leve", 1.2, 0.25),
        ("Médio", 0.7, 0.15),
        ("Forte", 0.4, 0.08)
    ]

    init(project: Project, episodes: [Episode], selectedEpisodeID: UUID?,
         coverage: @escaping (Episode) -> [ClosedRange<Double>],
         onApply: @escaping ([ClosedRange<Double>], Set<UUID>) -> Void) {
        self.project = project
        self.episodes = episodes
        self.selectedEpisodeID = selectedEpisodeID
        self.coverage = coverage
        self.onApply = onApply
    }

    private var usableWords: [TranscriptWord] {
        guard let words = project.transcriptWords,
              let transcriptDuration = project.transcriptSequenceDuration,
              abs(transcriptDuration - project.sequenceSourceDuration) <= 0.5 else { return [] }
        return words
    }

    private var scopeEpisodes: [Episode] {
        if allOutputs || episodes.count <= 1 { return episodes }
        return episodes.filter { $0.id == selectedEpisodeID }
    }

    private var scopeCoverage: [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for range in scopeEpisodes.flatMap({ coverage($0) }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.upperBound > range.lowerBound else { continue }
            if let last = merged.last, range.lowerBound <= last.upperBound + 0.02 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private var checkedPauses: [DetectedPause] {
        pauses.filter { !unchecked.contains($0.id) }
    }

    private var scopeDuration: Double {
        scopeCoverage.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    private var removedDuration: Double {
        checkedPauses.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section {
                        Text("Deixe o vídeo mais dinâmico removendo silêncios. O original não é apagado e dá para desfazer.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text(usableWords.isEmpty
                                 ? "Só áudio — transcreva para mais precisão"
                                 : "Fala + áudio")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                            if measuring {
                                Spacer()
                                ProgressView()
                                Text("Medindo o áudio…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Intensidade") {
                        Picker("Intensidade", selection: $intensity) {
                            ForEach(intensities.indices, id: \.self) { index in
                                Text(intensities[index].label).tag(index)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: intensity) { value in
                            minPause = intensities[value].minPause
                            margin = intensities[value].margin
                        }

                        DisclosureGroup("Ajuste fino") {
                            VStack(alignment: .leading) {
                                Text("Pausa mínima: \(String(format: "%.1f", minPause)) s")
                                    .font(.caption)
                                Slider(value: $minPause, in: 0.3...2.0, step: 0.1)
                                Text("Margem: \(String(format: "%.2f", margin)) s")
                                    .font(.caption)
                                Slider(value: $margin, in: 0...0.5, step: 0.02)
                            }
                            .padding(.top, 4)
                        }
                    }

                    if episodes.count > 1 {
                        Section("Escopo") {
                            Picker("Escopo", selection: $allOutputs) {
                                Text("Esta saída").tag(false)
                                Text("Todas as saídas (\(episodes.count))").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    Section {
                        Text(summary)
                            .font(.subheadline.weight(.medium))
                        overviewBar
                            .frame(height: 18)
                        HStack {
                            Button("Marcar todas") { unchecked = [] }
                                .buttonStyle(.borderless)
                            Spacer()
                            Button("Desmarcar todas") { unchecked = Set(pauses.map(\.id)) }
                                .buttonStyle(.borderless)
                        }
                        .font(.caption)
                    }

                    Section("Pausas encontradas (\(pauses.count))") {
                        ForEach(pauses) { pause in
                            pauseRow(pause)
                        }
                    }
                }
                Button {
                    apply()
                } label: {
                    Text("Remover \(checkedPauses.count) pausas")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(checkedPauses.isEmpty)
                .padding()
            }
            .navigationTitle("Remover pausas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
            .task {
                let profile = await AudioEnergyAnalyzer.sequenceProfile(project: project, interval: energyInterval)
                await MainActor.run {
                    energy = profile
                    measuring = false
                    recompute()
                }
            }
            .onChange(of: minPause) { _ in recompute() }
            .onChange(of: margin) { _ in recompute() }
            .onChange(of: allOutputs) { _ in recompute() }
            .onDisappear {
                previewPlayer?.pause()
            }
        }
    }

    private var summary: String {
        "\(checkedPauses.count) pausas · remove \(clock(removedDuration)) · \(clock(scopeDuration)) → \(clock(max(0, scopeDuration - removedDuration)))"
    }

    private var overviewBar: some View {
        GeometryReader { geo in
            let total = max(0.001, scopeDuration)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                ForEach(checkedPauses) { pause in
                    let position = barPosition(for: pause.start, total: total, width: geo.size.width)
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: max(2, geo.size.width * CGFloat(pause.duration / total)), height: geo.size.height)
                        .offset(x: position)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func barPosition(for time: Double, total: Double, width: CGFloat) -> CGFloat {
        // Position pauses relative to their order inside the coverage, not absolute time.
        var covered: Double = 0
        for range in scopeCoverage {
            let length = range.upperBound - range.lowerBound
            if time <= range.upperBound {
                covered += max(0, min(length, time - range.lowerBound))
                break
            }
            covered += length
        }
        return width * CGFloat(covered / total)
    }

    private func pauseRow(_ pause: DetectedPause) -> some View {
        HStack(spacing: 10) {
            Button {
                if unchecked.contains(pause.id) {
                    unchecked.remove(pause.id)
                } else {
                    unchecked.insert(pause.id)
                }
            } label: {
                Image(systemName: unchecked.contains(pause.id) ? "square" : "checkmark.square.fill")
                    .foregroundStyle(unchecked.contains(pause.id) ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)

            Text("\(clock(pause.start)) · \(String(format: "%.1f", pause.duration)) s")
                .font(.subheadline.monospacedDigit())
            Text(pause.kind.rawValue)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            Spacer()
            Button {
                preview(pause)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }

    private func recompute() {
        guard !measuring else { return }
        pauses = PauseDetector.detect(
            words: usableWords,
            energy: energy,
            interval: energyInterval,
            totalDuration: project.sequenceSourceDuration,
            minPause: minPause,
            margin: margin,
            coverage: scopeCoverage
        )
        unchecked = []
    }

    private func preview(_ pause: DetectedPause) {
        guard let location = project.sourceLocation(at: pause.start),
              let clip = project.sourceClips.first(where: {
                  pause.start >= $0.sequenceStartTime + $0.startTime && pause.start < $0.sequenceStartTime + $0.endTime
              }) else { return }
        let seekStart = max(clip.startTime, location.time - 1.5)
        let player = AVPlayer(url: location.url)
        previewPlayer?.pause()
        previewPlayer = player
        player.seek(to: CMTime(seconds: seekStart, preferredTimescale: 600))
        // Map the global preview end back to a local time in this source file.
        let localEnd = min(clip.endTime, location.time + ((pause.end + 1.5) - pause.start))
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: localEnd, preferredTimescale: 600)
        player.play()
    }

    private func apply() {
        let ranges = checkedPauses.map { $0.start...$0.end }
        onApply(ranges, Set(scopeEpisodes.map(\.id)))
        dismiss()
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
