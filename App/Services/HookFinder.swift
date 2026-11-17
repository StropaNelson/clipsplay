import Foundation

enum HookPurpose {
    case opening
    case closing
}

/// A short candidate trecho suggested for a vinheta, in asset-local seconds.
struct HookSuggestion: Identifiable, Hashable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
    let reasons: [String]
    let score: Double

    var duration: Double { end - start }
}

enum HookFinder {
    private static let closingLexicon: Set<String> = [
        "inscreva", "inscrever", "curte", "curtir", "comenta", "comentar",
        "compartilha", "compartilhar", "próximo", "próxima", "valeu",
        "obrigado", "obrigada", "tchau", "até", "fechou", "link",
        "segue", "seguir", "ativa", "sininho"
    ]

    private static let sentenceFinals: Set<Character> = [".", "?", "!", "…"]

    /// Suggests short, hook-like trechos from a transcript in asset-local time.
    static func suggest(
        words: [TranscriptWord],
        duration: Double,
        purpose: HookPurpose,
        minLength: Double = 3,
        maxLength: Double = 10,
        limit: Int = 5
    ) -> [HookSuggestion] {
        let sorted = words.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }

        // Sentence boundaries: punctuation or a ≥ 0.6 s gap; last word always ends one.
        var sentenceStarts: [Int] = [0]
        var sentenceEnds: [Int] = []
        for index in 0..<sorted.count {
            let isLast = index == sorted.count - 1
            let boundary = isLast
                || isSentenceFinal(sorted[index].text)
                || (sorted[index + 1].start - sorted[index].end) >= 0.6
            if boundary {
                sentenceEnds.append(index)
                if !isLast { sentenceStarts.append(index + 1) }
            }
        }
        let sentences = zip(sentenceStarts, sentenceEnds).map { ($0, $1) }

        // Candidates: sentence-aligned prefixes with span inside [minLength, maxLength].
        var ranges: [(Int, Int)] = []
        for (startIndex, endIndex) in sentences {
            var cursor = startIndex
            while cursor <= endIndex {
                let span = sorted[cursor].end - sorted[startIndex].start
                if span > maxLength { break }
                if span >= minLength { ranges.append((startIndex, cursor)) }
                cursor += 1
            }
        }
        if ranges.isEmpty {
            // Fallback when no sentence-aligned candidate fits: longest word
            // prefix from each sentence start, even across sentence ends.
            for (startIndex, _) in sentences {
                var best: (Int, Int)?
                var cursor = startIndex
                while cursor < sorted.count {
                    let span = sorted[cursor].end - sorted[startIndex].start
                    if span > maxLength { break }
                    if span >= minLength { best = (startIndex, cursor) }
                    cursor += 1
                }
                if let best = best { ranges.append(best) }
            }
        }

        var candidates: [HookSuggestion] = []
        for (startIndex, endIndex) in ranges {
            let first = sorted[startIndex]
            let last = sorted[endIndex]
            var start = max(0, first.start - 0.15)
            var end = min(duration, last.end + 0.25)
            if endIndex + 1 < sorted.count {
                end = min(end, sorted[endIndex + 1].start)
            }
            start = min(start, end)
            let rangeWords = sorted[startIndex...endIndex]
            let tokens = rangeWords.flatMap { ClipSuggestionEngine.normalizedTokens($0.text) }
            let joinedTokens = " " + tokens.joined(separator: " ") + " "
            let text = rangeWords.map { $0.text }.joined(separator: " ")

            var score = 0.0
            var reasons: [String] = []
            let span = end - start
            let endsWithPunctuation = last.text.last.map { sentenceFinals.contains($0) } == true
            let endsDangling = tokens.last.map { ClipSuggestionEngine.danglingEndings.contains($0) } == true
            let startsWithFiller = tokens.first.map { ClipSuggestionEngine.fillerWords.contains($0) } == true

            switch purpose {
            case .opening:
                let lexiconHits = ClipSuggestionEngine.hookLexicon.reduce(0) { total, term in
                    term.contains(" ")
                        ? total + ClipSuggestionEngine.occurrenceCount(of: " \(term) ", in: joinedTokens)
                        : total + (tokens.contains(term) ? 1 : 0)
                }
                if lexiconHits > 0 {
                    score += Double(lexiconHits) * 2
                    reasons.append("gancho")
                }
                if rangeWords.contains(where: { $0.text.contains("?") }) {
                    score += 3
                    reasons.append("pergunta")
                }
                if tokens.contains(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) {
                    score += 1.5
                    reasons.append("número")
                }
                if span >= 4 && span <= 8 { score += 1 }
                let wordRate = Double(rangeWords.count) / max(0.001, span)
                if wordRate >= 1.8 && wordRate <= 3.5 { score += 1 }
                if endsWithPunctuation {
                    score += 1
                    reasons.append("frase completa")
                }
                if startsWithFiller { score -= 2 }
                if endsDangling { score -= 3 }
            case .closing:
                let hits = tokens.filter { closingLexicon.contains($0) }.count
                if hits > 0 {
                    score += Double(hits) * 2
                    reasons.append("chamada final")
                }
                if duration > 0 && start >= duration * 0.7 {
                    score += 2
                    reasons.append("perto do fim")
                }
                if endsWithPunctuation {
                    score += 1
                    reasons.append("frase completa")
                }
                if span >= 4 && span <= 8 { score += 1 }
                if endsDangling { score -= 3 }
            }
            candidates.append(HookSuggestion(
                id: candidates.count,
                start: start,
                end: end,
                text: text,
                reasons: reasons,
                score: score
            ))
        }

        // Greedy select: reject candidates overlapping a chosen one by >30% of the shorter.
        var chosen: [HookSuggestion] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let overlaps = chosen.contains { other in
                let shared = min(candidate.end, other.end) - max(candidate.start, other.start)
                guard shared > 0 else { return false }
                let shorter = min(candidate.duration, other.duration)
                return shared > shorter * 0.3
            }
            if !overlaps { chosen.append(candidate) }
            if chosen.count >= limit { break }
        }
        return chosen.enumerated().map { index, item in
            HookSuggestion(id: index, start: item.start, end: item.end,
                           text: item.text, reasons: item.reasons, score: item.score)
        }
    }

    private static func isSentenceFinal(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return sentenceFinals.contains(last)
    }
}
