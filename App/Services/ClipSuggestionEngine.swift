import Foundation

struct ClipSuggestion: Identifiable, Hashable {
    let id = UUID()
    var range: ClosedRange<Double>
    var score: Double
    var snippet: String
    var reasons: [String]
    var kind: ClipSuggestionKind

    var start: Double { range.lowerBound }
    var end: Double { range.upperBound }
    var duration: Double { end - start }
}

enum ClipSuggestionKind: String, CaseIterable, Identifiable, Codable {
    case clips = "Clipes curtos"
    case teasers = "Teasers"
    case segments = "Segmentos"

    var id: String { rawValue }

    var minDuration: Double {
        switch self {
        case .clips: return 15
        case .teasers: return 4
        case .segments: return 120
        }
    }

    var maxDuration: Double {
        switch self {
        case .clips: return 90
        case .teasers: return 15
        case .segments: return 600
        }
    }

    var targetDuration: Double {
        switch self {
        case .clips: return 45
        case .teasers: return 8
        case .segments: return 240
        }
    }

    var defaultCount: Int {
        switch self {
        case .clips: return 8
        case .teasers: return 4
        case .segments: return 4
        }
    }

    var outputName: String {
        switch self {
        case .clips: return "Clipe"
        case .teasers: return "Teaser"
        case .segments: return "Segmento"
        }
    }
}

enum ClipSuggestionEngine {
    static func suggest(
        words: [TranscriptWord],
        sourceDuration: Double,
        kind: ClipSuggestionKind,
        sceneCuts: [Double] = [],
        maxResults: Int? = nil
    ) -> [ClipSuggestion] {
        let limit = maxResults ?? kind.defaultCount
        var candidates = transcriptCandidates(
            words: words,
            sourceDuration: sourceDuration,
            kind: kind,
            sceneCuts: normalizedSceneCuts(sceneCuts, duration: sourceDuration)
        )
        candidates.append(contentsOf: sceneCandidates(
            sourceDuration: sourceDuration,
            kind: kind,
            sceneCuts: normalizedSceneCuts(sceneCuts, duration: sourceDuration)
        ))
        return select(candidates, limit: limit)
    }

    private static func normalizedSceneCuts(_ cuts: [Double], duration: Double) -> [Double] {
        var result: [Double] = []
        for cut in cuts.sorted() where cut > 0.5 && cut < duration - 0.5 {
            if result.last.map({ cut - $0 >= 0.5 }) ?? true { result.append(cut) }
        }
        return result
    }

    private static func transcriptCandidates(
        words input: [TranscriptWord],
        sourceDuration: Double,
        kind: ClipSuggestionKind,
        sceneCuts: [Double]
    ) -> [ClipSuggestion] {
        let words = input
            .filter { $0.end > $0.start && $0.start < sourceDuration }
            .sorted { $0.start < $1.start }
        guard words.count >= 2 else { return [] }

        func sceneNear(_ time: Double) -> Bool {
            sceneCuts.contains { abs($0 - time) <= 2.0 }
        }
        func sentenceEnd(_ text: String) -> Bool {
            text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) != nil
        }
        func boundaryGap(before index: Int) -> Double {
            index > 0 ? words[index].start - words[index - 1].end : .greatestFiniteMagnitude
        }

        var starts: [Int] = []
        var ends: [Int] = []
        for index in words.indices {
            if index == 0 || boundaryGap(before: index) >= 0.45 || sentenceEnd(words[index - 1].text) || sceneNear(words[index].start) {
                starts.append(index)
            }
            let nextGap = index + 1 < words.count ? words[index + 1].start - words[index].end : .greatestFiniteMagnitude
            if index == words.count - 1 || nextGap >= 0.45 || sentenceEnd(words[index].text) || sceneNear(words[index].end) {
                ends.append(index)
            }
        }

        var result: [ClipSuggestion] = []
        for startIndex in starts {
            var considered = 0
            for endIndex in ends where endIndex >= startIndex {
                let rawStart = words[startIndex].start
                let rawEnd = words[endIndex].end
                let duration = rawEnd - rawStart
                guard duration >= kind.minDuration * 0.7 else { continue }
                guard duration <= kind.maxDuration else { break }
                considered += 1
                if considered > 12 { break }
                if let suggestion = makeTranscriptSuggestion(
                    words: Array(words[startIndex...endIndex]),
                    kind: kind,
                    sourceDuration: sourceDuration,
                    sceneCuts: sceneCuts
                ) {
                    result.append(suggestion)
                }
            }
        }
        return result
    }

    private static func makeTranscriptSuggestion(
        words: [TranscriptWord],
        kind: ClipSuggestionKind,
        sourceDuration: Double,
        sceneCuts: [Double]
    ) -> ClipSuggestion? {
        guard let first = words.first, let last = words.last else { return nil }
        let range = max(0, first.start - 0.12)...min(sourceDuration, last.end + 0.12)
        let duration = max(0.1, range.upperBound - range.lowerBound)
        guard duration >= kind.minDuration * 0.7, duration <= kind.maxDuration else { return nil }

        let text = words.map(\.text).joined(separator: " ")
        let tokens = words.flatMap { normalizedTokens($0.text) }
        guard !tokens.isEmpty else { return nil }
        let normalizedText = " " + tokens.joined(separator: " ") + " "

        let density = Double(tokens.count) / duration
        let densityScore = max(0, 1 - abs(density - 2.1) / 2.1)
        let durationScore = max(0, 1 - abs(duration - kind.targetDuration) / kind.targetDuration)
        let uniqueRatio = Double(Set(tokens).count) / Double(tokens.count)
        let lexicalScore = min(1, uniqueRatio / 0.55)
        let singleFillers = tokens.filter { fillerWords.contains($0) }.count
        let phraseFillers = fillerWords.reduce(0) { total, phrase in
            phrase.contains(" ") ? total + occurrenceCount(of: " \(phrase) ", in: normalizedText) : total
        }
        let fillers = singleFillers + phraseFillers
        let fillerPenalty = min(1, Double(fillers) / Double(max(tokens.count, 1)) / 0.12)
        let internalPauses = zip(words, words.dropFirst()).filter { $0.1.start - $0.0.end >= 0.8 }.count
        let pausePenalty = min(1, Double(internalPauses) / max(1, duration / 30))
        let punctuationCount = words.filter { $0.text.rangeOfCharacter(from: CharacterSet(charactersIn: "?!")) != nil }.count
        let punctuationScore = min(1, Double(punctuationCount) / (kind == .teasers ? 1.0 : 2.0))
        let cleanEnding = last.text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) != nil ? 1.0 : 0.55
        let sceneBonus = sceneCuts.contains { abs($0 - first.start) <= 2 || abs($0 - last.end) <= 2 } ? 0.08 : 0

        var score = 18
            + durationScore * 24
            + densityScore * 20
            + lexicalScore * 10
            + punctuationScore * 8
            + cleanEnding * 10
            + sceneBonus * 100
            - fillerPenalty * 10
            - pausePenalty * 8
        score = max(1, min(99, score))

        var reasons: [String] = []
        if punctuationCount > 0 { reasons.append("Pergunta ou ênfase na fala") }
        if density >= 1.5 && density <= 3 { reasons.append("Ritmo de fala constante") }
        if cleanEnding == 1 { reasons.append("Termina em fim de frase") }
        if sceneBonus > 0 { reasons.append("Alinhado a um corte visual") }
        if fillers > 0 { reasons.append("Contém vícios de linguagem") }
        if reasons.isEmpty { reasons.append("Trecho completo detectado pela fala") }

        return ClipSuggestion(
            range: range,
            score: score,
            snippet: String(text.prefix(140)),
            reasons: Array(reasons.prefix(3)),
            kind: kind
        )
    }

    private static func sceneCandidates(
        sourceDuration: Double,
        kind: ClipSuggestionKind,
        sceneCuts: [Double]
    ) -> [ClipSuggestion] {
        guard sourceDuration > kind.minDuration, !sceneCuts.isEmpty else { return [] }
        let boundaries = [0] + sceneCuts + [sourceDuration]
        var result: [ClipSuggestion] = []
        for start in boundaries.indices {
            var considered = 0
            for end in (start + 1)..<boundaries.count {
                let duration = boundaries[end] - boundaries[start]
                guard duration >= kind.minDuration * 0.7 else { continue }
                guard duration <= kind.maxDuration else { break }
                considered += 1
                if considered > 4 { break }
                let durationScore = max(0, 1 - abs(duration - kind.targetDuration) / kind.targetDuration)
                let score = max(1, min(85, 30 + durationScore * 42 + Double(end - start) * 2))
                result.append(ClipSuggestion(
                    range: boundaries[start]...boundaries[end],
                    score: score,
                    snippet: "Corte montado a partir de \(end - start) cena(s)",
                    reasons: ["Limites visuais detectados", "Sem transcrição necessária"],
                    kind: kind
                ))
            }
        }
        return result
    }

    private static func select(_ candidates: [ClipSuggestion], limit: Int) -> [ClipSuggestion] {
        var chosen: [ClipSuggestion] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let duplicates = chosen.contains { existing in
                let overlap = min(existing.end, candidate.end) - max(existing.start, candidate.start)
                return overlap > 0 && overlap / min(existing.duration, candidate.duration) > 0.45
            }
            if !duplicates {
                chosen.append(candidate)
                if chosen.count >= limit { break }
            }
        }
        return chosen.sorted { $0.start < $1.start }
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func occurrenceCount(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    private static let fillerWords: Set<String> = [
        "né", "tipo", "então", "aí", "tá", "ok", "hum", "hm", "uh", "ah", "éé", "eee",
        "assim", "basicamente", "literalmente", "na verdade", "quer dizer", "sabe"
    ]
}
