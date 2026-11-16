import SwiftUI

/// Edit the video by its words: strike words or accept silence/filler suggestions to cut them.
struct TranscriptEditorView: View {
    let words: [TranscriptWord]
    let onRemove: ([ClosedRange<Double>]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.text
    @State private var struck: Set<Int> = []
    @State private var minSilence = 0.8
    @State private var includeFillers = true
    @State private var rejected: Set<String> = []

    enum Mode: String, CaseIterable, Identifiable {
        case text = "Texto"
        case suggestions = "Sugestões"
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
                } else {
                    suggestionsMode
                }
            }
            .padding()
            .navigationTitle("Editar pela fala")
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
            ScrollView {
                WordFlowLayout(spacing: 4) {
                    ForEach(words.indices, id: \.self) { index in
                        let isStruck = struck.contains(index)
                        Text(words[index].text)
                            .strikethrough(isStruck, color: .red)
                            .foregroundStyle(isStruck ? Color.red : Color.primary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                isStruck ? Color.red.opacity(0.15) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                            .onTapGesture {
                                if isStruck { struck.remove(index) } else { struck.insert(index) }
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var suggestionsMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Silêncio maior que \(String(format: "%.1f", minSilence))s")
                    .font(.footnote)
                Slider(value: $minSilence, in: 0.4...2.0, step: 0.1)
            }
            Toggle("Vícios de linguagem (né, tipo, hum, é…)", isOn: $includeFillers)
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

    private var applyBar: some View {
        let ranges = mode == .text ? struckRanges : acceptedRanges
        let count = mode == .text ? struck.count : ranges.count
        let label = mode == .text ? "Cortar \(count) palavra(s)" : "Aplicar \(count) sugestão(ões)"
        return Button {
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
        .padding()
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
        let pad = 0.15
        if let first = words.first, first.start >= minSilence {
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
                if gap >= minSilence {
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
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private var acceptedRanges: [ClosedRange<Double>] {
        suggestions.filter { !rejected.contains($0.id) }.map(\.range)
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
