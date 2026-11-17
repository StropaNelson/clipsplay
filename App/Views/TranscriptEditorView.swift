import SwiftUI

/// Edit the video by its words: strike words or accept silence/filler suggestions to cut them.
struct TranscriptEditorView: View {
    let words: [TranscriptWord]
    let onRemove: ([ClosedRange<Double>]) -> Void
    var onSeekWord: (Double) -> Void = { _ in }
    var onMarkTopics: ([Double]) -> Void = { _ in }
    var onCreateEpisodes: ([Double]) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.suggestions
    @State private var struck: Set<Int> = []
    @State private var minSilence = 0.8
    @State private var includeFillers = true
    @State private var includeRepetitions = true
    @State private var margin = 0.15
    @State private var level = CutLevel.equilibrado
    @State private var search = ""
    @State private var rejected: Set<String> = []

    enum CutLevel: String, CaseIterable, Identifiable {
        case conservador = "Conservador"
        case equilibrado = "Equilibrado"
        case intenso = "Intenso"
        var id: String { rawValue }

        var silence: Double { self == .conservador ? 1.2 : self == .equilibrado ? 0.8 : 0.5 }
        var margin: Double { self == .conservador ? 0.25 : self == .equilibrado ? 0.15 : 0.1 }
        var fillers: Bool { self != .conservador }
        var repetitions: Bool { true }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case suggestions = "Sugestões"
        case text = "Texto"
        case topics = "Assuntos"
        var id: String { rawValue }
    }

    struct Suggestion: Identifiable {
        let id: String
        let title: String
        let detail: String
        let icon: String
        let range: ClosedRange<Double>
    }

    private static let fillers: Set<String> = [
        "é", "eh", "ehh", "éh", "hum", "hm", "hmm", "humm", "ahn", "ah", "ahh", "uh", "uhm", "um", "né", "tipo", "tá"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Modo", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if mode == .text {
                    textMode
                } else if mode == .suggestions {
                    suggestionsMode
                } else {
                    topicsMode
                }
            }
            .padding()
            .navigationTitle("Autoedição por fala")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { applyBar }
        }
    }

    private var textMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Toque nas palavras que quer cortar do vídeo. Vale para todos os episódios.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Procurar palavra no vídeo", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .padding(8)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            ScrollView {
                WordFlowLayout(spacing: 4) {
                    ForEach(words.indices, id: \.self) { index in
                        let isStruck = struck.contains(index)
                        let matches = !search.isEmpty && words[index].text.lowercased().trimmingCharacters(in: .punctuationCharacters).contains(search.lowercased())
                        Text(words[index].text)
                            .strikethrough(isStruck, color: .red)
                            .foregroundStyle(isStruck ? Color.red : Color.primary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                isStruck ? Color.red.opacity(0.15) : matches ? Color.yellow.opacity(0.35) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                            .onTapGesture {
                                if !search.isEmpty && matches {
                                    onSeekWord(words[index].start)
                                    dismiss()
                                } else if isStruck {
                                    struck.remove(index)
                                } else {
                                    struck.insert(index)
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var suggestionsMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Nível de corte", selection: $level) {
                ForEach(CutLevel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: level) { level in
                minSilence = level.silence
                margin = level.margin
                includeFillers = level.fillers
                includeRepetitions = level.repetitions
            }
            HStack {
                Text("Silêncio maior que \(String(format: "%.1f", minSilence))s")
                    .font(.footnote)
                Slider(value: $minSilence, in: 0.4...2.0, step: 0.1)
            }
            Toggle("Vícios de linguagem (né, tipo, hum, é…)", isOn: $includeFillers)
                .font(.footnote)
            Toggle("Frases repetidas e retomadas", isOn: $includeRepetitions)
                .font(.footnote)
            if suggestions.isEmpty {
                Text("Nenhuma sugestão encontrada.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(suggestions) { suggestion in
                    let accepted = !rejected.contains(suggestion.id)
                    Button {
                        if accepted { rejected.insert(suggestion.id) } else { rejected.remove(suggestion.id) }
                    } label: {
                        HStack {
                            Image(systemName: accepted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(accepted ? Color.accentColor : Color.secondary)
                            Image(systemName: suggestion.icon)
                            VStack(alignment: .leading) {
                                Text(suggestion.title)
                                Text(suggestion.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    /// Topic boundaries: long pauses combined with a vocabulary shift between the
    /// surrounding word windows (Jaccard distance over a ~15-word window).
    private var topicBoundaries: [(time: Double, score: Double)] {
        let window = 15
        var result: [(Double, Double)] = []
        for index in words.indices.dropFirst() {
            let gap = words[index].start - words[index - 1].end
            guard gap >= 1.0 else { continue }
            let before = Set(words[max(0, index - window)..<index].map {
                $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
            }.filter { !$0.isEmpty })
            let after = Set(words[index..<min(words.count, index + window)].map {
                $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
            }.filter { !$0.isEmpty })
            let union = before.union(after).count
            guard union > 0 else { continue }
            let distance = 1 - Double(before.intersection(after).count) / Double(union)
            if distance >= 0.5 {
                result.append((words[index].start, distance))
            }
        }
        return result
    }

    private var topicsMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pontos onde uma pausa coincide com mudança de vocabulário — candidatos a dividir em episódios. Toque para ir ao ponto na prévia.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if topicBoundaries.isEmpty {
                Text("Nenhuma mudança de assunto detectada.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(topicBoundaries, id: \.time) { boundary in
                    Button { onSeekWord(boundary.time) } label: {
                        HStack {
                            Image(systemName: "bookmark")
                            Text(Self.clock(boundary.time)).monospacedDigit()
                            Spacer()
                            Text("mudança \(String(format: "%.0f%%", boundary.score * 100))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private var applyBar: some View {
        if mode == .topics {
            return AnyView(
                VStack(spacing: 8) {
                    Button {
                        onCreateEpisodes(topicBoundaries.map(\.time))
                        dismiss()
                    } label: {
                        Label("Criar episódios nos \(topicBoundaries.count) limite(s)", systemImage: "rectangle.split.3x1")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(topicBoundaries.isEmpty)
                    Text("Recria os episódios do projeto inteiro, como em Regenerar.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        onMarkTopics(topicBoundaries.map(\.time))
                        dismiss()
                    } label: {
                        Text("Só marcar na linha do tempo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(topicBoundaries.isEmpty)
                }
                .padding()
            )
        }
        let ranges = mode == .text ? struckRanges : acceptedRanges
        let count = mode == .text ? struck.count : ranges.count
        let label = mode == .text ? "Cortar \(count) palavra(s)" : "Aplicar \(count) sugestão(ões)"
        return AnyView(
            VStack(spacing: 8) {
                if mode == .suggestions {
                    Button {
                        onRemove(acceptedSilenceRanges)
                        dismiss()
                    } label: {
                        Label("Só cortar pausas (\(acceptedSilenceRanges.count))", systemImage: "speaker.slash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(acceptedSilenceRanges.isEmpty)
                }
                Button {
                    onRemove(ranges)
                    dismiss()
                } label: {
                    Label(label, systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(ranges.isEmpty)
            }
            .padding()
        )
    }

    private func wordRange(_ index: Int) -> ClosedRange<Double> {
        let word = words[index]
        let previousEnd = index > 0 ? words[index - 1].end : 0
        let nextStart = index + 1 < words.count ? words[index + 1].start : word.end + 0.1
        let start = max(previousEnd, word.start - 0.05)
        let end = max(start, min(nextStart, word.end + 0.1))
        return start...end
    }

    private var struckRanges: [ClosedRange<Double>] {
        struck.sorted().map(wordRange)
    }

    private var suggestions: [Suggestion] {
        var result: [Suggestion] = []
        let pad = margin
        if let first = words.first, first.start - pad > 0, first.start >= minSilence {
            result.append(Suggestion(
                id: "silence-start",
                title: "Silêncio no início (\(String(format: "%.1f", first.start))s)",
                detail: "Antes de “\(first.text)”",
                icon: "speaker.slash",
                range: 0...(first.start - pad)
            ))
        }
        for index in words.indices {
            let word = words[index]
            if index + 1 < words.count {
                let next = words[index + 1]
                let gap = next.start - word.end
                if gap >= minSilence, next.start - pad > word.end + pad {
                    result.append(Suggestion(
                        id: "silence-\(index)",
                        title: "Silêncio de \(String(format: "%.1f", gap))s",
                        detail: "\(Self.clock(word.end)) · entre “\(word.text)” e “\(next.text)”",
                        icon: "speaker.slash",
                        range: (word.end + pad)...(next.start - pad)
                    ))
                }
            }
            let normalized = word.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if includeFillers, Self.fillers.contains(normalized) {
                result.append(Suggestion(
                    id: "filler-\(index)",
                    title: "“\(word.text)”",
                    detail: Self.clock(word.start),
                    icon: "text.badge.xmark",
                    range: wordRange(index)
                ))
            }
        }
        if includeRepetitions {
            result.append(contentsOf: retakes(padding: pad))
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Detects repeated phrases: the speaker restarts a sentence nearby, so the earlier
    /// (abandoned) attempt is the one to cut. Groups words into phrases, then compares
    /// each phrase with the next ones.
    private func retakes(padding: Double) -> [Suggestion] {
        var phrases: [[Int]] = []
        var current: [Int] = []
        for index in words.indices {
            if let last = current.last,
               words[index].start - words[last].end > 0.6
                || words[last].text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) != nil {
                phrases.append(current)
                current = []
            }
            current.append(index)
        }
        if !current.isEmpty { phrases.append(current) }

        func tokens(_ phrase: [Int]) -> [String] {
            phrase.map { words[$0].text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        }
        func similar(_ a: [String], _ b: [String]) -> Bool {
            guard min(a.count, b.count) >= 4 else { return false }
            let overlap = Set(a).intersection(Set(b)).count
            return Double(overlap) / Double(max(a.count, b.count)) >= 0.6
        }

        var result: [Suggestion] = []
        var used: Set<Int> = []
        for i in phrases.indices {
            guard !used.contains(i), phrases[i].count >= 4 else { continue }
            let upperBound = min(i + 3, phrases.count - 1)
            guard i + 1 <= upperBound else { continue }
            for j in (i + 1)...upperBound where similar(tokens(phrases[i]), tokens(phrases[j])) {
                let first = phrases[i].first!, last = phrases[i].last!
                let start = max(words[first].start - padding, first > 0 ? words[first - 1].end : 0)
                let end = min(words[last].end + padding, words[phrases[j].first!].start)
                guard end > start else { break }
                let text = tokens(phrases[i]).prefix(4).joined(separator: " ")
                result.append(Suggestion(
                    id: "retake-\(i)",
                    title: "Retomada: “\(text)…”",
                    detail: "\(Self.clock(words[first].start)) · repetida em \(Self.clock(words[phrases[j].first!].start))",
                    icon: "arrow.uturn.backward",
                    range: start...end
                ))
                used.insert(i)
                break
            }
        }
        return result
    }

    private var acceptedRanges: [ClosedRange<Double>] {
        suggestions.filter { !rejected.contains($0.id) }.map(\.range)
    }

    private var acceptedSilenceRanges: [ClosedRange<Double>] {
        suggestions.filter { $0.id.hasPrefix("silence-") && !rejected.contains($0.id) }.map(\.range)
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct WordFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
